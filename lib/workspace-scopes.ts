import { parseFilters, type ProspectFilter } from "./prospect-filters";

export type CompanyScope = {
  search: string;
  filters: ProspectFilter[];
};

export type PeopleScope = {
  search: string;
  filters: ProspectFilter[];
};

export function parseCompanyScope(raw: string | null): CompanyScope | null {
  if (!raw) return null;
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(parsed.filters ?? [])),
  };
}

export function parsePeopleScope(raw: string | null): PeopleScope | null {
  if (!raw) return null;
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    filters: parseFilters(JSON.stringify(parsed.filters ?? [])),
  };
}
