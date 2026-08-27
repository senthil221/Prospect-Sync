import { authorizeApi } from "../../../../lib/auth";
import { normalizeText } from "../../../../db/normalize";
import { normalizeDataSource } from "../../../../lib/data-source";
import { missingRequiredFields, requiredPersonImportFields, resolvedImportFields, suggestedPersonImportField } from "../../../../lib/import-schema";
import { unassignedClientId, unassignedClientName, unassignedClientNormalizedName } from "../../../../lib/import-owner";
import { importHeaderSignature } from "../../../../lib/import-resume";
import { prospectImportBucket, validProspectImportObjectPath } from "../../../../lib/import-storage.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";

function validDateAdded(value: unknown) {
  const date = String(value ?? "").trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < "1900-01-01") return "";
  const parsed = new Date(`${date}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== date) return "";
  // Browsers submit the user's local calendar day. UTC can still be on the
  // previous day for UTC+ timezones, so allow the next UTC date; the UI itself
  // caps selection at its local today.
  return date <= new Date(Date.now() + 24 * 60 * 60_000).toISOString().slice(0, 10) ? date : "";
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json() as { clientId?: string; clientName?: string; withoutClient?: boolean; listName?: string; dateAdded?: string; fileName?: string; totalRows?: number; headers?: string[]; sourceHeaders?: string[]; fieldMap?: Record<string, string>; dataSource?: string; allowMissingFields?: boolean; background?: boolean; storageObjectPath?: string; fileSizeBytes?: number };
  const supabase = createAdminClient();
  const dataSource = normalizeDataSource(payload.dataSource);
  if (!dataSource) return Response.json({ error: "Choose a data source before importing." }, { status: 400 });
  const dateAdded = validDateAdded(payload.dateAdded);
  if (!dateAdded) return Response.json({ error: "Choose a valid Date added between 1900-01-01 and today." }, { status: 400 });
  const importHeaders = Array.isArray(payload.headers) ? payload.headers.map(String) : [];
  const missingFields = missingRequiredFields(requiredPersonImportFields, resolvedImportFields(importHeaders, payload.fieldMap, suggestedPersonImportField));
  // Missing mandatory columns normally block the import; the UI can override with an
  // explicit warning + confirm, in which case rows import with whatever identity they have.
  if (missingFields.length && payload.allowMissingFields !== true) {
    return Response.json({ error: `Map all required person columns: ${missingFields.join(", ")}.`, missingFields }, { status: 400 });
  }
  let clientId = payload.clientId ?? "";
  if (payload.withoutClient === true) {
    const owner = await supabase.from("clients").upsert({ id: unassignedClientId, name: unassignedClientName, normalized_name: unassignedClientNormalizedName }, { onConflict: "id" }).select("id").single();
    if (owner.error) return Response.json({ error: owner.error.message }, { status: 500 });
    clientId = owner.data.id;
  } else if (!clientId) {
    const clientName = String(payload.clientName ?? "").trim();
    if (!clientName) return Response.json({ error: "Choose or create a client." }, { status: 400 });
    const normalizedName = normalizeText(clientName);
    const existing = await supabase.from("clients").select("id").eq("normalized_name", normalizedName).maybeSingle();
    if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
    clientId = existing.data?.id ?? crypto.randomUUID();
    if (!existing.data) {
      const created = await supabase.from("clients").insert({ id: clientId, name: clientName, normalized_name: normalizedName });
      if (created.error) return Response.json({ error: created.error.message }, { status: 500 });
    }
  }
  const listName = String(payload.listName ?? "").trim();
  if (!listName) return Response.json({ error: "List name is required." }, { status: 400 });
  const listId = crypto.randomUUID();
  const importId = crypto.randomUUID();
  const headers = importHeaders.map((header) => header.trim()).filter(Boolean).slice(0, 500);
  const sourceHeaders = (Array.isArray(payload.sourceHeaders) ? payload.sourceHeaders : importHeaders).map(String).slice(0, 500);
  const totalRows = Number.isSafeInteger(payload.totalRows) && Number(payload.totalRows) >= 0 ? Number(payload.totalRows) : null;
  if (payload.background === true) {
    if (!validProspectImportObjectPath(payload.storageObjectPath)) return Response.json({ error: "Invalid background import object." }, { status: 400 });
    const [folder, objectName] = payload.storageObjectPath.split("/");
    const stored = await supabase.storage.from(prospectImportBucket).list(folder, { search: objectName, limit: 2 });
    if (stored.error) return Response.json({ error: stored.error.message }, { status: 500 });
    if (!stored.data.some((item) => item.name === objectName)) return Response.json({ error: "The uploaded CSV could not be found. Upload it again." }, { status: 409 });
    const active = await supabase.from("imports").select("id").eq("storage_object_path", payload.storageObjectPath).in("status", ["queued", "processing"]).limit(1);
    if (active.error) return Response.json({ error: active.error.message }, { status: 500 });
    if (active.data.length) return Response.json({ error: "This CSV is already being processed." }, { status: 409 });
  }
  const listResult = await supabase.from("lists").insert({ id: listId, client_id: clientId, name: listName, data_source: dataSource, source_file_name: payload.fileName ?? "", uploaded_rows: payload.totalRows ?? 0, field_headers: headers });
  if (listResult.error) return Response.json({ error: listResult.error.message }, { status: 500 });
  const importResult = await supabase.from("imports").insert({
    id: importId, client_id: clientId, list_id: listId, data_source: dataSource,
    file_name: payload.fileName ?? "", total_rows: totalRows, field_headers: headers,
    prospect_date_added: dateAdded,
    field_map: payload.fieldMap ?? {}, header_signature: importHeaderSignature(sourceHeaders),
    status: payload.background === true ? "queued" : "processing",
    ingestion_mode: payload.background === true ? "background" : "browser",
    storage_object_path: payload.background === true ? payload.storageObjectPath : null,
    source_headers: sourceHeaders,
    file_size_bytes: payload.background === true ? Number(payload.fileSizeBytes ?? 0) : null,
  });
  if (importResult.error) {
    await supabase.from("lists").delete().eq("id", listId);
    return Response.json({ error: importResult.error.message }, { status: 500 });
  }
  if (headers.length) {
    const seenAt = new Date().toISOString();
    const fieldResult = await supabase.from("prospect_fields").upsert(headers.map((fieldName) => ({ field_name: fieldName, last_seen_at: seenAt })), { onConflict: "field_name" });
    if (fieldResult.error) {
      await supabase.from("lists").delete().eq("id", listId);
      return Response.json({ error: fieldResult.error.message }, { status: 500 });
    }
  }
  return Response.json({ importId, listId, clientId }, { status: 201 });
}
