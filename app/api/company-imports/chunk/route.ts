import { normalizeDomain, normalizeText } from "../../../../db/normalize";
import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

type CompanyImportRow = { name?: unknown; website?: unknown; raw?: unknown; sourceRowNumber?: unknown };

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { importId?: unknown; rows?: CompanyImportRow[] } | null;
  const importId = String(payload?.importId ?? "").trim();
  if (!importId || !Array.isArray(payload?.rows) || !payload.rows.length) return Response.json({ error: "Invalid company import chunk." }, { status: 400 });
  if (payload.rows.length > 250) return Response.json({ error: "Company import chunks cannot exceed 250 rows." }, { status: 400 });
  const rows = payload.rows.map((row, index) => {
    const name = String(row.name ?? "").trim().slice(0, 300);
    const domain = normalizeDomain(String(row.website ?? ""));
    return {
      name,
      normalizedName: normalizeText(name),
      domain,
      normalizedDomain: domain,
      raw: row.raw && typeof row.raw === "object" ? row.raw : {},
      sourceRowNumber: Math.max(2, Math.round(Number(row.sourceRowNumber ?? index + 2))),
    };
  });
  const { data, error } = await createAdminClient().rpc("import_company_batch_v1", { p_import_id: importId, p_rows: rows });
  if (error) {
    const missing = error.code === "PGRST202" || error.code === "42883";
    return Response.json({ error: missing ? "Apply the latest database migration to enable company imports." : error.message }, { status: missing ? 503 : 500 });
  }
  const summary = Array.isArray(data) ? data[0] : data;
  return Response.json({
    processed: Number(summary?.processed ?? rows.length),
    added: Number(summary?.added ?? 0),
    updated: Number(summary?.updated ?? 0),
    skipped: Number(summary?.skipped ?? 0),
  });
}
