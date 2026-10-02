import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { readBoundedJson } from "../../../../../lib/bounded-json.ts";
import { readIcpSelection } from "../../../../../lib/icp-selection.ts";
import { observed } from "../../../../../lib/observability.ts";
import { filterErrorResponse, parseFilters } from "../../../../../lib/prospect-filters.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

// Pull people from the Master People DB into this client, at companies the
// client already has, by job title / management level / department
// (pull_master_people_v1, 20261003110000). "preview" counts, "pull" adds.

const missingCodes = new Set(["PGRST202", "42883", "42703"]);
const pullFields = new Set(["__title", "__title_seniority", "__title_seniority_tier", "__title_department", "__title_sub_department"]);

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to pull people from the Master DB." : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : error.code === "22023" || error.code === "54000" ? 400 : error.code === "57014" ? 504 : 500 },
  );
}

// The criteria of this client's last pull, so the next one starts from them.
async function handleGET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const { data, error } = await createAdminClient().from("client_settings").select("people_pull_filters").eq("client_id", id).maybeSingle();
  if (error) return failure(error);
  return Response.json({ filters: Array.isArray(data?.people_pull_filters) ? data.people_pull_filters : [] }, { headers: { "Cache-Control": "no-store" } });
}

async function handlePOST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const body = (decoded.value ?? {}) as Record<string, unknown>;
  const action = String(body.action ?? "preview");
  if (action !== "preview" && action !== "pull") return Response.json({ error: "Unknown action." }, { status: 400 });

  let peopleFilters;
  try { peopleFilters = parseFilters(JSON.stringify(body.peopleFilters ?? [])); }
  catch (error) { return filterErrorResponse(error, "Invalid job filters."); }
  if (peopleFilters.some((filter) => !pullFields.has(filter.field))) {
    return Response.json({ error: "A pull filters people by job title, management level and department only." }, { status: 400 });
  }

  const selection = await readIcpSelection(id, body, user?.id ?? "", "pull people for");
  if (selection.error) return selection.error;

  const requestId = String(body.requestId ?? "").trim();
  if (action === "pull" && !/^[a-zA-Z0-9-]{8,100}$/.test(requestId)) return Response.json({ error: "A pull needs a request id." }, { status: 400 });

  const { data, error } = await createAdminClient().rpc("pull_master_people_v1", {
    p_client_id: id,
    ...selection.args,
    p_people_filters: peopleFilters.map(({ field, operator, values }) => ({ field, operator, values })),
    p_apply: action === "pull",
    p_actor: user?.email ?? "",
    p_request_id: action === "pull" ? requestId : null,
  });
  if (error) return failure(error);
  return Response.json({ result: data });
}

export const GET = observed("/api/clients/[id]/pull-people", handleGET);
export const POST = observed("/api/clients/[id]/pull-people", handlePOST);
