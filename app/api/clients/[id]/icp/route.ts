import { authorizeApi } from "../../../../../lib/auth.ts";
import { readBoundedJson } from "../../../../../lib/bounded-json.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingTableCodes = new Set(["PGRST205", "PGRST202", "42883", "42P01"]);

// An ICP description is a pasted brief, sometimes pages of it. The cap is here
// rather than on the column so going over it is a refusal with a number in it,
// not a silent truncation of somebody's targeting brief.
const maxDescription = 20_000;
const maxName = 120;
const maxProfiles = 50;

// An ICP is the thing you describe and the thing you label with, so a named
// profile owns a client-scoped tag of the same name. Creating the tag here is
// what makes "apply this ICP to these prospects" possible at all - there is no
// other way to create a client tag in the product.
//
// prospect_tags is unique on (client_id, lower(name)) for client tags, so the
// lookup must carry the client. An unqualified lookup is the bug fixed in
// 44af7a1 for the master path.
async function syncProfileTag(
  supabase: ReturnType<typeof createAdminClient>,
  clientId: string,
  profile: { id: string; name: string; tag_id: string | null },
) {
  const name = profile.name.trim();
  // An unnamed ICP gets no tag: a tag with an empty name is not selectable and
  // would collide with the next unnamed one.
  if (!name) return profile.tag_id;

  if (profile.tag_id) {
    // Rename in place, so everything already tagged keeps its label.
    const renamed = await supabase.from("prospect_tags").update({ name }).eq("id", profile.tag_id).eq("client_id", clientId).select("id").maybeSingle();
    if (!renamed.error && renamed.data) return profile.tag_id;
    // Fall through and re-resolve if the tag has gone, or the new name
    // collides with another of this client's tags.
  }

  const existing = await supabase.from("prospect_tags").select("id").eq("client_id", clientId).ilike("name", name).maybeSingle();
  if (!existing.error && existing.data) return existing.data.id as string;

  const tagId = crypto.randomUUID();
  const created = await supabase.from("prospect_tags").insert({ id: tagId, name, client_id: clientId, color: "blue" }).select("id").maybeSingle();
  // A tag that cannot be created must not fail the save of the description the
  // user just typed; the next edit retries.
  return created.error ? profile.tag_id : tagId;
}

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingTableCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to enable client ICP profiles." : error.message },
    { status: missing ? 503 : 500 },
  );
}

type IcpBody = { id?: unknown; name?: unknown; description?: unknown; sortOrder?: unknown };

function readBody(value: unknown) {
  const body = (value ?? {}) as IcpBody;
  const name = String(body.name ?? "").trim().slice(0, maxName);
  const description = String(body.description ?? "");
  if (description.length > maxDescription) {
    return { error: Response.json({
      error: `An ICP description is limited to ${maxDescription.toLocaleString()} characters; this one is ${description.length.toLocaleString()}.`,
    }, { status: 413 }) };
  }
  return { name, description };
}

export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const { data, error } = await createAdminClient()
    .from("client_icp_profiles")
    .select("id,name,description,tag_id,sort_order,created_at,updated_at")
    .eq("client_id", id)
    .order("sort_order", { ascending: true })
    .order("id", { ascending: true });
  if (error) return failure(error);
  return Response.json({ profiles: data ?? [] });
}

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const body = readBody(decoded.value);
  if ("error" in body) return body.error;

  const supabase = createAdminClient();
  // A client with fifty ICPs has a different problem, and an unbounded list is
  // an unbounded page render.
  const existing = await supabase.from("client_icp_profiles").select("sort_order", { count: "exact" }).eq("client_id", id);
  if (existing.error) return failure(existing.error);
  if ((existing.count ?? 0) >= maxProfiles) {
    return Response.json({ error: `A client can have at most ${maxProfiles} ICPs.` }, { status: 409 });
  }
  const nextOrder = Math.max(0, ...(existing.data ?? []).map((row) => Number(row.sort_order ?? 0) + 1));

  const { data, error } = await supabase
    .from("client_icp_profiles")
    .insert({ id: crypto.randomUUID(), client_id: id, name: body.name, description: body.description, sort_order: nextOrder })
    .select("id,name,description,tag_id,sort_order,created_at,updated_at")
    .maybeSingle();
  if (error) return failure(error);
  return Response.json({ profile: data });
}

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const raw = (decoded.value ?? {}) as IcpBody;
  const profileId = String(raw.id ?? "").trim();
  if (!profileId) return Response.json({ error: "Which ICP?" }, { status: 400 });
  const body = readBody(decoded.value);
  if ("error" in body) return body.error;

  // Scoped by client_id as well as id: an ICP id from another client must not
  // be editable through this client's route.
  const supabase = createAdminClient();
  const { data, error } = await supabase
    .from("client_icp_profiles")
    .update({ name: body.name, description: body.description, updated_at: new Date().toISOString() })
    .eq("id", profileId)
    .eq("client_id", id)
    .select("id,name,description,tag_id,sort_order,created_at,updated_at")
    .maybeSingle();
  if (error) return failure(error);
  if (!data) return Response.json({ error: "That ICP no longer exists." }, { status: 404 });

  // Naming an ICP is what creates its tag, and renaming one renames the tag
  // rather than orphaning it.
  const tagId = await syncProfileTag(supabase, id, data);
  if (tagId !== data.tag_id) {
    await supabase.from("client_icp_profiles").update({ tag_id: tagId }).eq("id", profileId).eq("client_id", id);
    return Response.json({ profile: { ...data, tag_id: tagId } });
  }
  return Response.json({ profile: data });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const profileId = String(((decoded.value ?? {}) as IcpBody).id ?? "").trim();
  if (!profileId) return Response.json({ error: "Which ICP?" }, { status: 400 });

  const { data, error } = await createAdminClient()
    .from("client_icp_profiles")
    .delete()
    .eq("id", profileId)
    .eq("client_id", id)
    .select("id")
    .maybeSingle();
  if (error) return failure(error);
  if (!data) return Response.json({ error: "That ICP no longer exists." }, { status: 404 });
  // Deleting the description does not delete the tag it names - the tag is
  // applied to prospects and companies, and removing a brief must not silently
  // unlabel them.
  return Response.json({ deleted: data.id });
}
