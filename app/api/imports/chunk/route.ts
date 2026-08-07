import { authorizeApi } from "../../../../lib/auth";
import { mapProspect, normalizeText } from "../../../../db/normalize";
import { createAdminClient } from "../../../../lib/supabase/admin";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { importId, listId, headers, rows, rowOffset } = await request.json() as { importId?: string; listId?: string; headers?: string[]; rows?: string[][]; rowOffset?: number };
  if (!importId || !listId || !headers?.length || !rows?.length) return Response.json({ error: "Invalid import chunk." }, { status: 400 });
  if (rows.length > 250) return Response.json({ error: "Import chunks cannot exceed 250 rows." }, { status: 400 });

  const mapped = rows.map((values, index) => {
    const prospect = mapProspect(headers, values);
    const companyId = prospect.companyDomain
      ? `domain:${prospect.companyDomain}`
      : prospect.companyName ? `name:${normalizeText(prospect.companyName)}` : "";
    return { ...prospect, companyId, normalizedCompanyName: normalizeText(prospect.companyName), sourceRowNumber: Number(rowOffset ?? 0) + index + 2 };
  });
  const { data, error } = await createAdminClient().rpc("import_prospect_batch_v2", {
    p_import_id: importId,
    p_list_id: listId,
    p_rows: mapped,
  });
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const summary = Array.isArray(data) ? data[0] : data;
  return Response.json({
    processed: Number(summary?.processed ?? rows.length),
    uniqueAdded: Number(summary?.unique_added ?? 0),
    duplicatesLinked: Number(summary?.duplicates_linked ?? 0),
    skipped: Number(summary?.skipped ?? 0),
  });
}
