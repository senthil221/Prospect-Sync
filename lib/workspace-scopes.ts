import { normalizeDomain } from "../db/normalize";
import { parseFilters, type ProspectFilter } from "./prospect-filters";

export type CompanyScope = {
  search: string;
  names: string[];
  domains: string[];
  seniority: string[];
  locations: string[];
};

export type PeopleScope = {
  search: string;
  filters: ProspectFilter[];
};

function stringList(value: unknown, transform: (item: string) => string = (item) => item) {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  return value.slice(0, 100).flatMap((item) => {
    const cleaned = transform(String(item ?? "").trim().slice(0, 160));
    const key = cleaned.toLocaleLowerCase();
    if (!cleaned || seen.has(key)) return [];
    seen.add(key);
    return [cleaned];
  });
}

export function parseCompanyScope(raw: string | null): CompanyScope | null {
  if (!raw) return null;
  const parsed = JSON.parse(raw) as Record<string, unknown>;
  return {
    search: String(parsed.search ?? "").trim().slice(0, 300),
    names: stringList(parsed.names),
    domains: stringList(parsed.domains, normalizeDomain),
    seniority: stringList(parsed.seniority),
    locations: stringList(parsed.locations),
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
