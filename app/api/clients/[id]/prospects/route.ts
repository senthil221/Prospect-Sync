import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { isEmptySelection, parseBulkSelection, selectionArgs } from "../../../../../lib/client-operations.ts";
import { beginOperation, freezeFromResultSet, freezeSelection, parseRequestId, recordOperationResult, selectionContentHash } from "../../../../../lib/operation-jobs.ts";
import { filterErrorResponse } from "../../../../../lib/prospect-filters.ts";
import { ownerIdentity } from "../../../../../lib/result-sets.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";

const missingFunctionCodes = new Set(["PGRST202", "42883", "42P01"]);

function failure(error: { code?: string; message: string }, feature: string) {
  const missing = Boolean(error.code && missingFunctionCodes.has(error.code));
  return Response.json(
    { error: missing ? `Apply the latest database migration to enable ${feature}.` : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : 500 },
  );
}

function validDateContacted(value: unknown): string | null | undefined {
  if (value === null) return null;
  const date = String(value ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < "1900-01-01") return undefined;
  const parsed = new Date(`${date}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) return undefined;
  return date <= new Date(Date.now() + 24 * 60 * 60_000).toISOString().slice(0, 10) ? date : undefined;
}

// Push master records into this client, mark them ICP verified, or remove them.
// Every action accepts either explicit ids or the current search/filters, so a
// whole segment is one request.
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const user = await getAuthorizedUser();
  // The same identity a result set is owned by, so a job can freeze from one.
  const actor = ownerIdentity(user);

  const payload = await request.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload) return Response.json({ error: "Invalid request." }, { status: 400 });
  const action = String(payload.action ?? "push");

  let selection;
  try { selection = parseBulkSelection(payload); }
  catch (error) { return filterErrorResponse(error, "Invalid filter."); }

  // Validated before the job is created, not inside the branch that runs it: a
  // job that runs in the background carries its own parameters, and the worker
  // has nobody to ask if the date turns out to be nonsense.
  const dateContacted = action === "set_date_contacted" ? validDateContacted(payload.dateContacted) : null;
  if (action === "set_date_contacted" && dateContacted === undefined) {
    return Response.json({ error: "Choose a valid Date Contacted between 1900-01-01 and today, or select no contact date." }, { status: 400 });
  }
  const jobPayload: Record<string, unknown> = {
    clientId: id,
    ...(selection.sourceClientId ? { sourceClientId: selection.sourceClientId } : {}),
    // Present-and-null means "clear the date", which is different from absent.
    ...(action === "set_date_contacted" ? { dateContacted: dateContacted ?? null } : {}),
  };

  // Section 9.3, the part that was still missing: "all matching" freezes from a
  // result set the user already built and owns, so the ids are the ones that
  // matched when they looked - not whatever matches when the mutation runs.
  const resultSetId = String(payload.resultSetId ?? "").trim();

  // Without ids and without filters, these would act on the entire database.
  if (isEmptySelection(selection)) {
    return Response.json({ error: "Select prospects, or apply a filter, before running this action." }, { status: 400 });
  }

  const supabase = createAdminClient();

  // Section 9.2: a retry of the same request is the same operation, keyed on the
  // client-generated request id rather than on the content - two identical
  // pushes a week apart are two legitimate operations. A request that arrives
  // without an id is not refused; it simply gets no protection, which is what
  // happens today.
  const requestId = parseRequestId(payload.requestId);
  const operation = await beginOperation(supabase, {
    requestId,
    actor,
    action,
    entityType: "prospect",
    clientScope: id,
    contentHash: selectionContentHash({
      action, clientScope: id, search: selection.search, filters: selection.filters,
      prospectIds: selection.prospectIds, excludedIds: selection.excludedIds,
    }),
    versionVector: null,
    payload: jobPayload,
    excludedIds: selection.excludedIds,
  });
  // Already done. Answer with what it answered the first time rather than
  // running the mutation a second time.
  if (operation.kind === "replay") {
    return Response.json({ result: operation.result, replayed: true, jobId: operation.jobId });
  }

  // The background path. The selection is frozen from the result set and the
  // operations worker applies it in bounded batches; this request answers 202
  // with the job to watch rather than holding an interactive slot for the
  // minutes a 250,000-row push actually takes.
  if (resultSetId) {
    if (operation.kind !== "run") {
      return Response.json({ error: "A background action needs a request id." }, { status: 400 });
    }
    const frozen = await freezeFromResultSet(supabase, operation.jobId, actor, resultSetId);
    if (frozen.error) return frozen.error;
    return Response.json({
      jobId: operation.jobId,
      status: "frozen",
      background: true,
      totalItems: frozen.totalItems,
      excludedCount: frozen.excludedCount,
    }, { status: 202 });
  }

  // Section 9.3: freeze the explicit selection so the operation cannot widen
  // between choosing and running.
  if (operation.kind === "run" && selection.prospectIds?.length) {
    await freezeSelection(supabase, operation.jobId, actor, selection.prospectIds);
  }
  const finish = async (result: unknown) => {
    if (operation.kind === "run") await recordOperationResult(supabase, operation.jobId, actor, result);
    return Response.json(operation.kind === "run" ? { result, jobId: operation.jobId } : { result });
  };

  if (action === "push") {
    const { data, error } = await supabase.rpc("push_prospects_to_client_v1", {
      p_client_id: id,
      ...selectionArgs(selection),
      p_source_client_id: selection.sourceClientId,
      p_actor: actor,
    });
    if (error) return failure(error, "pushing records into a client");
    return finish(data);
  }

  if (action === "set_icp_verified" || action === "clear_icp_verified") {
    const { data, error } = await supabase.rpc("set_icp_verified_v1", {
      p_client_id: id,
      p_verified: action === "set_icp_verified",
      ...selectionArgs(selection),
      p_actor: actor,
    });
    if (error) return failure(error, "ICP verification");
    // Recorded like every other action. Without this the job stays open and a
    // retry of the same request id re-runs the mutation instead of being
    // answered from what it did the first time.
    return finish(data);
  }

  if (action === "set_date_contacted") {
    const { data, error } = await supabase.rpc("set_client_date_contacted_v1", {
      p_client_id: id,
      p_date_contacted: dateContacted,
      ...selectionArgs(selection),
      p_actor: actor,
    });
    if (error) return failure(error, "Date Contacted updates");
    return finish(data);
  }

  if (action === "remove") {
    const { data, error } = await supabase.rpc("remove_prospects_from_client_v2", {
      p_client_id: id,
      ...selectionArgs(selection),
      p_actor: actor,
    });
    if (error) return failure(error, "bulk removal from a client");
    return finish(data);
  }

  return Response.json({ error: "Unsupported client action." }, { status: 400 });
}
