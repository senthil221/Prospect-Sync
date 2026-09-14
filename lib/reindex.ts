import type { createAdminClient } from "./supabase/admin.ts";

type Admin = ReturnType<typeof createAdminClient>;

// Errors that mean the search-index migration is not applied yet. Reindex is a
// best-effort maintenance step, so these must never break the user's write.
const benignCodes = new Set(["PGRST202", "42883", "42P01"]);

// reindex_prospects runs under a 15s statement timeout. Sending it every id a
// large client owns is a guaranteed timeout, so callers never do - ids are split
// into batches this size, and any batch that still fails is queued for retry
// rather than silently dropped.
const batchSize = 2000;

function isBenign(error: { code?: string } | null | undefined) {
  return Boolean(error?.code && benignCodes.has(error.code));
}

export type ReindexOutcome = { reindexed: number; queued: number; degraded: boolean };

// Remember ids we could not index. Failing to enqueue is itself non-fatal: the
// nightly drift check will still report the gap, and reindex_all repairs it.
async function enqueue(supabase: Admin, ids: string[], reason: string) {
  const { error } = await supabase.rpc("enqueue_reindex", { p_ids: ids, p_error: reason.slice(0, 500) });
  return !error || isBenign(error);
}

// Index a specific set of prospects. Never throws: a write that already
// committed must not be reported as failed because its index update lagged.
export async function reindexProspects(supabase: Admin, ids: Array<string | null | undefined>): Promise<ReindexOutcome> {
  const unique = [...new Set(ids.filter((id): id is string => Boolean(id)))];
  if (!unique.length) return { reindexed: 0, queued: 0, degraded: false };

  let reindexed = 0;
  let queued = 0;
  let degraded = false;

  for (let index = 0; index < unique.length; index += batchSize) {
    const batch = unique.slice(index, index + batchSize);
    const { data, error } = await supabase.rpc("reindex_prospects", { p_ids: batch });
    if (!error) { reindexed += Number(data ?? batch.length); continue; }
    if (isBenign(error)) { degraded = true; continue; }
    if (await enqueue(supabase, batch, error.message)) queued += batch.length;
    else degraded = true;
  }

  return { reindexed, queued, degraded };
}

// Index everything attached to a client, list, import, or company - resolved
// inside the database so the ids never travel over HTTP just to come back.
export async function reindexScope(supabase: Admin, scope: {
  clientId?: string | null;
  listIds?: Array<string | null | undefined>;
  importIds?: Array<string | null | undefined>;
  companyIds?: Array<string | null | undefined>;
  prospectIds?: Array<string | null | undefined>;
}): Promise<ReindexOutcome> {
  const clean = (values?: Array<string | null | undefined>) => {
    const unique = [...new Set((values ?? []).filter((value): value is string => Boolean(value)))];
    return unique.length ? unique : null;
  };
  const args = {
    p_client_id: scope.clientId || null,
    p_list_ids: clean(scope.listIds),
    p_import_ids: clean(scope.importIds),
    p_company_ids: clean(scope.companyIds),
    p_prospect_ids: clean(scope.prospectIds),
    p_batch: batchSize,
  };
  if (!args.p_client_id && !args.p_list_ids && !args.p_import_ids && !args.p_company_ids && !args.p_prospect_ids) {
    return { reindexed: 0, queued: 0, degraded: false };
  }

  const { data, error } = await supabase.rpc("reindex_scope_v1", args);
  if (error) {
    // Older database: fall back to the explicit-id path where we can.
    if (isBenign(error) && args.p_prospect_ids) return reindexProspects(supabase, args.p_prospect_ids);
    if (isBenign(error)) return { reindexed: 0, queued: 0, degraded: true };
    if (args.p_prospect_ids && await enqueue(supabase, args.p_prospect_ids, error.message)) {
      return { reindexed: 0, queued: args.p_prospect_ids.length, degraded: false };
    }
    return { reindexed: 0, queued: 0, degraded: true };
  }
  const row = Array.isArray(data) ? data[0] : data;
  return {
    reindexed: Number(row?.reindexed ?? 0),
    queued: Number(row?.queued ?? 0),
    degraded: false,
  };
}

// Re-index everything a COMPANY import touched.
//
// DO NOT reach for reindexScope({ importIds }) here. reindex_scope_v1 resolves
// p_import_ids through public.list_rows, which is a People-import concept: a
// company import id matches nothing there, so it returns reindexed: 0 with no
// error at all. Silent success is the worst possible failure for an index
// refresh, and it is one rename away from happening again.
//
// Queue first, then drain. Queueing is a narrow insert measured at ~2s for the
// 131,769 prospects of a 12,498-company import; draining is the expensive half
// and is bounded per call so it can be abandoned and resumed. The operations
// worker drains continuously, so finishing here is an accelerator, not the
// guarantee - which is why running out of budget is not an error.
export async function reindexCompanyImport(
  supabase: Admin,
  importId: string,
  budgetMs = 45_000,
): Promise<ReindexOutcome & { remaining: number }> {
  const deadline = Date.now() + budgetMs;
  const pageSize = 25_000;
  let queued = 0;
  let reindexed = 0;
  let remaining = 0;
  let degraded = false;
  let cursor = "";

  for (let page = 0; page < 200; page += 1) {
    const { data, error } = await supabase.rpc("queue_company_import_reindex_v1", {
      p_import_id: importId, p_after_prospect_id: cursor, p_limit: pageSize,
    });
    if (error) { degraded = true; break; }
    const row = Array.isArray(data) ? data[0] : data;
    const added = Number(row?.queued ?? 0);
    queued += added;
    cursor = String(row?.last_prospect_id ?? cursor);
    if (added < pageSize) break;
    if (Date.now() > deadline) break;
  }

  // Same stop conditions as the Data Quality re-index button: no progress means
  // the queue is empty or every row in it is failing, and either way spinning
  // helps nobody.
  for (let pass = 0; pass < 25; pass += 1) {
    if (Date.now() > deadline) break;
    const { data, error } = await supabase.rpc("drain_reindex_backlog", { p_limit: 2000 });
    if (error) { if (!isBenign(error)) degraded = true; break; }
    const row = Array.isArray(data) ? data[0] : data;
    const done = Number(row?.processed ?? 0);
    remaining = Number(row?.remaining ?? 0);
    reindexed += done;
    if (!done || !remaining) break;
  }

  return { reindexed, queued, remaining, degraded };
}

export async function reindexProspectsOfLists(supabase: Admin, listIds: Array<string | null | undefined>) {
  return reindexScope(supabase, { listIds });
}

export async function reindexProspectsOfCompanies(supabase: Admin, companyIds: Array<string | null | undefined>) {
  return reindexScope(supabase, { companyIds });
}

export async function reindexAll(supabase: Admin) {
  const { error } = await supabase.rpc("reindex_all", {});
  return isBenign(error) ? null : error;
}

// A response field for writes whose index update did not fully land, so the UI
// can say so instead of showing stale rows and looking broken.
export function indexNotice(outcome: ReindexOutcome) {
  if (outcome.queued) return `${outcome.queued.toLocaleString("en-IN")} records are queued for re-indexing and will refresh shortly.`;
  if (outcome.degraded) return "Search index maintenance is unavailable - apply the latest database migration.";
  return "";
}
