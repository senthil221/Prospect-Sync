import { authorizeApi, getAuthorizedUser } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

export const runtime = "nodejs";

// Store a pasted value list once, and hand back an id the filters can carry.
//
// The alternative is what happens today: the whole list travels with the page,
// the count, every subsequent page, the pivot and every export page. At the
// 5,000 cap that is roughly 75 KB per request and 82 KB of compiled SQL.
//
// The ceiling here is 10,000 rather than the 5,000 that applies to inline
// values, which is the point of the mechanism - section 6.3 sizes durable sets
// at 10,000 unique normalized values.
const maxSetValues = 10_000;
const allowedEntities = new Set(["prospect", "company"]);

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;

  // Sets are owned, and the owner is the signed-in user rather than anything
  // the request supplies. A client-supplied owner would make the ownership
  // check on every later use meaningless.
  const user = await getAuthorizedUser();
  if (!user?.id) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const payload = await request.json().catch(() => null) as {
    entityType?: unknown;
    field?: unknown;
    clientScope?: unknown;
    values?: unknown;
  } | null;
  if (!payload) return Response.json({ error: "Invalid filter set request." }, { status: 400 });

  const entityType = String(payload.entityType ?? "").trim();
  if (!allowedEntities.has(entityType)) {
    return Response.json({ error: "A filter set needs an entity type of prospect or company." }, { status: 400 });
  }
  const field = String(payload.field ?? "").trim().slice(0, 160);
  if (!field) return Response.json({ error: "A filter set needs a field." }, { status: 400 });
  const clientScope = String(payload.clientScope ?? "").trim();

  const values = Array.isArray(payload.values)
    ? payload.values.map((value) => String(value ?? "").trim()).filter(Boolean)
    : [];
  if (!values.length) return Response.json({ error: "Paste at least one value." }, { status: 400 });
  // Refused, not trimmed - the same contract as every other over-cap request
  // since 20260902000040. The database enforces this too; answering here saves
  // sending 10,001 values only to have them rejected.
  if (values.length > maxSetValues) {
    return Response.json({
      error: `This list has ${values.length.toLocaleString("en-IN")} values; at most ${maxSetValues.toLocaleString("en-IN")} are allowed. Split it and run the parts one at a time.`,
      limit: "values",
      received: values.length,
      allowed: maxSetValues,
      field,
      alternative: `Split this list into batches of ${maxSetValues.toLocaleString("en-IN")} values or fewer.`,
    }, { status: 413 });
  }

  const { data, error } = await createAdminClient().rpc("create_filter_set_v1", {
    p_owner_id: user.id,
    p_entity_type: entityType,
    p_client_scope: clientScope,
    p_field: field,
    p_values: values,
  });
  if (error) {
    if (error.code === "PGRST202" || error.code === "42883") {
      return Response.json({ error: "Apply the latest database migration to enable saved value lists." }, { status: 503 });
    }
    // 22023 is the database rejecting the input (no values, over the cap, an
    // unknown entity); that is the caller's to fix, not a server fault.
    return Response.json({ error: error.message }, { status: error.code === "22023" ? 400 : 500 });
  }

  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.set_id) return Response.json({ error: "The filter set could not be stored." }, { status: 500 });

  return Response.json({
    setId: row.set_id,
    // The content hash, not the id, is what the count cache keys on (section
    // 4.1), so the client gets it back to use rather than the random uuid.
    contentHash: row.content_hash,
    valueCount: Number(row.value_count ?? 0),
    // True when identical values were already stored: the caller can say
    // "recognised" rather than implying it uploaded them again.
    reused: row.reused === true,
  });
}
