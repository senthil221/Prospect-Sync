import { parseFilters } from "./prospect-filters.ts";
import { parseCompanyScope, parsePeopleScope, type CompanyScope, type PeopleScope } from "./workspace-scopes.ts";
import type { ProspectFilter, ProspectFilterOperator, Section } from "./types.ts";

// The workspace, written into the address bar.
//
// SHELL-01: everything about where you were lived in React state, so a refresh,
// a Back button or a link sent to a colleague all landed on an empty Overview.
// Nothing was recoverable and nothing was shareable - in a tool whose whole job
// is narrowing 681,000 rows down to the ones you want, losing the narrowing is
// losing the work.
//
// WHY FILTERS ARE CAPPED HERE AND NOTHING ELSE IS. A URL is not a database, and
// this product already learned where that wall is: 400 pasted domains is a
// 12.9 KB request line and is accepted, 600 is 19.3 KB and Node answers 431
// before any handler runs (see app/api/companies/route.ts). Filters are the one
// piece of workspace state that can carry thousands of values, so they go in
// only while they are small. Past the cap the rest of the state still restores -
// section, search, sort, page, client, scope - and the filters do not, which is
// a smaller loss than a link that cannot be opened at all.
//
// A durable filter set (20260902000100) shrinks the big ones back to a uuid, so
// a 5,000-domain paste that has been saved as a set restores from the URL like
// anything else. That is the intended path for large lists.

export const maxFilterUrlChars = 1200;

export type WorkspaceUrlState = {
  section: Section;
  search: string;
  clientId: string;
  listId: string;
  prospectPage: number;
  companyPage: number;
  sort: string;
  direction: "asc" | "desc";
  prospectFilters: ProspectFilter[];
  companyFilters: ProspectFilter[];
  companyPeopleScope: CompanyScope | null;
  peopleCompanyScope: PeopleScope | null;
};

const sections = new Set<Section>(["overview", "prospects", "companies", "clients", "coverage", "quality", "imports"]);

export const defaultWorkspaceState: WorkspaceUrlState = {
  section: "overview",
  search: "",
  clientId: "",
  listId: "",
  prospectPage: 1,
  companyPage: 1,
  sort: "created_at",
  direction: "desc",
  prospectFilters: [],
  companyFilters: [],
  companyPeopleScope: null,
  peopleCompanyScope: null,
};

function page(value: string | null) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 && parsed <= 100_000 ? parsed : 1;
}

// Everything here is defensive. A URL is user input - hand-edited, truncated by
// a chat client, or simply from an older version of the app - and none of that
// may throw on the way into a render. Anything unreadable falls back to its
// default rather than taking the workspace down with it.
// Validated by the same parser the API uses - it enforces the 60-filter and
// 5,000-value caps and drops unknown fields and operators - then given the
// client-side row id the filter builder keys its rows on. Validating with the
// wire parser rather than trusting the URL is the point: a link is user input.
function filters(raw: string | null): ProspectFilter[] {
  if (!raw) return [];
  try {
    return parseFilters(raw).map((filter, index) => ({
      id: `url-${index}-${filter.field}`,
      field: filter.field,
      operator: filter.operator as ProspectFilterOperator,
      values: filter.values,
      ...(filter.scopes ? { scopes: filter.scopes as ProspectFilter["scopes"] } : {}),
    }));
  } catch { return []; }
}

export function readWorkspaceUrl(params: URLSearchParams): WorkspaceUrlState {
  const rawSection = params.get("s") ?? "";
  let companyPeopleScope: CompanyScope | null = null;
  let peopleCompanyScope: PeopleScope | null = null;
  try { companyPeopleScope = parseCompanyScope(params.get("cscope")); } catch { companyPeopleScope = null; }
  try { peopleCompanyScope = parsePeopleScope(params.get("pscope")); } catch { peopleCompanyScope = null; }

  return {
    section: sections.has(rawSection as Section) ? rawSection as Section : "overview",
    search: (params.get("q") ?? "").slice(0, 300),
    clientId: (params.get("client") ?? "").slice(0, 100),
    listId: (params.get("list") ?? "").slice(0, 100),
    prospectPage: page(params.get("pp")),
    companyPage: page(params.get("cp")),
    sort: (params.get("sort") ?? "created_at").slice(0, 60),
    direction: params.get("dir") === "asc" ? "asc" : "desc",
    prospectFilters: filters(params.get("pf")),
    companyFilters: filters(params.get("cf")),
    companyPeopleScope,
    peopleCompanyScope,
  };
}

// Only what differs from the default is written, so an untouched Overview has a
// clean URL and a shared link carries the narrowing rather than the defaults.
export function writeWorkspaceUrl(state: WorkspaceUrlState): string {
  const params = new URLSearchParams();
  const set = (key: string, value: string) => { if (value) params.set(key, value); };

  if (state.section !== defaultWorkspaceState.section) set("s", state.section);
  set("q", state.search.trim());
  set("client", state.clientId);
  set("list", state.listId);
  if (state.prospectPage > 1) set("pp", String(state.prospectPage));
  if (state.companyPage > 1) set("cp", String(state.companyPage));
  if (state.sort !== defaultWorkspaceState.sort) set("sort", state.sort);
  if (state.direction !== defaultWorkspaceState.direction) set("dir", state.direction);
  if (state.companyPeopleScope) set("cscope", JSON.stringify(state.companyPeopleScope));
  if (state.peopleCompanyScope) set("pscope", JSON.stringify(state.peopleCompanyScope));

  for (const [key, value] of [["pf", state.prospectFilters], ["cf", state.companyFilters]] as const) {
    if (!value.length) continue;
    const encoded = JSON.stringify(value);
    // Silently dropped rather than truncated: half a filter list is a different
    // question, and restoring the wrong narrowing is worse than restoring none.
    if (encoded.length <= maxFilterUrlChars) params.set(key, encoded);
  }

  const query = params.toString();
  return query ? `?${query}` : window.location.pathname;
}

// True when the filters are too large to survive a link, so the UI can say so
// instead of letting someone share a URL that quietly loses their work.
export function filtersFitInUrl(value: ProspectFilter[]) {
  return !value.length || JSON.stringify(value).length <= maxFilterUrlChars;
}
