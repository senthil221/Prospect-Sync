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
  const { data, error } = await createAdminClient()
    .from("client_icp_profiles")
    .update({ name: body.name, description: body.description, updated_at: new Date().toISOString() })
    .eq("id", profileId)
    .eq("client_id", id)
    .select("id,name,description,tag_id,sort_order,created_at,updated_at")
    .maybeSingle();
  if (error) return failure(error);
  if (!data) return Response.json({ error: "That ICP no longer exists." }, { status: 404 });
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
