import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";
import { observed } from "../../../../lib/observability";
import { attachmentDisposition } from "../../../../lib/csv";
import { isKeywordKind, keywordFileNames, keywordListCsv } from "../../../../lib/title-keywords";

// The job title keyword lists the classifier reads.
//
// GET  ?kind=seniority|department|top_management_include|top_management_exclude
//      the list as a CSV, in the layout of its file in data/.
// POST {kind, rows, apply}  check an edited list (apply false: what would be
//      added, changed, and which rows are wrong) or write it (apply true). Adds
//      and updates only; a keyword left out of the upload is kept. Re-run the
//      classifier afterwards to reclassify people.

const missingFunctionCodes = new Set(["PGRST202", "42883"]);
const maxRows = 20000;

function migrationRequired() {
  return Response.json({ error: "Apply the latest database migration to edit the keyword lists here." }, { status: 503 });
}

async function handleGET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const kind = new URL(request.url).searchParams.get("kind");
  if (!isKeywordKind(kind)) return Response.json({ error: "Choose a keyword list." }, { status: 400 });

  const { data, error } = await createAdminClient().rpc("title_keywords_export_v1", { p_kind: kind });
  if (error) {
    if (missingFunctionCodes.has(error.code ?? "")) return migrationRequired();
    return Response.json({ error: error.message }, { status: 500 });
  }
  return new Response(keywordListCsv(kind, (data ?? []) as Array<Record<string, string>>), { headers: {
    "Content-Type": "text/csv; charset=utf-8",
    "Content-Disposition": attachmentDisposition(`${keywordFileNames[kind]} - ${new Date().toISOString().slice(0, 10)}.csv`),
    "Cache-Control": "no-store",
  } });
}

async function handlePOST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { kind?: unknown; rows?: unknown; apply?: unknown } | null;
  if (!isKeywordKind(payload?.kind)) return Response.json({ error: "Choose a keyword list." }, { status: 400 });
  if (!Array.isArray(payload.rows) || !payload.rows.length) return Response.json({ error: "The file has no keyword rows." }, { status: 400 });
  if (payload.rows.length > maxRows) return Response.json({ error: `A keyword list holds at most ${maxRows.toLocaleString("en-US")} rows.` }, { status: 400 });

  const { data, error } = await createAdminClient().rpc("apply_title_keywords_v1", {
    p_kind: payload.kind,
    p_rows: payload.rows,
    p_dry_run: payload.apply !== true,
  });
  if (error) {
    if (missingFunctionCodes.has(error.code ?? "")) return migrationRequired();
    return Response.json({ error: error.message }, { status: error.code === "22023" ? 400 : 500 });
  }
  return Response.json(data, { headers: { "Cache-Control": "no-store" } });
}

export const GET = observed("/api/prospects/title-keywords", handleGET);
export const POST = observed("/api/prospects/title-keywords", handlePOST);
