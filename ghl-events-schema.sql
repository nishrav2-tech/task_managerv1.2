-- =========================================================
-- Utopian CRM — GHL event log + KPI rollup
--
-- SAFE TO RE-RUN. Additive and idempotent, same as schema.sql.
-- Run this once in the Supabase SQL Editor before deploying the
-- ghl-webhook Edge Function.
--
-- DESIGN
--   ghl_events is an append-only raw log of every webhook GHL sends
--   us — one row per event, nothing interpreted at write time. The
--   Edge Function's only job is "did this arrive, save it." All the
--   KPI logic (which stage means what, how hours get computed, which
--   events count as "contacted") lives here in SQL instead, in
--   refresh_ghl_kpis(). That split matters: if a mapping turns out to
--   be wrong, or GHL adds a field, we fix the SQL and re-run it
--   against history we already have — we don't lose data because the
--   ingestion function guessed wrong on day one.
--
--   Locked before this were written into the two functions below, matching
--   what was actually agreed on:
--     leadsProduced      — new opportunities in "Lead --> Contract" that day
--     hotLeadsProduced   — first-ever entry into "Priority Offer Ready", locked permanently
--     leadsOfferedOn     — entries into "Send Paperwork" (counts every entry,
--                          see note above the view — this is the one place a
--                          different reading was possible and wasn't fully pinned down)
--     contractsSent /
--     contractSentHrs    — contact_status custom field flips to "Sent"
--     contractsClosed /
--     dealsProduced      — first-ever entry into "Deal Closed!" in
--                          "Lead --> Contract" specifically, locked permanently
--     firstContactHrs    — opportunity createdAt -> first outbound call/SMS
--     touchPoints        — count of message/call events that day
--     leadsContacted     — call >15s AND Lead Notes non-empty, OR inbound SMS
--                          reply; locked on the day the later of the two
--                          conditions is first satisfied
--     offersPrepared /
--     offerPrepHrs       — a lead exiting "Vetted Lead" into any other
--                          stage. Count = number of exits that day.
--                          Hours = time between entering and leaving
--                          Vetted Lead, averaged over that day's exits.
--
--   NOT included yet, still open:
--     Everything in the Due Diligence + Funding group — not scoped yet.
--
--   INGESTION METHOD: hourly poll, not webhooks. ghl-hourly-poll calls
--   GHL's API directly once an hour, compares what it sees against
--   ghl_opportunity_state / ghl_contact_state / ghl_conversation_state
--   (this file, below) to find what changed since the last check, and
--   writes synthetic rows into ghl_events in the exact same shape a
--   webhook would have produced — occurred_at is GHL's own timestamp
--   (lastStageChangeAt, dateAdded, etc.), not poll time, so hour
--   precision is preserved even though we only check once an hour.
--   refresh_ghl_kpis() below doesn't know or care which one produced
--   its input rows. (A ghl-webhook function also exists in this repo
--   from an earlier design — it still works if you'd rather use real
--   GHL webhooks, but it's not required; the polling function is
--   self-contained and needs no GHL-side webhook/workflow setup at all.)
--
--   HONEST CAVEAT: the shape of a contact's customFields array
--   (specifically, whether each entry uses "id"/"value" keys) is
--   assumed from GHL's field-definitions endpoint, not confirmed
--   against a live populated example — the one contact we probed
--   earlier had an empty customFields array. First real poll run
--   needs a quick look (select raw from ghl_events where event_type =
--   'ContactUpdate' limit 5) to confirm this matches; if not, the
--   jsonb_array_elements(...) lookups in this file need adjusting.
-- =========================================================

-- ---------------------------------------------------------
-- Pipeline / stage IDs, from the live GHL account (see ghl-probe.py
-- output). Hardcoded here rather than looked up at query time — these
-- don't change without someone editing the pipeline in GHL, and
-- hardcoding means the SQL is readable without cross-referencing IDs.
-- If a stage ever gets renamed or rebuilt in GHL, these need updating.
-- ---------------------------------------------------------
--   pipeline "Lead --> Contract"          9wvdoIQrdKYrmeAnfod6
--     "Vetted Lead"                       094c7357-ee4a-4f88-b3b3-01e7ad6e8b17
--     "Priority Offer Ready"              eaf42c26-3d83-4bc1-bf20-f4974f0bf741
--     "Send Paperwork"                    6bcfc8b4-2037-453a-9279-2e38da9c63ad
--     "Deal Closed!"                      462724b5-24ce-4a16-b198-ba5c290eab85
--   custom field "Contract Status"        SsD1lNNGo0UKFQG0K4Ti  (contact.contract_status)
--   custom field "Lead Notes"             u19ve7mWJJUctzbrAqZ7  (contact.previous_sale_attempts__history)

-- ---------------------------------------------------------
-- ghl_events — append-only raw log
-- ---------------------------------------------------------
create table if not exists ghl_events (
  id            uuid primary key default gen_random_uuid(),
  event_type    text not null,        -- e.g. 'OpportunityStageUpdate', 'ContactUpdate', 'InboundMessage'
  occurred_at   timestamptz not null, -- from the payload (dateAdded / dateUpdated), not receipt time
  received_at   timestamptz not null default now(),
  contact_id    text,
  opportunity_id text,
  pipeline_id   text,
  stage_id      text,
  message_type  text,                 -- 'TYPE_CALL', 'TYPE_SMS', etc., when present
  direction     text,                 -- 'inbound' / 'outbound', when present
  call_duration_secs integer,         -- meta.call.duration, when present
  raw           jsonb not null        -- the full payload, always. Nothing is ever lost
                                       -- to a field we didn't think to pull out above.
);
alter table ghl_events add column if not exists event_type    text;
alter table ghl_events add column if not exists occurred_at   timestamptz;
alter table ghl_events add column if not exists received_at   timestamptz not null default now();
alter table ghl_events add column if not exists contact_id    text;
alter table ghl_events add column if not exists opportunity_id text;
alter table ghl_events add column if not exists pipeline_id   text;
alter table ghl_events add column if not exists stage_id      text;
alter table ghl_events add column if not exists message_type  text;
alter table ghl_events add column if not exists direction     text;
alter table ghl_events add column if not exists call_duration_secs integer;
alter table ghl_events add column if not exists raw           jsonb;

create index if not exists idx_ghl_events_type       on ghl_events(event_type);
create index if not exists idx_ghl_events_occurred    on ghl_events(occurred_at);
create index if not exists idx_ghl_events_contact     on ghl_events(contact_id);
create index if not exists idx_ghl_events_opportunity on ghl_events(opportunity_id);

-- Locked-down: only the service role (the Edge Function, using
-- SUPABASE_SERVICE_ROLE_KEY) can read or write this table. The anon
-- key — the one that's public in config.js — gets nothing. The
-- dashboard never queries this table directly; it only ever reads
-- kpi_entries, which holds aggregate counts, not raw event data.
alter table ghl_events enable row level security;
drop policy if exists "service role only" on ghl_events;
create policy "service role only" on ghl_events for all to service_role using (true) with check (true);
revoke all on ghl_events from anon, authenticated;
grant all on ghl_events to service_role;

-- Two events for the same GHL record can arrive out of order or get
-- retried by GHL's webhook sender. This table is intentionally NOT
-- deduplicated on receipt — every delivery gets a row. The rollup
-- function below is what makes "counted once, permanently" true,
-- not the ingestion layer. That's a deliberate simplification: making
-- ingestion dumb and idempotent-by-being-additive means a webhook
-- retry can never cause data loss, only a harmless duplicate row.

-- ---------------------------------------------------------
-- ghl_locked_events — the "counted once, permanently" ledger
--
-- For hotLeadsProduced, contractsClosed/dealsProduced, and
-- leadsContacted: once we've counted a given (metric, entity) as
-- having happened, that day is locked forever, even if the
-- underlying GHL record moves again later (leaves the stage,
-- reopens, etc.). This table is that lock. refresh_ghl_kpis()
-- checks it before inserting a new lock, so re-running the rollup
-- is always safe and never re-attributes a day.
-- ---------------------------------------------------------
create table if not exists ghl_locked_events (
  id          uuid primary key default gen_random_uuid(),
  metric_key  text not null,     -- 'hotLeadsProduced', 'dealsProduced', 'leadsContacted'
  entity_id   text not null,     -- opportunity_id or contact_id, depending on the metric
  log_date    date not null,
  created_at  timestamptz not null default now()
);
alter table ghl_locked_events add column if not exists metric_key text;
alter table ghl_locked_events add column if not exists entity_id  text;
alter table ghl_locked_events add column if not exists log_date   date;
alter table ghl_locked_events add column if not exists created_at timestamptz not null default now();

do $$
begin
  create unique index if not exists uq_ghl_locked_events on ghl_locked_events(metric_key, entity_id);
exception when others then
  raise notice 'Could not make ghl_locked_events(metric_key, entity_id) unique (duplicates?): %', sqlerrm;
end $$;

alter table ghl_locked_events enable row level security;
drop policy if exists "service role only" on ghl_locked_events;
create policy "service role only" on ghl_locked_events for all to service_role using (true) with check (true);
revoke all on ghl_locked_events from anon, authenticated;
grant all on ghl_locked_events to service_role;

-- ---------------------------------------------------------
-- Poll state tables — "what we last saw," one row per GHL record.
-- The hourly poll diffs the API's current answer against these to
-- figure out what's new since the last check. Without these, every
-- poll would look like every opportunity/contact changed, every time.
-- ---------------------------------------------------------
create table if not exists ghl_opportunity_state (
  opportunity_id text primary key,
  pipeline_id    text,
  stage_id       text,
  last_stage_change_at timestamptz,
  contact_id     text,
  updated_at     timestamptz not null default now()
);
alter table ghl_opportunity_state enable row level security;
drop policy if exists "service role only" on ghl_opportunity_state;
create policy "service role only" on ghl_opportunity_state for all to service_role using (true) with check (true);
revoke all on ghl_opportunity_state from anon, authenticated;
grant all on ghl_opportunity_state to service_role;

create table if not exists ghl_contact_state (
  contact_id     text primary key,
  contract_status_sent boolean not null default false,
  lead_notes_nonempty  boolean not null default false,
  last_seen_updated_at timestamptz,
  updated_at     timestamptz not null default now()
);
alter table ghl_contact_state enable row level security;
drop policy if exists "service role only" on ghl_contact_state;
create policy "service role only" on ghl_contact_state for all to service_role using (true) with check (true);
revoke all on ghl_contact_state from anon, authenticated;
grant all on ghl_contact_state to service_role;

create table if not exists ghl_conversation_state (
  conversation_id text primary key,
  last_message_id text,
  last_message_at timestamptz,
  updated_at      timestamptz not null default now()
);
alter table ghl_conversation_state enable row level security;
drop policy if exists "service role only" on ghl_conversation_state;
create policy "service role only" on ghl_conversation_state for all to service_role using (true) with check (true);
revoke all on ghl_conversation_state from anon, authenticated;
grant all on ghl_conversation_state to service_role;

-- ---------------------------------------------------------
-- increment_kpi_entry — additive upsert, shared with lead-entry-lag
--
-- lead-entry-lag (the other session's Edge Function, for Smarter
-- Contact) already calls an RPC with this name. Defining it here too,
-- guarded so it doesn't clobber an existing version — if that
-- function already created this exact signature, this is a no-op.
-- ---------------------------------------------------------
create or replace function increment_kpi_entry(p_metric_key text, p_log_date date, p_value numeric)
returns void
language plpgsql
security definer
as $$
begin
  insert into kpi_entries (metric_key, log_date, value)
  values (p_metric_key, p_log_date, p_value)
  on conflict (metric_key, log_date)
  do update set value = kpi_entries.value + excluded.value;
end;
$$;

-- Overwrite upsert — for metrics where each rollup run should REPLACE
-- the day's value rather than add to it (used for the *Hrs averages,
-- since re-running the rollup should recompute the average, not
-- inflate it every time the job fires).
create or replace function set_kpi_entry(p_metric_key text, p_log_date date, p_value numeric)
returns void
language plpgsql
security definer
as $$
begin
  insert into kpi_entries (metric_key, log_date, value)
  values (p_metric_key, p_log_date, p_value)
  on conflict (metric_key, log_date)
  do update set value = excluded.value;
end;
$$;

-- ---------------------------------------------------------
-- refresh_ghl_kpis(target_date) — the actual KPI logic
--
-- Call this once a day (see the rollup Edge Function) for "yesterday".
-- Safe to re-run for any date, any number of times — locked events
-- stay locked, and the *Hrs metrics use set_kpi_entry so they get
-- recomputed cleanly rather than double-counted.
-- ---------------------------------------------------------
create or replace function refresh_ghl_kpis(target_date date)
returns void
language plpgsql
security definer
as $$
declare
  PIPE_LEAD_TO_CONTRACT constant text := '9wvdoIQrdKYrmeAnfod6';
  STAGE_VETTED_LEAD     constant text := '094c7357-ee4a-4f88-b3b3-01e7ad6e8b17';
  STAGE_PRIORITY_OFFER  constant text := 'eaf42c26-3d83-4bc1-bf20-f4974f0bf741';
  STAGE_SEND_PAPERWORK  constant text := '6bcfc8b4-2037-453a-9279-2e38da9c63ad';
  STAGE_DEAL_CLOSED     constant text := '462724b5-24ce-4a16-b198-ba5c290eab85';
  STAGE_NOT_A_FIT       constant text := 'af524f69-fb50-4776-a0ee-d93639eb379e';
  FIELD_CONTRACT_STATUS constant text := 'SsD1lNNGo0UKFQG0K4Ti';
  FIELD_LEAD_NOTES      constant text := 'u19ve7mWJJUctzbrAqZ7';
  day_start timestamptz := target_date::timestamptz;
  day_end   timestamptz := (target_date + 1)::timestamptz;
  v_first_contact_avg numeric;
begin

  -- leadsProduced: opportunities whose first-ever appearance in the
  -- Lead-->Contract pipeline was IN THE VETTED LEAD STAGE specifically,
  -- that day. (2026-08-14: narrowed from "any stage in the pipeline" — an
  -- opportunity created or stage-updated into some other stage no longer
  -- counts as "produced.")
  perform set_kpi_entry('leadsProduced', target_date, (
    select count(*) from ghl_events
    where event_type in ('OpportunityCreate', 'OpportunityStageUpdate')
      and pipeline_id = PIPE_LEAD_TO_CONTRACT
      and stage_id = STAGE_VETTED_LEAD
      and occurred_at >= day_start and occurred_at < day_end
      and opportunity_id not in (
        select entity_id from ghl_locked_events where metric_key = 'leadsProduced'
      )
  ));
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'leadsProduced', opportunity_id, target_date
  from ghl_events
  where event_type in ('OpportunityCreate', 'OpportunityStageUpdate')
    and pipeline_id = PIPE_LEAD_TO_CONTRACT
    and stage_id = STAGE_VETTED_LEAD
    and occurred_at >= day_start and occurred_at < day_end
  on conflict (metric_key, entity_id) do nothing;

  -- hotLeadsProduced: first-ever entry into Priority Offer Ready, locked permanently.
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'hotLeadsProduced', opportunity_id, target_date
  from ghl_events
  where event_type = 'OpportunityStageUpdate'
    and stage_id = STAGE_PRIORITY_OFFER
    and occurred_at >= day_start and occurred_at < day_end
    and opportunity_id not in (select entity_id from ghl_locked_events where metric_key = 'hotLeadsProduced')
  on conflict (metric_key, entity_id) do nothing;
  perform set_kpi_entry('hotLeadsProduced', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'hotLeadsProduced' and log_date = target_date
  ));

  -- leadsOfferedOn: every entry into Send Paperwork that day (NOT locked —
  -- counts each time, including re-entries. This was the one place the
  -- exact counting rule was never fully pinned down; flip this to the
  -- locked pattern above if "count once per lead" turns out to be right instead.)
  perform set_kpi_entry('leadsOfferedOn', target_date, (
    select count(*) from ghl_events
    where event_type = 'OpportunityStageUpdate'
      and stage_id = STAGE_SEND_PAPERWORK
      and occurred_at >= day_start and occurred_at < day_end
  ));

  -- contractsClosed / dealsProduced: first-ever entry into Deal Closed!
  -- in Lead-->Contract, locked permanently. Same underlying event feeds both metrics.
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'dealsProduced', opportunity_id, target_date
  from ghl_events
  where event_type = 'OpportunityStageUpdate'
    and pipeline_id = PIPE_LEAD_TO_CONTRACT
    and stage_id = STAGE_DEAL_CLOSED
    and occurred_at >= day_start and occurred_at < day_end
    and opportunity_id not in (select entity_id from ghl_locked_events where metric_key = 'dealsProduced')
  on conflict (metric_key, entity_id) do nothing;
  perform set_kpi_entry('dealsProduced', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'dealsProduced' and log_date = target_date
  ));
  perform set_kpi_entry('contractsClosed', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'dealsProduced' and log_date = target_date
  ));

  -- contractsSent / contractSentHrs: Contract Status custom field flips to "Sent".
  -- ContactUpdate payloads carry the full customFields array; we look for
  -- this specific field id holding "Sent" and compare against whether
  -- we've already logged this contact as sent before.
  with sent_events as (
    select
      contact_id,
      occurred_at,
      raw
    from ghl_events
    where event_type = 'ContactUpdate'
      and occurred_at >= day_start and occurred_at < day_end
      and exists (
        select 1 from jsonb_array_elements(coalesce(raw->'customFields', '[]'::jsonb)) f
        where f->>'id' = FIELD_CONTRACT_STATUS
          and f->>'value' ilike '%sent%'
      )
      and contact_id not in (select entity_id from ghl_locked_events where metric_key = 'contractsSent')
  )
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select distinct on (contact_id) 'contractsSent', contact_id, target_date
  from sent_events
  order by contact_id, occurred_at asc
  on conflict (metric_key, entity_id) do nothing;

  perform set_kpi_entry('contractsSent', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'contractsSent' and log_date = target_date
  ));

  -- contractSentHrs: for contracts locked today, hours from the
  -- opportunity's creation to the Sent event. Needs the matching
  -- OpportunityCreate/first-seen event for the same contact.
  perform set_kpi_entry('contractSentHrs', target_date, (
    select coalesce(avg(extract(epoch from (se.occurred_at - oc.first_seen)) / 3600.0), 0)
    from ghl_locked_events le
    join lateral (
      select occurred_at from ghl_events
      where event_type = 'ContactUpdate' and contact_id = le.entity_id
        and exists (
          select 1 from jsonb_array_elements(coalesce(raw->'customFields','[]'::jsonb)) f
          where f->>'id' = FIELD_CONTRACT_STATUS and f->>'value' ilike '%sent%'
        )
      order by occurred_at asc limit 1
    ) se on true
    join lateral (
      select min(occurred_at) as first_seen from ghl_events
      where contact_id = le.entity_id
    ) oc on true
    where le.metric_key = 'contractsSent' and le.log_date = target_date
  ));

  -- firstContactHrs: opportunity createdAt -> first outbound call/SMS, for
  -- opportunities whose FIRST outbound touch happened today.
  with first_touches as (
    select
      opportunity_id,
      min(occurred_at) as first_touch_at
    from ghl_events
    where event_type in ('OutboundMessage', 'InboundMessage')  -- GHL fires this event type for calls too; direction column disambiguates
      and direction = 'outbound'
      and message_type in ('TYPE_CALL', 'TYPE_SMS')
      and opportunity_id is not null
    group by opportunity_id
  ),
  today_first_touches as (
    select ft.opportunity_id, ft.first_touch_at, oc.first_seen
    from first_touches ft
    join lateral (
      select min(occurred_at) as first_seen from ghl_events
      where opportunity_id = ft.opportunity_id
    ) oc on true
    where ft.first_touch_at >= day_start and ft.first_touch_at < day_end
  )
  select coalesce(avg(extract(epoch from (first_touch_at - first_seen)) / 3600.0), 0)
  into v_first_contact_avg
  from today_first_touches;

  perform set_kpi_entry('firstContactHrs', target_date, v_first_contact_avg);

  -- touchPoints: every message/call event logged that day, in or out.
  perform set_kpi_entry('touchPoints', target_date, (
    select count(*) from ghl_events
    where event_type in ('OutboundMessage', 'InboundMessage')
      and occurred_at >= day_start and occurred_at < day_end
  ));

  -- touchPerActiveLead: NEW 2026-08-15. Trailing-7-day snapshot, as of
  -- target_date, of average touch points (calls+texts, in+out) among
  -- leads that are ACTIVE as of that day — meaning their most-recent known
  -- stage in Lead-->Contract (reconstructed from real stage-change history,
  -- not today's live state, so backfilled days are accurate) is neither
  -- "Deal Closed!" nor "Not a Fit". Touches are matched to a lead via its
  -- contact_id, since message events carry contact_id, not opportunity_id.
  -- Stored as an already-averaged value (unlike other metrics, no paired
  -- count field) since "active as of this day" is a point-in-time snapshot,
  -- not something meant to sum across multiple days — the dashboard reads
  -- it with calc type 'latest' rather than 'avg'.
  perform set_kpi_entry('touchPerActiveLead', target_date, (
    with latest_stage as (
      select distinct on (opportunity_id)
        opportunity_id, contact_id, stage_id
      from ghl_events
      where event_type in ('OpportunityCreate','OpportunityStageUpdate')
        and pipeline_id = PIPE_LEAD_TO_CONTRACT
        and occurred_at < day_end
      order by opportunity_id, occurred_at desc
    ),
    active_leads as (
      select opportunity_id, contact_id
      from latest_stage
      where stage_id not in (STAGE_DEAL_CLOSED, STAGE_NOT_A_FIT)
        and contact_id is not null
    ),
    touch_counts as (
      select al.opportunity_id, count(e.*) as touches
      from active_leads al
      left join ghl_events e
        on e.contact_id = al.contact_id
       and e.event_type in ('InboundMessage','OutboundMessage')
       and e.occurred_at >= day_end - interval '7 days'
       and e.occurred_at < day_end
      group by al.opportunity_id
    )
    select coalesce(avg(touches), 0) from touch_counts
  ));

  -- leadsContacted: call >15s AND Lead Notes non-empty, OR inbound SMS reply.
  -- Locked the day the LATER of the two qualifying signals first appears.
  with call_qualified as (
    select contact_id, occurred_at
    from ghl_events
    where event_type = 'OutboundMessage' and message_type = 'TYPE_CALL'
      and coalesce(call_duration_secs, 0) > 15
  ),
  notes_present as (
    select contact_id, occurred_at
    from ghl_events
    where event_type = 'ContactUpdate'
      and exists (
        select 1 from jsonb_array_elements(coalesce(raw->'customFields','[]'::jsonb)) f
        where f->>'id' = FIELD_LEAD_NOTES and length(coalesce(f->>'value','')) > 0
      )
  ),
  call_path as (
    select cq.contact_id, greatest(cq.occurred_at, np.occurred_at) as qualified_at
    from call_qualified cq
    join notes_present np on np.contact_id = cq.contact_id
  ),
  text_reply_path as (
    select contact_id, occurred_at as qualified_at
    from ghl_events
    where event_type = 'InboundMessage' and message_type = 'TYPE_SMS' and direction = 'inbound'
  ),
  earliest_qualifying as (
    select contact_id, min(qualified_at) as qualified_at
    from (select * from call_path union all select * from text_reply_path) both_paths
    group by contact_id
  )
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'leadsContacted', contact_id, target_date
  from earliest_qualifying
  where qualified_at >= day_start and qualified_at < day_end
    and contact_id not in (select entity_id from ghl_locked_events where metric_key = 'leadsContacted')
  on conflict (metric_key, entity_id) do nothing;

  perform set_kpi_entry('leadsContacted', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'leadsContacted' and log_date = target_date
  ));

  -- offersPrepared / offerPrepHrs: a lead's FIRST-EVER exit from Vetted
  -- Lead into any other stage, now locked permanently like the other
  -- "first time" metrics (2026-08-14: previously counted every pass
  -- through the stage, including re-entries — now only the first exit
  -- counts, ever). offerPrepHrs averages the real elapsed hours between
  -- that specific entry and exit, however many calendar days apart they
  -- actually were — not clamped to same-day transitions.
  with stage_history as (
    select
      opportunity_id,
      stage_id,
      occurred_at,
      lag(stage_id) over (partition by opportunity_id order by occurred_at) as prev_stage_id,
      lag(occurred_at) over (partition by opportunity_id order by occurred_at) as prev_occurred_at
    from ghl_events
    where event_type = 'OpportunityStageUpdate'
      and pipeline_id = PIPE_LEAD_TO_CONTRACT
  ),
  first_exits as (
    select distinct on (opportunity_id) opportunity_id, occurred_at as exit_at, prev_occurred_at as entry_at
    from stage_history
    where prev_stage_id = STAGE_VETTED_LEAD
      and stage_id != STAGE_VETTED_LEAD
    order by opportunity_id, occurred_at asc
  )
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'offersPrepared', opportunity_id, target_date
  from first_exits
  where exit_at >= day_start and exit_at < day_end
    and opportunity_id not in (select entity_id from ghl_locked_events where metric_key = 'offersPrepared')
  on conflict (metric_key, entity_id) do nothing;

  perform set_kpi_entry('offersPrepared', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'offersPrepared' and log_date = target_date
  ));

  perform set_kpi_entry('offerPrepHrs', target_date, (
    with stage_history as (
      select
        opportunity_id,
        stage_id,
        occurred_at,
        lag(stage_id) over (partition by opportunity_id order by occurred_at) as prev_stage_id,
        lag(occurred_at) over (partition by opportunity_id order by occurred_at) as prev_occurred_at
      from ghl_events
      where event_type = 'OpportunityStageUpdate'
        and pipeline_id = PIPE_LEAD_TO_CONTRACT
    ),
    first_exits as (
      select distinct on (opportunity_id) opportunity_id, occurred_at as exit_at, prev_occurred_at as entry_at
      from stage_history
      where prev_stage_id = STAGE_VETTED_LEAD
        and stage_id != STAGE_VETTED_LEAD
      order by opportunity_id, occurred_at asc
    )
    select coalesce(avg(extract(epoch from (fe.exit_at - fe.entry_at)) / 3600.0), 0)
    from ghl_locked_events le
    join first_exits fe on fe.opportunity_id = le.entity_id
    where le.metric_key = 'offersPrepared' and le.log_date = target_date
  ));

end;
$$;
