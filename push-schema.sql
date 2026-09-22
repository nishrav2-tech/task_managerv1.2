-- =========================================================
-- WEB PUSH NOTIFICATIONS  (2026-09-12)
--
-- ALREADY APPLIED to the live database as migration
-- "web_push_subscriptions_and_notification_queue". Kept here so the repo
-- describes the whole schema and so a fresh project can be rebuilt from files.
-- Safe to re-run: it only adds.
--
-- Three notifications, all carrying the task's title:
--   assigned   the moment a task gains a new assignee
--   due_soon   the day before it's due
--   due_today  on the day
--
-- Why a queue rather than pushing straight from the browser: the person who
-- needs telling is almost never the person whose browser made the change, and
-- a browser that closes mid-save would drop the notification entirely. A row
-- in notification_queue survives that; a separate sender drains it.
-- =========================================================

-- One row per browser/device a person has opted in on. The endpoint URL the
-- push service hands out IS the identity of that device, so it's the key:
-- re-subscribing on the same device updates in place instead of piling up
-- duplicates that would each deliver the same notification.
create table if not exists push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  fail_count  int not null default 0
);
create index if not exists push_subscriptions_user_idx on push_subscriptions(user_id);

-- What still needs sending. dedupe_key is what makes the whole thing safe to
-- run on a timer: every notification has exactly one key, and the unique index
-- means queueing it twice is a no-op rather than a second buzz in someone's
-- pocket. The due-date keys include the date, so MOVING a task's due date
-- correctly earns it a fresh reminder while leaving it alone does not.
create table if not exists notification_queue (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,
  task_id     uuid,
  kind        text not null,
  title       text not null,
  body        text not null,
  dedupe_key  text not null unique,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  attempts    int not null default 0,
  last_error  text
);
create index if not exists notification_queue_pending_idx
  on notification_queue(created_at) where sent_at is null;

-- "Today" is Central, everywhere, matching the app.
create or replace function crm_today()
returns date language sql stable set search_path = public, pg_temp as $$
  select (now() at time zone 'America/Chicago')::date;
$$;

-- A task gained an assignee -> queue one notification per NEW assignee.
-- Only new ones: re-saving a task after editing its notes must not re-notify
-- everybody already on it.
-- SECURITY DEFINER is required (fixed 2026-09-22): the trigger fires as the
-- browser's anon role, which has no rights on notification_queue. Without it,
-- EVERY new task with an assignee, and every edit that adds an assignee,
-- failed with "permission denied for table notification_queue" — the task
-- simply never saved.
create or replace function queue_task_assignment()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  newly uuid[];
  due_txt text;
begin
  if new.status = 'done' then return new; end if;

  if tg_op = 'INSERT' then
    newly := new.assignees;
  else
    select coalesce(array_agg(a), '{}')
      into newly
      from (select unnest(new.assignees)
            except
            select unnest(coalesce(old.assignees, '{}'))) s(a);
  end if;

  if newly is null or array_length(newly, 1) is null then return new; end if;

  due_txt := case
    when new.due_date is null then 'No due date'
    when new.due_date = crm_today() then 'Due today'
    when new.due_date = crm_today() + 1 then 'Due tomorrow'
    when new.due_date < crm_today() then 'Overdue - was due ' || to_char(new.due_date, 'Mon FMDD')
    else 'Due ' || to_char(new.due_date, 'Mon FMDD')
  end;

  insert into notification_queue (user_id, task_id, kind, title, body, dedupe_key)
  select u, new.id, 'assigned', 'New task for you', new.title || E'\n' || due_txt,
         'assigned:' || new.id || ':' || u
    from unnest(newly) u
  on conflict (dedupe_key) do nothing;

  return new;
end $$;

drop trigger if exists tasks_assignment_notify on tasks;
create trigger tasks_assignment_notify
  after insert or update of assignees on tasks
  for each row execute function queue_task_assignment();

-- Due-date sweep. Run daily; queues "due tomorrow" and "due today" for every
-- still-open task that has assignees. Idempotent by dedupe_key, so running it
-- twice in a day (or catching up after an outage) sends nothing extra.
create or replace function queue_due_notifications()
returns int language plpgsql as $$
declare
  n int;
begin
  with queued as (
    insert into notification_queue (user_id, task_id, kind, title, body, dedupe_key)
    select u,
           t.id,
           case when t.due_date = crm_today() then 'due_today' else 'due_soon' end,
           case when t.due_date = crm_today() then 'Due today' else 'Due tomorrow' end,
           t.title,
           case when t.due_date = crm_today() then 'due0:' else 'due1:' end
             || t.id || ':' || u || ':' || t.due_date
      from tasks t, unnest(t.assignees) u
     where t.status <> 'done'
       and t.due_date in (crm_today(), crm_today() + 1)
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into n from queued;
  return n;
end $$;

-- Access. push_subscriptions is written by the app with the anon key, same as
-- every other table here. notification_queue deliberately gets NO anon policy:
-- only the Edge Function (service role, which bypasses RLS) touches it, so a
-- leaked anon key can't read who is being told what.
alter table push_subscriptions enable row level security;
drop policy if exists "anon full access push_subscriptions" on push_subscriptions;
create policy "anon full access push_subscriptions" on push_subscriptions
  for all to anon, authenticated using (true) with check (true);
grant select, insert, update, delete on push_subscriptions to anon, authenticated;

alter table notification_queue enable row level security;
revoke all on notification_queue from anon, authenticated;
