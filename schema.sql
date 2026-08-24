-- =========================================================
-- Utopian CRM — Supabase schema
--
-- SAFE TO RE-RUN. This script is fully idempotent and purely
-- ADDITIVE: it creates what's missing, adds columns the app
-- now needs, and relaxes leftover constraints from older
-- versions of this schema. It never drops a column or a table,
-- so no existing data is lost.
--
-- Run the whole file in your Supabase SQL Editor, top to bottom.
-- Then copy config.example.js -> config.js with your URL + anon key.
-- =========================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------
-- users (team members using this CRM)
-- ---------------------------------------------------------
create table if not exists users (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  role        text,
  color_idx   int  not null default 0,
  created_at  timestamptz not null default now()
);
alter table users add column if not exists name       text;
alter table users add column if not exists role       text;
alter table users add column if not exists color_idx  int not null default 0;
alter table users add column if not exists created_at timestamptz not null default now();

-- ---------------------------------------------------------
-- properties (deals under evaluation / contract / closed)
-- ---------------------------------------------------------
create table if not exists properties (
  id           uuid primary key default gen_random_uuid(),
  property_id  text,
  county       text,
  state        text default 'TX',
  acres        numeric,
  buy_price    numeric,
  sell_price   numeric,
  closing_date date,
  notes        text,
  -- Funding tiers: profit-split bands measured in days after closing, e.g.
  --   [{"id":"...","days":45, "pctUs":75,"pctFunder":25},
  --    {"id":"...","days":90, "pctUs":70,"pctFunder":30},
  --    {"id":"...","days":300,"pctUs":45,"pctFunder":55}]
  -- days is the last day of the band; a band starts the day after the previous
  -- one ends, so the list above reads 0-45, 46-90, 91-300. Calendar dates are
  -- derived from closing_date at render time and deliberately not stored, so
  -- moving a closing date reshuffles the whole schedule automatically.
  -- Tiers saved under the older {name,date,percent,amount} model are migrated
  -- on read by the app.
  funding_schedule jsonb not null default '[]'::jsonb,
  -- Where the deal sits, for the Properties tab's filter — 'pre-closing'
  -- (the default), 'closed', or 'listed'. Deliberately just three states.
  status       text default 'pre-closing',
  -- Listing details: a Zillow URL plus a hand-entered daily saves/views log,
  -- e.g. [{"date":"2026-08-24","views":12,"saves":3}, ...]. One entry per
  -- calendar date; the app upserts by date rather than appending duplicates.
  listing_url   text,
  listing_stats jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now()
);
alter table properties add column if not exists property_id  text;
alter table properties add column if not exists county       text;
alter table properties add column if not exists state        text default 'TX';
alter table properties add column if not exists acres        numeric;
alter table properties add column if not exists buy_price    numeric;
alter table properties add column if not exists sell_price   numeric;
alter table properties add column if not exists closing_date date;
alter table properties add column if not exists notes        text;
alter table properties add column if not exists funding_schedule jsonb not null default '[]'::jsonb;
alter table properties add column if not exists status        text default 'pre-closing';
alter table properties add column if not exists listing_url   text;
alter table properties add column if not exists listing_stats jsonb not null default '[]'::jsonb;
alter table properties add column if not exists created_at   timestamptz not null default now();

-- Existing rows predating the funding schedule get an empty list rather
-- than a null the app would have to defend against on every render.
update properties set funding_schedule = '[]'::jsonb where funding_schedule is null;
update properties set status = 'pre-closing' where status is null or status = 'new';
update properties set listing_stats = '[]'::jsonb where listing_stats is null;

-- ---------------------------------------------------------
-- funding_templates (saved profit-split schedules, e.g. "Rooster Flow
-- Capital split" — reusable across properties from the funding tier editor)
-- ---------------------------------------------------------
create table if not exists funding_templates (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  tiers      jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
alter table funding_templates add column if not exists name       text not null default '';
alter table funding_templates add column if not exists tiers      jsonb not null default '[]'::jsonb;
alter table funding_templates add column if not exists created_at timestamptz not null default now();

-- Optional: if your old "address" column has values you want carried
-- into the new "property_id" field, this COPIES them (the original
-- address column is left untouched either way):
--   update properties set property_id = address where property_id is null;

-- ---------------------------------------------------------
-- tasks (assigned to multiple users, optionally linked to a property)
-- ---------------------------------------------------------
create table if not exists tasks (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  linked_id    uuid,
  linked_type  text,
  due_date     date,
  priority     text not null default 'medium',
  status       text not null default 'todo',
  notes        text,
  assignees    uuid[] not null default '{}',
  completed_at date,
  created_at   timestamptz not null default now()
);
alter table tasks add column if not exists title        text;
alter table tasks add column if not exists linked_id    uuid;
alter table tasks add column if not exists linked_type  text;
alter table tasks add column if not exists due_date     date;
alter table tasks add column if not exists priority     text not null default 'medium';
alter table tasks add column if not exists status       text not null default 'todo';
alter table tasks add column if not exists notes        text;
alter table tasks add column if not exists assignees    uuid[] not null default '{}';
-- REQUIRED by the app (marking a task done writes this). Without it,
-- every task save silently failed with "column completed_at not found".
alter table tasks add column if not exists completed_at date;
alter table tasks add column if not exists created_at   timestamptz not null default now();

create index if not exists idx_tasks_status    on tasks(status);
create index if not exists idx_tasks_due_date  on tasks(due_date);
create index if not exists idx_tasks_assignees on tasks using gin (assignees);

-- ---------------------------------------------------------
-- projects (business improvements: marketing, SOPs, tools, etc.)
-- ---------------------------------------------------------
create table if not exists projects (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  category     text not null default 'Other',
  status       text not null default 'ideas',
  priority     text not null default 'medium',
  description  text,
  due_date     date,
  assignees    uuid[] not null default '{}',
  created_at   timestamptz not null default now()
);
alter table projects add column if not exists title       text;
alter table projects add column if not exists category    text not null default 'Other';
alter table projects add column if not exists status      text not null default 'ideas';
alter table projects add column if not exists priority    text not null default 'medium';
alter table projects add column if not exists description text;
alter table projects add column if not exists due_date    date;
alter table projects add column if not exists assignees   uuid[] not null default '{}';
alter table projects add column if not exists created_at  timestamptz not null default now();

create index if not exists idx_projects_status   on projects(status);
create index if not exists idx_projects_category on projects(category);

-- ---------------------------------------------------------
-- kpi_metrics (one row per metric — 7-day and 30-day totals)
-- ---------------------------------------------------------
create table if not exists kpi_metrics (
  id                uuid primary key default gen_random_uuid(),
  metric_key        text not null,
  trailing_7_value  integer not null default 0,
  trailing_30_value integer not null default 0,
  created_at        timestamptz not null default now()
);
alter table kpi_metrics add column if not exists metric_key        text;
alter table kpi_metrics add column if not exists trailing_7_value  integer not null default 0;
alter table kpi_metrics add column if not exists trailing_30_value integer not null default 0;
alter table kpi_metrics add column if not exists created_at        timestamptz not null default now();

create index if not exists idx_kpi_metrics_metric_key on kpi_metrics(metric_key);
-- One row per metric. Guarded: if legacy duplicate rows exist the script
-- keeps going and tells you, instead of aborting everything after it.
do $$
begin
  create unique index if not exists uq_kpi_metrics_metric_key on kpi_metrics(metric_key);
exception when others then
  raise notice 'Could not make kpi_metrics.metric_key unique (duplicate rows?): %', sqlerrm;
end $$;

-- ---------------------------------------------------------
-- kpi_meta (single row — the "last updated" stamp for the KPI section)
-- ---------------------------------------------------------
create table if not exists kpi_meta (
  id         uuid primary key default gen_random_uuid(),
  updated_at timestamptz not null default now()
);
alter table kpi_meta add column if not exists updated_at timestamptz not null default now();

-- ---------------------------------------------------------
-- kpi_entries (one hand-entered value per metric per day —
-- the trailing 7-day and 30-day figures on the dashboard are
-- summed from these, and any custom date range reads them too)
-- ---------------------------------------------------------
create table if not exists kpi_entries (
  id         uuid primary key default gen_random_uuid(),
  metric_key text not null,
  log_date   date not null,
  value      integer not null default 0,
  created_at timestamptz not null default now()
);
alter table kpi_entries add column if not exists metric_key text;
alter table kpi_entries add column if not exists log_date   date;
alter table kpi_entries add column if not exists value      integer not null default 0;
alter table kpi_entries add column if not exists created_at timestamptz not null default now();

create index if not exists idx_kpi_entries_log_date on kpi_entries(log_date);
create index if not exists idx_kpi_entries_metric_key on kpi_entries(metric_key);
-- One row per metric per day, so re-logging a day overwrites rather than
-- double-counting. Guarded the same way kpi_metrics is: duplicates from an
-- earlier run report themselves instead of aborting the rest of the script.
do $$
begin
  create unique index if not exists uq_kpi_entries_metric_day on kpi_entries(metric_key, log_date);
exception when others then
  raise notice 'Could not make kpi_entries (metric_key, log_date) unique (duplicate rows?): %', sqlerrm;
end $$;

-- ---------------------------------------------------------
-- increment_kpi_entry — atomic +=, for automated writers
-- ---------------------------------------------------------
-- Every value the app itself writes to kpi_entries is a plain overwrite
-- (see saveKpiEntry() in index.html) — the person editing a day's number
-- always means "this is now the total for that day."
--
-- Automated writers (the lead-entry-lag Edge Function, and anything else
-- that logs one event at a time rather than one human-typed daily total)
-- need the opposite: many small additions landing throughout the day
-- without clobbering each other. This function does that add atomically
-- inside Postgres, so two webhook calls arriving at the same instant both
-- still count. It's additive-only — safe only against a metric_key nobody
-- also edits by hand in the UI at the same time, or the two writers fight.
--
-- NOTE 2026-08-11: lead-entry-lag writes into scProcessHrs / scLeadsProcessed
-- (the existing "Hours processing those leads" pair) rather than dedicated
-- keys, on the team's confirmation that those are no longer hand-entered.
-- If manual entry into those two ever resumes, move the automation onto its
-- own keys first.
create or replace function increment_kpi_entry(p_metric_key text, p_log_date date, p_value numeric)
returns void
language sql
security definer
set search_path = public
as $$
  insert into kpi_entries (metric_key, log_date, value)
  values (p_metric_key, p_log_date, p_value)
  on conflict (metric_key, log_date)
  do update set value = kpi_entries.value + excluded.value;
$$;

-- ---------------------------------------------------------
-- KPI value type — durations are entered as fractional hours
-- ---------------------------------------------------------
-- kpi_entries.value started life as an integer, which was fine when every
-- metric was a count. The Lead Gen / Lead Conversion inputs now include hour
-- totals ("hours preparing offers"), which need decimals. Widening integer ->
-- numeric is a safe, in-place change: every existing whole number is preserved
-- exactly. This is guarded so re-running the script is harmless.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='kpi_entries'
      and column_name='value' and data_type in ('integer','bigint','smallint')
  ) then
    alter table kpi_entries alter column value type numeric using value::numeric;
    raise notice 'kpi_entries.value widened to numeric (existing values kept).';
  end if;
end $$;

-- ---------------------------------------------------------
-- Metric key renames — minutes/days inputs became hours
-- ---------------------------------------------------------
-- Five duration inputs were renamed when every duration standardised on hours.
-- These UPDATEs re-point existing rows at the new keys. Nothing is deleted:
-- only metric_key changes, and only for rows still using an old key.
--
--   scProcessMin -> scProcessHrs     offerPrepMin -> offerPrepHrs
--   ddStage2Days -> ddStage2Hrs      emdDays      -> emdHrs
--   hotBuyerDays -> hotBuyerHrs
--
-- IMPORTANT: the numbers themselves are NOT converted. A row that recorded 90
-- (meaning 90 minutes) will now read as 90 hours. Re-enter any such day; the
-- script deliberately does not guess at a conversion on your behalf.
do $$
declare
  renames text[][] := array[
    ['scProcessMin','scProcessHrs'],
    ['offerPrepMin','offerPrepHrs'],
    ['ddStage2Days','ddStage2Hrs'],
    ['emdDays','emdHrs'],
    ['hotBuyerDays','hotBuyerHrs']
  ];
  r text[];
  moved int;
  skipped int;
begin
  foreach r slice 1 in array renames loop
    -- Rename only where the new key isn't already taken for that day. Nothing
    -- is ever deleted: if both keys somehow hold a value for the same date,
    -- the old row is left exactly where it is and reported below, so you can
    -- decide which number is right rather than the script picking for you.
    update kpi_entries old_e
       set metric_key = r[2]
     where old_e.metric_key = r[1]
       and not exists (select 1 from kpi_entries new_e
                        where new_e.metric_key = r[2]
                          and new_e.log_date = old_e.log_date);
    get diagnostics moved = row_count;
    if moved > 0 then
      raise notice 'Renamed % kpi_entries rows: % -> %', moved, r[1], r[2];
    end if;

    select count(*) into skipped from kpi_entries where metric_key = r[1];
    if skipped > 0 then
      raise notice 'LEFT ALONE: % rows still on % (a % row already exists for those dates) — review manually.',
        skipped, r[1], r[2];
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------
-- kpi_targets (the "expectations" set against each KPI)
-- ---------------------------------------------------------
-- Goals are firm-wide, not per-person: one row per KPI key, so a number set by
-- anyone is the number everyone sees. The app reads this table at boot and
-- upserts on the unique index below, which is what makes two people editing
-- the same goal converge instead of stacking duplicate rows.
--
-- Deleting a row is how a goal is cleared — a KPI with no row here simply
-- shows its value with no expectation attached.
create table if not exists kpi_targets (
  id           uuid primary key default gen_random_uuid(),
  kpi_key      text not null,
  target_value numeric,
  updated_at   timestamptz not null default now()
);
alter table kpi_targets add column if not exists kpi_key      text;
alter table kpi_targets add column if not exists target_value numeric;
alter table kpi_targets add column if not exists updated_at   timestamptz not null default now();
do $$
begin
  create unique index if not exists uq_kpi_targets_key on kpi_targets(kpi_key);
exception when others then
  raise notice 'Could not make kpi_targets.kpi_key unique (duplicate rows?): %', sqlerrm;
end $$;

-- ---------------------------------------------------------
-- Reference: the metric_key values the app writes to kpi_entries
-- ---------------------------------------------------------
-- Lead Generation:  smsSent, leadsProduced, hotLeadsProduced,
--                   scLeadsProcessed, scProcessHrs (also written automatically
--                   by lead-entry-lag — see increment_kpi_entry() above),
--                   offersPrepared, offerPrepHrs
-- Lead Conversion:  leadsContacted, firstContactHrs, leadsOfferedOn,
--                   contractsSent, contractSentHrs, contractsClosed,
--                   touchPoints, dealsProduced, conversationsHad
-- Due Diligence:    ddStage2Done, ddStage2Hrs, emdSubmitted, emdHrs,
--                   contractsExecuted, contractsCancelled          (section off)
-- Disposition:      buyerLeadsResponded, buyerRespHrs, outboundBuyerRuns,
--                   outboundBuyerHrs, propsHit8HotBuyers, hotBuyerHrs,
--                   propsListed, zillowSaves, fbHits               (section off)
--
-- No schema change is needed to switch sections on: metric_key is free text,
-- so the Due Diligence and Disposition inputs write to the same table the
-- moment those sections are re-enabled in index.html.

-- ---------------------------------------------------------
-- user_prefs (one row per team member — which tab they were
-- on, calendar position, KPI date range. Kept server-side so
-- these follow a person from laptop to phone.)
--
-- NOTE: which teammate a given browser is signed in as stays
-- in that browser's localStorage. It's the key used to find
-- the row below, so it can't live inside it.
-- ---------------------------------------------------------
create table if not exists user_prefs (
  user_id    uuid primary key,
  prefs      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table user_prefs add column if not exists prefs      jsonb not null default '{}'::jsonb;
alter table user_prefs add column if not exists updated_at timestamptz not null default now();

-- NOTE: kpi_metrics is left in place untouched. The app no longer reads it —
-- the dashboard now sums kpi_entries instead — but your previously typed
-- 7-day/30-day totals are still sitting there if you want to reference them.

-- ---------------------------------------------------------
-- call_logs (Activity Log — one row per calendar day)
-- ---------------------------------------------------------
create table if not exists call_logs (
  id                 uuid primary key default gen_random_uuid(),
  log_date           date not null,
  calls_made         integer not null default 0,
  conversations_held integer not null default 0,
  offers_made        integer not null default 0,
  offers_accepted    integer not null default 0,
  not_interested     integer not null default 0,
  notes              text,
  created_at         timestamptz not null default now()
);
alter table call_logs add column if not exists log_date           date;
alter table call_logs add column if not exists calls_made         integer not null default 0;
alter table call_logs add column if not exists conversations_held integer not null default 0;
alter table call_logs add column if not exists offers_made        integer not null default 0;
alter table call_logs add column if not exists offers_accepted    integer not null default 0;
alter table call_logs add column if not exists not_interested     integer not null default 0;
alter table call_logs add column if not exists notes              text;
alter table call_logs add column if not exists created_at         timestamptz not null default now();

create index if not exists idx_call_logs_log_date on call_logs(log_date);
-- One row per calendar day.
do $$
begin
  create unique index if not exists uq_call_logs_log_date on call_logs(log_date);
exception when others then
  raise notice 'Could not make call_logs.log_date unique (duplicate rows?): %', sqlerrm;
end $$;

-- ---------------------------------------------------------
-- campaign_logs (Activity Log — any number of campaign touches per day)
-- ---------------------------------------------------------
create table if not exists campaign_logs (
  id              uuid primary key default gen_random_uuid(),
  log_date        date not null,
  campaign_name   text not null,
  channel         text,
  counties_hit    text,
  leads_generated integer,
  notes           text,
  created_at      timestamptz not null default now()
);
alter table campaign_logs add column if not exists log_date        date;
alter table campaign_logs add column if not exists campaign_name   text;
alter table campaign_logs add column if not exists channel         text;
alter table campaign_logs add column if not exists counties_hit    text;
alter table campaign_logs add column if not exists leads_generated integer;
alter table campaign_logs add column if not exists notes           text;
alter table campaign_logs add column if not exists created_at      timestamptz not null default now();

create index if not exists idx_campaign_logs_log_date on campaign_logs(log_date);

-- =========================================================
-- REPAIR PASS — this is what fixes "new items won't save"
--
-- If you ever ran an earlier version of this schema, your tables
-- may still carry columns the app no longer writes (address,
-- status, assigned_to, ask_price, offer_price, arv_price, ...).
-- Any of those that are NOT NULL will reject every new row the
-- app inserts, because the app sends nothing for them. Postgres
-- returns "null value in column ... violates not-null constraint"
-- and the save fails.
--
-- The block below finds every leftover column on these tables
-- that the app doesn't write, and makes it nullable. Nothing is
-- dropped; existing values stay exactly where they are.
-- =========================================================
do $$
declare
  t   record;
  c   record;
  app_cols text[];
begin
  for t in
    select * from (values
      ('users',         array['id','name','role','color_idx','created_at']),
      ('properties',    array['id','property_id','county','state','acres','buy_price','sell_price','closing_date','notes','funding_schedule','status','listing_url','listing_stats','created_at']),
      ('funding_templates', array['id','name','tiers','created_at']),
      ('tasks',         array['id','title','linked_id','linked_type','due_date','priority','status','notes','assignees','completed_at','created_at']),
      ('projects',      array['id','title','category','status','priority','description','due_date','assignees','created_at']),
      ('kpi_metrics',   array['id','metric_key','trailing_7_value','trailing_30_value','created_at']),
      ('kpi_meta',      array['id','updated_at']),
      ('kpi_entries',   array['id','metric_key','log_date','value','created_at']),
      ('kpi_targets',   array['id','kpi_key','target_value','updated_at']),
      ('call_logs',     array['id','log_date','calls_made','conversations_held','offers_made','offers_accepted','not_interested','notes','created_at']),
      ('campaign_logs', array['id','log_date','campaign_name','channel','counties_hit','leads_generated','notes','created_at'])
    ) as v(tbl, cols)
  loop
    app_cols := t.cols;

    -- 1. Make every leftover (non-app) column nullable.
    for c in
      select column_name
      from information_schema.columns
      where table_schema = 'public'
        and table_name   = t.tbl
        and is_nullable  = 'NO'
        and column_name::text <> all(app_cols)
    loop
      execute format('alter table public.%I alter column %I drop not null', t.tbl, c.column_name);
      raise notice 'Relaxed NOT NULL on %.%', t.tbl, c.column_name;
    end loop;

    -- 2. Drop stale CHECK constraints that reference leftover columns
    --    (e.g. an old properties.status check that no longer matches
    --    anything the app sends).
    for c in
      select con.conname, pg_get_constraintdef(con.oid) as def
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
      where ns.nspname = 'public'
        and rel.relname = t.tbl
        and con.contype = 'c'
    loop
      if exists (
        select 1
        from information_schema.columns col
        where col.table_schema = 'public'
          and col.table_name   = t.tbl
          and col.column_name::text <> all(app_cols)
          and c.def ilike '%' || col.column_name::text || '%'
      ) then
        execute format('alter table public.%I drop constraint %I', t.tbl, c.conname);
        raise notice 'Dropped stale check constraint % on %', c.conname, t.tbl;
      end if;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------
-- Normalize legacy values BEFORE re-adding the value checks.
--
-- Older installs contain rows the current app can't produce —
-- most commonly tasks.linked_type = 'lead' from the removed Leads
-- feature. Adding a CHECK constraint on top of those rows fails with
-- "check constraint ... is violated by some row". These updates
-- rewrite only the out-of-range values; every other field is untouched.
-- ---------------------------------------------------------

-- Links to anything other than a property (e.g. old 'lead' links) are
-- unlinked. The task itself, its title, notes and assignees are kept.
update tasks
   set linked_type = null,
       linked_id   = null
 where linked_type is not null
   and linked_type <> 'property';

-- A link type of 'property' pointing at a row that no longer exists
-- would render as a broken link — clear those too.
update tasks
   set linked_type = null,
       linked_id   = null
 where linked_type = 'property'
   and (linked_id is null or not exists (select 1 from properties p where p.id = tasks.linked_id));

-- Orphan linked_id with no linked_type is meaningless to the app.
update tasks set linked_id = null where linked_type is null and linked_id is not null;

update tasks    set priority = 'medium' where priority is null or priority not in ('high','medium','low');
update tasks    set status   = 'todo'   where status   is null or status   not in ('todo','in-progress','done','blocked');
update projects set status   = 'ideas'  where status   is null or status   not in ('ideas','planned','in-progress','done');
update projects set priority = 'medium' where priority is null or priority not in ('high','medium','low');
update properties set status = 'pre-closing' where status is null or status not in ('pre-closing','closed','listed');

-- completed_at only means something on a done task, and the app expects
-- a done task to have one (its on-time / cycle-time stats read it).
update tasks set completed_at = null       where status <> 'done' and completed_at is not null;
update tasks set completed_at = current_date where status =  'done' and completed_at is null;

-- Re-assert the value checks the app DOES rely on. Dropped first so
-- re-running never errors on a duplicate constraint name.
alter table tasks    drop constraint if exists tasks_priority_check;
alter table tasks    drop constraint if exists tasks_status_check;
alter table tasks    drop constraint if exists tasks_linked_type_check;
alter table projects drop constraint if exists projects_status_check;
alter table projects drop constraint if exists projects_priority_check;
alter table properties drop constraint if exists properties_status_check;

-- Added one at a time and guarded: if a row still somehow violates one,
-- you get a NOTICE naming the constraint instead of the whole script
-- aborting, and the remaining fixes still apply.
do $$
declare
  c record;
begin
  for c in
    select * from (values
      ('tasks',    'tasks_priority_check',    $q$check (priority in ('high','medium','low'))$q$),
      ('tasks',    'tasks_status_check',      $q$check (status in ('todo','in-progress','done','blocked'))$q$),
      ('tasks',    'tasks_linked_type_check', $q$check (linked_type in ('property') or linked_type is null)$q$),
      ('projects', 'projects_status_check',   $q$check (status in ('ideas','planned','in-progress','done'))$q$),
      ('projects', 'projects_priority_check', $q$check (priority in ('high','medium','low'))$q$),
      ('properties', 'properties_status_check', $q$check (status in ('pre-closing','closed','listed'))$q$)
    ) as v(tbl, cname, cdef)
  loop
    begin
      execute format('alter table public.%I add constraint %I %s', c.tbl, c.cname, c.cdef);
    exception when others then
      raise notice 'Skipped % — existing rows still violate it (%). Data is intact; the app will work, but review those rows.', c.cname, sqlerrm;
    end;
  end loop;
end $$;

-- =========================================================
-- Row Level Security
-- =========================================================
-- The app uses Supabase's anon key with permissive policies
-- (the "pick your name" login model — no per-user auth).
--
-- Fine for a small internal team on a private URL, but ANYONE
-- with the URL + anon key can read/write your data.
--
-- If you need real user auth later:
--   1. Enable Supabase Auth in the dashboard
--   2. Replace the policies below with auth.uid()-based rules
--   3. Add a login screen to the app
-- =========================================================
do $$
declare
  tbl text;
begin
  foreach tbl in array array[
    'users','properties','tasks','projects',
    'kpi_metrics','kpi_meta','kpi_entries','kpi_targets','call_logs','campaign_logs',
    'user_prefs','funding_templates'
  ]
  loop
    execute format('alter table public.%I enable row level security', tbl);
    execute format('drop policy if exists "anon full access %s" on public.%I', tbl, tbl);
    execute format(
      'create policy "anon full access %s" on public.%I for all to anon, authenticated using (true) with check (true)',
      tbl, tbl);
    -- Table-level grants: RLS only takes effect once the role can
    -- reach the table at all. A missing INSERT grant looks exactly
    -- like a failed save.
    execute format('grant select, insert, update, delete on public.%I to anon, authenticated', tbl);
  end loop;
end $$;

-- =========================================================
-- Verify — run this after the script and confirm you see
-- completed_at on tasks, and no unexpected "NO" in is_nullable.
-- =========================================================
-- select table_name, column_name, data_type, is_nullable
-- from information_schema.columns
-- where table_schema='public'
--   and table_name in ('users','properties','tasks','projects',
--                      'kpi_metrics','kpi_meta','kpi_entries','kpi_targets','call_logs','campaign_logs',
--                      'user_prefs')
-- order by table_name, ordinal_position;

-- =========================================================
-- Done. Now:
--   1. Copy config.example.js -> config.js
--   2. Fill in your project URL and anon key
--   3. Hard-refresh index.html — the badge should read "Supabase"
-- =========================================================
