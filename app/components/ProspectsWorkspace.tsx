"use client";

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { encodeFilters, fetchProspects, isAbortError } from "../../lib/dashboard-api";
import { filterPayloadWithSets } from "../../lib/filter-set-client";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import type { ClientRecord, Prospect, ProspectFilter } from "../../lib/types";
import ProspectTable from "./ProspectTable";
import { useDebouncedValue } from "./useDebouncedValue";
import { needsCompanyPreparation, type PreparationProgress } from "../../lib/prepared-search";

export function useProspectsWorkspaceController({ active, search, filters, sort, direction, companyScope, statsProspects, initialPage, onLoading, onError }: { active: boolean; search: string; filters: ProspectFilter[]; sort: string; direction: "asc" | "desc"; companyScope: CompanyScope | null; statsProspects: number; initialPage?: number; onLoading: (loading: boolean) => void; onError: (error: string) => void }) {
  const [prospects, setProspects] = useState<Prospect[]>([]);
  const [preparation, setPreparation] = useState<PreparationProgress | null>(null);
  const [total, setTotal] = useState(0);
  const [totalEstimated, setTotalEstimated] = useState(false);
  // The count stopped at its cap, so the total on screen is a floor.
  const [totalCapped, setTotalCapped] = useState(false);
  // The company scope matched more companies than its own cap, so these people
  // come from a truncated set. Reported per page, not cached with the count.
  const [scopeCapped, setScopeCapped] = useState(false);
  const [fields, setFields] = useState<string[]>([]);
  const [page, setPage] = useState(initialPage ?? 1);
  const [refresh, setRefresh] = useState(0);
  const fieldsLoaded = useRef(false);
  // A cached total is only meaningful alongside the dependency-version vector it
  // was counted at, so the two are stored together and sent back as a pair.
  const totalCache = useRef(new Map<string, { total: number; estimated: boolean; capped: boolean; versions: Record<string, number> | null }>());
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  const encodedFilters = useMemo(() => encodeFilters(filters), [filters]);
  const countKey = useMemo(() => JSON.stringify([debouncedSearch.trim(), encodedFilters, companyScope, refresh, statsProspects]), [companyScope, debouncedSearch, encodedFilters, refresh, statsProspects]);

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (!active) return () => { current = false; controller.abort(); };
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      onLoading(true); onError("");
      setPreparation(needsCompanyPreparation(companyScope) ? { status: 'checking', message: 'Checking the matching companies…', matchedCompanies: 0 } : null);
      try {
        const cached = totalCache.current.get(countKey);
        // A big pasted list is stored once and sent as an id from then on. Note
        // this changes the transport only: countKey above still uses the plain
        // encoding, because a set's random uuid must not affect logical
        // identity (section 4.1) - the same question asked with values or with
        // a set id is the same question, and must hit the same cached count.
        const requestFilters = JSON.stringify(await filterPayloadWithSets(JSON.parse(encodedFilters), "prospect", ""));
        const data = await fetchProspects<{ prospects: Prospect[]; total: number | null; totalEstimated: boolean; totalCapped?: boolean; scopeCapped?: boolean; versions?: Record<string, number> | null; fields?: string[] }>({ search: debouncedSearch, page, sort, direction, filters: requestFilters, includeFields: !fieldsLoaded.current, companyScope, withTotal: page === 1 && !cached, knownVersions: cached?.versions ?? null }, { signal: controller.signal }, progress => { if (current) setPreparation(progress); });
        if (current) {
          setProspects(data.prospects);
          setScopeCapped(data.scopeCapped === true);
          if (data.total !== null) {
            const cachedTotal = { total: data.total, estimated: data.totalEstimated, capped: data.totalCapped === true, versions: data.versions ?? null };
            totalCache.current.set(countKey, cachedTotal);
            setTotal(cachedTotal.total); setTotalEstimated(cachedTotal.estimated); setTotalCapped(cachedTotal.capped);
          } else {
            const cachedTotal = totalCache.current.get(countKey);
            if (cachedTotal) { setTotal(cachedTotal.total); setTotalEstimated(cachedTotal.estimated); setTotalCapped(cachedTotal.capped); }
          }
          if (data.fields?.length) { fieldsLoaded.current = true; setFields(data.fields); }
        }
      } catch (caught) { if (current && !isAbortError(caught)) onError(caught instanceof Error ? caught.message : "Unable to load workspace data."); }
      finally { if (current) { onLoading(false); setPreparation(null); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [active, deferredSearch, debouncedSearch, statsProspects, page, encodedFilters, sort, direction, refresh, companyScope, countKey, onError, onLoading]);

  const refreshWorkspace = useCallback(() => setRefresh((current) => current + 1), []);
  return { prospects, total, totalEstimated, totalCapped, scopeCapped, fields, page, setPage, deferredSearch, fieldsLoaded: fields.length > 0, refreshWorkspace, preparation };
}

export default function ProspectsWorkspace({ controller, filters, sort, direction, clients, companyScope, onClearCompanyScope, onClearSearch, onSeeCompanies, onFiltersChange, onSortChange, onSelect, onImport }: { controller: ReturnType<typeof useProspectsWorkspaceController>; filters: ProspectFilter[]; sort: string; direction: "asc" | "desc"; clients: ClientRecord[]; companyScope: CompanyScope | null; onClearCompanyScope: () => void; onClearSearch: () => void; onSeeCompanies: (scope: PeopleScope) => void; onFiltersChange: (filters: ProspectFilter[]) => void; onSortChange: (sort: string, direction: "asc" | "desc") => void; onSelect: (prospect: Prospect) => void; onImport: () => void }) {
  const handleSortChange = useCallback((nextSort: string, nextDirection: "asc" | "desc") => { onSortChange(nextSort, nextDirection); controller.setPage(1); }, [controller, onSortChange]);
  const handleFiltersChange = useCallback((next: ProspectFilter[]) => { onFiltersChange(next); controller.setPage(1); }, [controller, onFiltersChange]);
  if (controller.preparation) return <div className="panel" role="status" style={{ padding: 'var(--space-6)' }}><h3>Preparing your company search</h3><p>{controller.preparation.message}</p><button className="secondary" onClick={onClearCompanyScope}>Clear company scope</button></div>;
  return <ProspectTable prospects={controller.prospects} total={controller.total} totalEstimated={controller.totalEstimated} totalCapped={controller.totalCapped} scopeCapped={controller.scopeCapped} fields={controller.fields} filters={filters} page={controller.page} clients={clients} search={controller.deferredSearch} sort={sort} direction={direction} companyScope={companyScope} onClearCompanyScope={onClearCompanyScope} onClearSearch={onClearSearch} onSeeCompanies={onSeeCompanies} onSortChange={handleSortChange} onFiltersChange={handleFiltersChange} onPageChange={controller.setPage} onSelect={onSelect} onImport={onImport} onRefresh={controller.refreshWorkspace}/>;
}
