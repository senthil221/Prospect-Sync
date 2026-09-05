import { authorizeApi, getAuthorizedUser } from "../../../lib/auth";
import { backgroundAdmissionResponse } from '../../../lib/operations-health';
import { authorizeFilterSets } from "../../../lib/filter-sets";
import { filterErrorResponse, parseFilters } from "../../../lib/prospect-filters";
import { companyExportKeys } from "../../../lib/company-export";
import { availableExportFieldIds, exportRowKeys } from "../../../lib/prospect-export";
import { ownerIdentity, resultSetContentHash } from "../../../lib/result-sets";
import { createAdminClient } from "../../../lib/supabase/admin";
import { parseCompanyScope, scopeRestricts } from "../../../lib/workspace-scopes";

export const runtime = "nodejs";

// Ask for a file that is too big to download in one request, and watch it get
// written.
//
// Section 9.4 chooses between a direct stream and a background file on
// estimated bytes as well as rows; lib/export-plan.ts makes that choice and
// this is the second half of it. Nothing here builds anything: the route
// freezes the question into a result set and records a job, and the operations
// worker writes the file in bounded batches.
//
// THE RESULT SET IS THE FILE'S DEFINITION, AND ITS AUTHORIZATION. A job names a
// set, and request_export_v1 refuses a set belonging to anyone else. It also
// means the row count stops being a guess: an export whose count was "50,000+"
// knows exactly how many rows it will contain before the first one is written.
//
// AN UNFILTERED EXPORT IS ALLOWED HERE AND REFUSED BY /api/result-sets. That is
// deliberate rather than inconsistent. Freezing the whole database from the
// grid is almost always an accident - a stray click on a page with no filters -
// so that route insists on a search or a filter. Exporting everything is a
// thing people genuinely mean, and they mean it by choosing fields and pressing
// Export, so this route asks for the set itself.

const allowedEntities = new Set(["prospect", "company"]);
const missing = (code?: string) => code === "PGRST202" || code === "42883" || code === "42P01";
const migrationNeeded = () => Response.json(
  { error: "Apply the latest database migration to enable background exports." }, { status: 503 });


export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const user = await getAuthorizedUser();
  const owner = ownerIdentity(user);
  if (!owner) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const payload = decoded.value as Record<string, unknown> | null;
  if (!payload) return Response.json({ error: "Invalid export request." }, { status: 400 });

  const entityType = String(payload.entityType ?? "prospect").trim();
  if (!allowedEntities.has(entityType)) {
    return Response.json({ error: "An export needs an entity type of prospect or company." }, { status: 400 });
  }
  const requestId = String(payload.requestId ?? "").trim();
  if (!requestId) return Response.json({ error: "An export needs a request id." }, { status: 400 });

  const clientScope = String(payload.clientScope ?? "").trim();
  const search = String(payload.search ?? "").trim().slice(0, 300);
  let filters;
  try { filters = parseFilters(JSON.stringify(payload.filters ?? [])); }
  catch (error) { return filterErrorResponse(error, "Invalid filters."); }

  let companyScope;
  try { companyScope = parseCompanyScope(payload.companyScope ? JSON.stringify(payload.companyScope) : null); }
  catch (error) { return filterErrorResponse(error, "Invalid company navigation scope."); }
  // Carried into the set rather than refused. Until 20260902000180 a result set
  // had nowhere to put a pivot, so a background export under one would have
  // written every person matching the filters instead of only those companies -
  // which is why this used to answer 400 rather than build anything.
  const scopePayload = scopeRestricts(companyScope) ? companyScope : null;
  if (entityType === "company" && scopePayload) {
    return Response.json({ error: "A company export cannot carry a company scope." }, { status: 400 });
  }

  const requestedFields = Array.isArray(payload.fields)
    ? [...new Set(payload.fields.map((field) => String(field).trim()).filter(Boolean))].slice(0, 600)
    : [];
  const excludedIds = Array.isArray(payload.excludedIds)
    ? [...new Set(payload.excludedIds.map((id) => String(id).trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const fileBaseName = String(payload.fileBaseName ?? "prospect-sync-export")
    .replace(/[^a-zA-Z0-9._-]+/g, "-").slice(0, 80) || "export";

  const supabase = createAdminClient();
  // A set id is not authorization, and neither is a filter-set id inside one.
  const setDenial = await authorizeFilterSets(supabase, filters, user?.id ?? "", entityType as "prospect" | "company", clientScope,
    scopePayload ? [{ entityType: 'company', clientScope, filters: scopePayload.filters }] : []);
  if (setDenial) return setDenial;
  const unavailable = await backgroundAdmissionResponse();
  if (unavailable) return unavailable;

  let fields: string[] = [];
  let keys: string[] = [];
  if (entityType === "prospect") {
    if (!requestedFields.length) return Response.json({ error: "Choose at least one field to export." }, { status: 400 });
    const fieldRows = await supabase.from("prospect_fields").select("field_name").order("field_name").limit(500);
    if (fieldRows.error) return Response.json({ error: fieldRows.error.message }, { status: 500 });
    const customFieldNames = (fieldRows.data ?? []).map((field) => String(field.field_name ?? "")).filter(Boolean);
    const available = availableExportFieldIds(customFieldNames);
    fields = requestedFields.filter((field) => available.has(field));
    if (!fields.length) return Response.json({ error: "None of the selected fields are available." }, { status: 400 });
    keys = exportRowKeys(customFieldNames, fields);
  } else {
    // The company file is Name and Website and always has been; there is no
    // field picker for it, so the columns come from lib/company-export.ts at
    // both ends and only the keys need recording.
    keys = [...companyExportKeys];
  }

  const set = await supabase.rpc("request_result_set_v1", {
    p_owner_id: owner,
    p_entity_type: entityType,
    p_client_scope: clientScope,
    p_search: search,
    p_filters: filters,
    p_content_hash: resultSetContentHash({ entityType, clientScope, search, filters, companyScope: scopePayload }),
    // Null on purpose: the database takes the version vector at the moment of
    // the request, so a reused set is compared against the world as it is now.
    p_version_vector: null,
    p_company_scope: scopePayload ?? {},
  });
  if (set.error) {
    if (missing(set.error.code)) return migrationNeeded();
    return Response.json({ error: set.error.message }, { status: set.error.code === "22023" ? 400 : 500 });
  }
  const setRow = Array.isArray(set.data) ? set.data[0] : set.data;
  if (!setRow?.set_id) return Response.json({ error: "The export could not be prepared." }, { status: 500 });

  const job = await supabase.rpc("request_export_v1", {
    p_owner_id: owner,
    p_request_id: requestId,
    p_entity_type: entityType,
    p_client_scope: clientScope,
    p_result_set_id: setRow.set_id,
    p_fields: fields,
    p_keys: keys,
    p_excluded_ids: excludedIds,
    p_file_base_name: fileBaseName,
  });
  if (job.error) {
    if (missing(job.error.code)) return migrationNeeded();
    if (job.error.code === "P0002") return Response.json({ error: "That result set is no longer available." }, { status: 404 });
    if (job.error.code === "42501") return Response.json({ error: "That result set is not yours." }, { status: 403 });
    return Response.json({ error: job.error.message }, { status: job.error.code === "22023" ? 400 : 500 });
  }
  const jobRow = Array.isArray(job.data) ? job.data[0] : job.data;
  if (!jobRow?.job_id) return Response.json({ error: "The export could not be queued." }, { status: 500 });

  return Response.json({
    jobId: jobRow.job_id,
    token: jobRow.download_token,
    setId: setRow.set_id,
    setStatus: setRow.status,
    status: jobRow.status,
    // True when this exact request id already had a job. A retry after a dropped
    // connection watches the file that is already being written.
    reused: jobRow.reused === true,
    stale: setRow.stale === true,
  }, { status: 202 });
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const owner = ownerIdentity(await getAuthorizedUser());
  if (!owner) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const jobId = (new URL(request.url).searchParams.get("id") ?? "").trim();
  if (!jobId) return Response.json({ error: "Which export?" }, { status: 400 });

  const supabase = createAdminClient();
  const { data, error } = await supabase.rpc("export_status_v1", { p_job_id: jobId, p_owner_id: owner });
  if (error) {
    if (missing(error.code)) return migrationNeeded();
    // Ownership is the database's decision, and it answers the same way for a
    // job that is not yours as for one that never existed.
    if (error.code === "P0002") return Response.json({ error: "That export is no longer available." }, { status: 404 });
    return Response.json({ error: error.message }, { status: error.code === "22P02" ? 400 : 500 });
  }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return Response.json({ error: "That export is no longer available." }, { status: 404 });

  return Response.json({
    jobId,
    status: row.status,
    rowCount: Number(row.row_count ?? 0),
    byteCount: Number(row.byte_count ?? 0),
    partCount: Number(row.part_count ?? 0),
    // The list has to be finished before the file can start, and the two waits
    // look identical from outside unless both are reported.
    setStatus: row.set_status ?? null,
    setRows: Number(row.set_rows ?? 0),
    fileBaseName: row.file_base_name ?? "export",
    expiresAt: row.expires_at ?? null,
    error: row.error ?? null,
  });
}
import { readBoundedJson } from "../../../lib/bounded-json";
