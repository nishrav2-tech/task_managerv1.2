// market-refresh (2026-10-27): pulls one county's land market from Landportal
// into public.market_counties for the CRM's Markets tab.
//
// For the county it pages through four Landportal filter-data result sets
// (MLS property type Land):
//   active   listings for sale now
//   s1       sold in the last 30 days
//   s6       sold in the last 182 days
//   s12      sold in the last 365 days
// and counts each set by lot size into fixed acreage bins, so the app can
// show any acreage range (or several combined) and any time window without
// another API call. Only the counts are stored, never the listings.
//
// Landportal credentials live in public.app_secrets:
//   LANDPORTAL_API_URL    e.g. https://<landportal api host>   (no trailing slash)
//   LANDPORTAL_API_TOKEN  the account's public API token
//
// Called by a signed-in teammate (Refresh button) or with x-rates-secret
// (RATES_SECRET) for a scheduled refresh. POST {fips: "47003"}.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Bin lower edges in acres; the last bin is open-ended. Keep in sync with
// MK_EDGES in index.html.
const EDGES = [0, 1, 2, 3, 5, 7.5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 250];
const binOf = (a: number) => { let i = 0; while (i + 1 < EDGES.length && a >= EDGES[i + 1]) i++; return i; };

const LAND = { key: "mls_propertytype", operator: "condition", comparison: "is", value: ["8"] };
const SETS: Record<string, unknown[]> = {
  active: [{ key: "mls_for_sale", operator: "mls_condition", value: "active" }, LAND],
  s1: [{ key: "mls_sold", operator: "mls_condition", value: "sold", days: 30 }, LAND],
  s6: [{ key: "mls_sold", operator: "mls_condition", value: "sold", days: 182 }, LAND],
  s12: [{ key: "mls_sold", operator: "mls_condition", value: "sold", days: 365 }, LAND],
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rates-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function pullSet(base: string, token: string, fips: string, filters: unknown[]) {
  const bins = new Array(EDGES.length).fill(0);
  let unknown = 0, total = 0, pages = 0, reported: number | null = null;
  const seen = new Set<string>();
  let pageToken = "";
  for (;;) {
    const qs = new URLSearchParams({ page_size: "100" });
    if (pageToken) qs.set("page_token", pageToken);
    let res: Response | null = null;
    for (let attempt = 0; attempt < 5; attempt++) {
      res = await fetch(`${base}/v2/filter-data?${qs}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ fips: [fips], filters }),
        signal: AbortSignal.timeout(30000),
      });
      if (res.status !== 429 && res.status !== 503) break;
      await sleep(1000 * (Number(res.headers.get("Retry-After")) || 2 ** attempt));
    }
    pages++;
    const text = await res!.text();
    if (!res!.ok) throw new Error(`Landportal HTTP ${res!.status}: ${text.slice(0, 200)}`);
    const j = JSON.parse(text);
    const d = j.data || {};
    if (reported == null) reported = typeof d.count === "number" ? d.count : null;
    for (const p of d.properties || []) {
      const id = String(p.property_id ?? `${p.apn}|${p.street_address}`);
      if (seen.has(id)) continue;
      seen.add(id);
      total++;
      const a = Number(p.lot_size_acres);
      if (Number.isFinite(a) && a >= 0) bins[binOf(a)]++; else unknown++;
    }
    pageToken = d.next_page_token || "";
    if (!pageToken || !(d.properties || []).length) break;
  }
  // Prefer Landportal's own count for the headline number; the bins come
  // from the rows themselves.
  return { total: reported ?? total, bins, unknown, pages };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

  let allowed = false;
  const secret = req.headers.get("x-rates-secret");
  if (secret) {
    const { data } = await admin.from("app_secrets").select("value").eq("key", "RATES_SECRET").maybeSingle();
    allowed = !!data && data.value === secret;
  } else if (req.headers.get("Authorization")) {
    const asCaller = createClient(URL_, ANON, { global: { headers: { Authorization: req.headers.get("Authorization")! } } });
    const { data: { user } } = await asCaller.auth.getUser();
    if (user) {
      const { data: me } = await admin.from("users").select("active").eq("auth_id", user.id).maybeSingle();
      allowed = !!me && me.active !== false;
    }
  }
  if (!allowed) return json(401, { error: "Not allowed" });

  let body: { fips?: string };
  try { body = await req.json(); } catch { return json(400, { error: "Bad JSON" }); }
  const fips = String(body.fips || "");
  if (!/^\d{5}$/.test(fips)) return json(400, { error: "fips must be a 5-digit county code" });

  const { data: secrets } = await admin.from("app_secrets").select("key,value")
    .in("key", ["LANDPORTAL_API_URL", "LANDPORTAL_API_TOKEN"]);
  const s = Object.fromEntries((secrets || []).map((r) => [r.key, r.value]));
  if (!s.LANDPORTAL_API_URL || !s.LANDPORTAL_API_TOKEN) {
    return json(200, { ok: false, code: "not_configured", error: "Landportal API key is not set up yet." });
  }
  const base = String(s.LANDPORTAL_API_URL).replace(/\/+$/, "");

  try {
    const out: Record<string, { total: number; bins: number[]; unknown: number; pages: number }> = {};
    for (const [k, filters] of Object.entries(SETS)) out[k] = await pullSet(base, s.LANDPORTAL_API_TOKEN, fips, filters);
    const row = {
      fips,
      state_fp: fips.slice(0, 2),
      active_listings: out.active.total,
      sold_1m: out.s1.total,
      sold_6m: out.s6.total,
      sold_12m: out.s12.total,
      bins: {
        e: EDGES,
        a: out.active.bins, s1: out.s1.bins, s6: out.s6.bins, s12: out.s12.bins,
        u: { a: out.active.unknown, s1: out.s1.unknown, s6: out.s6.unknown, s12: out.s12.unknown },
      },
      stats_at: new Date().toISOString(),
    };
    const { data, error } = await admin.from("market_counties").upsert(row, { onConflict: "fips" }).select().single();
    if (error) throw new Error(error.message);
    const pages = Object.values(out).reduce((n, o) => n + o.pages, 0);
    return json(200, { ok: true, row: data, pages });
  } catch (e) {
    return json(200, { ok: false, code: "landportal_error", error: (e as Error).message });
  }
});
