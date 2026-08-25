import { authorizeApi } from "../../../../lib/auth";
import { deleteAndReindex, queuedNotice } from "../../../../lib/delete-cleanup.ts";
import { createAdminClient } from "../../../../lib/supabase/admin";

type ImportDetailRow = {
  id: string; list_id: string | null; file_name: string; data_source: string; status: string;
  ingestion_mode?: string; committed_row_offset: number; total_rows: number | null;
  processed_rows?: number; unique_added?: number; duplicates_linked?: number;
  processed_bytes?: number; file_size_bytes?: number | null; last_error?: string | null;
  field_headers: unknown; field_map: unknown; header_signature: string;
};

export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  const prospectImport = await supabase
    .from("imports")
    .select("id,list_id,file_name,data_source,status,ingestion_mode,committed_row_offset,total_rows,processed_rows,unique_added,duplicates_linked,processed_bytes,file_size_bytes,last_error,field_headers,field_map,header_signature")
    .eq("id", id)
    .maybeSingle();
  if (prospectImport.error) return Response.json({ error: prospectImport.error.message }, { status: 500 });

  let kind: "prospects" | "companies" = "prospects";
  let row = prospectImport.data as ImportDetailRow | null;
  if (!row) {
    kind = "companies";
    const companyImport = await supabase
      .from("company_imports")
      .select("id,file_name,data_source,status,committed_row_offset,total_rows,field_headers,field_map,header_signature,merge_mode")
      .eq("id", id)
      .maybeSingle();
    if (companyImport.error) return Response.json({ error: companyImport.error.message }, { status: 500 });
    row = companyImport.data ? { ...companyImport.data, list_id: null } as ImportDetailRow : null;
  }
  if (!row) return Response.json({ error: "Import not found." }, { status: 404 });

  return Response.json({
    id: row.id,
    kind,
    listId: row.list_id,
    fileName: row.file_name,
    dataSource: row.data_source,
    status: row.status,
    ingestionMode: row.ingestion_mode ?? "browser",
    committedRowOffset: Number(row.committed_row_offset ?? 0),
    totalRows: row.total_rows === null ? null : Number(row.total_rows),
    processedRows: Number(row.processed_rows ?? row.committed_row_offset ?? 0),
    uniqueAdded: Number(row.unique_added ?? 0),
    duplicatesLinked: Number(row.duplicates_linked ?? 0),
    processedBytes: Number(row.processed_bytes ?? 0),
    fileSizeBytes: row.file_size_bytes !== null && row.file_size_bytes !== undefined ? Number(row.file_size_bytes) : null,
    lastError: String(row.last_error ?? ""),
    headers: Array.isArray(row.field_headers) ? row.field_headers.map(String) : [],
    fieldMap: row.field_map && typeof row.field_map === "object" ? row.field_map : {},
    headerSignature: String(row.header_signature ?? ""),
    // Resuming must continue with the mode the import started under; changing it
    // halfway would apply two different rules to one file.
    mergeMode: kind === "companies" ? String((row as { merge_mode?: unknown }).merge_mode ?? "enrich") : null,
  }, { headers: { "Cache-Control": "no-store" } });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  const payload = await request.json().catch(() => null) as { cancel?: unknown; kind?: unknown } | null;
  let backgroundObjectPath: string | null = null;

  if (payload?.cancel === true) {
    if (payload.kind !== "prospects" && payload.kind !== "companies") {
      return Response.json({ error: "Invalid import type." }, { status: 400 });
    }

    if (payload.kind === "companies") {
      const existing = await supabase.from("company_imports").select("id,file_name,status").eq("id", id).maybeSingle();
      if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
      if (!existing.data) return Response.json({ error: "Import not found." }, { status: 404 });
      if (existing.data.status !== "processing") return Response.json({ error: "Only unfinished imports can be cancelled." }, { status: 409 });

      const cancelled = await supabase.from("company_imports").delete().eq("id", id).eq("status", "processing").select("id").maybeSingle();
      if (cancelled.error) return Response.json({ error: cancelled.error.message }, { status: 500 });
      if (!cancelled.data) return Response.json({ error: "This import is no longer unfinished." }, { status: 409 });
      return Response.json({ result: { kind: "company_import", name: existing.data.file_name, importsDeleted: 1 } });
    }

    const existing = await supabase.from("imports").select("id,status,ingestion_mode,storage_object_path").eq("id", id).maybeSingle();
    if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
    if (!existing.data) return Response.json({ error: "Import not found." }, { status: 404 });
    const cancellable = existing.data.ingestion_mode === "background"
      ? ["queued", "processing", "failed"].includes(existing.data.status)
      : existing.data.status === "processing";
    if (!cancellable) return Response.json({ error: "Only unfinished imports can be cancelled." }, { status: 409 });
    if (existing.data.ingestion_mode === "background") backgroundObjectPath = existing.data.storage_object_path;
  }

  // Client-side deletes never touch the People/Company databases: only the
  // import and its membership links are removed. The affected prospects are
  // re-indexed inside the same call, in bounded batches.
  const { data, error } = await deleteAndReindex(supabase, "delete_import_and_reindex_v1", "delete_import_with_cleanup", { p_import_id: id });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  if (backgroundObjectPath) await supabase.storage.from("prospect-imports").remove([backgroundObjectPath]);
  return Response.json({ result: data, notice: queuedNotice(data) });
}

export async function PATCH(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  const existing = await supabase.from("imports").select("status,ingestion_mode,storage_object_path").eq("id", id).maybeSingle();
  if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
  if (!existing.data) return Response.json({ error: "Import not found." }, { status: 404 });
  if (existing.data.ingestion_mode !== "background" || existing.data.status !== "failed") {
    return Response.json({ error: "Only a failed background import can be retried." }, { status: 409 });
  }
  const path = String(existing.data.storage_object_path ?? "");
  const [folder, name] = path.split("/");
  const stored = await supabase.storage.from("prospect-imports").list(folder, { search: name, limit: 2 });
  if (stored.error) return Response.json({ error: stored.error.message }, { status: 500 });
  if (!stored.data.some((item) => item.name === name)) return Response.json({ error: "The original CSV is no longer available. Start a new import." }, { status: 409 });
  const retried = await supabase.from("imports").update({ status: "queued", attempt_count: 0, next_attempt_at: new Date().toISOString(), last_error: null, worker_id: null, lease_expires_at: null }).eq("id", id).eq("status", "failed");
  if (retried.error) return Response.json({ error: retried.error.message }, { status: 500 });
  return Response.json({ status: "queued" });
}
