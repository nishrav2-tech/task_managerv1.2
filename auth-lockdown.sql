-- =========================================================
-- Sign-in & access control (2026-09-23)
-- =========================================================
-- Every table is readable and writable ONLY by a signed-in login that is
-- linked to an ACTIVE row in public.users. The anon key on its own gets
-- nothing. Admins (users.app_role = 'admin') additionally manage the users
-- table; logins themselves are created by the admin-users Edge Function.
--
-- FRESH PROJECT: after running this, nobody can see anything until the first
-- admin is linked by hand. Create their login in Supabase -> Authentication
-- -> Users -> Add user, then:
--   update public.users set auth_id = '<auth user id>', email = '<email>',
--          app_role = 'admin', active = true where name = '<their name>';
-- =========================================================

alter table public.users add column if not exists auth_id uuid unique references auth.users(id) on delete set null;
alter table public.users add column if not exists email text;
alter table public.users add column if not exists app_role text not null default 'member';
alter table public.users add column if not exists active boolean not null default true;
alter table public.users drop constraint if exists users_app_role_check;
alter table public.users add constraint users_app_role_check check (app_role in ('admin','member'));

-- SECURITY DEFINER so policies on public.users can call them without recursing.
create or replace function public.current_member_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.users where auth_id = auth.uid() and active limit 1
$$;
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.users where auth_id = auth.uid() and active)
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.users where auth_id = auth.uid() and active and app_role = 'admin')
$$;
revoke execute on function public.current_member_id(), public.is_member(), public.is_admin() from public, anon;
grant execute on function public.current_member_id(), public.is_member(), public.is_admin() to authenticated, service_role;

-- Workspace tables: any active teammate, full read/write.
do $$
declare
  tbl text;
begin
  foreach tbl in array array[
    'properties','tasks','projects',
    'kpi_metrics','kpi_meta','kpi_entries','kpi_targets','call_logs','campaign_logs',
    'funding_templates','audit_standards','audit_logs',
    'activity_entries','call_sessions','campaign_sends','dept_log_entries'
  ]
  loop
    execute format('alter table public.%I enable row level security', tbl);
    execute format('drop policy if exists "anon full access %s" on public.%I', tbl, tbl);
    execute format('drop policy if exists "members full access %s" on public.%I', tbl, tbl);
    execute format(
      'create policy "members full access %s" on public.%I for all to authenticated using (public.is_member()) with check (public.is_member())',
      tbl, tbl);
    execute format('revoke all on public.%I from anon', tbl);
    execute format('grant select, insert, update, delete on public.%I to authenticated', tbl);
  end loop;
end $$;

-- users: every teammate can see the team; only admins change it.
alter table public.users enable row level security;
drop policy if exists "anon full access users" on public.users;
drop policy if exists "members read users" on public.users;
drop policy if exists "admins write users" on public.users;
create policy "members read users" on public.users for select to authenticated using (public.is_member());
create policy "admins write users" on public.users for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.users from anon;
grant select, insert, update, delete on public.users to authenticated;

-- user_prefs: your own row (admins: any, for Reset all data).
alter table public.user_prefs enable row level security;
drop policy if exists "anon full access user_prefs" on public.user_prefs;
drop policy if exists "own prefs" on public.user_prefs;
create policy "own prefs" on public.user_prefs for all to authenticated
  using (user_id = public.current_member_id() or public.is_admin())
  with check (user_id = public.current_member_id() or public.is_admin());
revoke all on public.user_prefs from anon;
grant select, insert, update, delete on public.user_prefs to authenticated;

-- push_subscriptions: a device can only be registered to the person signed in on it.
alter table public.push_subscriptions enable row level security;
drop policy if exists "anon full access push_subscriptions" on public.push_subscriptions;
drop policy if exists "members own push" on public.push_subscriptions;
create policy "members own push" on public.push_subscriptions for all to authenticated
  using (public.is_member())
  with check (public.is_member() and user_id = public.current_member_id());
revoke all on public.push_subscriptions from anon;
grant select, insert, update, delete on public.push_subscriptions to authenticated;

-- Report functions (SECURITY DEFINER, so they bypass RLS): no longer callable
-- with just the anon key. The Edge Functions use the service role and are unaffected.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'avg_touches_before_deal','avg_touches_before_lost','cohort_from_contacted','cohort_lead_conversion',
      'purchase_stage_avgs','increment_kpi_entry','set_kpi_entry','refresh_ghl_kpis','refresh_sc_process_kpis',
      'queue_due_notifications','crm_today')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
