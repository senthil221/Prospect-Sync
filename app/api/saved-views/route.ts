import { authorizeApi } from "../../../lib/auth";
import { FilterLimitError, filterErrorResponse, parseFilters } from "../../../lib/prospect-filters";
import { createAdminClient } from "../../../lib/supabase/admin";

type ViewRow = { definition?: unknown } & Record<string, unknown>;

// A view saved before the caps existed can hold more filters or values than a
// request is now allowed to carry. Such a view is reported, never rewritten and
// never deleted: silently trimming it back would be the truncation this release
// removes, and dropping it would lose work the user did. The owner decides.
function reviewFlag(view: ViewRow) {
  const definition = view.definition;
  const filters = definition && typeof definition === "object" ? (definition as { filters?: unknown }).filters : null;
  try {
    parseFilters(JSON.stringify(filters ?? []));
    return null;
  } catch (error) {
    if (!(error instanceof FilterLimitError)) return {
      reason: 'This saved view contains a malformed or unsupported filter.',
      limit: 'invalid_filter', received: 0, allowed: 0, field: null,
      alternative: 'Review the original filter definition before applying it. The saved view has not been changed.',
    };
    return {
      reason: error.message,
      limit: error.kind,
      received: error.received,
      allowed: error.allowed,
      field: error.field,
      alternative: error.alternative,
    };
  }
}

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { data, error } = await createAdminClient().from("saved_views").select("*").order("updated_at", { ascending: false });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const views = (data ?? []).map((view: ViewRow) => {
    const needsReview = reviewFlag(view);
    return needsReview ? { ...view, needsReview } : view;
  });
  return Response.json({ views });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id, name, definition } = await request.json() as { id?: string; name?: string; definition?: unknown };
  const cleanedName = String(name ?? "").trim().slice(0, 80);
  if (!cleanedName || !definition || typeof definition !== "object") return Response.json({ error: "View name and definition are required." }, { status: 400 });
  // Refuse to store a view that no request could execute, so the caps are not
  // discovered later as a failure on every load of a saved view.
  try { parseFilters(JSON.stringify((definition as { filters?: unknown }).filters ?? [])); }
  catch (error) { return filterErrorResponse(error, "This view's filters are not valid."); }
  const view = { id: id || crypto.randomUUID(), name: cleanedName, definition, updated_at: new Date().toISOString() };
  const { data, error } = await createAdminClient().from("saved_views").upsert(view).select("*").single();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ view: data });
}

export async function DELETE(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const id = new URL(request.url).searchParams.get("id");
  if (!id) return Response.json({ error: "View id is required." }, { status: 400 });
  const { error } = await createAdminClient().from("saved_views").delete().eq("id", id);
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ deleted: true });
}
