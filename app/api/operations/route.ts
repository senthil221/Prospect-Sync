import { authorizeApi, getAuthorizedUser } from "../../../lib/auth";
import { readBoundedJson } from '../../../lib/bounded-json';
import { indexNotice, reindexProspects } from "../../../lib/reindex.ts";
import { ownerIdentity } from "../../../lib/result-sets.ts";
import { createAdminClient } from "../../../lib/supabase/admin";

// How a background bulk action reports itself. The mutation is being applied in
// batches by the operations worker, so the only honest thing this can do is say
// how far it has got - and it says so from operation_jobs, which the worker
// updates in the same transaction as the mutation itself.
async function jobStatus(jobId: string) {
  const actor = ownerIdentity(await getAuthorizedUser());
  if (!actor) return Response.json({ error: "Unauthorized" }, { status: 401 });
  const { data, error } = await createAdminClient().rpc("operation_status_v1", {
    p_job_id: jobId,
    p_actor: actor,
    p_version_vector: null,
  });
  if (error) {
    if (error.code === "PGRST202" || error.code === "42883") {
      return Response.json({ error: "Apply the latest database migration to enable background bulk actions." }, { status: 503 });
    }
    // Not yours and never existed answer identically, so an id is not a probe.
    if (error.code === "P0002") return Response.json({ error: "That action is no longer available." }, { status: 404 });
    return Response.json({ error: error.message }, { status: error.code === "22P02" ? 400 : 500 });
  }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return Response.json({ error: "That action is no longer available." }, { status: 404 });
  return Response.json({
    jobId,
    status: row.status,
    totalItems: Number(row.total_items ?? 0),
    appliedItems: Number(row.applied_items ?? 0),
    excludedCount: Number(row.excluded_count ?? 0),
    frozenAt: row.frozen_at ?? null,
    error: row.error ?? null,
    result: row.result ?? null,
  });
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const params = new URL(request.url).searchParams;
  const jobId = (params.get("jobId") ?? "").trim();
  if (jobId) return jobStatus(jobId);
  const prospectId = params.get("prospectId");
  const supabase = createAdminClient();
  const [tags, events] = await Promise.all([
    supabase.from("prospect_tags").select("*").order("name"),
    prospectId ? supabase.from("contact_events").select("*,client:clients(name)").eq("prospect_id", prospectId).order("contacted_at", { ascending: false }).limit(100) : Promise.resolve({ data: [], error: null }),
  ]);
  const error = tags.error ?? events.error;
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ tags: tags.data ?? [], events: events.data ?? [] });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const payload = decoded.value as { action?: string; prospectIds?: string[]; clientId?: string; contactedAt?: string; campaignName?: string } | null;
  if (!payload || !Array.isArray(payload.prospectIds)) return Response.json({ error: 'Select at least one prospect.' }, { status: 400 });
  if (payload.prospectIds.length > 5000) return Response.json({ code: 'selection_too_large', error: 'This action supports up to 5,000 selected prospects per request.' }, { status: 413 });
  const prospectIds = [...new Set(payload.prospectIds.map(String))];
  if (!prospectIds.length) return Response.json({ error: "Select at least one prospect." }, { status: 400 });
  const supabase = createAdminClient();
  // RETIRED: action "tag".
  //
  // This created an agency-wide tag - prospect_tags with client_id null -
  // from a window.prompt in the Master People DB. It was a second tag
  // vocabulary beside the client ICPs, indistinguishable from them in the
  // grid and in prospect_index.tags, and nothing scoped it to anyone. A tag
  // is now something an ICP owns, created by naming one, so the only writer
  // is set_client_prospect_tag_v1.
  //
  // Refused rather than quietly dropped: a stale tab still holding the old
  // button would otherwise get a 400 reading "Unsupported bulk action" and no
  // idea why. The tags already applied are untouched and still filterable.
  if (payload.action === "tag") {
    return Response.json({ error: "Agency-wide tags are retired. Name an ICP in the client workspace and apply that instead." }, { status: 410 });
  }
  if (payload.action === "mark_contacted") {
    if (!payload.clientId) return Response.json({ error: "Choose a client." }, { status: 400 });
    const contactedAt = payload.contactedAt && !Number.isNaN(Date.parse(payload.contactedAt)) ? new Date(payload.contactedAt).toISOString() : new Date().toISOString();
    const result = await supabase.from("contact_events").insert(prospectIds.map((prospectId) => ({ id: crypto.randomUUID(), prospect_id: prospectId, client_id: payload.clientId, contacted_at: contactedAt, campaign_name: String(payload.campaignName ?? "").trim().slice(0, 160) })));
    if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
    const contacted = await reindexProspects(supabase, prospectIds);
    return Response.json({ updated: prospectIds.length, notice: indexNotice(contacted) });
  }
  return Response.json({ error: "Unsupported bulk action." }, { status: 400 });
}
