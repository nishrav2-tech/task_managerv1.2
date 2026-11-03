// gcal (2026-11-01): per-user Google Calendar link for the CRM's dashboard
// calendar.
//
// Each signed-in teammate connects their OWN Google account. The Google
// refresh token is stored in public.gcal_connections keyed by that person's
// auth user id; the table has RLS on with no policies, so only this function
// (service role) can read it. Every action below works on the caller's own
// connection, taken from their session token, never from a user id sent by
// the page, so one person can't read or move another person's events.
//
// Google OAuth client: public.app_secrets
//   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET   from Google Cloud Console
//   GCAL_STATE_SECRET                        random, signs the OAuth state
// Authorized redirect URI to register in Google Cloud Console:
//   https://<project>.supabase.co/functions/v1/gcal
//
// POST (Authorization: Bearer <user session>) {action, ...}
//   status                       {configured, connected, email}
//   auth_url   {returnTo}        {url} to send the browser to Google
//   events     {timeMin,timeMax} {events:[...]} from calendars shown in Google
//   move       {calendarId, eventId, start, end}   reschedules one event
//   disconnect                   removes the CRM's task events, revokes, deletes the connection
//   task_changed {taskId}        bring one task's Google events up to date
//   sync_all                     push all of the caller's open dated tasks now
//   schedule_task {taskId,date,startMin,endMin}  give the caller's copy of a task a time window
//   unschedule_task {taskId}     make the caller's copy all-day again
// GET ?code=&state=  Google's redirect back after sign-in.
//
// CRM tasks -> Google (2026-11-03): after any task is saved or deleted the CRM
// sends task_changed. Each open task with a due date becomes an all-day event
// on the primary Google Calendar of every assignee (or its creator, if
// unassigned) who has connected Google. Done, undated or deleted tasks have
// their event removed. Events are found again by
// extendedProperties.private.crmTaskId, so no extra table is needed, and the
// CRM's own calendar skips them so tasks don't show twice.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const REDIRECT = `${URL_}/functions/v1/gcal`;
const SCOPES = [
  "openid", "email",
  "https://www.googleapis.com/auth/calendar.events",
  "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
].join(" ");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rates-secret",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const admin = () => createClient(URL_, SERVICE, { auth: { persistSession: false } });

async function secrets(db: ReturnType<typeof admin>) {
  const { data } = await db.from("app_secrets").select("key,value")
    .in("key", ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GCAL_STATE_SECRET", "RATES_SECRET"]);
  return Object.fromEntries((data || []).map((r) => [r.key, r.value])) as Record<string, string>;
}

// ---- signed OAuth state: who is connecting and where to send them back ----
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
async function hmac(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return b64u(new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg))));
}
async function signState(key: string, payload: unknown) {
  const body = b64u(new TextEncoder().encode(JSON.stringify(payload)));
  return `${body}.${await hmac(key, body)}`;
}
async function readState(key: string, state: string) {
  const [body, sig] = state.split(".");
  if (!body || !sig || (await hmac(key, body)) !== sig) return null;
  const p = JSON.parse(new TextDecoder().decode(unb64u(body)));
  return p.exp > Date.now() ? p : null;
}
// Only send people back to a real web page (the CRM), never anywhere odd.
function safeReturn(u: unknown) {
  try {
    const url = new URL(String(u));
    const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
    if (url.protocol === "https:" || (local && url.protocol === "http:")) return url.toString();
  } catch { /* fall through */ }
  return null;
}
function backTo(returnTo: string, result: string) {
  const url = new URL(returnTo);
  url.searchParams.set("gcal", result);
  return new Response(null, { status: 302, headers: { Location: url.toString() } });
}

// ---- tokens ----
async function tokenRequest(params: Record<string, string>) {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
  });
  const d = await r.json();
  if (!r.ok) throw Object.assign(new Error(d.error_description || d.error || "Google token error"), { code: d.error });
  return d;
}
// A live access token for this person, refreshing it when it's about to expire.
async function accessToken(db: ReturnType<typeof admin>, s: Record<string, string>, authId: string) {
  const { data: c } = await db.from("gcal_connections").select("*").eq("auth_id", authId).maybeSingle();
  if (!c) return null;
  if (c.access_token && c.access_expires_at && new Date(c.access_expires_at).getTime() > Date.now() + 60_000) return c.access_token as string;
  try {
    const t = await tokenRequest({
      client_id: s.GOOGLE_CLIENT_ID, client_secret: s.GOOGLE_CLIENT_SECRET,
      refresh_token: c.refresh_token, grant_type: "refresh_token",
    });
    await db.from("gcal_connections").update({
      access_token: t.access_token,
      access_expires_at: new Date(Date.now() + (t.expires_in || 3600) * 1000).toISOString(),
    }).eq("auth_id", authId);
    return t.access_token as string;
  } catch (e) {
    // Revoked in Google, or expired: drop it so the page offers Connect again.
    if ((e as { code?: string }).code === "invalid_grant") await db.from("gcal_connections").delete().eq("auth_id", authId);
    throw e;
  }
}
async function google(token: string, path: string, init: RequestInit = {}) {
  const r = await fetch(`https://www.googleapis.com/calendar/v3${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  const d = r.status === 204 ? {} : await r.json();
  if (!r.ok) throw Object.assign(new Error(d?.error?.message || `Google error ${r.status}`), { status: r.status });
  return d;
}

// ---- CRM tasks -> each person's Google Calendar ----
type Db = ReturnType<typeof admin>;
type Task = { id: string; title: string; due_date: string | null; priority?: string; status?: string; notes?: string | null; assignees?: string[]; created_by?: string | null };
const addDay = (ymd: string) => { const d = new Date(ymd + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); };
const APP_URL = "https://nishrav2-tech.github.io/task_managerv1.2/";
const isGone = (e: unknown) => [404, 410].includes((e as { status?: number }).status || 0);

function taskEventBody(t: Task) {
  const pri = t.priority ? t.priority[0].toUpperCase() + t.priority.slice(1) : "Medium";
  return {
    summary: t.title,
    description: `Utopian CRM task · ${pri} priority${t.notes ? "\n\n" + t.notes : ""}\n\nOpen the CRM: ${APP_URL}`,
    // dateTime: null so a PATCH can turn a timed copy back into an all-day one.
    start: { date: t.due_date, dateTime: null }, end: { date: addDay(t.due_date!), dateTime: null },
    transparency: "transparent",
    reminders: { useDefault: false, overrides: [] },
    extendedProperties: { private: { crmTaskId: t.id } },
  };
}
// The event for a task, keeping a time window someone gave it in the day view
// (a timed copy stays timed, same time of day and length, on the due date).
type GEvent = { id: string; summary?: string; description?: string; start?: { date?: string; dateTime?: string; timeZone?: string }; end?: { date?: string; dateTime?: string; timeZone?: string } };
const isoNoZ = (d: Date) => d.toISOString().slice(0, 19);
function bodyFor(t: Task, ex?: GEvent) {
  const b: Record<string, unknown> & { start: unknown; end: unknown } = taskEventBody(t);
  if (ex && ex.start?.dateTime && ex.end?.dateTime) {
    const tz = ex.start.timeZone || ex.end.timeZone || "America/Chicago";
    const dur = new Date(ex.end.dateTime).getTime() - new Date(ex.start.dateTime).getTime();
    const st = new Date(`${t.due_date}T${ex.start.dateTime.slice(11, 19)}Z`);
    b.start = { date: null, dateTime: isoNoZ(st), timeZone: tz };
    b.end = { date: null, dateTime: isoNoZ(new Date(st.getTime() + Math.max(15 * 60000, dur))), timeZone: tz };
  }
  return b;
}
const evDate = (e: GEvent) => e.start?.date || (e.start?.dateTime || "").slice(0, 10);

// Auth ids of the people this task belongs to: assignees, or the creator if
// nobody is assigned.
async function taskOwners(db: Db, t: Task | null) {
  if (!t) return new Set<string>();
  const ids = (t.assignees && t.assignees.length) ? t.assignees : (t.created_by ? [t.created_by] : []);
  if (!ids.length) return new Set<string>();
  const { data: us } = await db.from("users").select("auth_id,active").in("id", ids);
  return new Set((us || []).filter((u) => u.auth_id && u.active !== false).map((u) => u.auth_id as string));
}
async function taskEvents(token: string, taskId: string) {
  const d = await google(token, `/calendars/primary/events?privateExtendedProperty=${encodeURIComponent("crmTaskId=" + taskId)}&maxResults=10`);
  return (d.items || []).filter((e: { status?: string }) => e.status !== "cancelled") as GEvent[];
}
async function delEvent(token: string, id: string) {
  await google(token, `/calendars/primary/events/${encodeURIComponent(id)}?sendUpdates=none`, { method: "DELETE" })
    .catch((e) => { if (!isGone(e)) throw e; });
}
// Bring one task's events in line with the task as it is now, for everyone
// connected (or just `onlyFor`).
async function syncTask(db: Db, s: Record<string, string>, taskId: string, onlyFor?: string) {
  const { data: t } = await db.from("tasks").select("id,title,due_date,priority,status,notes,assignees,created_by").eq("id", taskId).maybeSingle();
  const live = !!(t && t.due_date && t.status !== "done");
  const owners = live ? await taskOwners(db, t as Task) : new Set<string>();
  let q = db.from("gcal_connections").select("auth_id");
  if (onlyFor) q = q.eq("auth_id", onlyFor);
  const { data: conns } = await q;
  for (const c of conns || []) {
    try {
      const token = await accessToken(db, s, c.auth_id);
      if (!token) continue;
      const found = await taskEvents(token, taskId);
      if (owners.has(c.auth_id)) {
        const body = JSON.stringify(bodyFor(t as Task, found[0]));
        if (found.length) {
          await google(token, `/calendars/primary/events/${encodeURIComponent(found[0].id)}?sendUpdates=none`, { method: "PATCH", body });
          for (const extra of found.slice(1)) await delEvent(token, extra.id);
        } else {
          await google(token, `/calendars/primary/events?sendUpdates=none`, { method: "POST", body });
        }
      } else {
        for (const e of found) await delEvent(token, e.id);
      }
    } catch { /* one person's Google trouble shouldn't stop the others */ }
  }
}
// Make one person's Google Calendar match their CRM tasks exactly: every open
// task with a due date from 30 days back on has one event; events for tasks
// that are done, undated, deleted or no longer theirs are removed. Only
// touches events the CRM made (tagged crmTaskId). Returns counts.
async function reconcileFor(db: Db, s: Record<string, string>, authId: string) {
  const out = { tasks: 0, created: 0, updated: 0, removed: 0 };
  const { data: me } = await db.from("users").select("id,active").eq("auth_id", authId).maybeSingle();
  const token = await accessToken(db, s, authId);
  if (!token) return out;
  const since = new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10);
  const { data: ts } = await db.from("tasks").select("id,title,due_date,priority,status,notes,assignees,created_by")
    .neq("status", "done").not("due_date", "is", null).gte("due_date", since);
  const want = new Map<string, Task>();
  if (me && me.active !== false) {
    for (const t of (ts || []) as Task[]) {
      const mine = (t.assignees && t.assignees.length) ? t.assignees.includes(me.id) : t.created_by === me.id;
      if (mine) want.set(t.id, t);
    }
  }
  out.tasks = want.size;
  // What's in Google now (CRM-made events only).
  const have = new Map<string, GEvent[]>();
  const timeMin = new Date(Date.now() - 400 * 864e5).toISOString();
  let pageToken = "";
  do {
    const q = new URLSearchParams({ timeMin, maxResults: "2500", singleEvents: "true", ...(pageToken ? { pageToken } : {}) });
    const d = await google(token, `/calendars/primary/events?${q}`);
    for (const e of d.items || []) {
      const tid = e.extendedProperties?.private?.crmTaskId;
      if (!tid || e.status === "cancelled") continue;
      if (!have.has(tid)) have.set(tid, []);
      have.get(tid)!.push(e);
    }
    pageToken = d.nextPageToken || "";
  } while (pageToken);
  for (const [tid, t] of want) {
    const evs = have.get(tid) || [];
    const body = bodyFor(t, evs[0]) as ReturnType<typeof taskEventBody>;
    if (!evs.length) {
      await google(token, `/calendars/primary/events?sendUpdates=none`, { method: "POST", body: JSON.stringify(body) });
      out.created++;
    } else {
      const e = evs[0];
      if (e.summary !== body.summary || e.description !== body.description || evDate(e) !== t.due_date) {
        await google(token, `/calendars/primary/events/${encodeURIComponent(e.id)}?sendUpdates=none`, { method: "PATCH", body: JSON.stringify(body) });
        out.updated++;
      }
      for (const extra of evs.slice(1)) { await delEvent(token, extra.id); out.removed++; }
    }
  }
  for (const [tid, evs] of have) {
    if (want.has(tid)) continue;
    for (const e of evs) { await delEvent(token, e.id); out.removed++; }
  }
  return out;
}
async function syncAllFor(db: Db, s: Record<string, string>, authId: string) {
  return (await reconcileFor(db, s, authId)).tasks;
}
// Take every CRM task event back out of one person's primary calendar.
async function removeAllFor(db: Db, s: Record<string, string>, authId: string) {
  const token = await accessToken(db, s, authId);
  if (!token) return;
  const timeMin = new Date(Date.now() - 400 * 864e5).toISOString();
  let pageToken = "";
  do {
    const q = new URLSearchParams({ timeMin, maxResults: "2500", singleEvents: "true", ...(pageToken ? { pageToken } : {}) });
    const d = await google(token, `/calendars/primary/events?${q}`);
    for (const e of d.items || []) if (e.extendedProperties?.private?.crmTaskId) await delEvent(token, e.id);
    pageToken = d.nextPageToken || "";
  } while (pageToken);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = admin();
  const s = await secrets(db);
  const configured = !!(s.GOOGLE_CLIENT_ID && s.GOOGLE_CLIENT_SECRET && s.GCAL_STATE_SECRET);

  // ---- Google sends the browser back here after sign-in ----
  if (req.method === "GET") {
    const q = new URL(req.url).searchParams;
    const st = q.get("state") ? await readState(s.GCAL_STATE_SECRET || "", q.get("state")!) : null;
    if (!st) return new Response("This sign-in link has expired. Go back to the CRM and press Connect Google Calendar again.", { status: 400 });
    if (q.get("error") || !q.get("code")) return backTo(st.r, "cancelled");
    try {
      const t = await tokenRequest({
        code: q.get("code")!, client_id: s.GOOGLE_CLIENT_ID, client_secret: s.GOOGLE_CLIENT_SECRET,
        redirect_uri: REDIRECT, grant_type: "authorization_code",
      });
      let email: string | null = null;
      try { email = JSON.parse(new TextDecoder().decode(unb64u(String(t.id_token).split(".")[1]))).email || null; } catch { /* optional */ }
      const { data: prev } = await db.from("gcal_connections").select("refresh_token").eq("auth_id", st.u).maybeSingle();
      const refresh = t.refresh_token || prev?.refresh_token;
      if (!refresh) return backTo(st.r, "error");
      const { error } = await db.from("gcal_connections").upsert({
        auth_id: st.u, google_email: email, refresh_token: refresh, access_token: t.access_token,
        access_expires_at: new Date(Date.now() + (t.expires_in || 3600) * 1000).toISOString(),
        connected_at: new Date().toISOString(),
      });
      return backTo(st.r, error ? "error" : "connected");
    } catch {
      return backTo(st.r, "error");
    }
  }

  // ---- scheduled sweep: bring everyone's calendar in line with the CRM ----
  // Catches tasks changed outside the CRM screen (imports, automations).
  const sweep = req.headers.get("x-rates-secret");
  if (sweep) {
    if (!s.RATES_SECRET || sweep !== s.RATES_SECRET) return json(401, { error: "Not allowed" });
    if (!configured) return json(200, { ok: true, skipped: "not_configured" });
    const { data: conns } = await db.from("gcal_connections").select("auth_id,google_email");
    const results: Record<string, unknown> = {};
    for (const c of conns || []) {
      try { results[c.google_email || c.auth_id] = await reconcileFor(db, s, c.auth_id); }
      catch (e) { results[c.google_email || c.auth_id] = { error: (e as Error).message }; }
    }
    return json(200, { ok: true, results });
  }

  // ---- everything else: the signed-in teammate's own calendar only ----
  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { error: "Sign in first" });
  const asCaller = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await asCaller.auth.getUser();
  if (!user) return json(401, { error: "Sign in first" });
  const { data: me } = await db.from("users").select("active").eq("auth_id", user.id).maybeSingle();
  if (!me || me.active === false) return json(403, { error: "Not allowed" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: "Bad JSON" }); }

  try {
    switch (body.action) {
      case "status": {
        const { data: c } = await db.from("gcal_connections").select("google_email").eq("auth_id", user.id).maybeSingle();
        return json(200, { configured, connected: !!c, email: c?.google_email || null, syncTasks: !!c });
      }
      case "task_changed": {
        if (!configured) return json(200, { ok: true });
        const id = String(body.taskId || "");
        if (!/^[0-9a-f-]{36}$/i.test(id)) return json(400, { error: "taskId required" });
        await syncTask(db, s, id);
        return json(200, { ok: true });
      }
      case "schedule_task":
      case "unschedule_task": {
        if (!configured) return json(200, { error: "Google Calendar isn't set up" });
        const id = String(body.taskId || "");
        if (!/^[0-9a-f-]{36}$/i.test(id)) return json(400, { error: "taskId required" });
        const token = await accessToken(db, s, user.id);
        if (!token) return json(200, { error: "Connect Google Calendar first", code: "not_connected" });
        const { data: t0 } = await db.from("tasks").select("id,title,due_date,priority,status,notes,assignees,created_by").eq("id", id).maybeSingle();
        if (!t0) return json(200, { error: "That task no longer exists" });
        if (!(await taskOwners(db, t0 as Task)).has(user.id)) return json(200, { error: "Only tasks assigned to you (or that you made, if unassigned) can be scheduled on your calendar" });
        const t = { ...(t0 as Task) };
        let ev: GEvent;
        const found = await taskEvents(token, id);
        if (body.action === "unschedule_task") {
          if (!t.due_date) return json(200, { ok: true });
          const b = JSON.stringify(taskEventBody(t));
          ev = found.length
            ? await google(token, `/calendars/primary/events/${encodeURIComponent(found[0].id)}?sendUpdates=none`, { method: "PATCH", body: b })
            : await google(token, `/calendars/primary/events?sendUpdates=none`, { method: "POST", body: b });
        } else {
          const date = String(body.date || "");
          const sm = Math.round(Number(body.startMin)), em = Math.round(Number(body.endMin));
          if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !(sm >= 0 && sm < 1440) || !(em > sm && em <= 1440)) return json(400, { error: "Bad time window" });
          // Moving it to another day moves the task's due date too.
          if (t.due_date !== date) {
            const { error } = await db.from("tasks").update({ due_date: date }).eq("id", id);
            if (error) throw new Error(error.message);
            t.due_date = date;
          }
          const cal = await google(token, "/calendars/primary");
          const tz = cal.timeZone || "America/Chicago";
          const at = (m: number) => isoNoZ(new Date(Date.parse(`${date}T00:00:00Z`) + m * 60000));
          const b = JSON.stringify({ ...taskEventBody(t), start: { date: null, dateTime: at(sm), timeZone: tz }, end: { date: null, dateTime: at(em), timeZone: tz } });
          ev = found.length
            ? await google(token, `/calendars/primary/events/${encodeURIComponent(found[0].id)}?sendUpdates=none`, { method: "PATCH", body: b })
            : await google(token, `/calendars/primary/events?sendUpdates=none`, { method: "POST", body: b });
        }
        for (const extra of found.slice(1)) await delEvent(token, extra.id);
        // Other people's copies follow the due date (they keep their own times).
        try { await syncTask(db, s, id); } catch { /* best effort */ }
        return json(200, { ok: true, dueDate: t.due_date, event: {
          id: ev.id, calendarId: "primary", calendar: "", color: null, title: ev.summary || t.title,
          start: ev.start, end: ev.end, link: (ev as { htmlLink?: string }).htmlLink || null, crmTaskId: id, canMove: true } });
      }
      case "sync_all": {
        const n = await syncAllFor(db, s, user.id);
        return json(200, { ok: true, tasks: n });
      }
      case "auth_url": {
        if (!configured) return json(200, { error: "Google Calendar isn't set up for this workspace yet.", code: "not_configured" });
        const returnTo = safeReturn(body.returnTo);
        if (!returnTo) return json(400, { error: "Bad return address" });
        const state = await signState(s.GCAL_STATE_SECRET, { u: user.id, r: returnTo, exp: Date.now() + 15 * 60_000 });
        const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
        url.search = new URLSearchParams({
          client_id: s.GOOGLE_CLIENT_ID, redirect_uri: REDIRECT, response_type: "code", scope: SCOPES,
          access_type: "offline", prompt: "consent", include_granted_scopes: "true", state,
          ...(user.email ? { login_hint: user.email } : {}),
        }).toString();
        return json(200, { url: url.toString() });
      }
      case "events": {
        const token = await accessToken(db, s, user.id);
        if (!token) return json(200, { connected: false, events: [] });
        const timeMin = new Date(String(body.timeMin)).toISOString();
        const timeMax = new Date(String(body.timeMax)).toISOString();
        const list = await google(token, "/users/me/calendarList?minAccessRole=reader&maxResults=250");
        const cals = (list.items || []).filter((c: { selected?: boolean; hidden?: boolean }) => c.selected && !c.hidden);
        const out: unknown[] = [];
        await Promise.all(cals.map(async (cal: { id: string; summary?: string; summaryOverride?: string; backgroundColor?: string; accessRole?: string; primary?: boolean }) => {
          let pageToken = "";
          do {
            const q = new URLSearchParams({ timeMin, timeMax, singleEvents: "true", orderBy: "startTime", maxResults: "250", ...(pageToken ? { pageToken } : {}) });
            const d = await google(token, `/calendars/${encodeURIComponent(cal.id)}/events?${q}`);
            for (const e of d.items || []) {
              if (e.status === "cancelled") continue;
              const mine = !e.organizer || e.organizer.self || e.guestsCanModify;
              out.push({
                id: e.id, calendarId: cal.id, calendar: cal.summaryOverride || cal.summary || "",
                color: cal.backgroundColor || null, title: e.summary || "(No title)",
                start: e.start, end: e.end, link: e.htmlLink || null,
                crmTaskId: e.extendedProperties?.private?.crmTaskId || null,
                canMove: (cal.accessRole === "owner" || cal.accessRole === "writer") && !!mine,
              });
            }
            pageToken = d.nextPageToken || "";
          } while (pageToken);
        }));
        return json(200, { connected: true, events: out });
      }
      case "move": {
        const token = await accessToken(db, s, user.id);
        if (!token) return json(200, { error: "Google Calendar isn't connected", code: "not_connected" });
        const calId = encodeURIComponent(String(body.calendarId));
        const evId = encodeURIComponent(String(body.eventId));
        const e = await google(token, `/calendars/${calId}/events/${evId}?sendUpdates=none`, {
          method: "PATCH", body: JSON.stringify({ start: body.start, end: body.end }),
        });
        return json(200, { ok: true, event: { id: e.id, start: e.start, end: e.end } });
      }
      case "disconnect": {
        // Take the CRM's task events back out of their Google Calendar first.
        try { await removeAllFor(db, s, user.id); } catch { /* still disconnect */ }
        const { data: c } = await db.from("gcal_connections").select("refresh_token").eq("auth_id", user.id).maybeSingle();
        if (c?.refresh_token) {
          await fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(c.refresh_token)}`, { method: "POST" }).catch(() => {});
        }
        await db.from("gcal_connections").delete().eq("auth_id", user.id);
        return json(200, { ok: true });
      }
      default:
        return json(400, { error: "Unknown action" });
    }
  } catch (e) {
    const err = e as { message?: string; code?: string; status?: number };
    if (err.code === "invalid_grant") return json(200, { error: "Google Calendar was disconnected. Connect it again in Settings.", code: "not_connected" });
    return json(200, { error: err.message || "Google Calendar error" });
  }
});
