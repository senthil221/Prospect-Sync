import { assertQueryFilterBudget, filterErrorResponse, filterSetIds, type ProspectFilter } from "./prospect-filters.ts";
import type { createAdminClient } from "./supabase/admin.ts";

// Durable filter sets (migration 20260902000100). A request carries a set id
// instead of thousands of values; these are the two things the application has
// to do about that.
//
// Section 4.1 is the rule this file exists to enforce: "Ownership (owner ID) is
// stored on filter_sets, result_sets and jobs and checked on every use. Neither
// a hash nor a cache hit is an authorization decision." A set id is otherwise a
// bearer token - it appears in request bodies, in logs, and in whatever a
// browser extension can see - so every use re-checks it against the caller.
//
// The check deliberately happens here rather than inside the SQL compiler. The
// compiler emits a predicate for a set id; the plan it produces gets cached. If
// authorization lived in the compiled plan, a second caller could inherit a
// decision made for the first.

export type FilterSetEntity = "prospect" | "company";
export type FilterAuthorizationScope = {
  entityType: FilterSetEntity;
  clientScope: string;
  filters: ProspectFilter[];
  parents?: FilterAuthorizationScope[];
};

export class FilterSetAccessError extends Error {
  readonly setId: string;
  constructor(setId: string) {
    // One message for missing, not-yours and expired, matching what the
    // database answers. A caller probing ids learns nothing from the wording.
    super("That saved value list is no longer available. Re-paste the values to continue.");
    this.name = "FilterSetAccessError";
    this.setId = setId;
  }
}

// Verify the caller may use every set the filters reference. Returns null when
// they may, or a 403 response naming what to do instead.
export async function authorizeFilterSets(
  supabase: ReturnType<typeof createAdminClient>,
  filters: ProspectFilter[],
  ownerId: string,
  entityType: FilterSetEntity,
  clientScope: string,
  parents: FilterAuthorizationScope[] = [],
): Promise<Response | null> {
  // Walk every server-parsed query dependency before compiling, caching,
  // exporting or freezing it. A cache hit must not skip authorization.
  const scopes: FilterAuthorizationScope[] = [];
  const pending: Array<{ scope: FilterAuthorizationScope; depth: number }> = [
    { scope: { entityType, clientScope, filters, parents }, depth: 0 },
  ];
  while (pending.length) {
    const { scope, depth } = pending.pop()!;
    if (depth > 8 || scopes.length >= 16) return Response.json({ error: 'Query scope is too complex.' }, { status: 400 });
    scopes.push(scope);
    for (const parent of scope.parents ?? []) pending.push({ scope: parent, depth: depth + 1 });
  }
  const references = scopes.flatMap(scope => filterSetIds(scope.filters).map(setId => ({ ...scope, setId })));
  try { assertQueryFilterBudget(scopes.map(scope => scope.filters)); }
  catch (error) { return filterErrorResponse(error, 'Query filters exceed the supported budget.'); }
  if (!references.length) return null;
  if (!ownerId) {
    return Response.json({ error: "A saved value list needs a signed-in owner." }, { status: 403 });
  }

  const checked = new Set<string>();
  for (const { setId, entityType, clientScope } of references) {
    const identity = JSON.stringify([entityType, clientScope, setId]);
    if (checked.has(identity)) continue;
    checked.add(identity);
    const { data, error } = await supabase.rpc("resolve_filter_set_v1", {
      p_set_id: setId,
      p_owner_id: ownerId,
      p_entity_type: entityType,
      p_client_scope: clientScope,
    });
    // P0002 is the database refusing it; anything else is a genuine fault and
    // must not be reported as "not yours".
    if (error) {
      if (error.code === "P0002") {
        return Response.json({ error: new FilterSetAccessError(setId).message, setId }, { status: 403 });
      }
      return Response.json({ error: error.message }, { status: 500 });
    }
    if (!Array.isArray(data) || data.length === 0) {
      return Response.json({ error: new FilterSetAccessError(setId).message, setId }, { status: 403 });
    }
  }
  return null;
}
