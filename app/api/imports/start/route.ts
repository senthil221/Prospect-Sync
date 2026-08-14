import { authorizeApi } from "../../../../lib/auth";
import { normalizeText } from "../../../../db/normalize";
import { normalizeDataSource } from "../../../../lib/data-source";
import { missingRequiredFields, requiredPersonImportFields, resolvedImportFields, suggestedPersonImportField } from "../../../../lib/import-schema";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json() as { clientId?: string; clientName?: string; listName?: string; fileName?: string; totalRows?: number; headers?: string[]; fieldMap?: Record<string, string>; dataSource?: string; allowMissingFields?: boolean };
  const supabase = createAdminClient();
  const dataSource = normalizeDataSource(payload.dataSource);
  if (!dataSource) return Response.json({ error: "Choose a data source before importing." }, { status: 400 });
  const importHeaders = Array.isArray(payload.headers) ? payload.headers.map(String) : [];
  const missingFields = missingRequiredFields(requiredPersonImportFields, resolvedImportFields(importHeaders, payload.fieldMap, suggestedPersonImportField));
  // Missing mandatory columns normally block the import; the UI can override with an
  // explicit warning + confirm, in which case rows import with whatever identity they have.
  if (missingFields.length && payload.allowMissingFields !== true) {
    return Response.json({ error: `Map all required person columns: ${missingFields.join(", ")}.`, missingFields }, { status: 400 });
  }
  let clientId = payload.clientId ?? "";
  if (!clientId) {
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
  const listResult = await supabase.from("lists").insert({ id: listId, client_id: clientId, name: listName, data_source: dataSource, source_file_name: payload.fileName ?? "", uploaded_rows: payload.totalRows ?? 0, field_headers: headers });
  if (listResult.error) return Response.json({ error: listResult.error.message }, { status: 500 });
  const importResult = await supabase.from("imports").insert({ id: importId, client_id: clientId, list_id: listId, data_source: dataSource, file_name: payload.fileName ?? "", total_rows: payload.totalRows ?? 0, field_headers: headers });
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
