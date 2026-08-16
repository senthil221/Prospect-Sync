import { normalizeDomain, normalizeText, parseEmployeeCount } from "../../../../db/normalize";
import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

type CompanyImportRow = { name?: unknown; website?: unknown; employeeCount?: unknown; industry?: unknown; city?: unknown; state?: unknown; country?: unknown; keywords?: unknown; shortDescription?: unknown; foundedYear?: unknown; technologies?: unknown; totalFunding?: unknown; raw?: unknown; sourceRowNumber?: unknown };

function listValue(value: unknown) {
  return [...new Set(String(value ?? "").split(/[,;|]/).map((item) => item.trim()).filter(Boolean))].slice(0, 100);
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { importId?: unknown; rows?: CompanyImportRow[]; rowOffset?: unknown } | null;
  const importId = String(payload?.importId ?? "").trim();
  if (!importId || !Array.isArray(payload?.rows) || !payload.rows.length) return Response.json({ error: "Invalid company import chunk." }, { status: 400 });
  if (payload.rows.length > 250) return Response.json({ error: "Company import chunks cannot exceed 250 rows." }, { status: 400 });
  const rowOffset = Number(payload.rowOffset);
  if (!Number.isSafeInteger(rowOffset) || rowOffset < 0) return Response.json({ error: "A non-negative rowOffset is required." }, { status: 400 });
  const rows = payload.rows.map((row, index) => {
    const name = String(row.name ?? "").trim().slice(0, 300);
    const domain = normalizeDomain(String(row.website ?? ""));
    const employeeCount = parseEmployeeCount(String(row.employeeCount ?? ""));
    const foundedYear = Number(String(row.foundedYear ?? "").match(/\d{4}/)?.[0] ?? 0);
    return {
      name,
      normalizedName: normalizeText(name),
      domain,
      normalizedDomain: domain,
      employeeCountMin: employeeCount.min,
      employeeCountMax: employeeCount.max,
      industry: String(row.industry ?? "").trim().slice(0, 300),
      city: String(row.city ?? "").trim().slice(0, 200),
      state: String(row.state ?? "").trim().slice(0, 200),
      country: String(row.country ?? "").trim().slice(0, 200),
      keywords: listValue(row.keywords),
      shortDescription: String(row.shortDescription ?? "").trim().slice(0, 5000),
      foundedYear: foundedYear >= 1000 && foundedYear <= new Date().getFullYear() ? foundedYear : null,
      technologies: listValue(row.technologies),
      totalFunding: String(row.totalFunding ?? "").trim().slice(0, 200),
      raw: row.raw && typeof row.raw === "object" ? row.raw : {},
      sourceRowNumber: Math.max(2, Math.round(Number(row.sourceRowNumber ?? rowOffset + index + 2))),
    };
  });
  const { data, error } = await createAdminClient().rpc("import_company_batch_v2", { p_import_id: importId, p_rows: rows, p_row_offset: rowOffset });
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
    committedRowOffset: rowOffset + rows.length,
  });
}
