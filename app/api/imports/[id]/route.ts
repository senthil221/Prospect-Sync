import { authorizeApi } from "../../../../lib/auth";
import { reindexProspects } from "../../../../lib/reindex";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  const prospectImport = await supabase
    .from("imports")
    .select("id,list_id,file_name,data_source,status,committed_row_offset,total_rows,field_headers,field_map,header_signature")
    .eq("id", id)
    .maybeSingle();
  if (prospectImport.error) return Response.json({ error: prospectImport.error.message }, { status: 500 });

  let kind: "prospects" | "companies" = "prospects";
  let row = prospectImport.data;
  if (!row) {
    kind = "companies";
    const companyImport = await supabase
      .from("company_imports")
      .select("id,file_name,data_source,status,committed_row_offset,total_rows,field_headers,field_map,header_signature")
      .eq("id", id)
      .maybeSingle();
    if (companyImport.error) return Response.json({ error: companyImport.error.message }, { status: 500 });
    row = companyImport.data ? { ...companyImport.data, list_id: null } : null;
  }
  if (!row) return Response.json({ error: "Import not found." }, { status: 404 });

  return Response.json({
    id: row.id,
    kind,
    listId: row.list_id,
    fileName: row.file_name,
    dataSource: row.data_source,
    status: row.status,
    committedRowOffset: Number(row.committed_row_offset ?? 0),
    totalRows: row.total_rows === null ? null : Number(row.total_rows),
    headers: Array.isArray(row.field_headers) ? row.field_headers.map(String) : [],
    fieldMap: row.field_map && typeof row.field_map === "object" ? row.field_map : {},
    headerSignature: String(row.header_signature ?? ""),
  }, { headers: { "Cache-Control": "no-store" } });
}

export async function DELETE(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();
  const payload = await request.json().catch(() => null) as { cancel?: unknown; kind?: unknown } | null;

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

    const existing = await supabase.from("imports").select("id,status").eq("id", id).maybeSingle();
    if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
    if (!existing.data) return Response.json({ error: "Import not found." }, { status: 404 });
    if (existing.data.status !== "processing") return Response.json({ error: "Only unfinished imports can be cancelled." }, { status: 409 });
  }

  const affected = await supabase.from("list_rows").select("prospect_id").eq("import_id", id);
  // Client-side deletes never touch the People/Company databases: only the
  // import and its membership links are removed.
  const { data, error } = await supabase.rpc("delete_import_with_cleanup", {
    p_import_id: id,
    p_delete_orphans: false,
  });
  if (error) return Response.json({ error: error.message }, { status: error.code === "P0002" ? 404 : 500 });
  await reindexProspects(supabase, (affected.data ?? []).map((row) => row.prospect_id));
  return Response.json({ result: data });
}
