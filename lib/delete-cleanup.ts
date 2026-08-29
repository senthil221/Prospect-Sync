import type { createAdminClient } from "./supabase/admin.ts";

type Admin = ReturnType<typeof createAdminClient>;

const missingFunctionCodes = new Set(["PGRST202", "42883"]);

// Deleting a client, list, or import has to re-index every prospect that lost a
// membership. Doing that from the app meant selecting all the affected ids over
// HTTP and handing the same ids straight back - untenable for a client with
// 100k prospects, and the reindex that followed was one call certain to exceed
// its 15s timeout. The *_and_reindex_v1 functions do both inside the database,
// in bounded batches, queueing anything they could not finish.
//
// The fallback keeps a database that is one migration behind working: it runs
// the original cleanup function, just without the server-side re-index.
export async function deleteAndReindex(
  supabase: Admin,
  combinedFn: string,
  fallbackFn: string,
  args: Record<string, string>,
) {
  const combined = await supabase.rpc(combinedFn, args);
  if (!combined.error) return combined;
  if (!combined.error.code || !missingFunctionCodes.has(combined.error.code)) return combined;
  return supabase.rpc(fallbackFn, { ...args, p_delete_orphans: false });
}

// The delete functions fold their re-index counts into the returned JSON. Say so
// when work was deferred, rather than letting the user see stale rows and
// conclude the delete silently failed.
export function queuedNotice(result: unknown) {
  const queued = Number((result as { queued?: unknown } | null)?.queued ?? 0);
  if (!Number.isFinite(queued) || queued <= 0) return "";
  return `${queued.toLocaleString("en-IN")} records are queued for re-indexing and will refresh shortly.`;
}
