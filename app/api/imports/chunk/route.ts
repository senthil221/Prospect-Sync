import { authorizeApi } from "../../../../lib/auth";
import { mapProspect, normalizeText } from "../../../../db/normalize";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { importId, listId, headers, rows, rowOffset, fieldMap } = await request.json() as { importId?: string; listId?: string; headers?: string[]; rows?: string[][]; rowOffset?: number; fieldMap?: Record<string, string> };
  if (!importId || !listId || !headers?.length || !rows?.length) return Response.json({ error: "Invalid import chunk." }, { status: 400 });
  if (rows.length > 250) return Response.json({ error: "Import chunks cannot exceed 250 rows." }, { status: 400 });

  const mapped = rows.map((values, index) => {
    const mappedHeaders = headers.map((header) => String(fieldMap?.[header] || header));
    const prospect = mapProspect(mappedHeaders, values);
    prospect.raw = Object.fromEntries(headers.map((header, valueIndex) => [header, String(values[valueIndex] ?? "").trim()]));
    const companyId = prospect.companyDomain
      ? `domain:${prospect.companyDomain}`
      : prospect.companyName ? `name:${normalizeText(prospect.companyName)}` : "";
    return { ...prospect, companyId, normalizedCompanyName: normalizeText(prospect.companyName), sourceRowNumber: Number(rowOffset ?? 0) + index + 2 };
  });
  const supabase = createAdminClient();
  const requiresV4 = mapped.some((row) => row.keywords.length > 0
    || row.companyEmployeeCountMin !== null || row.companyEmployeeCountMax !== null
    || row.companyLocation || row.companyCity || row.companyState || row.companyCountry);
  let result = await supabase.rpc("import_prospect_batch_v4", {
    p_import_id: importId,
    p_list_id: listId,
    p_rows: mapped,
  });
  if (result.error?.code === "PGRST202" || result.error?.code === "42883") {
    if (requiresV4) return Response.json({ error: "Apply the latest database migration before importing Keywords, employee counts, or company locations." }, { status: 503 });
    result = await supabase.rpc("import_prospect_batch_v3", { p_import_id: importId, p_list_id: listId, p_rows: mapped });
  }
  if (result.error?.code === "PGRST202" || result.error?.code === "42883") {
    result = await supabase.rpc("import_prospect_batch_v2", { p_import_id: importId, p_list_id: listId, p_rows: mapped });
  }
  if (result.error) return Response.json({ error: result.error.message }, { status: 500 });
  const summary = Array.isArray(result.data) ? result.data[0] : result.data;
  return Response.json({
    processed: Number(summary?.processed ?? rows.length),
    uniqueAdded: Number(summary?.unique_added ?? 0),
    duplicatesLinked: Number(summary?.duplicates_linked ?? 0),
    skipped: Number(summary?.skipped ?? 0),
  });
}
