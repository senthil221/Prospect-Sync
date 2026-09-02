import { filterSetIds, type ProspectFilter } from "./prospect-filters.ts";
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
): Promise<Response | null> {
  const ids = filterSetIds(filters);
  if (!ids.length) return null;
  if (!ownerId) {
    return Response.json({ error: "A saved value list needs a signed-in owner." }, { status: 403 });
  }

  for (const setId of ids) {
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
