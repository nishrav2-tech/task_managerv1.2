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
//   LANDPORTAL_API_URL    e.g. https://api.landportal.com   (no trailing slash)
//   LANDPORTAL_API_TOKEN  the account's public API token
//
// Called by a signed-in teammate (Refresh button) or with x-rates-secret
// (RATES_SECRET) for a scheduled refresh. POST {fips: "47003"}.
//
// POST {fips, ppaOnly: true} instead pulls only the $/acre breakdown of the
// county's sold land (about 15 to 30 Landportal requests), on request from a
// county's chart. A normal refresh never pulls it.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Bin lower edges in acres; the last bin is open-ended. Keep in sync with
// MK_EDGES in index.html.
const EDGES = [0, 1, 2, 3, 5, 7.5, 10, 15, 20, 30, 40, 50, 75, 100, 150, 250];
const binOf = (a: number) => { let i = 0; while (i + 1 < EDGES.length && a >= EDGES[i + 1]) i++; return i; };

// Price-per-acre bands for sold land ($/acre lower edges; last is open-ended).
// Bulk results carry lot size but no price, so sold land is re-pulled once
// per band; the app interpolates the median inside its band.
const PPA = [0, 1000, 2000, 3000, 4000, 5000, 6500, 8000, 10000, 12500, 15000, 20000, 30000, 50000, 100000];

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

// One filter-data page, retrying on rate limits.
async function lpPage(base: string, token: string, fips: string, filters: unknown[], pageToken: string) {
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
  const text = await res!.text();
  if (!res!.ok) throw new Error(`Landportal HTTP ${res!.status}: ${text.slice(0, 200)}`);
  return JSON.parse(text).data || {};
}

async function pullSet(base: string, token: string, fips: string, filters: unknown[]) {
  const bins = new Array(EDGES.length).fill(0);
  let unknown = 0, total = 0, pages = 0, reported: number | null = null;
  const seen = new Set<string>();
  let pageToken = "";
  for (;;) {
    const d = await lpPage(base, token, fips, filters, pageToken);
    pages++;
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
  return { total: reported ?? total, bins, unknown, pages, seen };
}

// Sold in the last 365 days, one pull per $/acre band. Each sale lands in
// [window][acreage bin][band]; window membership comes from the 30- and
// 182-day id sets.
async function pullPpa(base: string, token: string, fips: string, s1: Set<string>, s6: Set<string>) {
  const grid = () => EDGES.map(() => new Array(PPA.length).fill(0));
  const out = { s1: grid(), s6: grid(), s12: grid() };
  let pages = 0;
  for (let b = 0; b < PPA.length; b++) {
    const range: Record<string, number> = { min: PPA[b] };
    if (b + 1 < PPA.length) range.max = PPA[b + 1] - 0.01;
    const filters = [
      ...(SETS.s12 as Record<string, unknown>[]),
      { key: "mls_priceperacre", operator: "range", comparison: "is_between", include_nulls: false, value: range },
    ];
    let pageToken = "";
    const seen = new Set<string>();
    for (;;) {
      const d = await lpPage(base, token, fips, filters, pageToken);
      pages++;
      for (const p of d.properties || []) {
        const id = String(p.property_id ?? `${p.apn}|${p.street_address}`);
        if (seen.has(id)) continue;
        seen.add(id);
        const a = Number(p.lot_size_acres);
        if (!Number.isFinite(a) || a < 0) continue;
        const i = binOf(a);
        out.s12[i][b]++;
        if (s6.has(id)) out.s6[i][b]++;
        if (s1.has(id)) out.s1[i][b]++;
      }
      pageToken = d.next_page_token || "";
      if (!pageToken || !(d.properties || []).length) break;
    }
  }
  return { e: PPA, ...out, pages };
}

// Median $/acre per size bucket (the app's presets), per window, as
// [median, sales]. Interpolated inside the band holding the middle sale.
// Small enough to load for every county, so rows can show the curve's shape.
const BUCKETS: [number, number][] = [[0, 1], [1, 5], [5, 10], [10, 20], [20, 50], [50, 100], [100, Infinity]];
function ppaSummary(ppa: { s1: number[][]; s6: number[][]; s12: number[][] }) {
  const one = (grid: number[][]) => BUCKETS.map(([lo, hi]) => {
    const counts = PPA.map(() => 0);
    grid.forEach((row, i) => {
      const aLo = EDGES[i], aHi = i + 1 < EDGES.length ? EDGES[i + 1] : Infinity;
      if (aLo >= lo && aHi <= hi) row.forEach((v, b) => { counts[b] += v; });
    });
    const n = counts.reduce((a, b) => a + b, 0);
    if (!n) return [null, 0];
    let cum = 0;
    for (let b = 0; b < counts.length; b++) {
      if (cum + counts[b] >= n / 2) {
        const bLo = PPA[b], bHi = b + 1 < PPA.length ? PPA[b + 1] : PPA[b] * 1.5;
        const frac = counts[b] ? (n / 2 - cum) / counts[b] : 0;
        return [Math.round(bLo + frac * (bHi - bLo)), n];
      }
      cum += counts[b];
    }
    return [null, n];
  });
  return { s1: one(ppa.s1), s6: one(ppa.s6), s12: one(ppa.s12) };
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

  let body: { fips?: string; ppaOnly?: boolean };
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

  if (body.ppaOnly) {
    try {
      // The 30- and 182-day id sets tell each sale which windows it's in.
      const s1 = await pullSet(base, s.LANDPORTAL_API_TOKEN, fips, SETS.s1);
      const s6 = await pullSet(base, s.LANDPORTAL_API_TOKEN, fips, SETS.s6);
      const ppa = await pullPpa(base, s.LANDPORTAL_API_TOKEN, fips, s1.seen, s6.seen);
      const ppaJson = { e: ppa.e, s1: ppa.s1, s6: ppa.s6, s12: ppa.s12 };
      const ppaSum = ppaSummary(ppa);
      const at = new Date().toISOString();
      const { error } = await admin.from("market_counties").upsert({
        fips, state_fp: fips.slice(0, 2), ppa: ppaJson, ppa_sum: ppaSum, ppa_at: at,
      }, { onConflict: "fips" });
      if (error) throw new Error(error.message);
      return json(200, { ok: true, ppa_sum: ppaSum, ppa_at: at, pages: s1.pages + s6.pages + ppa.pages });
    } catch (e) {
      return json(200, { ok: false, code: "landportal_error", error: (e as Error).message });
    }
  }

  try {
    const out: Record<string, { total: number; bins: number[]; unknown: number; pages: number; seen: Set<string> }> = {};
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
    // ppa is fetched by the browser per county when its chart opens.
    const { ppa: _ppa, ...lean } = data;
    return json(200, { ok: true, row: lean, pages });
  } catch (e) {
    return json(200, { ok: false, code: "landportal_error", error: (e as Error).message });
  }
});
