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
  const payload = decoded.value as { action?: string; prospectIds?: string[]; tagName?: string; clientId?: string; contactedAt?: string; campaignName?: string } | null;
  if (!payload || !Array.isArray(payload.prospectIds)) return Response.json({ error: 'Select at least one prospect.' }, { status: 400 });
  if (payload.prospectIds.length > 5000) return Response.json({ code: 'selection_too_large', error: 'This action supports up to 5,000 selected prospects per request.' }, { status: 413 });
  const prospectIds = [...new Set(payload.prospectIds.map(String))];
  if (!prospectIds.length) return Response.json({ error: "Select at least one prospect." }, { status: 400 });
  const supabase = createAdminClient();
  if (payload.action === "tag") {
    const tagName = String(payload.tagName ?? "").trim().slice(0, 60);
    if (!tagName) return Response.json({ error: "Tag name is required." }, { status: 400 });
    const existing = await supabase.from("prospect_tags").select("id").eq("name", tagName).maybeSingle();
    if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
    const tagId = existing.data?.id ?? crypto.randomUUID();
    if (!existing.data) {
      const created = await supabase.from("prospect_tags").insert({ id: tagId, name: tagName });
      if (created.error) return Response.json({ error: created.error.message }, { status: 500 });
    }
    const result = await supabase.from("prospect_tag_links").upsert(prospectIds.map((prospectId) => ({ prospect_id: prospectId, tag_id: tagId })), { onConflict: "prospect_id,tag_id", ignoreDuplicates: true });
    if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
    const tagged = await reindexProspects(supabase, prospectIds);
    return Response.json({ updated: prospectIds.length, tagId, notice: indexNotice(tagged) });
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
