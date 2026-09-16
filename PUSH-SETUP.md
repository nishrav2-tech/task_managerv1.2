# Push notifications — setup

Three notifications, each naming the task:

| When | Title | Body |
|---|---|---|
| A task gains a new assignee | **New task for you** | task title + when it's due |
| The day before it's due | **Due tomorrow** | task title |
| On the day it's due | **Due today** | task title |

They come from the server, so they arrive whether or not the app is open.

The database side is **already done** — tables, trigger and sweep function are
live. What's left is four manual steps: keys, function, secrets, schedule.

---

## What was already applied to Supabase

Migration `web_push_subscriptions_and_notification_queue`:

- `push_subscriptions` — one row per device that has opted in, keyed on the
  push endpoint so re-subscribing updates in place instead of duplicating.
- `notification_queue` — what still needs sending, with a **`dedupe_key`**
  unique index. That key is what makes the whole thing safe to run on a timer:
  queueing the same notification twice is a no-op rather than a second buzz.
- `tasks_assignment_notify` — trigger that queues on new assignees only, so
  editing a task's notes doesn't re-notify everyone already on it.
- `queue_due_notifications()` — the daily sweep. Verified: it queued 9 real
  notifications on first run and 0 on the second.

`notification_queue` deliberately has **no anon policy**. Only the Edge
Function (service role) touches it, so a leaked anon key can't read who's being
told what.

---

## 1. Generate the VAPID key pair

On your Mac:

```bash
npx --yes web-push generate-vapid-keys
```

It prints a **Public Key** and a **Private Key**. Keep the terminal open.

> The public key identifies you to the push service and is safe to ship in the
> app. The private key is what proves a push is really from you — it goes only
> into the Edge Function's secrets, never into git, never into the browser.

## 2. Create the Edge Function

Supabase dashboard → **Edge Functions** → **Create a new function**, named
exactly `send-push`. Paste the contents of
`supabase/functions/send-push/index.ts`. Deploy.

Then **turn OFF "Verify JWT"** on that function, same as `ghl-hourly-poll` —
otherwise pg_cron's request is rejected before the function runs. It does its
own auth against `PUSH_SECRET`.

## 3. Set the secrets

Edge Functions → **Secrets**:

| Secret | Value |
|---|---|
| `VAPID_PUBLIC_KEY` | public key from step 1 |
| `VAPID_PRIVATE_KEY` | private key from step 1 |
| `VAPID_SUBJECT` | `mailto:you@yourdomain.com` — a real address; push services reject some requests without one |
| `PUSH_SECRET` | any long random string you invent |
| `APP_URL` | the GitHub Pages URL, so tapping a notification opens the app |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.

## 4. Add the public key to GitHub

Repo → Settings → Secrets and variables → **Actions** → New repository secret:

- Name: `VAPID_PUBLIC_KEY`
- Value: the **public** key from step 1

The deploy workflow writes it into `config.js`. Without it the app deploys fine
but the push button stays disabled and says so.

## 5. Schedule it

SQL Editor, once. Replace `PROJECT_REF` and `YOUR_PUSH_SECRET`:

```sql
-- Deliver whatever is waiting, every 5 minutes.
select cron.schedule(
  'send-push-drain',
  '*/5 * * * *',
  $$
  select net.http_post(
    url     := 'https://PROJECT_REF.supabase.co/functions/v1/send-push',
    headers := '{"Content-Type":"application/json","x-push-secret":"YOUR_PUSH_SECRET"}'::jsonb,
    body    := '{}'::jsonb
  );
  $$
);

-- Once a day at 7am Central: sweep for due/due-tomorrow, then deliver.
-- 12:00 UTC is 7am CDT. Between early November and mid-March that lands at
-- 6am Central instead — change to '0 13 * * *' if you'd rather it stay 7am
-- through the winter.
select cron.schedule(
  'send-push-daily-sweep',
  '0 12 * * *',
  $$
  select net.http_post(
    url     := 'https://PROJECT_REF.supabase.co/functions/v1/send-push?sweep=1',
    headers := '{"Content-Type":"application/json","x-push-secret":"YOUR_PUSH_SECRET"}'::jsonb,
    body    := '{}'::jsonb
  );
  $$
);
```

---

## Turning it on, per person

Each teammate does this **on their own phone, signed in as themselves**:

1. Open the app → **Dashboard** → pick themselves in "Who's using this device?"
2. **Settings → Push notifications → Turn on push for this device**
3. Accept the browser prompt

**iPhone/iPad users must install the app first.** iOS only allows web push from
an installed PWA: Share → **Add to Home Screen**, then open it from the home
screen and enable push there. The button stays disabled in plain Safari and
tells them why. Android and desktop work straight from the browser.

On a shared device there's one subscription, and it follows whoever is
currently selected — switching user re-points it rather than stacking a second.

---

## Checking it works

```sql
-- Who has opted in
select user_id, created_at, last_ok_at, fail_count from push_subscriptions;

-- Recent traffic, newest first
select kind, title, body, sent_at, last_error
from notification_queue order by created_at desc limit 20;

-- Force a run without waiting for cron
select net.http_post(
  url     := 'https://PROJECT_REF.supabase.co/functions/v1/send-push?sweep=1',
  headers := '{"Content-Type":"application/json","x-push-secret":"YOUR_PUSH_SECRET"}'::jsonb,
  body    := '{}'::jsonb
);
```

`last_error = 'no subscribed devices'` means the notification was correct but
nobody had opted in — the commonest thing to see before step 5 is done by
everyone.

A row is marked sent once it has been **attempted** against every device, not
once every device accepted. A phone that's off still gets it when it comes back
— holding it is the push service's job, and re-sending from here would double
up on everyone whose delivery already worked.

Dead subscriptions (404/410 — app deleted, browser data cleared) are removed
automatically. Those never recover, and left in place they'd fail forever.
