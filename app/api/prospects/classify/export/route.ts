import { authorizeApi } from "../../../../../lib/auth";
import { createAdminClient } from "../../../../../lib/supabase/admin";
import { observed } from "../../../../../lib/observability";
import { attachmentDisposition, csvDocument } from "../../../../../lib/csv";

// The whole Undefined log as a CSV - every unresolved title, not the top 200 the
// Job titles tab shows - so new keywords can be worked out offline and sent back.

const missingFunctionCodes = new Set(["PGRST202", "42883"]);
const missingLabels: Record<string, string> = { any: "missing either", both: "missing both", seniority: "missing seniority", department: "missing department" };

async function handleGET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const requested = String(new URL(request.url).searchParams.get("missing") ?? "any");
  const missing = requested in missingLabels ? requested : "any";

  const { data, error } = await createAdminClient().rpc("title_classification_gaps_export_v1", { p_missing: missing });
  if (error) {
    if (missingFunctionCodes.has(error.code ?? "")) return Response.json({ error: "Apply the latest database migration to export the undefined titles." }, { status: 503 });
    return Response.json({ error: error.message }, { status: 500 });
  }

  const rows = ((data ?? []) as Array<[string, string, number, string, string, boolean, boolean]>).map(
    ([title, normalized, people, seniority, department, missingSeniority, missingDepartment]) =>
      [title, normalized, people, seniority, department, missingSeniority && missingDepartment ? "Seniority + department" : missingSeniority ? "Seniority" : "Department"],
  );
  const csv = csvDocument(["Job title", "Normalized title", "People", "Seniority", "Department", "Missing"], rows);
  return new Response(csv, { headers: {
    "Content-Type": "text/csv; charset=utf-8",
    "Content-Disposition": attachmentDisposition(`Undefined job titles - ${missingLabels[missing]} - ${new Date().toISOString().slice(0, 10)}.csv`),
    "Cache-Control": "no-store",
  } });
}

export const GET = observed("/api/prospects/classify/export", handleGET);
