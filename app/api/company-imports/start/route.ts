import { authorizeApi } from "../../../../lib/auth";
import { normalizeDataSource } from "../../../../lib/data-source";
import { missingRequiredFields, requiredCompanyImportFields, resolvedImportFields, suggestedCompanyImportField } from "../../../../lib/import-schema";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { fileName?: unknown; totalRows?: unknown; dataSource?: unknown; headers?: unknown; fieldMap?: unknown } | null;
  if (!payload) return Response.json({ error: "Invalid company import." }, { status: 400 });
  const dataSource = normalizeDataSource(payload.dataSource);
  if (!dataSource) return Response.json({ error: "Choose a data source before importing." }, { status: 400 });
  const headers = Array.isArray(payload.headers) ? payload.headers.map(String).slice(0, 500) : [];
  const fieldMap = payload.fieldMap && typeof payload.fieldMap === "object" ? payload.fieldMap as Record<string, string> : undefined;
  const missingFields = missingRequiredFields(requiredCompanyImportFields, resolvedImportFields(headers, fieldMap, suggestedCompanyImportField));
  if (missingFields.length) return Response.json({ error: `Map all required company columns: ${missingFields.join(", ")}.` }, { status: 400 });
  const totalRows = Math.max(0, Math.min(100_000, Math.round(Number(payload.totalRows ?? 0))));
  if (!totalRows) return Response.json({ error: "The company CSV has no rows." }, { status: 400 });
  const id = crypto.randomUUID();
  const { error } = await createAdminClient().from("company_imports").insert({
    id,
    file_name: String(payload.fileName ?? "").trim().slice(0, 240),
    data_source: dataSource,
    total_rows: totalRows,
  });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  return Response.json({ importId: id }, { status: 201 });
}
