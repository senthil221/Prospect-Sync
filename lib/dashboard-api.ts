import type { ProspectFilter } from "./types.ts";
import { BoundedCache } from './bounded-cache.ts';
import type { CompanyScope, PeopleScope } from "./workspace-scopes.ts";
import { awaitPreparedSearch, needsCompanyPreparation, type PreparationProgress } from "./prepared-search.ts";

const apiResponseCache = new BoundedCache<{ data: unknown; expiresAt: number }>(64, 8 * 1024 * 1024);
const apiRequests = new Map<string, Promise<unknown>>();
let apiCacheGeneration = 0;

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
  apiCacheGeneration++;
  apiResponseCache.clear();
  apiRequests.clear();
}

// The server refuses rather than queues when the interactive pool is under
// pressure, and says so with 503 + Retry-After. A read is idempotent, so it is
// worth retrying; a mutation is not retried here, because without an
// idempotency key a retry can apply the same change twice.
//
// The wait is jittered around the server's Retry-After. Without jitter every
// client refused in the same burst comes back in the same millisecond, which is
// the burst again.
const overloadRetries = 2;

function retryDelayMs(response: Response, attempt: number) {
  const header = Number(response.headers.get("Retry-After"));
  const base = Number.isFinite(header) && header > 0 ? header * 1000 : 1000;
  const backoff = base * Math.pow(2, attempt);
  return Math.min(8000, backoff) * (0.5 + Math.random());
}

function isOverloaded(response: Response) {
  return response.status === 503 || response.status === 429;
}

async function fetchWithBackpressure(path: string, options: RequestInit | undefined, idempotent: boolean) {
  let response = await fetch(path, options);
  if (!idempotent) return response;
  for (let attempt = 0; attempt < overloadRetries && isOverloaded(response); attempt += 1) {
    const wait = retryDelayMs(response, attempt);
    await new Promise<void>((resolve, reject) => {
      const signal = options?.signal;
      const aborted = () => { clearTimeout(timer); reject(signal?.reason ?? new DOMException('Aborted', 'AbortError')); };
      const timer = setTimeout(() => { signal?.removeEventListener('abort', aborted); resolve(); }, wait);
      if (signal?.aborted) aborted();
      else signal?.addEventListener('abort', aborted, { once: true });
    });
    response = await fetch(path, options);
  }
  return response;
}

export async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const generation = apiCacheGeneration;
  const method = String(options?.method ?? "GET").toUpperCase();
  // Polling callers opt out with `cache: "no-store"`. Without this guard the
  // in-memory cache can keep returning the first import status for five minutes.
  const cacheable = method === "GET" && !options?.signal && options?.cache !== "no-store";
  if (cacheable) {
    const cached = apiResponseCache.get(path);
    if (cached && cached.expiresAt > Date.now()) return cached.data as T;
    if (cached) apiResponseCache.delete(path);
    const pending = apiRequests.get(path);
    if (pending) return pending as Promise<T>;
  }
  const request = (async () => {
    const response = await fetchWithBackpressure(path, options, method === "GET");
    // An overload response is never cached: it says nothing about the data, and
    // caching it would keep answering "busy" for five minutes after the load
    // had passed.
    const data = await parseApiResponse<T>(response);
    if (cacheable && generation === apiCacheGeneration && !isOverloaded(response)) apiResponseCache.set(path, { data, expiresAt: Date.now() + 5 * 60_000 });
    else if (method !== "GET") clearApiCache();
    return data;
  })();
  if (cacheable) apiRequests.set(path, request);
  try { return await request; }
  finally { if (cacheable && apiRequests.get(path) === request) apiRequests.delete(path); }
}

export function prefetchApi(path: string) {
  void api(path).catch(() => undefined);
}

export function prospectApiPath({ search = "", page = 1, sort = "created_at", direction = "desc", filters = "[]", clientId = "", includeFields = true, companyScope = null, withTotal = page === 1, knownVersions = null }: { search?: string; page?: number; sort?: string; direction?: "asc" | "desc"; filters?: string; clientId?: string; includeFields?: boolean; companyScope?: CompanyScope | null; withTotal?: boolean; knownVersions?: Record<string, number> | null }) {
  const params = new URLSearchParams({ search, page: String(page), sort, direction, filters, includeFields: includeFields ? "1" : "0", withTotal: withTotal ? "1" : "0" });
  if (clientId) params.set("clientId", clientId);
  if (companyScope) params.set("companyScope", JSON.stringify(companyScope));
  // The version vector the caller's cached total was counted at. The server
  // recounts when it no longer matches, so a stale total cannot survive a
  // completed mutation until some later page load happens to notice.
  if (knownVersions) params.set("knownVersions", JSON.stringify(knownVersions));
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

// A caller may hand over filters that are already encoded. That is how a large
// pasted list reaches the server as a set id instead of as thousands of values:
// the substitution is asynchronous (it stores the list first), so it cannot
// happen inside a path builder. The array form stays for callers with nothing
// to substitute - a prefetch, a client-scoped view with no filters at all.
function companyFilterParam(filters: ProspectFilter[], encodedFilters: string) {
  const encoded = encodedFilters || (filters.length ? encodeFilters(filters) : "");
  return encoded && encoded !== "[]" ? encoded : "";
}

export function companyApiPath({ search = "", page = 1, clientId = "", filters = [], encodedFilters = "", peopleScope = null, knownVersions = null }: { search?: string; page?: number; clientId?: string; filters?: ProspectFilter[]; encodedFilters?: string; peopleScope?: PeopleScope | null; knownVersions?: Record<string, number> | null }) {
  const params = new URLSearchParams({ search, page: String(page), pageSize: "50" });
  if (clientId) params.set("clientId", clientId);
  const encoded = companyFilterParam(filters, encodedFilters);
  if (encoded) params.set("filters", encoded);
  if (peopleScope) params.set("peopleScope", JSON.stringify(peopleScope));
  // Opaque to the client: handed back to the database, which compares it with
  // the live vector and recounts only if they differ. Counting companies is now
  // exact rather than capped at 50,000, so it is worth not repeating.
  if (knownVersions) params.set("knownVersions", JSON.stringify(knownVersions));
  return `/api/companies?${params.toString()}`;
}

// Node answers 431 Request Header Fields Too Large once the request line passes
// its 16KB header budget, before any application code runs. Measured against
// production: 400 domains in the __website filter is a 12.9KB URL and is
// accepted; 600 is 19.3KB and is rejected. Bulk domains allows 1000 values, so
// any sizeable paste failed outright.
//
// 8KB leaves room for the rest of the request's headers (cookies, auth) and is
// well under the wall. Past it the identical query goes in a POST body instead.
const maxCompanyQueryUrlBytes = 8000;

type CompanyQuery = {
  search?: string;
  page?: number;
  clientId?: string;
  filters?: ProspectFilter[];
  encodedFilters?: string;
  peopleScope?: PeopleScope | null;
  knownVersions?: Record<string, number> | null;
};

export async function fetchCompanies<T>(query: CompanyQuery, init?: RequestInit, onPreparation?: (progress: PreparationProgress | null) => void): Promise<T> {
  const path = companyApiPath(query);
  const filters = query.encodedFilters ? JSON.parse(query.encodedFilters) as ProspectFilter[] : query.filters ?? [];
  const prepared = !query.clientId && !query.peopleScope && needsCompanyPreparation({ search: query.search ?? '', filters, limit: 250000 });
  if (path.length <= maxCompanyQueryUrlBytes && !prepared) return api<T>(path, init);

  // Deliberately not routed through api(): it keys its cache on the path, and
  // treats every non-GET as a mutation that clears the whole cache. Neither is
  // right for a read that simply outgrew the URL.
  const encoded = companyFilterParam(query.filters ?? [], query.encodedFilters ?? "");
  const read = () => path.length <= maxCompanyQueryUrlBytes
    ? fetchWithBackpressure(path, { ...init, cache: 'no-store' }, true)
    : fetchWithBackpressure("/api/companies", {
    ...init,
    cache: 'no-store',
    method: "POST",
    headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
    body: JSON.stringify({
      search: query.search ?? "",
      page: String(query.page ?? 1),
      pageSize: "50",
      ...(query.clientId ? { clientId: query.clientId } : {}),
      ...(encoded ? { filters: encoded } : {}),
      ...(query.peopleScope ? { peopleScope: JSON.stringify(query.peopleScope) } : {}),
      ...(query.knownVersions ? { knownVersions: JSON.stringify(query.knownVersions) } : {}),
    }),
  }, true);
  const response = prepared ? await awaitPreparedSearch(read, { signal: init?.signal, onProgress: onPreparation }) : await read();
  return parseApiResponse<T>(response);
}

type ProspectQuery = Parameters<typeof prospectApiPath>[0];

// The People filters have the same 1000-value ceiling and the same query-string
// transport, so they hit the same 431 wall. Same remedy.
export async function fetchProspects<T>(query: ProspectQuery, init?: RequestInit, onPreparation?: (progress: PreparationProgress | null) => void): Promise<T> {
  const path = prospectApiPath(query);
  const prepared = needsCompanyPreparation(query.companyScope);
  if (path.length <= maxCompanyQueryUrlBytes && !prepared) return api<T>(path, init);
  const read = () => path.length <= maxCompanyQueryUrlBytes
    ? fetchWithBackpressure(path, { ...init, cache: 'no-store' }, true)
    : fetchWithBackpressure("/api/prospects", {
    ...init,
    cache: 'no-store',
    method: "POST",
    headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
    body: JSON.stringify({
      search: query.search ?? "",
      page: String(query.page ?? 1),
      sort: query.sort ?? "created_at",
      direction: query.direction ?? "desc",
      filters: query.filters ?? "[]",
      includeFields: query.includeFields === false ? "0" : "1",
      withTotal: (query.withTotal ?? (query.page ?? 1) === 1) ? "1" : "0",
      ...(query.clientId ? { clientId: query.clientId } : {}),
      ...(query.companyScope ? { companyScope: JSON.stringify(query.companyScope) } : {}),
      ...(query.knownVersions ? { knownVersions: JSON.stringify(query.knownVersions) } : {}),
    }),
  }, true);
  const response = prepared ? await awaitPreparedSearch(read, { signal: init?.signal, onProgress: onPreparation }) : await read();
  return parseApiResponse<T>(response);
}

export function isAbortError(error: unknown) {
  return typeof error === "object" && error !== null && "name" in error && error.name === "AbortError";
}
