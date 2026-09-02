import { createHash } from "node:crypto";

// Durable result sets (migration 20260902000120, reachable since
// 20260902000160). A result set is the answer to a question, frozen: the ids
// that matched, in order, with the version vector they matched at.
//
// It exists because two things in the product cannot be done inside a request.
// A count past the cap is answered as "50,000+", which is a floor rather than a
// number; and "select all matching, then push" resolves its ids at execution
// time, so an import landing in between silently widens the action. Both need
// the same thing - the full id list, built once, over minutes if necessary, and
// then owned.

// The identity of the question. Two callers asking the same thing get the same
// set rather than two builds of it.
//
// The owner is deliberately NOT part of this hash. request_set_v1 matches on
// (owner, entity, scope, hash), so the owner is already part of the lookup key;
// folding it in here as well would only make the hash harder to reason about.
//
// The filters go in exactly as sent, which means a set id and the values it
// stands for hash differently. That is the honest answer: this is a cache key
// for a build, not a statement about logical identity, and a wrong reuse would
// freeze the wrong ids into someone's bulk action.
export function resultSetContentHash(input: {
  entityType: string;
  clientScope: string;
  search: string;
  filters: unknown;
}) {
  return createHash("sha256").update(JSON.stringify({
    entityType: input.entityType,
    clientScope: input.clientScope,
    search: input.search.trim(),
    filters: input.filters ?? [],
  })).digest("hex");
}

// Who owns a result set, and who acts on an operation, have to be the same
// string: freeze_operation_from_result_set_v1 looks the set up by the job's
// actor. Email is what the bulk routes have always recorded as the actor, so
// that is the identity; the id is a fallback for an account without one rather
// than a second namespace.
export function ownerIdentity(user: { id?: string | null; email?: string | null } | null) {
  return String(user?.email ?? "").trim() || String(user?.id ?? "").trim();
}
