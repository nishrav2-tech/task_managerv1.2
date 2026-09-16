/**
 * send-push — drains notification_queue and delivers each row as a Web Push
 * notification to every device the recipient has opted in on.
 *
 * Called two ways, both from pg_cron (see PUSH-SETUP.md):
 *   every 5 min          deliver whatever is waiting
 *   once a day, ?sweep=1 run the due-date sweep first, then deliver
 *
 * Auth is a shared secret, the same pattern ghl-hourly-poll uses, because
 * "Verify JWT" has to be off for pg_cron to reach the function at all.
 *
 * Two delivery rules worth knowing:
 *  - A row is marked sent once it has been ATTEMPTED against every device,
 *    not once every device accepted it. A teammate whose phone is off still
 *    gets it when the phone comes back — holding it open for retry is the
 *    push service's job, and re-sending from here would double up on
 *    everyone whose delivery already worked.
 *  - 404/410 from a push service means that subscription is permanently dead
 *    (app deleted, browser data cleared). Those are removed immediately —
 *    they never recover, and left in place they would fail forever.
 */
import webpush from "npm:web-push@3.6.7";
import { createClient } from "jsr:@supabase/supabase-js@2";

const VAPID_PUBLIC  = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";
const PUSH_SECRET   = Deno.env.get("PUSH_SECRET") ?? "";
const APP_URL       = Deno.env.get("APP_URL") ?? "./index.html";

const BATCH = 200;          // rows per invocation
const MAX_ATTEMPTS = 5;     // stop retrying a row that keeps erroring

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const db = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const given = req.headers.get("x-push-secret") ?? url.searchParams.get("secret") ?? "";
  if (!PUSH_SECRET || given !== PUSH_SECRET) return json({ error: "unauthorized" }, 401);
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
    return json({ error: "VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY are not set" }, 500);
  }

  let swept = 0;
  if (url.searchParams.get("sweep") === "1") {
    const { data, error } = await db.rpc("queue_due_notifications");
    if (error) return json({ error: "sweep failed: " + error.message }, 500);
    swept = data ?? 0;
  }

  const { data: pending, error: qErr } = await db
    .from("notification_queue")
    .select("id,user_id,task_id,kind,title,body,attempts")
    .is("sent_at", null)
    .lt("attempts", MAX_ATTEMPTS)
    .order("created_at", { ascending: true })
    .limit(BATCH);
  if (qErr) return json({ error: "queue read failed: " + qErr.message }, 500);
  if (!pending?.length) return json({ swept, pending: 0, sent: 0, devices: 0, dropped: 0 });

  // One lookup covering every recipient in the batch, rather than one per row.
  const userIds = [...new Set(pending.map((r) => r.user_id))];
  const { data: subs, error: sErr } = await db
    .from("push_subscriptions")
    .select("id,user_id,endpoint,p256dh,auth,fail_count")
    .in("user_id", userIds);
  if (sErr) return json({ error: "subscription read failed: " + sErr.message }, 500);

  type Sub = { id: string; user_id: string; endpoint: string; p256dh: string; auth: string; fail_count: number };
  const byUser = new Map<string, Sub[]>();
  for (const s of (subs ?? []) as Sub[]) {
    if (!byUser.has(s.user_id)) byUser.set(s.user_id, []);
    byUser.get(s.user_id)!.push(s);
  }

  let sent = 0, devices = 0, dropped = 0;
  const deadSubs: string[] = [];
  const now = () => new Date().toISOString();

  for (const row of pending) {
    const targets = byUser.get(row.user_id) ?? [];

    // Nobody opted in. Retire the row rather than letting it sit forever and
    // then arrive as a surprise weeks later when they finally enable push.
    if (!targets.length) {
      await db.from("notification_queue")
        .update({ sent_at: now(), last_error: "no subscribed devices" })
        .eq("id", row.id);
      continue;
    }

    const payload = JSON.stringify({
      title: row.title,
      body: row.body,
      // One tag per task+kind: a phone that was off for two days shows the
      // current state of that reminder, not a stack of identical ones.
      tag: `${row.kind}:${row.task_id ?? row.id}`,
      url: APP_URL,
    });

    let lastError: string | null = null;
    for (const t of targets) {
      try {
        await webpush.sendNotification(
          { endpoint: t.endpoint, keys: { p256dh: t.p256dh, auth: t.auth } },
          payload,
        );
        devices++;
        await db.from("push_subscriptions")
          .update({ last_ok_at: now(), fail_count: 0 })
          .eq("id", t.id);
      } catch (err) {
        const status = (err as { statusCode?: number })?.statusCode ?? 0;
        lastError = `${status || "err"}: ${(err as Error)?.message ?? String(err)}`;
        if (status === 404 || status === 410) {
          deadSubs.push(t.id);                       // gone for good
          dropped++;
        } else {
          await db.from("push_subscriptions")
            .update({ fail_count: (t.fail_count ?? 0) + 1 })
            .eq("id", t.id);
        }
      }
    }

    await db.from("notification_queue")
      .update({ sent_at: now(), attempts: (row.attempts ?? 0) + 1, last_error: lastError })
      .eq("id", row.id);
    sent++;
  }

  if (deadSubs.length) await db.from("push_subscriptions").delete().in("id", deadSubs);

  return json({ swept, pending: pending.length, sent, devices, dropped });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
