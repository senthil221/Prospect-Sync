import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { isEmptySelection, parseBulkSelection, selectionArgs } from "../../../../../lib/client-operations.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

function failure(error: { code?: string; message: string }, feature: string) {
  const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
  return Response.json(
    { error: missing ? `Apply the latest database migration to enable ${feature}.` : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
  );
}

// Push master records into this client, mark them ICP verified, or remove them.
// Every action accepts either explicit ids or the current search/filters, so a
// whole segment is one request.
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  const actor = user?.email ?? "";

  const payload = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  const action = String(payload.action ?? "push");

  let selection;
  try { selection = parseBulkSelection(payload); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : "Invalid filter." }, { status: 400 }); }

  // Without ids and without filters, these would act on the entire database.
  if (isEmptySelection(selection)) {
    return Response.json({ error: "Select prospects, or apply a filter, before running this action." }, { status: 400 });
  }

  const supabase = createAdminClient();

  if (action === "push") {
    const { data, error } = await supabase.rpc("push_prospects_to_client_v1", {
      p_client_id: id,
      ...selectionArgs(selection),
      p_source_client_id: selection.sourceClientId,
      p_actor: actor,
    });
    if (error) return failure(error, "pushing records into a client");
    return Response.json({ result: data });
  }

  if (action === "set_icp_verified" || action === "clear_icp_verified") {
    const { data, error } = await supabase.rpc("set_icp_verified_v1", {
      p_client_id: id,
      p_verified: action === "set_icp_verified",
      ...selectionArgs(selection),
      p_actor: actor,
    });
    if (error) return failure(error, "ICP verification");
    return Response.json({ result: data });
  }

  if (action === "remove") {
    const { data, error } = await supabase.rpc("remove_prospects_from_client_v2", {
      p_client_id: id,
      ...selectionArgs(selection),
      p_actor: actor,
    });
    if (error) return failure(error, "bulk removal from a client");
    return Response.json({ result: data });
  }

  return Response.json({ error: "Unsupported client action." }, { status: 400 });
}
