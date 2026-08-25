import type { ProspectFilter } from "./types.ts";
import type { CompanyScope, PeopleScope } from "./workspace-scopes.ts";

const apiResponseCache = new Map<string, { data: unknown; expiresAt: number }>();
const apiRequests = new Map<string, Promise<unknown>>();

export function clearApiCache() {
  apiResponseCache.clear();
}

export async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const method = String(options?.method ?? "GET").toUpperCase();
  const cacheable = method === "GET" && !options?.signal;
  if (cacheable) {
    const cached = apiResponseCache.get(path);
    if (cached && cached.expiresAt > Date.now()) return cached.data as T;
    const pending = apiRequests.get(path);
    if (pending) return pending as Promise<T>;
  }
  const request = (async () => {
    const response = await fetch(path, options);
    const data = await response.json() as T & { error?: string };
    if (!response.ok) throw new Error(data.error || "Something went wrong.");
    if (cacheable) apiResponseCache.set(path, { data, expiresAt: Date.now() + 5 * 60_000 });
    else if (method !== "GET") clearApiCache();
    return data;
  })();
  if (cacheable) apiRequests.set(path, request);
  try { return await request; }
  finally { if (cacheable) apiRequests.delete(path); }
}

export function prefetchApi(path: string) {
  void api(path).catch(() => undefined);
}

export function prospectApiPath({ search = "", page = 1, sort = "created_at", direction = "desc", filters = "[]", clientId = "", includeFields = true, companyScope = null, withTotal = page === 1 }: { search?: string; page?: number; sort?: string; direction?: "asc" | "desc"; filters?: string; clientId?: string; includeFields?: boolean; companyScope?: CompanyScope | null; withTotal?: boolean }) {
  const params = new URLSearchParams({ search, page: String(page), sort, direction, filters, includeFields: includeFields ? "1" : "0", withTotal: withTotal ? "1" : "0" });
  if (clientId) params.set("clientId", clientId);
  if (companyScope) params.set("companyScope", JSON.stringify(companyScope));
  return `/api/prospects?${params.toString()}`;
}

export function encodeFilters(filters: ProspectFilter[]) {
  return JSON.stringify(filters.map(({ field, operator, values }) => ({ field, operator, values })));
}

export function companyApiPath({ search = "", page = 1, clientId = "", filters = [], peopleScope = null }: { search?: string; page?: number; clientId?: string; filters?: ProspectFilter[]; peopleScope?: PeopleScope | null }) {
  const params = new URLSearchParams({ search, page: String(page), pageSize: "50" });
  if (clientId) params.set("clientId", clientId);
  if (filters.length) params.set("filters", encodeFilters(filters));
  if (peopleScope) params.set("peopleScope", JSON.stringify(peopleScope));
  return `/api/companies?${params.toString()}`;
}

export function isAbortError(error: unknown) {
  return typeof error === "object" && error !== null && "name" in error && error.name === "AbortError";
}
