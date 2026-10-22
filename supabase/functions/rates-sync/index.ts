// rates-sync (2026-10-21): pulls the CRE Debt Tracker's market indexes from
// the publishers (Treasury.gov, NY Fed) into public.market_rates, FRED as fallback.
//
//   dgs5   DGS5    5-Year Treasury constant maturity yield (daily)
//   dgs10  DGS10   10-Year Treasury constant maturity yield (daily)
//   sofr   SOFR    Secured Overnight Financing Rate (NY Fed, daily)
//   prime  DPRIME  Bank prime loan rate (daily)
//
// None of the sources need an API key. Each run fetches only from a
// week before the latest stored date, so a daily run moves a few rows.
//
// Called by pg_cron with x-rates-secret (matched against app_secrets
// RATES_SECRET), or by a signed-in teammate from the app's Refresh button.
import { createClient } from "npm:@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SERIES: Record<string, string> = { dgs5: "DGS5", dgs10: "DGS10", sofr: "SOFR", prime: "DPRIME" };
const HISTORY_START = "2021-01-01";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rates-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

function shiftDays(iso: string, n: number) {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

const UA = { "User-Agent": "UtopianCapitalCRM/1.0 (rates tracker)" };
type Row = { rate_date: string; value: number };
const today = () => new Date().toISOString().slice(0, 10);

// Primary sources, straight from the publishers:
//   Treasury.gov daily par yield curve (5 Yr, 10 Yr columns), one CSV per year
//   NY Fed Markets API: SOFR, and EFFR whose target range sets prime
//   (prime = fed funds target upper bound + 3.00%, the WSJ convention FRED's DPRIME tracks)
// FRED is kept only as a fallback.
async function treasury(from: string): Promise<Record<string, Row[]>> {
  const out: Record<string, Row[]> = { dgs5: [], dgs10: [] };
  const y0 = +from.slice(0, 4), y1 = +today().slice(0, 4);
  for (let y = y0; y <= y1; y++) {
    const url = `https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv/${y}/all?type=daily_treasury_yield_curve&field_tdr_date_value=${y}&page&_format=csv`;
    const res = await fetch(url, { signal: AbortSignal.timeout(25000), headers: UA });
    const text = await res.text();
    if (!res.ok) throw new Error(`Treasury ${y}: HTTP ${res.status}`);
    const lines = text.trim().split(/\r?\n/);
    const head = lines[0].split(",").map((h) => h.replace(/"/g, "").trim());
    const i5 = head.indexOf("5 Yr"), i10 = head.indexOf("10 Yr");
    if (i5 < 0 || i10 < 0) throw new Error(`Treasury ${y}: unexpected header: ${text.slice(0, 160)}`);
    for (const line of lines.slice(1)) {
      const c = line.split(",").map((s) => s.replace(/"/g, "").trim());
      const m = c[0].match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
      if (!m) continue;
      const d = `${m[3]}-${m[1]}-${m[2]}`;
      if (d < from) continue;
      const a = parseFloat(c[i5]), b = parseFloat(c[i10]);
      if (Number.isFinite(a)) out.dgs5.push({ rate_date: d, value: a });
      if (Number.isFinite(b)) out.dgs10.push({ rate_date: d, value: b });
    }
  }
  return out;
}

async function nyfed(kind: "secured/sofr" | "unsecured/effr", from: string) {
  const all: any[] = [];
  const y0 = +from.slice(0, 4), y1 = +today().slice(0, 4);
  for (let y = y0; y <= y1; y++) {
    const s = y === y0 ? from : `${y}-01-01`, e = y === y1 ? today() : `${y}-12-31`;
    const url = `https://markets.newyorkfed.org/api/rates/${kind}/search.json?startDate=${s}&endDate=${e}`;
    const res = await fetch(url, { signal: AbortSignal.timeout(25000), headers: { ...UA, Accept: "application/json" } });
    const text = await res.text();
    if (!res.ok) throw new Error(`NY Fed ${kind}: HTTP ${res.status}`);
    let j: any;
    try { j = JSON.parse(text); } catch { throw new Error(`NY Fed ${kind}: not JSON: ${text.slice(0, 160)}`); }
    all.push(...(j.refRates || []));
  }
  return all;
}

async function fred(id: string, from: string): Promise<Row[]> {
  const url = `https://fred.stlouisfed.org/graph/fredgraph.csv?id=${id}&cosd=${from}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(20000), headers: UA });
  const text = await res.text();
  const rows: Row[] = [];
  for (const line of text.trim().split(/\r?\n/).slice(1)) {
    const [d, v] = line.split(",");
    const n = parseFloat(v);
    if (/^\d{4}-\d{2}-\d{2}$/.test(d) && Number.isFinite(n)) rows.push({ rate_date: d, value: n });
  }
  if (!rows.length) throw new Error(`FRED ${id}: no data (HTTP ${res.status})`);
  return rows;
}

const tCache: Record<string, Promise<Record<string, Row[]>>> = {};
async function pull(key: string, from: string): Promise<{ rows: Row[]; source: string }> {
  const errs: string[] = [];
  try {
    if (key === "dgs5" || key === "dgs10") {
      tCache[from] ??= treasury(from); // 5Y and 10Y come from the same file
      return { rows: (await tCache[from])[key], source: "treasury.gov" };
    }
    if (key === "sofr") {
      const r = await nyfed("secured/sofr", from);
      return { rows: r.filter((x) => Number.isFinite(+x.percentRate)).map((x) => ({ rate_date: x.effectiveDate, value: +x.percentRate })), source: "newyorkfed.org" };
    }
    if (key === "prime") {
      const r = await nyfed("unsecured/effr", from);
      return { rows: r.filter((x) => Number.isFinite(+x.targetRateTo)).map((x) => ({ rate_date: x.effectiveDate, value: +(+x.targetRateTo + 3).toFixed(2) })), source: "newyorkfed.org (fed funds upper + 3)" };
    }
  } catch (e) { errs.push((e as Error).message); }
  try { return { rows: await fred(SERIES[key], from), source: "fred" }; }
  catch (e) { errs.push((e as Error).message); }
  throw new Error(errs.join(" | "));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

  // Who may run it: the cron (shared secret) or any active teammate.
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

  const result: Record<string, unknown> = {};
  for (const key of Object.keys(SERIES)) {
    try {
      const { data: last } = await admin.from("market_rates").select("rate_date")
        .eq("series", key).order("rate_date", { ascending: false }).limit(1).maybeSingle();
      const from = last ? shiftDays(last.rate_date, -7) : HISTORY_START;
      const { rows, source } = await pull(key, from);
      rows.sort((a, b) => (a.rate_date < b.rate_date ? -1 : 1));
      if (rows.length) {
        const { error } = await admin.from("market_rates")
          .upsert(rows.map((r) => ({ series: key, ...r })), { onConflict: "series,rate_date" });
        if (error) throw new Error(error.message);
      }
      result[key] = { from, source, rows: rows.length, latest: rows.length ? rows[rows.length - 1] : null };
    } catch (e) {
      result[key] = { error: (e as Error).message };
    }
  }
  return json(200, { ok: true, result });
});
