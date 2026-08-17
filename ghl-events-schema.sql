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
  -- ADDED 2026-08-16, for the free (no Zapier Code/Webhooks) Smarter
  -- Contact processing-time pipeline. contact_date_added is the contact's
  -- own GHL creation timestamp (when the SC->GHL zap actually created the
  -- record); sms_reply_at_raw is the raw comma-joined "Message History
  -- Date" list, passed straight through by that same zap into a GHL
  -- custom field (SMS Reply At, id u6uszYSPjmajNbSS2NbF) with zero
  -- computation on Zapier's side. refresh_sc_process_kpis() below does
  -- all the parsing/math in SQL. See that function and
  -- supabase/functions/ghl-hourly-poll/index.ts (pollContacts) for how
  -- these get populated.
  contact_date_added timestamptz,
  sms_reply_at_raw text,
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

  -- leadsProduced: CHANGED 2026-08-15 (again). Now counts every opportunity
  -- CREATED in the Lead-->Contract pipeline, full stop — "every time a lead
  -- comes in and a contact is made" — not restricted to a specific stage
  -- (earlier versions narrowed this to "any stage" then to "Vetted Lead
  -- only"; both undercounted per an explicit correction). OpportunityCreate
  -- fires exactly once per opportunity by construction, so this is
  -- naturally a one-time count; still routed through the lock table (same
  -- idempotent pattern as the others below) purely as a safety net against
  -- duplicate event ingestion, not because dedup logic is doing real work
  -- here. (Also FIXED 2026-08-15, same day: earlier versions of this block
  -- counted directly from ghl_events while excluding already-locked
  -- opportunities, which is NOT idempotent — re-running refresh_ghl_kpis
  -- for an already-backfilled date found zero "new" opportunities and
  -- silently overwrote a correct historical value with 0. Lock first, then
  -- count rows already locked for that exact log_date — safe to re-run.)
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'leadsProduced', opportunity_id, target_date
  from ghl_events
  where event_type = 'OpportunityCreate'
    and pipeline_id = PIPE_LEAD_TO_CONTRACT
    and occurred_at >= day_start and occurred_at < day_end
    and opportunity_id not in (select entity_id from ghl_locked_events where metric_key = 'leadsProduced')
  on conflict (metric_key, entity_id) do nothing;

  perform set_kpi_entry('leadsProduced', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'leadsProduced' and log_date = target_date
  ));

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

  -- leadsOfferedOn: CHANGED 2026-08-15 -- now first-ever entry into Send
  -- Paperwork, locked permanently, same pattern as hotLeadsProduced /
  -- dealsProduced / offersPrepared. This was the one place the exact
  -- counting rule was left ambiguous when the rollup was first built;
  -- explicitly resolved now to "count once per opportunity." Re-entries no
  -- longer inflate the count. Still gated to opportunities already counted
  -- in leadsProduced (numerator ⊆ denominator, enforced 2026-08-15 earlier
  -- the same day).
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'leadsOfferedOn', opportunity_id, target_date
  from ghl_events
  where event_type = 'OpportunityStageUpdate'
    and pipeline_id = PIPE_LEAD_TO_CONTRACT
    and stage_id = STAGE_SEND_PAPERWORK
    and occurred_at >= day_start and occurred_at < day_end
    and opportunity_id not in (select entity_id from ghl_locked_events where metric_key = 'leadsOfferedOn')
    and opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsProduced')
  on conflict (metric_key, entity_id) do nothing;
  perform set_kpi_entry('leadsOfferedOn', target_date, (
    select count(*) from ghl_locked_events where metric_key = 'leadsOfferedOn' and log_date = target_date
  ));

  -- contractsClosed / dealsProduced: first-ever entry into Deal Closed!
  -- in Lead-->Contract, locked permanently. Same underlying event feeds both metrics.
  -- FIXED 2026-08-15: added an explicit leadsProduced membership check
  -- (belt-and-suspenders alongside the existing pipeline_id filter) so a
  -- deal can never close and count without ever appearing in leadsProduced.
  insert into ghl_locked_events (metric_key, entity_id, log_date)
  select 'dealsProduced', opportunity_id, target_date
  from ghl_events
  where event_type = 'OpportunityStageUpdate'
    and pipeline_id = PIPE_LEAD_TO_CONTRACT
    and stage_id = STAGE_DEAL_CLOSED
    and occurred_at >= day_start and occurred_at < day_end
    and opportunity_id not in (select entity_id from ghl_locked_events where metric_key = 'dealsProduced')
    and opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsProduced')
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
  -- FIXED 2026-08-15: ContactUpdate events carry contact_id, not
  -- opportunity_id, so this had no tie back to leadsProduced at all.
  -- Resolve the contact to its opportunity via that contact's
  -- OpportunityCreate event in Lead-->Contract, and require that
  -- opportunity to already be in the leadsProduced lock set.
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
      and contact_id in (
        select contact_id from ghl_events
        where event_type = 'OpportunityCreate'
          and pipeline_id = PIPE_LEAD_TO_CONTRACT
          and opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsProduced')
      )
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
  -- opportunity's FIRST ENTRY into the "Send Paperwork" stage to the Sent
  -- event. CHANGED 2026-08-16 -- previously measured from the contact's
  -- earliest-ever ghl_events row (a proxy for GHL record creation), which
  -- overstated the real prep-to-send lag by including everything before
  -- the lead ever reached Send Paperwork (time in earlier stages, initial
  -- vetting, etc). The user's framing: "time from when the lead enters
  -- the pipeline stage send paperwork to contract sent marked." Contracts
  -- with no matching Send Paperwork entry (shouldn't normally happen, but
  -- data can be messy) are simply excluded via the inner join -- avg()
  -- already skips nulls, so this is the safe default.
  perform set_kpi_entry('contractSentHrs', target_date, (
    select coalesce(avg(extract(epoch from (se.occurred_at - pw.entered_paperwork_at)) / 3600.0), 0)
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
      select min(occurred_at) as entered_paperwork_at from ghl_events
      where contact_id = le.entity_id
        and event_type = 'OpportunityStageUpdate'
        and pipeline_id = PIPE_LEAD_TO_CONTRACT
        and stage_id = STAGE_SEND_PAPERWORK
    ) pw on true
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
  --
  -- SUPERSEDED 2026-08-16 for dashboard display — the "avg touch points"
  -- tile now calls avg_touches_before_lost(from, to) live instead (see
  -- below), same reasoning as the *CohortRate7 supersession further down:
  -- the actual ask was "of the leads marked Lost Leads in the selected
  -- window, how many touches did they get before that", a cohort keyed off
  -- Lost Leads entries, not a fixed trailing-7-day snapshot of currently-
  -- active leads. Left running here unchanged — still a useful point-in-
  -- time historical record, and nothing currently reads it, so removing it
  -- would only lose data for no benefit.
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
  -- FIXED 2026-08-15: added the same leadsProduced membership check as
  -- contractsSent above — a contact only locks as "contacted" if it maps
  -- (via its OpportunityCreate event) to an opportunity already counted in
  -- leadsProduced.
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
    and contact_id in (
      select contact_id from ghl_events
      where event_type = 'OpportunityCreate'
        and pipeline_id = PIPE_LEAD_TO_CONTRACT
        and opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsProduced')
    )
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
  -- FIXED 2026-08-15: added the same leadsProduced membership check used
  -- for the other conversion metrics — an opportunity's exit from Vetted
  -- Lead only locks as offersPrepared if that opportunity is already
  -- counted in leadsProduced. offerPrepHrs inherits this automatically,
  -- since it only averages over entities already locked here.
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
    and opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsProduced')
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

  -- ---- Cohort-based lead-conversion rates (trailing 7 days ending target_date) ----
  -- SUPERSEDED 2026-08-16 for dashboard display -- pctContacted7/
  -- pctOffered7/pctContract7/pctClosed7 and dealsProduced7 now call the
  -- cohort_lead_conversion(from_date, to_date) function live instead of
  -- reading these fixed-7-day daily snapshots, so the headline tiles
  -- correctly recompute for whatever range the KPI Tracker page has
  -- selected (7/30/90/last month/custom), not just 7 days. Left running
  -- here unchanged -- still a useful point-in-time historical record, and
  -- nothing currently reads it, so removing it would only lose data for
  -- no benefit.
  -- ADDED 2026-08-15: the dashboard's pct* KPIs (pctContacted7, pctOffered7,
  -- pctContract7, pctClosed7) used to divide two independently
  -- time-windowed sums -- leads CONTACTED/OFFERED/SENT/CLOSED in the
  -- trailing 7 days over leads PRODUCED in the trailing 7 days. Those are
  -- different cohorts: a lead produced 10 days ago can still get contacted
  -- today, adding to this week's numerator without ever counting in this
  -- week's denominator. Result: the ratio could (and did) exceed 100%,
  -- even though the numerator-is-a-subset-of-leadsProduced fix above holds
  -- perfectly at the all-time level.
  --
  -- These four *CohortRate7 metrics fix that by asking one question per
  -- day, about one fixed group: of the leads PRODUCED in the trailing 7
  -- days (log_date between target_date-6 and target_date), what
  -- percentage have EVER reached [contacted / offered on / contract sent /
  -- closed] -- checked against full history, not just this window.
  -- Because every one of those checks is already gated to leadsProduced
  -- membership, this can never exceed 100%.
  --
  -- Stored as an already-computed percentage (0-100), matching
  -- touchPerActiveLead's pattern: a point-in-time cohort snapshot, not
  -- something to sum across days, so the dashboard reads it with calc
  -- type 'latest' rather than 'ratio'.
  perform set_kpi_entry('contactedCohortRate7', target_date, (
    with cohort as (
      select le.entity_id as opportunity_id, oc.contact_id
      from ghl_locked_events le
      join ghl_events oc
        on oc.event_type = 'OpportunityCreate'
       and oc.pipeline_id = PIPE_LEAD_TO_CONTRACT
       and oc.opportunity_id = le.entity_id
      where le.metric_key = 'leadsProduced'
        and le.log_date between (target_date - 6) and target_date
    )
    select case when count(*) = 0 then 0 else
      100.0 * count(*) filter (
        where contact_id in (select entity_id from ghl_locked_events where metric_key = 'leadsContacted')
      ) / count(*)
    end
    from cohort
  ));

  -- offeredCohortRate7: CHANGED 2026-08-15 to match leadsOfferedOn's new
  -- locked semantics -- checks lock-table membership instead of a raw
  -- exists() against ghl_events, consistent with the other three cohort
  -- rates.
  perform set_kpi_entry('offeredCohortRate7', target_date, (
    with cohort as (
      select entity_id as opportunity_id
      from ghl_locked_events
      where metric_key = 'leadsProduced'
        and log_date between (target_date - 6) and target_date
    )
    select case when count(*) = 0 then 0 else
      100.0 * count(*) filter (
        where opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsOfferedOn')
      ) / count(*)
    end
    from cohort
  ));

  perform set_kpi_entry('contractSentCohortRate7', target_date, (
    with cohort as (
      select le.entity_id as opportunity_id, oc.contact_id
      from ghl_locked_events le
      join ghl_events oc
        on oc.event_type = 'OpportunityCreate'
       and oc.pipeline_id = PIPE_LEAD_TO_CONTRACT
       and oc.opportunity_id = le.entity_id
      where le.metric_key = 'leadsProduced'
        and le.log_date between (target_date - 6) and target_date
    )
    select case when count(*) = 0 then 0 else
      100.0 * count(*) filter (
        where contact_id in (select entity_id from ghl_locked_events where metric_key = 'contractsSent')
      ) / count(*)
    end
    from cohort
  ));

  perform set_kpi_entry('closedCohortRate7', target_date, (
    with cohort as (
      select entity_id as opportunity_id
      from ghl_locked_events
      where metric_key = 'leadsProduced'
        and log_date between (target_date - 6) and target_date
    )
    select case when count(*) = 0 then 0 else
      100.0 * count(*) filter (
        where opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'dealsProduced')
      ) / count(*)
    end
    from cohort
  ));

end;
$$;

-- ---------------------------------------------------------
-- cohort_lead_conversion(from_date, to_date) — ADDED 2026-08-16
--
-- The four *CohortRate7 metrics above are daily snapshots hardcoded to a
-- trailing 7-day cohort window, written once per day by refresh_ghl_kpis.
-- That's fine as long as the dashboard only ever looks at a 7-day range,
-- but the KPI Tracker page lets the user pick 7/30/90/last month/custom --
-- and reading a 7-day-cohort snapshot through a 90-day lens just shows
-- the most recent day's 7-day number again, silently wrong for anything
-- other than the 7-day view. Same problem hits "Deals produced": it used
-- to just sum the dealsProduced daily counts over whatever range was
-- selected, which counts every deal that CLOSED in that range regardless
-- of whether the underlying lead was produced inside or outside it --
-- not what "deals produced out of leads from the time window selected"
-- means.
--
-- This function replaces both: called live, on demand, with whatever
-- from/to the dashboard's range picker currently has selected (RPC'd
-- straight from index.html via supabase.rpc, not precomputed). It asks
-- one question for one arbitrary window: of the leads PRODUCED between
-- from_date and to_date inclusive, how many (and what %) have EVER gone
-- on to reach each later stage, checked against full history the same
-- way the *CohortRate7 metrics already do. Every count here is a strict
-- subset of `produced`, so the percentages can never exceed 100 and
-- `closed` is exactly the cohort-gated deal count the dashboard needs.
--
-- SECURITY DEFINER so it can read ghl_locked_events/ghl_events (both
-- service-role-only via RLS) the same way refresh_ghl_kpis does, with
-- EXECUTE granted directly to anon/authenticated below -- the underlying
-- tables stay locked down, only this narrow, read-only, aggregate-only
-- function is reachable from the browser.
create or replace function cohort_lead_conversion(from_date date, to_date date)
returns table (
  produced        bigint,
  contacted       bigint,
  offered         bigint,
  contract_sent   bigint,
  closed          bigint,
  pct_contacted   numeric,
  pct_offered     numeric,
  pct_contract_sent numeric,
  pct_closed      numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  PIPE_LEAD_TO_CONTRACT constant text := '9wvdoIQrdKYrmeAnfod6';
begin
  return query
  with cohort as (
    select le.entity_id as opportunity_id, oc.contact_id
    from ghl_locked_events le
    join ghl_events oc
      on oc.event_type = 'OpportunityCreate'
     and oc.pipeline_id = PIPE_LEAD_TO_CONTRACT
     and oc.opportunity_id = le.entity_id
    where le.metric_key = 'leadsProduced'
      and le.log_date between from_date and to_date
  ),
  totals as (
    select
      count(*) as produced,
      count(*) filter (
        where contact_id in (select entity_id from ghl_locked_events where metric_key = 'leadsContacted')
      ) as contacted,
      count(*) filter (
        where opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'leadsOfferedOn')
      ) as offered,
      count(*) filter (
        where contact_id in (select entity_id from ghl_locked_events where metric_key = 'contractsSent')
      ) as contract_sent,
      count(*) filter (
        where opportunity_id in (select entity_id from ghl_locked_events where metric_key = 'dealsProduced')
      ) as closed
    from cohort
  )
  select
    t.produced, t.contacted, t.offered, t.contract_sent, t.closed,
    case when t.produced = 0 then 0 else round(100.0 * t.contacted / t.produced, 1) end,
    case when t.produced = 0 then 0 else round(100.0 * t.offered / t.produced, 1) end,
    case when t.produced = 0 then 0 else round(100.0 * t.contract_sent / t.produced, 1) end,
    case when t.produced = 0 then 0 else round(100.0 * t.closed / t.produced, 1) end
  from totals t;
end;
$$;

revoke all on function cohort_lead_conversion(date, date) from public;
grant execute on function cohort_lead_conversion(date, date) to anon, authenticated;

-- ---------------------------------------------------------
-- avg_touches_before_lost(from_date, to_date) — ADDED 2026-08-16
--
-- Replaces touchPerActiveLead (below, in refresh_ghl_kpis) as the
-- dashboard's "avg touch points" tile. touchPerActiveLead answers "on a
-- given day, how many touches are currently-active leads getting" -- a
-- trailing-7-day snapshot, fixed window, can't be asked over 30/90/custom.
-- The question actually wanted: "of the leads marked Lost Leads during the
-- selected time period, how many times were they touched before that" --
-- a cohort question keyed off WHEN a lead was abandoned, not a daily
-- snapshot of currently-active leads. Same reason cohort_lead_conversion
-- exists instead of the old *CohortRate7 columns: needs to be called live
-- for whatever range the KPI Tracker's picker has selected.
--
-- For every opportunity whose FIRST-EVER entry into the Lost Leads stage
-- falls inside [from_date, to_date] (first-ever, so a lead that bounces
-- into and out of Lost Leads more than once is only ever attributed to
-- the day it was first abandoned -- same pattern as hotLeadsProduced /
-- dealsProduced / offersPrepared above), counts every inbound/outbound
-- message or call event tied to that lead's contact that happened BEFORE
-- the moment it entered Lost Leads. Averages that count across every
-- qualifying lead. touchPoints' own in/out + call/SMS event types are
-- reused unchanged (InboundMessage/OutboundMessage), so "touch" means the
-- same thing here as it does everywhere else on the dashboard.
--
-- SECURITY DEFINER + explicit grants, same reasoning as
-- cohort_lead_conversion: ghl_events/ghl_locked_events stay service-role-
-- only, this narrow read-only aggregate is what's reachable from the
-- browser.
create or replace function avg_touches_before_lost(from_date date, to_date date)
returns table (
  lost_leads  bigint,
  avg_touches numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  PIPE_LEAD_TO_CONTRACT constant text := '9wvdoIQrdKYrmeAnfod6';
  STAGE_LOST_LEADS      constant text := 'd2f78e1d-1715-4599-b904-131ee5b3d8c2';
  win_start timestamptz := from_date::timestamptz;
  win_end   timestamptz := (to_date + 1)::timestamptz;
begin
  return query
  with lost_transitions as (
    select distinct on (opportunity_id)
      opportunity_id, contact_id, occurred_at as lost_at
    from ghl_events
    where event_type = 'OpportunityStageUpdate'
      and pipeline_id = PIPE_LEAD_TO_CONTRACT
      and stage_id = STAGE_LOST_LEADS
    order by opportunity_id, occurred_at asc
  ),
  in_window as (
    select * from lost_transitions
    where lost_at >= win_start and lost_at < win_end
  ),
  touch_counts as (
    select
      lt.opportunity_id,
      count(e.*) as touches
    from in_window lt
    left join ghl_events e
      on e.contact_id = lt.contact_id
     and e.event_type in ('InboundMessage', 'OutboundMessage')
     and e.occurred_at < lt.lost_at
    group by lt.opportunity_id
  )
  select count(*), coalesce(avg(touches), 0)
  from touch_counts;
end;
$$;

revoke all on function avg_touches_before_lost(date, date) from public;
grant execute on function avg_touches_before_lost(date, date) to anon, authenticated;

-- ---------------------------------------------------------
-- avg_touches_before_deal(from_date, to_date) — ADDED 2026-08-17
--
-- The mirror image of avg_touches_before_lost above: instead of touches
-- spent on leads that got abandoned, how many touches did a lead get
-- before its deal actually closed. Same cohort shape and same reasoning --
-- of the leads whose FIRST-EVER entry into "Deal Closed!" falls inside
-- [from_date, to_date], counts every inbound/outbound message or call
-- event tied to that lead's contact that happened BEFORE the moment it
-- entered Deal Closed!, then averages that count across every qualifying
-- deal. Same touchPoints event types reused (InboundMessage/
-- OutboundMessage), so "touch" means the same thing here as everywhere
-- else on the dashboard.
--
-- SECURITY DEFINER + explicit grants, same reasoning as
-- avg_touches_before_lost: ghl_events/ghl_locked_events stay service-role-
-- only, this narrow read-only aggregate is what's reachable from the
-- browser.
create or replace function avg_touches_before_deal(from_date date, to_date date)
returns table (
  deals_closed bigint,
  avg_touches  numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  PIPE_LEAD_TO_CONTRACT constant text := '9wvdoIQrdKYrmeAnfod6';
  STAGE_DEAL_CLOSED     constant text := '462724b5-24ce-4a16-b198-ba5c290eab85';
  win_start timestamptz := from_date::timestamptz;
  win_end   timestamptz := (to_date + 1)::timestamptz;
begin
  return query
  with deal_transitions as (
    select distinct on (opportunity_id)
      opportunity_id, contact_id, occurred_at as closed_at
    from ghl_events
    where event_type = 'OpportunityStageUpdate'
      and pipeline_id = PIPE_LEAD_TO_CONTRACT
      and stage_id = STAGE_DEAL_CLOSED
    order by opportunity_id, occurred_at asc
  ),
  in_window as (
    select * from deal_transitions
    where closed_at >= win_start and closed_at < win_end
  ),
  touch_counts as (
    select
      dt.opportunity_id,
      count(e.*) as touches
    from in_window dt
    left join ghl_events e
      on e.contact_id = dt.contact_id
     and e.event_type in ('InboundMessage', 'OutboundMessage')
     and e.occurred_at < dt.closed_at
    group by dt.opportunity_id
  )
  select count(*), coalesce(avg(touches), 0)
  from touch_counts;
end;
$$;

revoke all on function avg_touches_before_deal(date, date) from public;
grant execute on function avg_touches_before_deal(date, date) to anon, authenticated;

-- ---------------------------------------------------------
-- refresh_sc_process_kpis — Smarter Contact processing-time, ADDED
-- 2026-08-16
--
-- Replaces the lead-entry-lag Edge Function, which required a paid
-- Zapier plan (Code by Zapier + Webhooks by Zapier, on top of the base
-- 2-step Export Contact -> Add/Update Contact zap -- Zapier's Free plan
-- caps every zap at exactly 2 steps, trigger + action, full stop,
-- regardless of which apps are used). This version does zero computation
-- in Zapier: the same 2-step zap now also maps the trigger's raw,
-- comma-joined "Message History Date" list straight into a GHL custom
-- field (SMS Reply At, contact-level, id u6uszYSPjmajNbSS2NbF) with no
-- Code step needed. ghl-hourly-poll's pollContacts() captures that raw
-- text plus the contact's own GHL dateAdded into ghl_contact_state on
-- every poll (see that column's comment above). All the actual math
-- happens here:
--   - "second message" = the lead's reply, per the original convention
--     (message #1 assumed to be our own outbound opener).
--   - lag = the contact's GHL creation time minus that reply time.
--   - same 0-168h plausibility guard the old Edge Function used, for the
--     same reason: reject anything wildly implausible (bad mapping, a
--     backfilled contact with stale message history, etc.) rather than
--     let it silently poison the average.
--
-- Feeds the SAME kpi_entries keys as before -- scProcessHrs,
-- scLeadsProcessed -- but via overwrite (set_kpi_entry), not the
-- additive increment_kpi_entry the old Edge Function used. Only one
-- writer should ever touch these keys at a time; now that this function
-- is live, the lead-entry-lag Edge Function's Zapier steps (Code +
-- Webhooks) should be removed from the zap -- they're no longer needed
-- and were the only reason that zap couldn't run on Zapier's Free plan.
--
-- Called once per poll for today + yesterday, same pattern as
-- refresh_ghl_kpis (see ghl-hourly-poll's runRollup()). Safe to re-run
-- for any date any number of times -- always recomputes fully from
-- ghl_contact_state's current snapshot rather than accumulating.
create or replace function refresh_sc_process_kpis(target_date date)
returns void
language plpgsql
security definer
as $$
declare
  day_start timestamptz := target_date::timestamptz;
  day_end   timestamptz := (target_date + 1)::timestamptz;
begin
  perform set_kpi_entry('scLeadsProcessed', target_date, (
    select count(*)
    from (
      select
        cs.contact_date_added,
        (string_to_array(cs.sms_reply_at_raw, ','))[2]::timestamptz as reply_at
      from ghl_contact_state cs
      where cs.contact_date_added >= day_start and cs.contact_date_added < day_end
        and cs.sms_reply_at_raw is not null
        and array_length(string_to_array(cs.sms_reply_at_raw, ','), 1) >= 2
    ) x
    where extract(epoch from (x.contact_date_added - x.reply_at)) / 3600.0 between 0 and 168
  ));

  perform set_kpi_entry('scProcessHrs', target_date, (
    select coalesce(avg(lag_hrs), 0)
    from (
      select extract(epoch from (x.contact_date_added - x.reply_at)) / 3600.0 as lag_hrs
      from (
        select
          cs.contact_date_added,
          (string_to_array(cs.sms_reply_at_raw, ','))[2]::timestamptz as reply_at
        from ghl_contact_state cs
        where cs.contact_date_added >= day_start and cs.contact_date_added < day_end
          and cs.sms_reply_at_raw is not null
          and array_length(string_to_array(cs.sms_reply_at_raw, ','), 1) >= 2
      ) x
    ) y
    where lag_hrs between 0 and 168
  ));
end;
$$;
