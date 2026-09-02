// ghl-webhook
//
// Receives webhook POSTs from GoHighLevel (fired by a GHL Workflow on
// stage-change / contact-update / message triggers) and logs every one,
// as-is, into ghl_events. This function does NOT decide what counts
// toward which KPI -- that logic lives in refresh_ghl_kpis() (see
// ghl-events-schema.sql). Keeping ingestion this dumb is deliberate: a
// payload GHL sends today should never get silently dropped because a
// parsing assumption here was wrong. We always store the full raw
// payload, so a mapping mistake is fixable later by editing SQL and
// re-running it against history already captured.
//
// DEPLOYED 2026-08-15 to close a real gap in the hourly-poll pipeline:
// polling only sees an opportunity's CURRENT stage once every 5 minutes,
// so a lead that enters and leaves a stage between two polls (e.g.
// "Priority Offer Ready") never generates an event at all. This webhook
// is real-time -- GHL fires it the instant the stage actually changes --
// so it doesn't have that blind spot. Runs alongside ghl-hourly-poll,
// doesn't replace it.
//
// UPDATED 2026-08-15/16: two GHL payload-shape surprises fixed after
// looking at a real captured webhook payload:
//   1. Opportunity fields (id, pipeline_id, pipleline_stage) DO ride
//      along at the payload ROOT as "standard data", as documented --
//      pipleline_stage (GHL's own typo) is the stage NAME, not an id, so
//      it's mapped through STAGE_NAME_TO_ID below.
//   2. The one Custom Data field configured in the GHL workflow action
//      (event_type) is NOT merged into the root -- GHL nests all Custom
//      Data under a `customData` object instead, e.g.
//      `"customData": { "event_type": "OpportunityStageUpdate" }`. Confirmed
//      against a real captured payload 2026-08-16. extractFields() now
//      checks body.customData?.event_type first.
//
// SECRET STORAGE -- same workaround as lead-entry-lag: GHL_WEBHOOK_SECRET
// lives in the locked-down app_secrets table (RLS enabled, zero policies,
// service-role-only) rather than a normal Edge Function secret, because
// the Supabase MCP connector used to deploy this has no `secrets set`
// tool. If CLI/terminal access returns, this can move back to a plain
// Deno.env.get("GHL_WEBHOOK_SECRET").
//
// GHL side: create ONE Workflow per trigger type you want tracked
// (Opportunity Stage Changed, Opportunity Created, Contact Changed /
// Custom Field Updated), each with a "Webhook" action pointed at:
//   https://yahosblylysopbxgztvg.supabase.co/functions/v1/ghl-webhook?secret=<the value in app_secrets.GHL_WEBHOOK_SECRET>
// with one Custom Data item: event_type = OpportunityStageUpdate (as a
// literal string, not a merge tag). See GHL-WEBHOOK-SETUP.md section 6.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

// Same stage ids hardcoded in refresh_ghl_kpis (ghl-events-schema.sql),
// keyed by the exact stage NAME GHL's webhook payload sends in
// `pipleline_stage`. Confirmed against the live GHL Pipelines API and a
// real captured webhook payload, 2026-08-15/16. If the pipeline's stages
// are ever renamed/added/removed in GHL, this map (and the STAGE_*
// constants in refresh_ghl_kpis) both need updating to match.
const STAGE_NAME_TO_ID: Record<string, string> = {
  "Vetted Lead": "094c7357-ee4a-4f88-b3b3-01e7ad6e8b17",
  "Reopened Lead": "39765fff-ba18-4426-aa79-8705cd4a4351",
  "Call Ready": "03fee1af-2b27-4864-b5a2-c1cfb058af9c",
  "Priority Offer Ready": "eaf42c26-3d83-4bc1-bf20-f4974f0bf741",
  "Call Again (Nurture)": "ad1d0cd3-fa68-4f49-a3a2-e693b2014a89",
  "Send Paperwork": "6bcfc8b4-2037-453a-9279-2e38da9c63ad",
  "Follow Up to Closing": "c9c5aa45-fdd3-47f6-9da9-e0d59f59defe",
  "Deal Closed!": "462724b5-24ce-4a16-b198-ba5c290eab85",
  "Long Term Follow Up (General)": "971b67f5-0602-40ed-80e5-9093b2bedb60",
  "Stale Leads (Revive)": "c661bc15-d8cb-4621-be98-bcba18b3d820",
  "Lost Leads": "d2f78e1d-1715-4599-b904-131ee5b3d8c2",
  "Not a Fit": "af524f69-fb50-4776-a0ee-d93639eb379e",

  // ADDED 2026-09-02 — the "Purchase" KPI section's pipeline (New Contract
  // through closing). PLACEHOLDER values: run `python3 ghl-probe.py` from
  // the repo root to print your account's real pipeline/stage ids and
  // names, then replace these six. They must match the SAME six constants
  // in purchase_stage_avgs() (ghl-events-schema.sql) exactly, or the two
  // sides will silently disagree about which event is which stage. Also
  // needs a GHL Workflow (Opportunity Stage Changed, scoped to this
  // pipeline) pointed at this same webhook — see GHL-WEBHOOK-SETUP.md.
  "New Contract": "PLACEHOLDER_STAGE_ID__NEW_CONTRACT",
  "EMD Confirmed": "PLACEHOLDER_STAGE_ID__EMD_CONFIRMED",
  "DD Phase II": "PLACEHOLDER_STAGE_ID__DD_PHASE_2",
  "Funding": "PLACEHOLDER_STAGE_ID__FUNDING",
  "DD Phase III": "PLACEHOLDER_STAGE_ID__DD_PHASE_3",
  "Post Closing Docs": "PLACEHOLDER_STAGE_ID__POST_CLOSING_DOCS",
};

let cachedSecret: string | null | undefined;
async function getWebhookSecret(): Promise<string | null> {
  if (cachedSecret !== undefined) return cachedSecret;
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    cachedSecret = null;
    return null;
  }
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/app_secrets?key=eq.GHL_WEBHOOK_SECRET&select=value`,
    {
      headers: {
        apikey: SERVICE_ROLE_KEY,
        authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
    },
  );
  if (!res.ok) {
    cachedSecret = null;
    return null;
  }
  const rows = (await res.json()) as Array<{ value: string }>;
  cachedSecret = rows[0]?.value ?? null;
  return cachedSecret;
}

async function checkSecret(req: Request): Promise<boolean> {
  const secret = await getWebhookSecret();
  if (!secret) return false;
  const header = req.headers.get("x-webhook-secret");
  if (header && header === secret) return true;
  const url = new URL(req.url);
  const qs = url.searchParams.get("secret");
  return !!qs && qs === secret;
}

// Pulls whatever fields we recognize out of a GHL payload into typed
// columns, for cheap querying later. Nothing here is load-bearing for
// data safety -- the `raw` column always keeps everything, including
// fields this function doesn't know about yet.
function extractFields(body: Record<string, unknown>) {
  const meta = (body.meta ?? {}) as Record<string, unknown>;
  const call = (meta.call ?? {}) as Record<string, unknown>;
  const customData = (body.customData ?? {}) as Record<string, unknown>;

  const stageName =
    (body.pipleline_stage as string) ?? (body.pipeline_stage as string) ?? undefined;
  const explicitStageId =
    (body.pipelineStageId as string) ?? (body.stageId as string) ?? (body.stage_id as string) ?? undefined;
  const stageId = explicitStageId ?? (stageName ? STAGE_NAME_TO_ID[stageName] : undefined) ?? null;

  return {
    // Custom Data fields configured in the GHL workflow action land under
    // `customData`, NOT the payload root -- check there first.
    event_type:
      (customData.event_type as string) ??
      (body.event_type as string) ??
      (body.type as string) ??
      "Unknown",
    occurred_at:
      (customData.occurred_at as string) ??
      (body.occurred_at as string) ??
      (body.dateAdded as string) ??
      (body.dateUpdated as string) ??
      (body.lastStageChangeAt as string) ??
      new Date().toISOString(),
    contact_id:
      (body.contactId as string) ?? (body.contact_id as string) ?? (body.contact_Id as string) ?? null,
    opportunity_id:
      (body.opportunityId as string) ?? (body.opportunity_id as string) ?? (body.id as string) ?? null,
    pipeline_id: (body.pipelineId as string) ?? (body.pipeline_id as string) ?? null,
    stage_id: stageId,
    stage_name: stageName ?? null,
    message_type: (body.messageType as string) ?? (body.message_type as string) ?? null,
    direction: (body.direction as string) ?? null,
    call_duration_secs: typeof call.duration === "number" ? call.duration : null,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!(await checkSecret(req))) {
    return new Response("Unauthorized", { status: 401 });
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return new Response("Supabase env not configured", { status: 500 });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return new Response("Body must be JSON", { status: 400 });
  }

  const fields = extractFields(body);

  const row = {
    event_type: fields.event_type,
    occurred_at: fields.occurred_at,
    contact_id: fields.contact_id,
    opportunity_id: fields.opportunity_id,
    pipeline_id: fields.pipeline_id,
    stage_id: fields.stage_id,
    message_type: fields.message_type,
    direction: fields.direction,
    call_duration_secs: fields.call_duration_secs,
    raw: body,
  };

  const res = await fetch(`${SUPABASE_URL}/rest/v1/ghl_events`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: SERVICE_ROLE_KEY,
      authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      prefer: "return=minimal",
    },
    body: JSON.stringify(row),
  });

  if (!res.ok) {
    const errText = await res.text();
    console.error("Failed to insert ghl_event:", res.status, errText);
    return new Response(JSON.stringify({ ok: false, error: errText }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(
    JSON.stringify({ ok: true, event_type: fields.event_type, stage_id: fields.stage_id, stage_name: fields.stage_name }),
    {
      status: 200,
      headers: { "content-type": "application/json" },
    },
  );
});
