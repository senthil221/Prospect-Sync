// Stable request ids for mutations, so a retry is a retry.
//
// The point of an idempotency key is easy to lose by generating it in the wrong
// place. A fresh uuid per click makes every retry a new operation, which is
// exactly the double-push it was meant to prevent - the server would see two
// distinct requests and honour both.
//
// So the id belongs to the user's *intent*, not to the click. The same
// selection, action and target reuse the same id until it succeeds; changing
// any of them is a new intent and gets a new id. That way:
//
//   click, connection drops, click again   -> one operation
//   push 50 rows, then push 50 more rows   -> two operations
//
// Section 9.2 puts the uniqueness on (actor, action, request UUID), so the id
// only has to be stable per actor - it does not need to encode the selection,
// and deliberately does not: the selection is hashed separately as an audit
// field.

const pending = new Map<string, string>();

// A description of what the user is asking for, stable under things that do not
// change the request - the order rows were ticked, most obviously.
export function intentKey(input: {
  action: string;
  target?: string;
  selectionMode?: string;
  ids?: string[];
  extra?: unknown;
}) {
  return JSON.stringify({
    action: input.action,
    target: input.target ?? "",
    mode: input.selectionMode ?? "",
    ids: [...(input.ids ?? [])].sort(),
    extra: input.extra ?? null,
  });
}

// The id for this intent, created once and reused until it is settled.
export function requestIdFor(key: string) {
  const existing = pending.get(key);
  if (existing) return existing;
  // randomUUID needs a secure context; a page served over http:// in
  // development has no crypto.randomUUID, and failing the mutation for that
  // would be worse than falling back.
  const created = typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
    ? crypto.randomUUID()
    : `${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 10)}-4000-8000-${Math.random().toString(16).slice(2, 14)}`;
  pending.set(key, created);
  return created;
}

// Called once the operation has actually landed. The next deliberate action of
// the same shape is a new operation and must get a new id - which is why this
// is not cleared on failure.
export function settleIntent(key: string) {
  pending.delete(key);
}

// Tests only.
export function pendingIntentCount() {
  return pending.size;
}
