import { authorizeApi } from "../../../lib/auth";
import { createAdminClient } from "../../../lib/supabase/admin";

type InterruptedImportRow = {
  id: string;
  file_name: string;
  data_source: string;
  status: string;
  committed_row_offset: number;
  total_rows: number | null;
  created_at: string;
};

export async function GET() {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const supabase = createAdminClient();
  const [prospectImports, companyImports] = await Promise.all([
    supabase.from("imports").select("id,file_name,data_source,status,committed_row_offset,total_rows,created_at").eq("status", "processing").order("created_at", { ascending: false }).limit(50),
    supabase.from("company_imports").select("id,file_name,data_source,status,committed_row_offset,total_rows,created_at").eq("status", "processing").order("created_at", { ascending: false }).limit(50),
  ]);
  const error = prospectImports.error ?? companyImports.error;
  if (error) {
    const migrationMissing = error.code === "42703" || error.code === "PGRST204";
    return migrationMissing
      ? Response.json({ imports: [] }, { headers: { "Cache-Control": "no-store" } })
      : Response.json({ error: error.message }, { status: 500 });
  }

  const resumable = (rows: InterruptedImportRow[], kind: "prospects" | "companies") => rows
    .filter((row) => row.total_rows !== null && Number(row.committed_row_offset) < Number(row.total_rows))
    .map((row) => ({
      id: row.id,
      kind,
      fileName: row.file_name,
      dataSource: row.data_source,
      status: row.status,
      committedRowOffset: Number(row.committed_row_offset),
      totalRows: Number(row.total_rows),
      resumeFromRow: Number(row.committed_row_offset) + 1,
      createdAt: row.created_at,
    }));
  const imports = [
    ...resumable((prospectImports.data ?? []) as InterruptedImportRow[], "prospects"),
    ...resumable((companyImports.data ?? []) as InterruptedImportRow[], "companies"),
  ].sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  return Response.json({ imports }, { headers: { "Cache-Control": "no-store" } });
}
