// market-docs (2026-11-04): "Subdivide rules & exemptions" for the Markets tab.
// One write-up and any number of files per state (statewide) and per county
// (countywide), kept in a private Supabase Storage bucket that only this
// function can reach (service role). Any active teammate can read and edit.
//
//   state/<state fips>/rules.json         {text, updated_at, updated_by}
//   state/<state fips>/files/<ts>-<name>  uploaded files
//   county/<county fips>/...              same, per county
//
// POST (signed-in teammate) {action, ...}
//   summary                          {states:[fp], counties:[fips]} that have anything saved
//   get        {scope, id}           {text, updated_at, updated_by, files:[...]}
//   save_text  {scope, id, text}
//   upload_url {scope, id, name}     signed upload {path, token}
//   file_url   {path}                short-lived download link
//   delete_file {path}
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "market-docs";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function base(scope: unknown, id: unknown) {
  const sc = String(scope), i = String(id);
  if (sc === "state" && /^\d{2}$/.test(i)) return `state/${i}`;
  if (sc === "county" && /^\d{5}$/.test(i)) return `county/${i}`;
  return null;
}
const okPath = (p: unknown) => typeof p === "string" && /^(state\/\d{2}|county\/\d{5})\/files\/[^/]+$/.test(p) && !p.includes("..");
const safeName = (n: string) => (n || "file").replace(/[\/\\]/g, "-").replace(/[^\w.\- ()&,']/g, "_").slice(0, 120) || "file";

let bucketReady = false;
async function ensureBucket(db: ReturnType<typeof createClient>) {
  if (bucketReady) return;
  const { data } = await db.storage.getBucket(BUCKET);
  if (!data) {
    const { error } = await db.storage.createBucket(BUCKET, { public: false, fileSizeLimit: 50 * 1024 * 1024 });
    if (error && !/exists/i.test(error.message)) throw new Error(error.message);
  }
  bucketReady = true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const auth = req.headers.get("Authorization");
  if (!auth) return json(401, { error: "Sign in first" });
  const asCaller = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
  const { data: { user } } = await asCaller.auth.getUser();
  if (!user) return json(401, { error: "Sign in first" });
  const db = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const { data: me } = await db.from("users").select("id,name,active").eq("auth_id", user.id).maybeSingle();
  if (!me || me.active === false) return json(403, { error: "Not allowed" });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: "Bad JSON" }); }

  try {
    await ensureBucket(db);
    const st = db.storage.from(BUCKET);
    switch (body.action) {
      case "summary": {
        const [a, b] = await Promise.all([st.list("state", { limit: 1000 }), st.list("county", { limit: 5000 })]);
        return json(200, {
          states: (a.data || []).map((x) => x.name).filter((n) => /^\d{2}$/.test(n)),
          counties: (b.data || []).map((x) => x.name).filter((n) => /^\d{5}$/.test(n)),
        });
      }
      case "get": {
        const p = base(body.scope, body.id);
        if (!p) return json(400, { error: "Bad scope" });
        let text = "", updated_at = null, updated_by = null;
        const r = await st.download(`${p}/rules.json`);
        if (r.data) {
          try { const j = JSON.parse(await r.data.text()); text = j.text || ""; updated_at = j.updated_at || null; updated_by = j.updated_by || null; } catch { /* empty */ }
        }
        const { data: fl } = await st.list(`${p}/files`, { limit: 500, sortBy: { column: "created_at", order: "desc" } });
        const files = (fl || []).filter((f) => f.id).map((f) => ({
          path: `${p}/files/${f.name}`, name: f.name.replace(/^\d{13}-/, ""),
          size: f.metadata?.size || null, created_at: f.created_at,
          by: (f.metadata as Record<string, unknown> | undefined)?.by || null,
        }));
        return json(200, { text, updated_at, updated_by, files });
      }
      case "save_text": {
        const p = base(body.scope, body.id);
        if (!p) return json(400, { error: "Bad scope" });
        const text = String(body.text || "").slice(0, 200000);
        const doc = { text, updated_at: new Date().toISOString(), updated_by: me.name || user.email };
        if (!text.trim()) { await st.remove([`${p}/rules.json`]); return json(200, { ok: true, ...doc }); }
        const { error } = await st.upload(`${p}/rules.json`, new Blob([JSON.stringify(doc)], { type: "application/json" }), { upsert: true, contentType: "application/json" });
        if (error) throw new Error(error.message);
        return json(200, { ok: true, ...doc });
      }
      case "upload_url": {
        const p = base(body.scope, body.id);
        if (!p) return json(400, { error: "Bad scope" });
        const path = `${p}/files/${Date.now()}-${safeName(String(body.name || ""))}`;
        const { data, error } = await st.createSignedUploadUrl(path);
        if (error) throw new Error(error.message);
        return json(200, { path, token: data.token });
      }
      case "file_url": {
        if (!okPath(body.path)) return json(400, { error: "Bad path" });
        const { data, error } = await st.createSignedUrl(String(body.path), 300, { download: body.download ? String(body.path).split("/").pop()!.replace(/^\d{13}-/, "") : false });
        if (error) throw new Error(error.message);
        return json(200, { url: data.signedUrl });
      }
      case "delete_file": {
        if (!okPath(body.path)) return json(400, { error: "Bad path" });
        const { error } = await st.remove([String(body.path)]);
        if (error) throw new Error(error.message);
        return json(200, { ok: true });
      }
      default:
        return json(400, { error: "Unknown action" });
    }
  } catch (e) {
    return json(200, { error: (e as Error).message || "Something went wrong" });
  }
});
