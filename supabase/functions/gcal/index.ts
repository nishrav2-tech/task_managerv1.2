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
//   disconnect                   revokes and deletes the connection
// GET ?code=&state=  Google's redirect back after sign-in.
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
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const admin = () => createClient(URL_, SERVICE, { auth: { persistSession: false } });

async function secrets(db: ReturnType<typeof admin>) {
  const { data } = await db.from("app_secrets").select("key,value")
    .in("key", ["GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET", "GCAL_STATE_SECRET"]);
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
        return json(200, { configured, connected: !!c, email: c?.google_email || null });
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
