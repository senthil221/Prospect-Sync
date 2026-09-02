import { authorizeApi, getAuthorizedUser } from "../../../lib/auth";
import { authorizeFilterSets } from "../../../lib/filter-sets";
import { filterErrorResponse, parseFilters } from "../../../lib/prospect-filters";
import { ownerIdentity, resultSetContentHash } from "../../../lib/result-sets";
import { createAdminClient } from "../../../lib/supabase/admin";

export const runtime = "nodejs";

// Ask for the full id list behind a question, and watch it get built.
//
// Two user-visible failures end here. A count past the cap is shown as
// "50,000+" because search_prospect_workspace_v12 stops counting - the honest
// answer, but not the one that was asked for. And a heavy filter combination
// times out at 10s with a 504, which is a refusal rather than a result. Neither
// can be fixed inside a request: the work is genuinely minutes long. It can be
// done outside one, by a worker with its own connection, and then read back.
//
// NOTHING HERE BUILDS ANYTHING. The route records the request; the operations
// worker claims it, builds it in bounded batches, and extends its own lease by
// making progress. A build that takes four minutes costs this route one insert.

const allowedEntities = new Set(["prospect", "company"]);
const missing = (code?: string) => code === "PGRST202" || code === "42883";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const owner = ownerIdentity(await getAuthorizedUser());
  if (!owner) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const payload = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload) return Response.json({ error: "Invalid result set request." }, { status: 400 });

  const entityType = String(payload.entityType ?? "prospect").trim();
  if (!allowedEntities.has(entityType)) {
    return Response.json({ error: "A result set needs an entity type of prospect or company." }, { status: 400 });
  }
  const clientScope = String(payload.clientScope ?? "").trim();
  const search = String(payload.search ?? "").trim().slice(0, 300);

  let filters;
  try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
  catch (error) { return filterErrorResponse(error, "Invalid filters."); }

  // Without a search term and without filters this would freeze the entire
  // database. That is a real thing to want, but not by accident.
  if (!search && !filters.length) {
    return Response.json({ error: "Apply a filter or a search term before building a result set." }, { status: 400 });
  }

  const supabase = createAdminClient();
  // A set id is not authorization, and neither is a filter-set id inside it.
  const setDenial = await authorizeFilterSets(supabase, filters, (await getAuthorizedUser())?.id ?? "", entityType as "prospect" | "company", clientScope);
  if (setDenial) return setDenial;

  const { data, error } = await supabase.rpc("request_result_set_v1", {
    p_owner_id: owner,
    p_entity_type: entityType,
    p_client_scope: clientScope,
    p_search: search,
    p_filters: filters,
    p_content_hash: resultSetContentHash({ entityType, clientScope, search, filters }),
    // Null on purpose: the database takes the version vector at the moment of
    // the request. See 20260902000160 - a browser-supplied vector could only
    // ever make a stale set look fresh.
    p_version_vector: null,
  });
  if (error) {
    if (missing(error.code)) return Response.json({ error: "Apply the latest database migration to enable background result sets." }, { status: 503 });
    return Response.json({ error: error.message }, { status: error.code === "22023" ? 400 : 500 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.set_id) return Response.json({ error: "The result set could not be requested." }, { status: 500 });
  return Response.json({
    setId: row.set_id,
    status: row.status,
    rowCount: Number(row.row_count ?? 0),
    // True when an identical request was already in flight or finished.
    reused: row.reused === true,
    // True when a reused set was built before the data changed. The caller
    // decides what to do about that; nothing is rebuilt behind its back.
    stale: row.stale === true,
  });
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const owner = ownerIdentity(await getAuthorizedUser());
  if (!owner) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const url = new URL(request.url);
  const setId = (url.searchParams.get("id") ?? "").trim();
  if (!setId) return Response.json({ error: "Which result set?" }, { status: 400 });

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("result_set_status_v1", {
    p_set_id: setId,
    p_owner_id: owner,
    p_version_vector: null,
  });
  if (error) {
    if (missing(error.code)) return Response.json({ error: "Apply the latest database migration to enable background result sets." }, { status: 503 });
    // Ownership is the database's decision: status_v1 raises P0002 for a set
    // that is not this caller's, with the same message as for one that never
    // existed. Someone probing ids learns nothing either way.
    if (error.code === "P0002") return Response.json({ error: "That result set is no longer available." }, { status: 404 });
    // 22P02 is a malformed uuid - the caller's to fix, not a server fault.
    return Response.json({ error: error.message }, { status: error.code === "22P02" ? 400 : 500 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return Response.json({ error: "That result set is no longer available." }, { status: 404 });

  return Response.json({
    setId,
    status: row.status,
    rowCount: Number(row.row_count ?? 0),
    stale: row.stale === true,
    frozenAt: row.frozen_at ?? null,
    error: row.error ?? null,
  });
}
