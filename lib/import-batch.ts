import { mapProspect, normalizeText } from "../db/normalize.ts";
import { skipImportField } from "./import-schema.ts";
import { createAdminClient } from "./supabase/admin.ts";

export type ProspectChunkPayload = {
  importId?: string;
  listId?: string;
  headers?: string[];
  rows?: string[][];
  rowOffset?: number;
  fieldMap?: Record<string, string>;
};

export async function importProspectChunk(payload: ProspectChunkPayload) {
  const { importId, listId, headers, rows, rowOffset, fieldMap } = payload;
  if (!importId || !listId || !headers?.length || !rows?.length) {
    return { response: Response.json({ error: "Invalid import chunk." }, { status: 400 }) };
  }
  if (rows.length > 250) {
    return { response: Response.json({ error: "Import chunks cannot exceed 250 rows." }, { status: 400 }) };
  }
  const normalizedRowOffset = Number(rowOffset);
  if (!Number.isSafeInteger(normalizedRowOffset) || normalizedRowOffset < 0) {
    return { response: Response.json({ error: "A non-negative rowOffset is required." }, { status: 400 }) };
  }

  const keptColumns = headers.map((header, column) => ({ header: String(header), column }))
    .filter(({ header }) => fieldMap?.[header] !== skipImportField);
  const keptHeaders = keptColumns.map(({ header }) => header);
  if (!keptHeaders.length) return { response: Response.json({ error: "Every import column was skipped." }, { status: 400 }) };
  const mappedHeaders = keptHeaders.map((header) => String(fieldMap?.[header] || header));
  const mapped = rows.map((sourceValues, index) => {
    const values = keptColumns.map(({ column }) => String(sourceValues[column] ?? ""));
    const prospect = mapProspect(mappedHeaders, values);
    prospect.raw = Object.fromEntries(keptHeaders.map((header, valueIndex) => [header, String(values[valueIndex] ?? "").trim()]));
    const companyId = prospect.companyDomain
      ? `domain:${prospect.companyDomain}`
      : prospect.companyName ? `name:${normalizeText(prospect.companyName)}` : "";
    return { ...prospect, companyId, normalizedCompanyName: normalizeText(prospect.companyName), sourceRowNumber: normalizedRowOffset + index + 2 };
  });

  const supabase = createAdminClient();
  // This path goes through PostgREST, so import_prospect_batch_v5's declared
  // `SET statement_timeout = '15s'` is genuinely in force here - measured on
  // production, a function declaring 10s was cancelled at 10.004s over HTTP and
  // ignored entirely on a direct connection. The 250-row chunk cap above is
  // what keeps a browser import inside that 15s; the import worker sends 1,000
  // rows down a direct connection and sets its own bound instead.
  const result = await supabase.rpc("import_prospect_batch_v5", {
    p_import_id: importId,
    p_list_id: listId,
    p_rows: mapped,
    p_row_offset: normalizedRowOffset,
  });
  if (result.error) return { response: Response.json({ error: result.error.message }, { status: result.error.code === "P0002" ? 409 : 500 }) };
  const summary = Array.isArray(result.data) ? result.data[0] : result.data;
  return { data: {
    processed: Number(summary?.processed ?? rows.length),
    uniqueAdded: Number(summary?.unique_added ?? 0),
    duplicatesLinked: Number(summary?.duplicates_linked ?? 0),
    skipped: Number(summary?.skipped ?? 0),
    committedRowOffset: normalizedRowOffset + rows.length,
  } };
}
