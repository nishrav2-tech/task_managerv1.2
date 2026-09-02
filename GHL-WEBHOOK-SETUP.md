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
2. **Action:** "Webhook".
   - Method: POST
   - URL: the one above (secret already in the query string)
   - **Custom Data:** this action does NOT support a custom JSON body —
     confirmed against GHL's own "Webhook Action Data Format Guide". For
     an opportunity-stage trigger, GHL automatically sends opportunity
     fields at the root of the payload as part of its "standard data":
     `id` (the opportunity id), `pipeline_id`, and `pipleline_stage`
     (GHL's own typo — this is the stage **name**, not an id). The Edge
     Function maps that name to the right stage id itself (see
     `STAGE_NAME_TO_ID` in `supabase/functions/ghl-webhook/index.ts`),
     so nothing needs to be done for those three.
     The only thing to add manually is one Custom Data row, with the
     **key typed as plain text** (don't use the tag/merge icon on the
     key field, only on values — and this one doesn't need a merge tag
     at all):
     | Key | Value |
     |---|---|
     | `event_type` | `OpportunityStageUpdate` (literal text) |
   - Leave Headers empty.
3. Save the action, then **publish** the Workflow (drafts don't fire).

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

## 7. Auto-populating the Zillow Listing link on a property

`ghl-hourly-poll`'s `pollContacts()` step now also reads each GHL contact's
**Zillow Listing** custom field (Closing and Marketing section) and, when it
CHANGES, writes it straight into that property's Listing Details tab in the
CRM (`properties.listing_url`) — no more copy-pasting the link over by hand.

**How it finds the right property:** by matching `properties.property_id`
against the GHL contact id — the same id already used when the property was
produced from that lead. There's no separate linking field to fill in; if a
property's Property ID field already holds the GHL contact id that produced
it, this works automatically.

**One-time setup — the field id isn't known yet, so the sync is currently a
no-op:**

1. Run `python3 ghl-probe.py`, find section **"4b. CUSTOM FIELDS"**, and
   look for the field named `"Zillow Listing"`. Copy its `id` (looks like
   `SsD1lNNGo0UKFQG0K4Ti`, same shape as `FIELD_CONTRACT_STATUS` above).
2. Supabase dashboard → **Edge Functions → Secrets** → add
   `GHL_FIELD_ZILLOW_LISTING` = that id.

That's it — no redeploy needed, no new GHL Workflow. The existing 5-minute
poll picks it up on its next run. A property only gets overwritten when the
GHL value actually **changes** since the last poll (tracked in
`ghl_contact_state.zillow_listing_url`), so a link someone already fixed up
by hand in the CRM won't get silently reset to the same GHL value on every
cycle — it's only touched again once the GHL side changes.

### Verify it's working

```sql
select contact_id, zillow_listing_url, updated_at
from ghl_contact_state
where zillow_listing_url is not null
order by updated_at desc
limit 10;
```

Rows here confirm the poll is reading the field at all. Then check it
actually landed on the property:

```sql
select property_id, listing_url from properties where listing_url is not null;
```

If a property's `property_id` matches one of the `contact_id`s above but
`listing_url` didn't update, the most likely cause is the property's
Property ID field not exactly matching the GHL contact id (extra spaces,
wrong id pasted, etc.) — the match is an exact string comparison.

## 8. The "Purchase" KPI section — New Contract → Close pipeline timing

ADDED 2026-09-02. This is a **separate GHL pipeline** from Lead →
Contract (everything in sections 1–7 above) — it covers a signed
contract through closing: New Contract → EMD Confirmed → DD Phase II →
Funding → DD Phase III → Post Closing Docs. Five KPI tiles report the
average hours from an opportunity's first entry into **New Contract** to
its first entry into each of the other five stages. They're switched on
in the app already but will read "no data" until both pieces below use
your account's real ids instead of the placeholders currently in the
code.

**1. Get your real pipeline and stage ids.** Run `python3 ghl-probe.py`
from the repo root — it prints every pipeline's name alongside each of
its stages' names and ids, safely (no contact data). Find the New
Contract → Close pipeline (or whatever it's actually named in your GHL
account) and copy its pipeline id and the six stage ids for New
Contract, EMD Confirmed, DD Phase II, Funding, DD Phase III, and Post
Closing Docs. If any of those stage names differ from what's in GHL,
use the exact names your account has.

**2. Fill them into two places, matching exactly:**

- `ghl-events-schema.sql` → `purchase_stage_avgs()` → the
  `PIPE_PURCHASE` / `STAGE_NEW_CONTRACT` / `STAGE_EMD_CONFIRMED` /
  `STAGE_DD_PHASE_2` / `STAGE_FUNDING` / `STAGE_DD_PHASE_3` /
  `STAGE_POST_CLOSING_DOCS` constants. Re-run the whole file in the SQL
  Editor after editing (safe — `create or replace function`).
- `supabase/functions/ghl-webhook/index.ts` → `STAGE_NAME_TO_ID` → the
  six entries added under the "ADDED 2026-09-02" comment. Redeploy the
  `ghl-webhook` function after editing.

Both sides need the *same* ids — the SQL function reads `ghl_events`
rows the webhook already wrote, keyed by `stage_id`; if the two disagree
about which id means "EMD Confirmed," the average silently comes out
wrong instead of erroring.

**3. Point a GHL Workflow at the webhook**, same pattern as step 6
above: **Automation → Workflows → Create Workflow** → trigger
"Opportunity Stage Changed," scoped to the New Contract → Close pipeline
(all stages) → action "Webhook" → same URL as section 6 (secret already
in the query string) → one Custom Data row, `event_type` =
`OpportunityStageUpdate` (literal text) → publish.

### Verify it's working

```sql
select stage_id, count(*), max(occurred_at) as most_recent
from ghl_events
where event_type = 'OpportunityStageUpdate'
  and pipeline_id = 'the pipeline id you filled in above'
group by stage_id order by 2 desc;
```

Rows here mean the webhook is capturing this pipeline's stage changes.
Then in the app, open the KPI Tracker tab and check the Purchase
section's tiles — each one's "Reached <stage>" breakdown row (click a
tile to see it) should now show a real number instead of "no data" once
at least one opportunity has moved from New Contract into that stage.
