import { authorizeApi } from "../../../../lib/auth";
import { createAdminClient } from "../../../../lib/supabase/admin";

// Job title classifier maintenance.
//
// GET  -- the Undefined log: titles the keyword lists could not fully resolve,
//         ranked by how many people each fix would cover. This is the list to work
//         from when extending data/seniority_map.csv and data/department_map.csv.
// POST -- re-run the classifier over prospects that were never classified, or were
//         classified against an older version of the keyword lists.
//
// Classification happens automatically on every write, so POST is only needed after
// the keyword lists change (or for the initial backfill of rows imported before the
// classifier existed).

const missingFunctionCodes = new Set(["PGRST202", "42883"]);
const batchSize = 2000;
// One checkpoint per request keeps each HTTP run bounded. The client or the
// maintenance job repeats it until the authoritative remaining count is zero.
const maxBatchesPerRequest = 1;

function isMissingFunction(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && missingFunctionCodes.has(error.code));
}

function migrationRequired() {
  return Response.json({ error: "Apply the latest database migration to enable the job title classifier." }, { status: 503 });
}

export async function GET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const limit = Math.max(1, Math.min(2000, Math.round(Number(url.searchParams.get("limit") ?? 200))));
  const requested = String(url.searchParams.get("missing") ?? "any");
  const missing = ["any", "both", "seniority", "department"].includes(requested) ? requested : "any";

  const { data, error } = await createAdminClient().rpc("title_classification_gaps_v1", {
    p_limit: limit,
    p_missing: missing,
  });
  if (error) {
    if (isMissingFunction(error)) return migrationRequired();
    return Response.json({ error: error.message }, { status: 500 });
  }

  return Response.json({
    missing,
    gaps: (data ?? []).map((row: {
      normalized_title: string;
      sample_title: string;
      occurrences: number;
      missing_seniority: boolean;
      missing_department: boolean;
    }) => ({
      normalizedTitle: row.normalized_title,
      sampleTitle: row.sample_title,
      occurrences: Number(row.occurrences ?? 0),
      missingSeniority: Boolean(row.missing_seniority),
      missingDepartment: Boolean(row.missing_department),
    })),
  }, { headers: { "Cache-Control": "no-store" } });
}

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const payload = await request.json().catch(() => null) as { batches?: unknown } | null;
  const batches = Math.max(1, Math.min(maxBatchesPerRequest, Math.round(Number(payload?.batches ?? maxBatchesPerRequest))));

  const supabase = createAdminClient();
  let reclassified = 0;
  let remaining = false;
  let remainingCount = 0;

  for (let run = 0; run < batches; run += 1) {
    const { data, error } = await supabase.rpc("run_title_classification_batch_v2", { p_limit: batchSize });
    if (error) {
      if (isMissingFunction(error)) return migrationRequired();
      return Response.json({ error: error.message }, { status: 500 });
    }
    const result = (Array.isArray(data) ? data[0] : data) as { processed?: unknown; remaining?: unknown; acquired?: unknown } | null;
    if (!result?.acquired) return Response.json({ error: "Another title-classification runner is active. Retry in a moment." }, { status: 409 });
    const count = Number(result.processed ?? 0);
    remainingCount = Number(result.remaining ?? 0);
    reclassified += count;
    if (remainingCount > 0 && count === 0) {
      return Response.json({ error: `Classification made no progress; ${remainingCount} stale rows remain.`, reclassified, remainingCount }, { status: 500 });
    }
    if (remainingCount === 0) break;
    remaining = run === batches - 1;
  }

  return Response.json({ reclassified, remaining, remainingCount });
}
