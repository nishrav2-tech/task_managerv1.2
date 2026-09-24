// admin-users — login management for the Team page (2026-09-23).
//
// The browser only ever holds the public anon key, which cannot create or
// change logins. This function holds the service-role key server-side and
// performs those actions on an admin's behalf — after checking, on every call,
// that the caller is signed in AND is an active admin in public.users.
//
// Actions (POST JSON {action, ...}):
//   create_login   {userId, email, password, role?}  make a login and link it to a teammate
//   reset_password {userId, password}                set a new temporary password
//   set_active     {userId, active}                  deactivate / reactivate (bans the login)
//   set_role       {userId, role}                    'admin' | 'member'
//   remove_login   {userId}                          delete the login, keep the teammate + history
//
// Temporary passwords set here carry user_metadata.must_change_password, and
// the app makes the person choose their own before anything loads.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const MIN_PW = 10;
const FOREVER = "876000h"; // ~100 years: Supabase's way of saying "banned"

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json(405, { error: "POST only" });

  // 1. Who is calling? Verified against Supabase Auth, not trusted from the body.
  const authHeader = req.headers.get("Authorization") || "";
  const asCaller = createClient(URL_, ANON, { global: { headers: { Authorization: authHeader } } });
  const { data: { user: caller }, error: whoErr } = await asCaller.auth.getUser();
  if (whoErr || !caller) return json(401, { error: "Not signed in" });

  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

  // 2. Are they an active admin?
  const { data: me } = await admin.from("users").select("id, app_role, active")
    .eq("auth_id", caller.id).maybeSingle();
  if (!me || !me.active || me.app_role !== "admin") return json(403, { error: "Admins only" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: "Bad JSON" }); }
  const action = String(body.action || "");
  const userId = String(body.userId || "");
  if (!userId) return json(400, { error: "userId is required" });

  const { data: target, error: tErr } = await admin.from("users")
    .select("id, name, auth_id, email, app_role, active").eq("id", userId).maybeSingle();
  if (tErr || !target) return json(404, { error: "Teammate not found" });

  const isSelf = target.id === me.id;
  const otherActiveAdmins = async () => {
    const { count } = await admin.from("users").select("id", { count: "exact", head: true })
      .eq("app_role", "admin").eq("active", true).neq("id", target.id).not("auth_id", "is", null);
    return count || 0;
  };

  try {
    if (action === "create_login") {
      if (target.auth_id) return json(409, { error: `${target.name} already has a login` });
      const email = String(body.email || "").trim().toLowerCase();
      const password = String(body.password || "");
      const role = body.role === "admin" ? "admin" : "member";
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json(400, { error: "Enter a valid email" });
      if (password.length < MIN_PW) return json(400, { error: `Password must be at least ${MIN_PW} characters` });

      const { data: taken } = await admin.from("users").select("id").ilike("email", email).neq("id", target.id).maybeSingle();
      if (taken) return json(409, { error: "That email is already linked to another teammate" });

      const { data: created, error } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { must_change_password: true, name: target.name },
      });
      if (error || !created.user) return json(400, { error: error?.message || "Could not create login" });

      const { error: linkErr } = await admin.from("users")
        .update({ auth_id: created.user.id, email, app_role: role, active: true }).eq("id", target.id);
      if (linkErr) {
        await admin.auth.admin.deleteUser(created.user.id); // don't leave an orphan login
        return json(500, { error: linkErr.message });
      }
      return json(200, { ok: true });
    }

    if (!target.auth_id && action !== "set_role") return json(400, { error: `${target.name} has no login yet` });

    if (action === "reset_password") {
      const password = String(body.password || "");
      if (password.length < MIN_PW) return json(400, { error: `Password must be at least ${MIN_PW} characters` });
      const { error } = await admin.auth.admin.updateUserById(target.auth_id, {
        password, user_metadata: { must_change_password: true },
      });
      if (error) return json(400, { error: error.message });
      return json(200, { ok: true });
    }

    if (action === "set_active") {
      const active = body.active === true;
      if (!active && isSelf) return json(400, { error: "You can't deactivate yourself" });
      if (!active && target.app_role === "admin" && (await otherActiveAdmins()) === 0)
        return json(400, { error: "Can't deactivate the last admin" });
      // The users.active flag cuts data access on the very next request (every
      // table policy checks it). The ban also stops the login being refreshed.
      const { error } = await admin.auth.admin.updateUserById(target.auth_id, { ban_duration: active ? "none" : FOREVER });
      if (error) return json(400, { error: error.message });
      const { error: uErr } = await admin.from("users").update({ active }).eq("id", target.id);
      if (uErr) return json(500, { error: uErr.message });
      return json(200, { ok: true });
    }

    if (action === "set_role") {
      const role = body.role === "admin" ? "admin" : "member";
      if (role === "member" && isSelf) return json(400, { error: "You can't remove your own admin access" });
      if (role === "member" && target.app_role === "admin" && (await otherActiveAdmins()) === 0)
        return json(400, { error: "There must be at least one admin" });
      const { error } = await admin.from("users").update({ app_role: role }).eq("id", target.id);
      if (error) return json(500, { error: error.message });
      return json(200, { ok: true });
    }

    if (action === "remove_login") {
      if (isSelf) return json(400, { error: "You can't remove your own login" });
      if (target.app_role === "admin" && (await otherActiveAdmins()) === 0)
        return json(400, { error: "Can't remove the last admin" });
      const { error } = await admin.auth.admin.deleteUser(target.auth_id);
      if (error) return json(400, { error: error.message });
      await admin.from("users").update({ auth_id: null, email: null, app_role: "member" }).eq("id", target.id);
      return json(200, { ok: true });
    }

    return json(400, { error: `Unknown action: ${action}` });
  } catch (e) {
    return json(500, { error: (e as Error).message || "Unexpected error" });
  }
});
