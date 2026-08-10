import { authorizeApi } from "../../../lib/auth";
import { reindexProspects } from "../../../lib/reindex";
import { createAdminClient } from "../../../lib/supabase/admin";

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const prospectId = new URL(request.url).searchParams.get("prospectId");
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
  const payload = await request.json() as { action?: string; prospectIds?: string[]; tagName?: string; clientId?: string; contactedAt?: string; campaignName?: string };
  const prospectIds = [...new Set((payload.prospectIds ?? []).map(String))].slice(0, 5000);
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
    await reindexProspects(supabase, prospectIds);
    return Response.json({ updated: prospectIds.length, tagId });
  }
  if (payload.action === "mark_contacted") {
    if (!payload.clientId) return Response.json({ error: "Choose a client." }, { status: 400 });
    const contactedAt = payload.contactedAt && !Number.isNaN(Date.parse(payload.contactedAt)) ? new Date(payload.contactedAt).toISOString() : new Date().toISOString();
    const result = await supabase.from("contact_events").insert(prospectIds.map((prospectId) => ({ id: crypto.randomUUID(), prospect_id: prospectId, client_id: payload.clientId, contacted_at: contactedAt, campaign_name: String(payload.campaignName ?? "").trim().slice(0, 160) })));
    if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
    await reindexProspects(supabase, prospectIds);
    return Response.json({ updated: prospectIds.length });
  }
  return Response.json({ error: "Unsupported bulk action." }, { status: 400 });
}
