import type { createAdminClient } from "./supabase/admin";

type Admin = ReturnType<typeof createAdminClient>;

// Errors that mean the search-index migration is not applied yet. Reindex is a
// best-effort maintenance step, so these must never break the user's write.
const benignCodes = new Set(["PGRST202", "42883", "42P01"]);

async function callReindex(supabase: Admin, fn: string, args: Record<string, unknown>) {
  const { error } = await supabase.rpc(fn, args);
  if (error && !benignCodes.has(error.code ?? "")) return error;
  return null;
}

export async function reindexProspects(supabase: Admin, ids: Array<string | null | undefined>) {
  const unique = [...new Set(ids.filter((id): id is string => Boolean(id)))];
  if (!unique.length) return null;
  return callReindex(supabase, "reindex_prospects", { p_ids: unique });
}

export async function reindexProspectsOfLists(supabase: Admin, listIds: Array<string | null | undefined>) {
  const unique = [...new Set(listIds.filter((id): id is string => Boolean(id)))];
  if (!unique.length) return null;
  return callReindex(supabase, "reindex_prospects_of_lists", { p_list_ids: unique });
}

export async function reindexProspectsOfCompanies(supabase: Admin, companyIds: Array<string | null | undefined>) {
  const unique = [...new Set(companyIds.filter((id): id is string => Boolean(id)))];
  if (!unique.length) return null;
  return callReindex(supabase, "reindex_prospects_of_companies", { p_company_ids: unique });
}

export async function reindexAll(supabase: Admin) {
  return callReindex(supabase, "reindex_all", {});
}
