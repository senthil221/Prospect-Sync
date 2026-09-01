"use client";

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { encodeFilters, fetchProspects, isAbortError } from "../../lib/dashboard-api";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import type { ClientRecord, Prospect, ProspectFilter } from "../../lib/types";
import ProspectTable from "./ProspectTable";
import { useDebouncedValue } from "./useDebouncedValue";

export function useProspectsWorkspaceController({ active, search, filters, sort, direction, companyScope, statsProspects, onLoading, onError }: { active: boolean; search: string; filters: ProspectFilter[]; sort: string; direction: "asc" | "desc"; companyScope: CompanyScope | null; statsProspects: number; onLoading: (loading: boolean) => void; onError: (error: string) => void }) {
  const [prospects, setProspects] = useState<Prospect[]>([]);
  const [total, setTotal] = useState(0);
  const [totalEstimated, setTotalEstimated] = useState(false);
  // The company scope matched more companies than its own cap, so these people
  // come from a truncated set. Reported per page, not cached with the count.
  const [scopeCapped, setScopeCapped] = useState(false);
  const [fields, setFields] = useState<string[]>([]);
  const [page, setPage] = useState(1);
  const [refresh, setRefresh] = useState(0);
  const fieldsLoaded = useRef(false);
  const totalCache = useRef(new Map<string, { total: number; estimated: boolean }>());
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
      try {
        const data = await fetchProspects<{ prospects: Prospect[]; total: number | null; totalEstimated: boolean; scopeCapped?: boolean; fields?: string[] }>({ search: debouncedSearch, page, sort, direction, filters: encodedFilters, includeFields: !fieldsLoaded.current, companyScope, withTotal: page === 1 && !totalCache.current.has(countKey) }, { signal: controller.signal });
        if (current) {
          setProspects(data.prospects);
          setScopeCapped(data.scopeCapped === true);
          if (data.total !== null) {
            const cachedTotal = { total: data.total, estimated: data.totalEstimated };
            totalCache.current.set(countKey, cachedTotal);
            setTotal(cachedTotal.total); setTotalEstimated(cachedTotal.estimated);
          } else {
            const cachedTotal = totalCache.current.get(countKey);
            if (cachedTotal) { setTotal(cachedTotal.total); setTotalEstimated(cachedTotal.estimated); }
          }
          if (data.fields?.length) { fieldsLoaded.current = true; setFields(data.fields); }
        }
      } catch (caught) { if (current && !isAbortError(caught)) onError(caught instanceof Error ? caught.message : "Unable to load workspace data."); }
      finally { if (current) onLoading(false); }
    })();
    return () => { current = false; controller.abort(); };
  }, [active, deferredSearch, debouncedSearch, statsProspects, page, encodedFilters, sort, direction, refresh, companyScope, countKey, onError, onLoading]);

  const refreshWorkspace = useCallback(() => setRefresh((current) => current + 1), []);
  return { prospects, total, totalEstimated, scopeCapped, fields, page, setPage, deferredSearch, fieldsLoaded: fields.length > 0, refreshWorkspace };
}

export default function ProspectsWorkspace({ controller, filters, sort, direction, clients, companyScope, onClearCompanyScope, onSeeCompanies, onFiltersChange, onSortChange, onSelect, onImport }: { controller: ReturnType<typeof useProspectsWorkspaceController>; filters: ProspectFilter[]; sort: string; direction: "asc" | "desc"; clients: ClientRecord[]; companyScope: CompanyScope | null; onClearCompanyScope: () => void; onSeeCompanies: (scope: PeopleScope) => void; onFiltersChange: (filters: ProspectFilter[]) => void; onSortChange: (sort: string, direction: "asc" | "desc") => void; onSelect: (prospect: Prospect) => void; onImport: () => void }) {
  const handleSortChange = useCallback((nextSort: string, nextDirection: "asc" | "desc") => { onSortChange(nextSort, nextDirection); controller.setPage(1); }, [controller, onSortChange]);
  const handleFiltersChange = useCallback((next: ProspectFilter[]) => { onFiltersChange(next); controller.setPage(1); }, [controller, onFiltersChange]);
  return <ProspectTable prospects={controller.prospects} total={controller.total} totalEstimated={controller.totalEstimated} scopeCapped={controller.scopeCapped} fields={controller.fields} filters={filters} page={controller.page} clients={clients} search={controller.deferredSearch} sort={sort} direction={direction} companyScope={companyScope} onClearCompanyScope={onClearCompanyScope} onSeeCompanies={onSeeCompanies} onSortChange={handleSortChange} onFiltersChange={handleFiltersChange} onPageChange={controller.setPage} onSelect={onSelect} onImport={onImport} onRefresh={controller.refreshWorkspace}/>;
}
