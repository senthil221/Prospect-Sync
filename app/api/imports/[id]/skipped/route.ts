import { authorizeApi } from "../../../../../lib/auth";
import { csvDocument } from "../../../../../lib/csv";
import { createAdminClient } from "../../../../../lib/supabase/admin";

// The completion screen's "Kept without a People DB link" count has never had
// anywhere to look further - the rows themselves only ever lived in list_rows
// (prospect_id null), invisible to the List workspace, which only shows rows
// that resolved to a prospect. This is the one place that count can be turned
// into something a person can act on: the exact source rows, and their
// original row numbers, so they can be found again in the file that made them.
export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const supabase = createAdminClient();

  const prospectImport = await supabase.from("imports").select("id,file_name").eq("id", id).maybeSingle();
  if (prospectImport.error) return Response.json({ error: prospectImport.error.message }, { status: 500 });
  if (!prospectImport.data) return Response.json({ error: "Import not found." }, { status: 404 });

  const { data: rows, error } = await supabase
    .from("list_rows")
    .select("source_row_number,raw_data")
    .eq("import_id", id)
    .is("prospect_id", null)
    .order("source_row_number", { ascending: true })
    .limit(200_000);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  // Every row in one import shares the same field mapping, so raw_data carries
  // the same keys throughout - collecting them across all rows (rather than
  // just the first) only guards against an import whose mapping changed
  // mid-resume.
  const fieldOrder: string[] = [];
  const seenFields = new Set<string>();
  for (const row of rows ?? []) {
    const raw = row.raw_data && typeof row.raw_data === "object" ? row.raw_data as Record<string, unknown> : {};
    for (const field of Object.keys(raw)) {
      if (!seenFields.has(field)) { seenFields.add(field); fieldOrder.push(field); }
    }
  }

  const headers = ["Row #", ...fieldOrder];
  const body = (rows ?? []).map((row) => {
    const raw = row.raw_data && typeof row.raw_data === "object" ? row.raw_data as Record<string, unknown> : {};
    return [row.source_row_number, ...fieldOrder.map((field) => String(raw[field] ?? ""))];
  });

  const fileBaseName = String(prospectImport.data.file_name ?? "import").replace(/\.[^.]+$/, "").replace(/[^a-zA-Z0-9._-]+/g, "-") || "import";
  return new Response(csvDocument(headers, body), {
    status: 200,
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${fileBaseName}-skipped-rows.csv"`,
      "Cache-Control": "no-store",
    },
  });
}
