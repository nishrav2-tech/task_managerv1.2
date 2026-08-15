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

Superseded by the section below — `ghl-webhook` is now deployed and in
active use, not just sitting in the repo. `ghl-kpi-rollup` is still
unused; `ghl-hourly-poll`'s own built-in rollup step covers that.

## 6. Closing the poll's blind spot: real-time stage-change webhook

**Why this exists:** `ghl-hourly-poll` (now running every 5 minutes, see
below) only sees an opportunity's *current* stage each time it runs. If
a lead enters a stage and moves on again before the next run, that visit
never generates an event — it's invisible, permanently. Confirmed
2026-08-15: this was silently undercounting `hotLeadsProduced` (only 9
"Priority Offer Ready" events ever captured against 342 total leads
produced) and skewing `offerPrepHrs`, since both are reconstructed from
the same gap-prone event log.

**The fix:** `ghl-webhook` (deployed, tested, live at
`https://yahosblylysopbxgztvg.supabase.co/functions/v1/ghl-webhook`) logs
one `ghl_events` row per real GHL stage-change event, the instant it
happens — no polling gap. It runs *alongside* `ghl-hourly-poll`, not
instead of it; the poll still covers contacts/conversations and is a
safety net if a webhook delivery ever gets dropped.

**Poll frequency bumped as an immediate stopgap** — `ghl-hourly-poll`'s
cron schedule was changed from `0 * * * *` (hourly) to `*/5 * * * *`
(every 5 minutes) on 2026-08-15. This alone doesn't close the gap (a lead
that enters and leaves a stage within 5 minutes is still missed) but
shrinks the window a lot until the webhook below is fully wired up.

### Set up the GHL side (one Workflow per event type you want live)

The webhook secret is already stored in Supabase (`app_secrets` table,
key `GHL_WEBHOOK_SECRET`) — the function reads it from there, same
pattern as `lead-entry-lag`. The URL to POST to is:

```
https://yahosblylysopbxgztvg.supabase.co/functions/v1/ghl-webhook?secret=<value from app_secrets.GHL_WEBHOOK_SECRET>
```

In GHL: **Automation → Workflows → Create Workflow**. For the stage-lag
gap specifically, the one that matters most:

1. **Trigger:** "Opportunity Stage Changed" (or "Pipeline Stage Changed"
   — exact trigger name varies by GHL account version), scoped to the
   **Lead --> Contract** pipeline, all stages.
2. **Action:** "Webhook" (Custom Webhook / Inbound Webhook action).
   - Method: POST
   - URL: the one above
   - Body type: JSON
   - Body — map GHL's own merge fields into these exact keys (the
     function also accepts GHL's native field names like
     `pipelineStageId`/`opportunityId` directly, but explicit is safer):
     ```json
     {
       "event_type": "OpportunityStageUpdate",
       "opportunity_id": "{{opportunity.id}}",
       "pipeline_id": "{{opportunity.pipeline_id}}",
       "pipelineStageId": "{{opportunity.pipeline_stage_id}}",
       "contactId": "{{contact.id}}",
       "occurred_at": "{{opportunity.date_updated}}"
     }
     ```
   The exact merge-tag names (`{{opportunity.id}}` etc.) need to be
   picked from GHL's own variable picker inside the workflow builder —
   the names above are the common ones but GHL sometimes labels them
   slightly differently per account. Whatever the real tag turns out to
   be, just make sure it lands in the JSON keys shown above.
3. Publish the Workflow.

Optional, same pattern, for full parity with what the poll already
half-covers: a second Workflow on "Opportunity Created" trigger sending
`"event_type": "OpportunityCreate"` with the same fields, and a third on
"Contact Changed"/"Custom Field Updated" sending
`"event_type": "ContactUpdate"` with `contactId` and whatever custom
field payload GHL includes.

### Verify it's working

```sql
select event_type, count(*), max(occurred_at) as most_recent
from ghl_events
where raw->>'event_type' is not null  -- webhook-sourced rows always set this
group by event_type order by 2 desc;
```

Trigger a real stage change on a test opportunity in GHL, then re-run
that query — you should see a fresh `OpportunityStageUpdate` row with
`most_recent` matching right now.
