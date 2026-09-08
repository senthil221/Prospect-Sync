import { normalizeDomain, normalizeText, parseEmployeeCount } from "../../../../db/normalize";
import { authorizeApi } from "../../../../lib/auth";
import { companyImportFields } from "../../../../lib/import-schema";
import { createAdminClient } from "../../../../lib/supabase/admin";

type CompanyImportRow = { name?: unknown; website?: unknown; employeeCount?: unknown; industry?: unknown; city?: unknown; state?: unknown; country?: unknown; keywords?: unknown; shortDescription?: unknown; foundedYear?: unknown; technologies?: unknown; totalFunding?: unknown; raw?: unknown; sourceRowNumber?: unknown };
type ImportSummary = { processed: number; added: number; updated: number; skipped: number };

function listValue(value: unknown) {
  return [...new Set(String(value ?? "").split(/[,;|]/).map((item) => item.trim()).filter(Boolean))].slice(0, 100);
}

const allowedCompanyRawFields = new Set<string>(companyImportFields);

function fixedCompanyRaw(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value as Record<string, unknown>)
    .filter(([field]) => allowedCompanyRawFields.has(field))
    .map(([field, item]) => [field, String(item ?? "").trim()]));
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
    const city = String(row.city ?? "").trim().slice(0, 200);
    const state = String(row.state ?? "").trim().slice(0, 200);
    const country = String(row.country ?? "").trim().slice(0, 200);
    return {
      name,
      normalizedName: normalizeText(name),
      domain,
      normalizedDomain: domain,
      employeeCountMin: employeeCount.min,
      employeeCountMax: employeeCount.max,
      industry: String(row.industry ?? "").trim().slice(0, 300),
      location: [city, state, country].filter(Boolean).join(", ").slice(0, 500),
      city,
      state,
      country,
      keywords: listValue(row.keywords),
      shortDescription: String(row.shortDescription ?? "").trim().slice(0, 5000),
      foundedYear: foundedYear >= 1000 && foundedYear <= new Date().getFullYear() ? foundedYear : null,
      technologies: listValue(row.technologies),
      totalFunding: String(row.totalFunding ?? "").trim().slice(0, 200),
      raw: fixedCompanyRaw(row.raw),
      sourceRowNumber: Math.max(2, Math.round(Number(row.sourceRowNumber ?? rowOffset + index + 2))),
    };
  });
  const rejected = rows.filter((row) => !row.name && !row.domain);
  if (rejected.length) return Response.json({
    error: `${rejected.length} company row${rejected.length === 1 ? " has" : "s have"} neither a company name nor website.`,
    rejectedRows: rejected.slice(0, 20).map((row) => row.sourceRowNumber),
    rejectedCount: rejected.length,
  }, { status: 422 });
  const supabase = createAdminClient();
  const isMissing = (candidate: { code?: string } | null) => candidate?.code === "PGRST202" || candidate?.code === "42883";
  const isTimeout = (candidate: { code?: string; message?: string } | null) => candidate?.code === "57014" || /statement timeout/i.test(candidate?.message ?? "");

  async function importBatch(batch: typeof rows, offset: number): Promise<ImportSummary> {
    const args = { p_import_id: importId, p_rows: batch, p_row_offset: offset };
    let { data, error } = await supabase.rpc("import_company_batch_v3", args);
    if (isMissing(error)) ({ data, error } = await supabase.rpc("import_company_batch_v2", args));
    if (error && isTimeout(error) && batch.length > 1) {
      const midpoint = Math.ceil(batch.length / 2);
      const left = await importBatch(batch.slice(0, midpoint), offset);
      const right = await importBatch(batch.slice(midpoint), offset + midpoint);
      return {
        processed: left.processed + right.processed,
        added: left.added + right.added,
        updated: left.updated + right.updated,
        skipped: left.skipped + right.skipped,
      };
    }
    if (error) {
      throw Object.assign(new Error(error.message), { code: error.code });
    }
    const summary = Array.isArray(data) ? data[0] : data;
    return {
      processed: Number(summary?.processed ?? batch.length),
      added: Number(summary?.added ?? 0),
      updated: Number(summary?.updated ?? 0),
      skipped: Number(summary?.skipped ?? 0),
    };
  }

  let summary: ImportSummary;
  try {
    summary = await importBatch(rows, rowOffset);
  } catch (caught) {
    const error = caught as Error & { code?: string };
    const missing = isMissing(error);
    return Response.json({ error: missing ? "Apply the latest database migration to enable company imports." : error.message }, { status: missing ? 503 : 500 });
  }
  return Response.json({
    processed: summary.processed,
    added: summary.added,
    updated: summary.updated,
    skipped: summary.skipped,
    committedRowOffset: rowOffset + rows.length,
  });
}
