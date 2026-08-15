# Wiring up automated KPI filling — no terminal required

Everything below uses the Supabase dashboard only. No GHL webhook or
Workflow setup needed — one function checks GHL's API once an hour
and does everything itself.

## 1. Run the schema

Supabase dashboard → **SQL Editor** → New query → paste the entire contents
of `ghl-events-schema.sql` → **Run**.

This adds the event log, the "counted once, permanently" lock table, the
poll's memory of what it last saw, and the `refresh_ghl_kpis()` function
that does the actual KPI math. Safe to re-run any time — it only adds,
never drops.

## 2. Create the Edge Function

Supabase dashboard → **Edge Functions** → **Create a new function**.
Name it exactly `ghl-hourly-poll`. Paste in the full contents of
`supabase/functions/ghl-hourly-poll/index.ts`. Deploy.

**Then turn OFF "Verify JWT"** for this function — it's in the
function's own configuration/settings area on its detail page. Leave it
on and every call gets rejected with:

```
{"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"Missing authorization header"}
```

...because Supabase's gateway blocks the request before the function
runs. That's safe to disable here: the function does its own auth
check against `ROLLUP_SECRET` (see step 3) and returns 401 to anyone
who doesn't have it. You're substituting our shared-secret check for
Supabase's JWT check, not removing protection.

## 3. Set the secrets it needs

Still in **Edge Functions**, find **Secrets** (shared across all
functions in the project). Add:

- `GHL_TOKEN` — the same private integration token from `.env`
- `GHL_LOCATION_ID` — same as in `.env`
- `ROLLUP_SECRET` — make up a long random string; this is what proves
  the request scheduling the poll is actually yours
- `ROLLUP_TIMEZONE` — optional, defaults to `America/Chicago`

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` don't need setting — Supabase
injects those into every Edge Function automatically.

## 4. Schedule it hourly

**SQL Editor**, run this once:

```sql
select cron.schedule(
  'ghl-hourly-poll',
  '0 * * * *',  -- every hour, on the hour
  $$
  select net.http_post(
    url := 'https://yahosblylysopbxgztvg.supabase.co/functions/v1/ghl-hourly-poll?secret=YOUR_ROLLUP_SECRET',
    headers := '{"content-type": "application/json"}'::jsonb
  );
  $$
);
```

Swap in the real `ROLLUP_SECRET` value. If this errors saying `cron` or
`net` doesn't exist, go to **Database → Extensions** first and enable
`pg_cron` and `pg_net`, then re-run the query above.

## 5. Verify it's actually working

You don't have to wait an hour — trigger it once by hand first. Visit
in a browser:

```
https://yahosblylysopbxgztvg.supabase.co/functions/v1/ghl-hourly-poll?secret=YOUR_ROLLUP_SECRET
```

You should get back JSON like `{"ok":true,"oppEvents":4,...}`. Then in
SQL Editor:

```sql
select event_type, count(*) from ghl_events group by event_type order by 2 desc;
```

Rows here mean it's reading GHL correctly. Then:

```sql
select * from kpi_entries where log_date >= current_date - 3 order by log_date desc;
```

Numbers here mean the whole pipeline works end to end — the dashboard
picks these up automatically, no further action needed.

**One thing worth checking on that first manual run:** the shape of a
contact's custom fields wasn't confirmed against a live populated
example (see the caveat at the top of `ghl-events-schema.sql`). Run:

```sql
select raw from ghl_events where event_type = 'ContactUpdate' limit 3;
```

If contract-status/lead-notes detection doesn't seem to be firing once
someone actually fills those in, this is the first thing to check —
tell me what that query returns and I'll adjust the field-matching
logic in the poll function.

## What's still not covered by this

- Due Diligence + Funding group (`ddStage2Done`, `emdSubmitted`,
  `contractsExecuted`, etc.) — not scoped
- Smarter Contact metrics beyond lead-entry-lag — the other session's
  function covers response-lag timing, now writing into `scProcessHrs`/
  `scLeadsProcessed`; `smsSent` isn't wired up
- QuickSigner — nothing built

## A note on the older `ghl-webhook` / `ghl-kpi-rollup` files

Still in the repo from an earlier design, and they still work if you
ever want true real-time webhooks instead of hourly polling. Not
required — `ghl-hourly-poll` is fully self-contained and replaces
both. Safe to ignore or delete them.
