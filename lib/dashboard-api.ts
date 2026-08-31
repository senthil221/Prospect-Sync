import type { ProspectFilter } from "./types.ts";
import type { CompanyScope, PeopleScope } from "./workspace-scopes.ts";

const apiResponseCache = new Map<string, { data: unknown; expiresAt: number }>();
const apiRequests = new Map<string, Promise<unknown>>();

function failedRequestMessage(response: Response, body: string, parsed: unknown) {
  if (typeof parsed === "object" && parsed !== null && "error" in parsed) {
    const error = String((parsed as { error?: unknown }).error ?? "").trim();
    if (error) return error;
  }
  const contentType = response.headers.get("content-type") ?? "";
  if (contentType.toLowerCase().startsWith("text/plain")) {
    const text = body.trim().slice(0, 300);
    if (text) return text;
  }
  return response.statusText || `Request failed (${response.status}).`;
}

async function parseApiResponse<T>(response: Response): Promise<T> {
  const body = await response.text();
  let parsed: unknown = null;
  if (body) {
    try { parsed = JSON.parse(body); }
    catch {
      if (!response.ok) throw new Error(failedRequestMessage(response, body, null));
      throw new Error("The server returned an invalid response. Please try again.");
    }
  }
  if (!response.ok) throw new Error(failedRequestMessage(response, body, parsed));
  if (!body) throw new Error("The server returned an empty response. Please try again.");
  return parsed as T;
}

export function clearApiCache() {
  apiResponseCache.clear();
}

export async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const method = String(options?.method ?? "GET").toUpperCase();
  // Polling callers opt out with `cache: "no-store"`. Without this guard the
  // in-memory cache can keep returning the first import status for five minutes.
  const cacheable = method === "GET" && !options?.signal && options?.cache !== "no-store";
  if (cacheable) {
    const cached = apiResponseCache.get(path);
    if (cached && cached.expiresAt > Date.now()) return cached.data as T;
    const pending = apiRequests.get(path);
    if (pending) return pending as Promise<T>;
  }
  const request = (async () => {
    const response = await fetch(path, options);
    const data = await parseApiResponse<T>(response);
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

export function filterPayload(filters: ProspectFilter[]) {
  return filters.map(({ field, operator, values, scopes }) => ({
    field, operator, values, ...(scopes?.length ? { scopes } : {}),
  }));
}

export function encodeFilters(filters: ProspectFilter[]) {
  return JSON.stringify(filterPayload(filters));
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
