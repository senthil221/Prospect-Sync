import { createHash } from "node:crypto";
import type { createAdminClient } from "./supabase/admin.ts";

// Idempotency and frozen selections for bulk mutations (section 9.2 / 9.3,
// migration 20260902000140).
//
// The problem this solves is not exotic. A bulk action is a POST; if its
// response is lost - a dropped connection, a reload, an impatient second click -
// the browser cannot tell "it did not happen" from "it happened and I did not
// hear". Retrying pushes forty thousand prospects into a client twice.
//
// The key is the request, never the content. Section 9.2: "unique per
// actor/action/request UUID ... Never deduplicate solely by content hash." Two
// identical pushes a week apart are two legitimate operations; the same request
// arriving twice is one, and only a client-generated id can tell them apart.

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function parseRequestId(value: unknown) {
  const candidate = typeof value === "string" ? value.trim() : "";
  return uuidPattern.test(candidate) ? candidate : null;
}

// The audit hash from section 9.2. Deliberately not the idempotency key - it
// travels beside the request id so an operation can be traced back to the
// selection that produced it.
export function selectionContentHash(input: {
  action: string;
  clientScope: string;
  search: string;
  filters: unknown;
  prospectIds: string[] | null;
  excludedIds: string[] | null;
}) {
  const canonical = JSON.stringify({
    action: input.action,
    clientScope: input.clientScope,
    search: input.search.trim(),
    filters: input.filters ?? [],
    // Sorted, so the hash does not depend on the order rows were ticked.
    ids: [...(input.prospectIds ?? [])].sort(),
    excluded: [...(input.excludedIds ?? [])].sort(),
  });
  return createHash("sha256").update(canonical).digest("hex");
}

export type OperationHandle =
  | { kind: "replay"; jobId: string; result: unknown }
  | { kind: "run"; jobId: string }
  | { kind: "untracked" };

// Open an operation. Returns "replay" when this exact request has already
// completed, in which case the caller answers with the recorded result and does
// not touch the database again.
//
// A request without an id is not refused: the UI is being taught to send one,
// and existing callers (including the authenticated import test) must keep
// working. It simply gets no protection, which is what happens today.
export async function beginOperation(
  supabase: ReturnType<typeof createAdminClient>,
  input: {
    requestId: string | null;
    actor: string;
    action: string;
    entityType: "prospect" | "company";
    clientScope: string;
    contentHash: string;
    versionVector: Record<string, number> | null;
    payload: Record<string, unknown>;
    excludedIds: string[] | null;
  },
): Promise<OperationHandle> {
  if (!input.requestId || !input.actor) return { kind: "untracked" };

  const { data, error } = await supabase.rpc("enqueue_operation_v1", {
    p_actor: input.actor,
    p_request_id: input.requestId,
    p_action: input.action,
    p_entity_type: input.entityType,
    p_client_scope: input.clientScope,
    p_content_hash: input.contentHash,
    p_version_vector: input.versionVector ?? {},
    p_payload: input.payload,
    p_excluded_ids: input.excludedIds ?? [],
  });
  // A tracking failure must not take the operation down with it: the mutation
  // is still safe to run, it just runs unprotected, which is today's behaviour.
  if (error) {
    console.warn(JSON.stringify({ at: new Date().toISOString(), event: "operation_tracking_unavailable", message: error.message }));
    return { kind: "untracked" };
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.job_id) return { kind: "untracked" };
  if (row.status === "completed") {
    return { kind: "replay", jobId: row.job_id, result: row.result ?? null };
  }
  return { kind: "run", jobId: row.job_id };
}

// Freeze the selection the user actually chose, so the operation cannot widen
// between choosing and running. Explicit ids only; "all matching" freezes from
// a built result set instead (freeze_operation_from_result_set_v1).
export async function freezeSelection(
  supabase: ReturnType<typeof createAdminClient>,
  jobId: string,
  actor: string,
  ids: string[],
) {
  const { error } = await supabase.rpc("freeze_operation_ids_v1", {
    p_job_id: jobId,
    p_actor: actor,
    p_ids: ids,
  });
  if (error) console.warn(JSON.stringify({ at: new Date().toISOString(), event: "operation_freeze_failed", message: error.message }));
}

// Record what the operation answered, so a retry is answered from here.
export async function recordOperationResult(
  supabase: ReturnType<typeof createAdminClient>,
  jobId: string,
  actor: string,
  result: unknown,
) {
  const { error } = await supabase.rpc("record_operation_result_v1", {
    p_job_id: jobId,
    p_actor: actor,
    p_result: result ?? null,
  });
  if (error) console.warn(JSON.stringify({ at: new Date().toISOString(), event: "operation_result_not_recorded", message: error.message }));
}
