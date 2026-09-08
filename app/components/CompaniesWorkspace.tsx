"use client";
import { BoundedCache } from '../../lib/bounded-cache';

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import CompanyFilterPanel, { BulkDomainPaste, addDomainsToWebsiteFilter } from "../CompanyFilterPanel";
import { buildCompanyCustomFields, companyAllData, companyExportFields, defaultCompanyExportFields, estimatedCompanyBytesPerRow } from "../../lib/company-export";
import { backgroundExportNotice, fileSystemAccessSupported, runCompanyExport, type ExportProgress } from "../../lib/export-runner";
import { megabytes, planExport } from "../../lib/export-plan";
import { intentKey, requestIdFor, settleIntent } from "../../lib/request-intent";
import { api, encodeFilters, fetchCompanies, isAbortError } from "../../lib/dashboard-api";
import { filterPayloadWithSets } from "../../lib/filter-set-client";
import { emptyWorkspaceState } from "../../lib/workspace-states";
import { colorTone, formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientRecord, Company, CompanyDetail, Prospect, ProspectFilter } from "../../lib/types";
import { AppIcon, WorkspaceEmpty } from "./DashboardUi";
import CompanyTableRow from "./CompanyTableRow";
import MenuButton from "./MenuButton";
import { useDebouncedValue } from "./useDebouncedValue";
import { needsCompanyPreparation, type PreparationProgress } from "../../lib/prepared-search";
import SearchPreparation from './SearchPreparation';

export function useCompaniesWorkspaceController({ active, search, filters, peopleScope, initialPage, onLoading, onError }: { active: boolean; search: string; filters: ProspectFilter[]; peopleScope: PeopleScope | null; initialPage?: number; onLoading: (loading: boolean) => void; onError: (error: string) => void }) {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [preparation, setPreparation] = useState<PreparationProgress | null>(null);
  const [preparationError, setPreparationError] = useState('');
  const [page, setPage] = useState(initialPage ?? 1);
  const [summary, setSummary] = useState({ total: 0, totalCapped: false, covered: 0, prospectTotal: 0, pageSize: 50 });
  const [refresh, setRefresh] = useState(0);
  // The company count is exact rather than capped at 50,000, which costs real
  // seconds on a filter matching hundreds of thousands of rows. A count is only
  // meaningful alongside the dependency-version vector it was counted at, so the
  // two are cached together and sent back as a pair; the database recounts only
  // when companies or prospects have actually moved since.
  const countCache = useRef(new BoundedCache<{ total: number; covered: number; prospectTotal: number; versions: Record<string, number> | null }>());
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  // The question, not the array that expresses it. Bulk domains is the biggest
  // producer of large value lists in the product - up to 1,000 domains in one
  // paste - so this is the path the durable sets of 20260902000100 were built
  // for. Depending on the encoding rather than the array also stops a parent
  // re-render from re-fetching an unchanged query.
  const encodedFilters = useMemo(() => encodeFilters(filters), [filters]);
  // Deliberately excludes `page`: paging through a result set does not change
  // how many rows are in it, so page 4 reuses page 1's count.
  const countKey = useMemo(
    () => JSON.stringify([debouncedSearch.trim(), encodedFilters, peopleScope, refresh]),
    [debouncedSearch, encodedFilters, peopleScope, refresh],
  );

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (!active) return () => { current = false; controller.abort(); };
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      onLoading(true); onError("");
      setPreparationError('');
      setPreparation(!peopleScope && needsCompanyPreparation({ search: debouncedSearch, filters: JSON.parse(encodedFilters), limit: 250000 })
        ? { status: 'checking', message: 'Checking the matching companies…', matchedCompanies: 0 } : null);
      try {
        const requestFilters = JSON.stringify(await filterPayloadWithSets(JSON.parse(encodedFilters), "company", ""));
        if (!current) return;
        // A set id is a transport detail: countKey above uses the plain
        // encoding, so the same question asked with values or with a set id
        // hits the same cached count.
        const cached = countCache.current.get(countKey);
        const data = await fetchCompanies<{ companies: Company[]; total: number | null; totalCapped?: boolean; covered: number | null; prospectTotal: number | null; versions?: Record<string, number> | null; pageSize: number }>({ search: debouncedSearch, page, encodedFilters: requestFilters, peopleScope, knownVersions: cached?.versions ?? null }, { signal: controller.signal }, progress => { if (current) setPreparation(progress); });
        if (current) {
          setCompanies(data.companies);
          if (data.total !== null && data.total !== undefined) {
            const counted = { total: data.total, covered: data.covered ?? 0, prospectTotal: data.prospectTotal ?? 0, versions: data.versions ?? null };
            countCache.current.set(countKey, counted);
            setSummary({ ...counted, totalCapped: Boolean(data.totalCapped), pageSize: data.pageSize });
          } else if (cached) {
            setSummary({ total: cached.total, covered: cached.covered, prospectTotal: cached.prospectTotal, totalCapped: false, pageSize: data.pageSize });
          }
        }
      } catch (caught) { if (current && !isAbortError(caught)) {
        const message = caught instanceof Error ? caught.message : "Unable to load workspace data.";
        onError(message);
        if (!peopleScope && needsCompanyPreparation({ search: debouncedSearch, filters: JSON.parse(encodedFilters), limit: 250000 })) setPreparationError(message);
      } }
      finally { if (current) { onLoading(false); setPreparation(null); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [active, deferredSearch, debouncedSearch, page, encodedFilters, refresh, peopleScope, countKey, onError, onLoading]);

  const refreshWorkspace = useCallback(() => setRefresh((current) => current + 1), []);
  return { companies, page, setPage, summary, deferredSearch, refreshWorkspace, preparation, preparationError };
}

export default function CompaniesWorkspace({ controller, clients, filters, peopleScope, onClearPeopleScope, onClearSearch, onSeePeople, onFilters, onImport }: { controller: ReturnType<typeof useCompaniesWorkspaceController>; clients: ClientRecord[]; filters: ProspectFilter[]; peopleScope: PeopleScope | null; onClearPeopleScope: () => void; onClearSearch: () => void; onSeePeople: (scope: CompanyScope) => void; onFilters: (filters: ProspectFilter[]) => void; onImport: () => void }) {
  const handleFilters = useCallback((next: ProspectFilter[]) => { onFilters(next); controller.setPage(1); }, [controller, onFilters]);
  return <><SearchPreparation progress={controller.preparation} error={controller.preparationError} onRetry={controller.refreshWorkspace} onClear={() => handleFilters([])} clearLabel="Clear company filters"/>
    <div hidden={Boolean(controller.preparation || controller.preparationError)}><CompanyTable companies={controller.companies} clients={clients} total={controller.summary.total} totalCapped={controller.summary.totalCapped} covered={controller.summary.covered} prospectTotal={controller.summary.prospectTotal} page={controller.page} pageSize={controller.summary.pageSize} search={controller.deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onClearSearch={onClearSearch} onSeePeople={onSeePeople} onFilters={handleFilters} onPageChange={controller.setPage} onImport={onImport} onRefresh={controller.refreshWorkspace}/></div></>;
}

export function CompanyTable({ companies, clients = [], total, totalCapped = false, covered, prospectTotal, page, pageSize, clientId = "", search = "", filters = [], peopleScope = null, onClearPeopleScope, onClearSearch, onSeePeople, onFilters, onPageChange, onImport, onRefresh }: { companies: Company[]; clients?: ClientRecord[]; total: number; totalCapped?: boolean; covered: number; prospectTotal: number; page: number; pageSize: number; clientId?: string; search?: string; filters?: ProspectFilter[]; peopleScope?: PeopleScope | null; onClearPeopleScope?: () => void; onClearSearch?: () => void; onSeePeople: (scope: CompanyScope) => void; onFilters?: (filters: ProspectFilter[]) => void; onPageChange: (page: number) => void; onImport: () => void; onRefresh?: () => void }) {
  const [selectedCompany, setSelectedCompany] = useState<Company | null>(null);
  const [prospectsByCompany, setProspectsByCompany] = useState<Record<string, Prospect[]>>({});
  const [prospectTotalsByCompany, setProspectTotalsByCompany] = useState<Record<string, number>>({});
  const [loadingCompany, setLoadingCompany] = useState("");
  const [companyError, setCompanyError] = useState("");
  const [companyNotice, setCompanyNotice] = useState("");
  const [detailsByCompany, setDetailsByCompany] = useState<Record<string, CompanyDetail>>({});
  const [loadingDetail, setLoadingDetail] = useState("");
  const [exportingCompanies, setExportingCompanies] = useState(false);
  const [companyExportScope, setCompanyExportScope] = useState<"all" | "with_websites">("all");
  const [exportDialogOpen, setExportDialogOpen] = useState(false);
  const [exportFields, setExportFields] = useState<string[]>(defaultCompanyExportFields);
  const [exportFormat, setExportFormat] = useState<"single" | "parts">("single");
  const [exportRowsPerFile, setExportRowsPerFile] = useState(25000);
  const [exportProgress, setExportProgress] = useState<ExportProgress | null>(null);
  // Uploaded companies.all_data keys, found by a sampling scan on the server.
  // Fetched once, when the dialog first opens, and never on a page load: the
  // typed fields are what the picker is for and these are the extras.
  const [customFieldNames, setCustomFieldNames] = useState<string[] | null>(null);
  const exportAbortRef = useRef<AbortController | null>(null);
  const exportFieldCatalog = useMemo(
    () => [...companyExportFields.map((field) => ({ id: field.id, label: field.label })), ...buildCompanyCustomFields(customFieldNames ?? [])],
    [customFieldNames],
  );
  // Roughly how large the file will be. Worth showing because the columns are
  // not comparable: Description alone is about a kilobyte a row, so ticking it
  // over 400,000 companies is the difference between a 20 MB file and a 400 MB
  // one, and nothing else on the picker hints at that.
  const exportBytes = useMemo(
    () => totalCapped ? null : total * estimatedCompanyBytesPerRow(customFieldNames ?? [], exportFields),
    [customFieldNames, exportFields, total, totalCapped],
  );
  const [filtersOpen, setFiltersOpen] = useState(true);
  const [bulkOpen, setBulkOpen] = useState(false);
  const [bulkSelectOpen, setBulkSelectOpen] = useState(false);
  const [bulkSelectValues, setBulkSelectValues] = useState("");
  const [bulkSelecting, setBulkSelecting] = useState(false);
  const activeFilterCount = filters.reduce((count, filter) => count + (filter.operator === "empty" || filter.operator === "not_empty" ? 1 : filter.values.length), 0);
  const domainFilterCount = filters.filter((filter) => filter.field === "__website" && (filter.operator === "contains" || filter.operator === "equals")).reduce((count, filter) => count + filter.values.length, 0);
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  // A capped total is a floor, not an exact count -- say so rather than showing a
  // bounded number as though it were the real one.
  const totalLabel = totalCapped ? `${formatNumber(total)}+` : formatNumber(total);
  const resultStart = total ? (page - 1) * pageSize + 1 : 0;
  const resultEnd = Math.min(page * pageSize, total);

  // Global selection deletes companies. Client selection changes only that
  // client's ICP validation state and never mutates the shared company row.
  const canDelete = !clientId;
  const showSelection = canDelete || Boolean(clientId);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [selectionMode, setSelectionMode] = useState<"explicit" | "all_matching">("explicit");
  const [excludedIds, setExcludedIds] = useState<Set<string>>(new Set());
  const [selectionQueryKey, setSelectionQueryKey] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<{ mode: "ids" | "all_matching"; count: number; ids?: string[] } | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [updatingIcp, setUpdatingIcp] = useState(false);
  const [pushClientId, setPushClientId] = useState("");
  const [pushing, setPushing] = useState(false);
  const selectionKey = JSON.stringify({ search: search.trim(), filters: filters.map(({ field, operator, values, scopes }) => ({ field, operator, values, ...(scopes?.length ? { scopes } : {}) })), peopleScope });
  const selectionMatchesQuery = selectionQueryKey === selectionKey;
  const selectedCount = !selectionMatchesQuery ? 0 : selectionMode === "all_matching" ? Math.max(0, total - excludedIds.size) : selectedIds.size;

  function isSelected(id: string) {
    if (!selectionMatchesQuery) return false;
    return selectionMode === "all_matching" ? !excludedIds.has(id) : selectedIds.has(id);
  }
  function clearSelection() {
    setSelectionMode("explicit"); setSelectedIds(new Set()); setExcludedIds(new Set()); setSelectionQueryKey(selectionKey);
  }
  function selectAllMatching() {
    setSelectionMode("all_matching"); setSelectedIds(new Set()); setExcludedIds(new Set()); setSelectionQueryKey(selectionKey);
  }
  const toggleSelected = useCallback((id: string) => {
    if (!selectionMatchesQuery) { setSelectionMode("explicit"); setSelectedIds(new Set([id])); setExcludedIds(new Set()); setSelectionQueryKey(selectionKey); return; }
    if (selectionMode === "all_matching") { setExcludedIds((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; }); return; }
    setSelectedIds((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  }, [selectionKey, selectionMatchesQuery, selectionMode]);

  const deleteCompany = useCallback((id: string) => {
    setDeleteRequest({ mode: "ids", count: 1, ids: [id] });
  }, []);
  function togglePageSelection() {
    const pageIds = companies.map((company) => company.id);
    const allSelected = pageIds.length > 0 && pageIds.every(isSelected);
    if (!selectionMatchesQuery || selectionMode === "explicit") {
      setSelectionMode("explicit"); setExcludedIds(new Set()); setSelectionQueryKey(selectionKey);
      setSelectedIds((current) => { const next = selectionMatchesQuery ? new Set(current) : new Set<string>(); pageIds.forEach((id) => allSelected ? next.delete(id) : next.add(id)); return next; });
      return;
    }
    setExcludedIds((current) => { const next = new Set(current); pageIds.forEach((id) => allSelected ? next.add(id) : next.delete(id)); return next; });
  }
  function requestDeleteSelected() {
    if (!selectedCount) return;
    if (selectionMode === "all_matching") setDeleteRequest({ mode: "all_matching", count: selectedCount });
    else setDeleteRequest({ mode: "ids", count: selectedIds.size, ids: [...selectedIds] });
  }
  async function deleteCompanies() {
    if (!deleteRequest) return;
    setDeleting(true); setCompanyError(""); setCompanyNotice("");
    try {
      const body = deleteRequest.mode === "ids"
        ? { ids: deleteRequest.ids }
        : { allMatching: true, search: search.trim(), filters: filters.map(({ field, operator, values, scopes }) => ({ field, operator, values, ...(scopes?.length ? { scopes } : {}) })), excludedIds: [...excludedIds] };
      const result = await api<{ deleted: number }>("/api/companies", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      setCompanyNotice(`Deleted ${formatNumber(result.deleted)} compan${result.deleted === 1 ? "y" : "ies"} from the Company database.`);
      setDeleteRequest(null); clearSelection(); onRefresh?.();
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to delete companies."); }
    finally { setDeleting(false); }
  }

  async function setCompanyIcpValidation(validated: boolean) {
    if (!clientId || !selectedCount) return;
    setUpdatingIcp(true); setCompanyError(""); setCompanyNotice("");
    try {
      const selection = selectionMode === "all_matching"
        ? { allMatching: true, search: search.trim(), filters: filters.map(({ field, operator, values, scopes }) => ({ field, operator, values, ...(scopes?.length ? { scopes } : {}) })), peopleScope, excludedIds: [...excludedIds] }
        : { companyIds: [...selectedIds] };
      const response = await api<{ result: { updated?: number; selected?: number; eligibleProspects?: number; prospectsUpdated?: number } }>(`/api/clients/${encodeURIComponent(clientId)}/companies`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: validated ? "set_icp_verified" : "clear_icp_verified", ...selection }),
      });
      const updated = Number(response.result.updated ?? 0);
      const eligibleProspects = Number(response.result.eligibleProspects ?? 0);
      const prospectNotice = validated
        ? `${formatNumber(eligibleProspects)} linked prospect${eligibleProspects === 1 ? " is" : "s are"} now eligible.`
        : `${formatNumber(eligibleProspects)} linked prospect${eligibleProspects === 1 ? " was" : "s were"} recalculated; manually verified prospects remain eligible.`;
      setCompanyNotice(`${formatNumber(updated)} compan${updated === 1 ? "y" : "ies"} ${validated ? "marked ICP verified" : "had ICP verification removed"}. ${prospectNotice}`);
      clearSelection();
      onRefresh?.();
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to update company ICP verification."); }
    finally { setUpdatingIcp(false); }
  }

  async function pushCompaniesToClient() {
    if (clientId || !pushClientId || !selectedCount) return;
    setPushing(true); setCompanyError(""); setCompanyNotice("");
    try {
      const selection = selectionMode === "all_matching"
        ? { allMatching: true, search: search.trim(), filters: filters.map(({ field, operator, values, scopes }) => ({ field, operator, values, ...(scopes?.length ? { scopes } : {}) })), peopleScope, excludedIds: [...excludedIds] }
        : { companyIds: [...selectedIds] };
      const response = await api<{ result: { selected?: number; added?: number; alreadyPresent?: number } }>(`/api/clients/${encodeURIComponent(pushClientId)}/companies`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "push", ...selection }),
      });
      const target = clients.find((client) => client.id === pushClientId)?.name ?? "the client";
      const added = Number(response.result.added ?? 0);
      const alreadyPresent = Number(response.result.alreadyPresent ?? 0);
      setCompanyNotice(`${formatNumber(added)} compan${added === 1 ? "y" : "ies"} pushed to ${target}.${alreadyPresent ? ` ${formatNumber(alreadyPresent)} already present.` : ""}`);
      clearSelection();
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to push companies to the client."); }
    finally { setPushing(false); }
  }

  async function selectCompaniesFromPaste() {
    if (!clientId || !bulkSelectValues.trim()) return;
    setBulkSelecting(true); setCompanyError(""); setCompanyNotice("");
    try {
      const response = await api<{ companyIds: string[]; matched: number; submitted: number; truncated: boolean }>(`/api/clients/${encodeURIComponent(clientId)}/companies`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "resolve_selection", values: bulkSelectValues }),
      });
      if (!response.companyIds.length) {
        setCompanyNotice(`No companies matched the ${formatNumber(response.submitted)} pasted value${response.submitted === 1 ? "" : "s"} in this client.`);
        return;
      }
      setSelectionMode("explicit");
      setSelectedIds(new Set(response.companyIds));
      setExcludedIds(new Set());
      setSelectionQueryKey(selectionKey);
      setBulkSelectOpen(false);
      setCompanyNotice(`${formatNumber(response.matched)} matching compan${response.matched === 1 ? "y is" : "ies are"} selected across all pages.${response.truncated ? " Only the first 20,000 pasted values were processed." : ""}`);
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to select pasted companies."); }
    finally { setBulkSelecting(false); }
  }

  // The profile and the linked people are two independent reads, and the drawer
  // shows both. Kicked off together rather than in sequence so the details are
  // not waiting behind a page of prospects that renders below them.
  const loadCompanyDetail = useCallback(async (company: Company) => {
    if (detailsByCompany[company.id]) return;
    setLoadingDetail(company.id);
    try {
      const data = await api<{ company: CompanyDetail }>(`/api/companies/${encodeURIComponent(company.id)}`);
      setDetailsByCompany((current) => ({ ...current, [company.id]: { ...company, ...data.company } }));
    } catch (caught) {
      if (!isAbortError(caught)) setCompanyError(caught instanceof Error ? caught.message : "Unable to load company details.");
    } finally { setLoadingDetail((current) => current === company.id ? "" : current); }
  }, [detailsByCompany]);

  const openCompany = useCallback(async (company: Company) => {
    setSelectedCompany(company);
    setCompanyError("");
    void loadCompanyDetail(company);
    if (prospectsByCompany[company.id] || !company.prospect_count) return;
    setLoadingCompany(company.id);
    try {
      const data = await api<{ prospects: Prospect[]; total: number }>(`/api/companies/${encodeURIComponent(company.id)}/prospects?page=1&pageSize=50${clientId ? `&clientId=${encodeURIComponent(clientId)}` : ""}`);
      setProspectsByCompany((current) => ({ ...current, [company.id]: data.prospects }));
      setProspectTotalsByCompany((current) => ({ ...current, [company.id]: data.total }));
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to load company prospects."); }
    finally { setLoadingCompany(""); }
  }, [clientId, loadCompanyDetail, prospectsByCompany]);

  async function loadMoreProspects(company: Company) {
    const existing = prospectsByCompany[company.id] ?? [];
    const nextPage = Math.floor(existing.length / 50) + 1;
    setLoadingCompany(company.id); setCompanyError("");
    try {
      const data = await api<{ prospects: Prospect[]; total: number }>(`/api/companies/${encodeURIComponent(company.id)}/prospects?page=${nextPage}&pageSize=50${clientId ? `&clientId=${encodeURIComponent(clientId)}` : ""}`);
      setProspectsByCompany((current) => {
        const combined = [...(current[company.id] ?? []), ...data.prospects];
        return { ...current, [company.id]: Array.from(new Map(combined.map((prospect) => [prospect.id, prospect])).values()) };
      });
      setProspectTotalsByCompany((current) => ({ ...current, [company.id]: data.total }));
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to load more prospects."); }
    finally { setLoadingCompany(""); }
  }

  async function openExportDialog() {
    setExportDialogOpen(true);
    if (customFieldNames !== null) return;
    try {
      const data = await api<{ fields: string[] }>("/api/companies/export-fields");
      setCustomFieldNames(data.fields ?? []);
    } catch {
      // The typed fields are the picker; the uploaded ones are extra. Failing to
      // find them is not a reason to refuse to export.
      setCustomFieldNames([]);
    }
  }

  function toggleExportField(id: string) {
    setExportFields((current) => current.includes(id) ? current.filter((field) => field !== id) : [...current, id]);
  }

  async function exportCompanies() {
    if (!exportFields.length) { setCompanyError("Choose at least one field to export."); return; }
    const names = customFieldNames ?? [];
    // A pivot cannot be frozen into a result set, so it cannot go to the
    // worker. Rather than start a download that will wedge the tab, say what
    // will work - splitting is bounded per file and needs no worker at all.
    const plan = planExport({ bytesPerRow: estimatedCompanyBytesPerRow(names, exportFields), rows: totalCapped ? null : total });
    if (peopleScope && plan.mode === "background" && exportFormat === "single") {
      setCompanyError(`${plan.reason} A people-scoped export cannot be built in the background, so choose "Split into parts" - or clear the people scope to have it built for you.`);
      return;
    }
    const controller = new AbortController();
    exportAbortRef.current = controller;
    // One id per intent, as the bulk actions use: retrying after a dropped
    // connection collects the file already being written rather than starting a
    // second identical one.
    const intent = intentKey({
      action: "export-companies",
      target: "master",
      selectionMode: companyExportScope,
      ids: [],
      extra: { search: search.trim(), filters: encodeFilters(filters), fields: exportFields, peopleScope },
    });
    const requestId = requestIdFor(intent);
    setExportingCompanies(true); setCompanyError(""); setCompanyNotice("");
    setExportProgress({ exported: 0, files: 0, phase: "downloading" });
    try {
      // The count is not known when the response headers are sent - the endpoint
      // streams - so the rows are counted from the records as they arrive, and
      // `total` here is only what the grid already believes for the progress bar.
      const result = await runCompanyExport({
        search: search.trim(),
        filters,
        peopleScope,
        websitesOnly: companyExportScope === "with_websites",
        fields: exportFields,
        customFieldNames: names,
        format: exportFormat,
        rowsPerFile: exportRowsPerFile,
        fileBaseName: `prospect-sync-companies-${companyExportScope === "with_websites" ? "with-websites" : "all"}-${new Date().toISOString().slice(0, 10)}`,
        totalRows: totalCapped ? null : total,
        requestId,
        signal: controller.signal,
        onProgress: setExportProgress,
      });
      if (result.canceled) { setCompanyNotice("Export canceled."); return; }
      // Settled: the next deliberate export of this shape is a new request.
      // Deliberately not cleared on failure, so a retry reuses the id.
      settleIntent(intent);
      setExportDialogOpen(false);
      setCompanyNotice(result.handedOff && result.plan
        ? `Built ${formatNumber(result.exported)} companies. ${backgroundExportNotice(result.plan, exportFormat)}`
        : `Exported ${formatNumber(result.exported)} ${search.trim() || filters.length || peopleScope ? "matching " : ""}companies${companyExportScope === "with_websites" ? " with websites" : ""}${result.files > 1 ? ` across ${formatNumber(result.files)} files` : ""} with ${formatNumber(exportFields.length)} selected fields.`);
    } catch (caught) {
      if (caught instanceof DOMException && caught.name === "AbortError") setCompanyNotice("Export canceled.");
      else setCompanyError(caught instanceof Error ? caught.message : "Unable to export companies.");
    } finally {
      setExportingCompanies(false); setExportProgress(null); exportAbortRef.current = null;
    }
  }

  return <section className="companies-workspace">
    <div className="section-intro company-intro"><div><p className="eyebrow">COMPANIES</p><h2>Companies already in your database.</h2><p>Open a company to see its prospects in a separate panel.</p></div><div className="company-intro-actions">{onFilters ? <button className={`outline-button filter-toggle ${filtersOpen ? "active" : ""}`} aria-pressed={filtersOpen} onClick={() => setFiltersOpen((open) => !open)}><AppIcon name="filter" size={14}/> Filters {activeFilterCount ? <span>{activeFilterCount}</span> : null}</button> : null}<MenuButton label="Actions" icon="grid" panelLabel="Company actions" align="end">{onFilters ? <button className="ds-menu-item" aria-pressed={bulkOpen} onClick={() => setBulkOpen((open) => !open)}><AppIcon name="search" size={14}/> Bulk domains{domainFilterCount ? ` (${domainFilterCount})` : ""}</button> : null}{clientId ? <button className="ds-menu-item" aria-pressed={bulkSelectOpen} onClick={() => setBulkSelectOpen((open) => !open)}><AppIcon name="check" size={14}/> Bulk select</button> : null}{!clientId ? <button className="ds-menu-item" disabled={exportingCompanies} title="Choose the company columns to export across every page" onClick={() => void openExportDialog()}><AppIcon name="download" size={14}/> {exportingCompanies ? "Exporting…" : "Export CSV"}</button> : null}<button className="ds-menu-item" title="Safely scope up to 250,000 matching companies" onClick={() => onSeePeople({ search: search.trim(), filters, limit: 250000 })}><AppIcon name="arrow" size={14}/> See these people</button></MenuButton><button className="primary" onClick={onImport}><AppIcon name="plus" size={15}/> Add from CSV</button></div></div>
    <div className="company-summary"><div className="summary-violet"><span>Companies in database</span><strong>{totalLabel}</strong><small>{totalCapped ? "Counting stopped early to keep this fast" : "Complete company directory"}</small></div><div className="summary-blue"><span>With prospect coverage</span><strong>{formatNumber(covered)}</strong><small>{total ? `${Math.round((covered / total) * 100)}% of companies` : "No companies yet"}</small></div><div className="summary-green"><span>Total linked prospects</span><strong>{formatNumber(prospectTotal)}</strong><small>Across all matching companies</small></div><p><AppIcon name="quality" size={17}/><span>Matched by normalized domain first, then company name.</span></p></div>
    {peopleScope ? <div className="cross-scope-banner" role="status"><span>Showing companies represented in your previous People DB search (safety limit: {formatNumber(peopleScope.limit)} matching people).</span><button onClick={onClearPeopleScope}>Clear people scope</button></div> : null}
    {companyError ? <div className="inline-error" role="alert">{companyError}</div> : null}
    {companyNotice ? <div className="inline-notice company-export-notice" role="status">{companyNotice}<button aria-label="Dismiss export notification" onClick={() => setCompanyNotice("")}><AppIcon name="close" size={14}/></button></div> : null}
    {clientId && bulkSelectOpen ? <div className="panel company-bulk-panel"><div className="company-bulk-panel-head"><div><strong>Select companies by website or name</strong><small>Paste one value per line. Exact normalized matches are selected across every page for this client only.</small></div><button className="company-bulk-close" aria-label="Close bulk company selection" onClick={() => setBulkSelectOpen(false)}><AppIcon name="close" size={14}/></button></div><div className="bulk-domain-paste"><label htmlFor="bulk-company-selection">Paste company websites or names</label><textarea id="bulk-company-selection" value={bulkSelectValues} placeholder={'acme.com\nGlobex Corporation\nhttps://initech.com'} onChange={(event) => setBulkSelectValues(event.target.value)}/><div className="bulk-domain-actions"><button type="button" disabled={bulkSelecting || !bulkSelectValues.trim()} onClick={() => void selectCompaniesFromPaste()}>{bulkSelecting ? "Matching…" : "Select matching companies"}</button>{bulkSelectValues ? <button type="button" className="ghost" disabled={bulkSelecting} onClick={() => setBulkSelectValues("")}>Clear pasted values</button> : null}<span className="bulk-domain-note">Up to 20,000 pasted values and 50,000 matches</span></div></div></div> : null}
    {onFilters && bulkOpen ? <div className="panel company-bulk-panel"><div className="company-bulk-panel-head"><div><strong>Filter by a list of domains</strong><small>Paste domains - each is normalized and matched against company websites. They stack with your other filters.</small></div><button className="company-bulk-close" aria-label="Close bulk domains" onClick={() => setBulkOpen(false)}><AppIcon name="close" size={14}/></button></div><BulkDomainPaste onAdd={(domains) => { onFilters(addDomainsToWebsiteFilter(filters, domains)); onPageChange(1); }} />{domainFilterCount ? <button type="button" className="company-bulk-clear" onClick={() => { onFilters(filters.filter((filter) => !(filter.field === "__website" && (filter.operator === "contains" || filter.operator === "equals")))); onPageChange(1); }}>Clear {domainFilterCount} domain{domainFilterCount === 1 ? "" : "s"}</button> : null}</div> : null}
    <div className={`people-layout ${onFilters && filtersOpen ? "" : "filters-collapsed"}`}>
    <article className="panel company-table-panel"><div className="panel-head company-panel-head"><div><h3>Company database</h3><p>Showing {formatNumber(resultStart)}–{formatNumber(resultEnd)} of {totalLabel} companies. Click any row to open its details.</p></div><span className="directory-badge">{totalLabel} total</span></div>
      {selectedCount ? <div className="bulk-bar company-bulk-bar">
        <div className="bulk-selection-summary"><strong>{formatNumber(selectedCount)} selected {selectionMode === "all_matching" ? "across all pages" : "across pages"}</strong>
        {selectionMode === "explicit" && selectedCount < total ? <button onClick={selectAllMatching}>Select all {formatNumber(total)}</button> : null}</div>
        {canDelete ? <>
          <div className="bulk-action-group bulk-action-group-primary"><select aria-label="Client to receive selected companies" value={pushClientId} disabled={pushing} onChange={(event) => setPushClientId(event.target.value)}><option value="">Choose client…</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select>
          <button className="bulk-verify" disabled={pushing || !pushClientId} onClick={() => void pushCompaniesToClient()}><AppIcon name="arrow" size={14}/> {pushing ? "Pushing…" : "Push to Client"}</button>
          </div><div className="bulk-action-group bulk-action-group-danger"><button className="row-danger bulk-delete" disabled={deleting || pushing} onClick={requestDeleteSelected}>🗑 Delete {selectionMode === "all_matching" ? formatNumber(selectedCount) : "selected"}</button></div>
        </> : <>
          <div className="bulk-action-group bulk-action-group-primary">
          <button className="bulk-verify" disabled={updatingIcp} onClick={() => void setCompanyIcpValidation(true)}><AppIcon name="check" size={14}/> Mark ICP verified</button>
          <button disabled={updatingIcp} onClick={() => void setCompanyIcpValidation(false)}><AppIcon name="close" size={14}/> Remove ICP verification</button>
          </div>
        </>}
        <button className="bulk-clear" disabled={updatingIcp || deleting || pushing} onClick={clearSelection}>Clear</button>
      </div> : null}
      {companies.length ? <><div className="table-wrap"><table className="company-table"><thead><tr>{showSelection ? <th className="select-column"><input aria-label="Select all companies on this page" title="Select all companies on this page" type="checkbox" checked={companies.length > 0 && companies.every((company) => isSelected(company.id))} onChange={togglePageSelection}/></th> : null}<th>Company</th><th>Website</th><th className="numeric-cell">Prospects</th><th className="numeric-cell">Client coverage</th><th>Added</th><th>Status</th>{clientId ? <th className="company-icp-column">ICP verified</th> : null}{canDelete ? <th className="row-detail-column">Actions</th> : null}</tr></thead><tbody>{companies.map((company) => <CompanyTableRow key={company.id} company={company} selected={isSelected(company.id)} showSelection={showSelection} canDelete={canDelete} clientScoped={Boolean(clientId)} onOpen={openCompany} onToggleSelected={toggleSelected} onDelete={deleteCompany}/>)}</tbody></table></div><div className="company-pagination"><span>Page {page} of {totalPages}</span><div><button disabled={page <= 1} onClick={() => onPageChange(page - 1)}><AppIcon name="back" size={14}/> Previous</button><button disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Next</button></div></div></> : <WorkspaceEmpty state={emptyWorkspaceState({ entity: "companies", search, filterCount: activeFilterCount, scoped: Boolean(peopleScope), clientScoped: Boolean(clientId) })} onClearSearch={onClearSearch} onClearFilters={onFilters ? () => onFilters([]) : undefined} onClearScope={onClearPeopleScope} onImport={onImport} />}
    </article>
    {onFilters && filtersOpen ? <CompanyFilterPanel filters={filters} onChange={onFilters} /> : null}
    </div>
    {selectedCompany ? <CompanyDrawer company={selectedCompany} detail={detailsByCompany[selectedCompany.id] ?? null} loadingDetail={loadingDetail === selectedCompany.id} prospects={prospectsByCompany[selectedCompany.id] ?? []} total={prospectTotalsByCompany[selectedCompany.id] ?? selectedCompany.prospect_count} loading={loadingCompany === selectedCompany.id} error={companyError} onLoadMore={() => void loadMoreProspects(selectedCompany)} onClose={() => { setSelectedCompany(null); setCompanyError(""); }} /> : null}
    {exportDialogOpen ? <div className="modal-backdrop" role="presentation"><section className="export-modal" role="dialog" aria-modal="true" aria-labelledby="company-export-title">
      <div className="export-modal-head"><div><p className="eyebrow">CSV EXPORT</p><h2 id="company-export-title">Choose companies and fields</h2><p>Only the fields checked below will be included in the download.</p></div><button aria-label="Close export dialog" disabled={exportingCompanies} onClick={() => setExportDialogOpen(false)}><AppIcon name="close" size={14}/></button></div>
      <fieldset className="export-scope"><legend>Companies to export</legend>
        <label htmlFor="company-export-all"><span className="sr-only">All matching companies</span><input id="company-export-all" type="radio" name="company-export-scope" disabled={exportingCompanies} checked={companyExportScope === "all"} onChange={() => setCompanyExportScope("all")}/><span><strong>All {search.trim() || activeFilterCount || peopleScope ? "matching " : ""}companies</strong><small>{totalLabel} records across every page</small></span></label>
        <label htmlFor="company-export-websites"><span className="sr-only">Only companies with a website</span><input id="company-export-websites" type="radio" name="company-export-scope" disabled={exportingCompanies} checked={companyExportScope === "with_websites"} onChange={() => setCompanyExportScope("with_websites")}/><span><strong>Only with websites</strong><small>Skips companies with no domain saved</small></span></label>
      </fieldset>
      <div className="export-fields-head"><div><strong>Fields to include</strong><span>{formatNumber(exportFields.length)} selected{exportBytes === null ? "" : ` · roughly ${megabytes(exportBytes)} MB`}</span></div><div><button disabled={exportingCompanies} onClick={() => setExportFields(exportFieldCatalog.map((field) => field.id))}>Select all</button><button disabled={exportingCompanies} onClick={() => setExportFields(defaultCompanyExportFields)}>Recommended</button><button disabled={exportingCompanies} onClick={() => setExportFields([])}>Clear</button></div></div>
      <div className="export-field-grid">{exportFieldCatalog.map((field) => <label key={field.id}><input type="checkbox" disabled={exportingCompanies} checked={exportFields.includes(field.id)} onChange={() => toggleExportField(field.id)}/><span>{field.label}</span></label>)}</div>
      <fieldset className="export-scope export-format"><legend>Output</legend>
        <label htmlFor="company-export-single"><span className="sr-only">Single CSV file</span><input id="company-export-single" type="radio" name="company-export-format" checked={exportFormat === "single"} disabled={exportingCompanies} onChange={() => setExportFormat("single")}/><span><strong>One CSV file</strong><small>Everything in a single download, any size</small></span></label>
        <label htmlFor="company-export-parts"><span className="sr-only">Split into multiple files</span><input id="company-export-parts" type="radio" name="company-export-format" checked={exportFormat === "parts"} disabled={exportingCompanies} onChange={() => setExportFormat("parts")}/><span><strong>Split into parts</strong><small>Multiple CSVs of <select aria-label="Rows per file" disabled={exportingCompanies || exportFormat !== "parts"} value={exportRowsPerFile} onClick={(event) => event.stopPropagation()} onChange={(event) => setExportRowsPerFile(Number(event.target.value))}>{[10000, 25000, 50000, 100000].map((size) => <option key={size} value={size}>{formatNumber(size)}</option>)}</select> rows each</small></span></label>
      </fieldset>
      {/* The Blob fallback holds the whole file before it writes a byte, so a
          browser without the File System Access API is the one place where the
          size estimate is a warning rather than a note. */}
      {!fileSystemAccessSupported() ? <p className="export-hint">Your browser will download the file{exportFormat === "parts" ? "s" : ""} when the export finishes{exportBytes !== null && exportBytes > 25 * 1024 * 1024 ? `, holding roughly ${megabytes(exportBytes)} MB in memory first - a Chromium browser writes straight to disk instead` : ""}.</p> : null}
      {exportProgress ? <div className="export-progress" role="status"><span className="export-progress-bar"><i style={{ width: `${exportProgress.total ? Math.min(100, Math.round((exportProgress.exported / Math.max(1, exportProgress.total)) * 100)) : 100}%` }}/></span><span>Exported {formatNumber(exportProgress.exported)}{exportProgress.total ? ` of ${formatNumber(exportProgress.total)}` : ""} companies</span></div> : null}
      <div className="modal-actions">{exportingCompanies ? <button className="secondary" onClick={() => exportAbortRef.current?.abort()}>Cancel export</button> : <button className="secondary" onClick={() => setExportDialogOpen(false)}>Close</button>}<button className="primary" disabled={exportingCompanies || !exportFields.length} onClick={() => void exportCompanies()}>{exportingCompanies ? "Exporting…" : `Export ${totalLabel} companies`}</button></div>
    </section></div> : null}
    {deleteRequest ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="company-delete-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="company-delete-title">Delete {formatNumber(deleteRequest.count)} {deleteRequest.count === 1 ? "company" : "companies"}?</h2><p>This permanently removes {deleteRequest.count === 1 ? "this company" : "these companies"} from the Company database. Any linked people stay in the People database - they just lose the company link. This cannot be undone.</p>{deleteRequest.mode === "all_matching" && !search.trim() && !filters.length && !excludedIds.size ? <p className="form-error" role="alert"><AppIcon name="warning" size={14}/> No search or filters are applied - this will empty your entire Company database.</p> : null}<div className="modal-actions"><button className="secondary" disabled={deleting} onClick={() => setDeleteRequest(null)}>Cancel</button><button className="danger-button solid" disabled={deleting} onClick={() => void deleteCompanies()}>{deleting ? "Deleting…" : `Delete ${formatNumber(deleteRequest.count)}`}</button></div></section></div> : null}
  </section>;
}

// A list of values that is usually short and occasionally enormous - one
// company in the database carries twenty-four keywords and twenty-nine
// technologies. Showing all of them pushes the linked people off the screen and
// showing six with no way to see the rest hides data the import paid for, so it
// shows six and says how many are behind the button.
function ChipList({ label, values, id }: { label: string; values: string[]; id: string }) {
  const [expanded, setExpanded] = useState(false);
  if (!values.length) return null;
  const shown = expanded ? values : values.slice(0, 6);
  return <div className="company-fact">
    <span className="company-fact-label">{label}</span>
    <div className="company-chips">
      {shown.map((value, index) => <span key={`${id}-${index}`} className="company-chip" title={value}>{value}</span>)}
      {values.length > 6 ? <button type="button" className="company-chip-more" aria-expanded={expanded} onClick={() => setExpanded((open) => !open)}>{expanded ? "Show less" : `Show all ${formatNumber(values.length)}`}</button> : null}
    </div>
  </div>;
}

function Fact({ label, value }: { label: string; value: string }) {
  if (!value.trim()) return null;
  return <div className="company-fact"><span className="company-fact-label">{label}</span><span className="company-fact-value">{value}</span></div>;
}

function employeeRangeText(detail: CompanyDetail) {
  const minimum = detail.employee_count_min ?? null;
  const maximum = detail.employee_count_max ?? null;
  if (minimum == null && maximum == null) return "";
  if (minimum != null && maximum == null) return `${formatNumber(minimum)}+ employees`;
  if (minimum === maximum) return `${formatNumber(maximum ?? 0)} employees`;
  return `${formatNumber(minimum ?? 0)}–${formatNumber(maximum ?? 0)} employees`;
}

// Uploaded keys worth showing under the typed facts.
//
// companies.all_data is the company-scoped half of the row the import read, and
// most of it is the same data as the columns above under a different spelling.
// Repeating "Industry: accounting" directly under "Industry: accounting" is
// noise, so anything whose value already appears above is dropped and only what
// is genuinely extra survives.
function extraUploadedFacts(detail: CompanyDetail) {
  const data = companyAllData(detail.all_data);
  const shown = new Set([
    detail.name, detail.domain, detail.industry, detail.short_description, detail.total_funding,
    detail.location, detail.city, detail.state, detail.country,
    detail.founded_year == null ? "" : String(detail.founded_year),
    ...(detail.keywords ?? []), ...(detail.technologies ?? []),
  ].map((value) => String(value ?? "").trim().toLocaleLowerCase()).filter(Boolean));
  return Object.entries(data)
    .map(([key, value]) => [key.trim(), String(value ?? "").trim()] as const)
    // A leading underscore is the product's own bookkeeping - _enriched_from and
    // _enriched_at, stamped by the fill-from-company enrichment - not something
    // anyone uploaded, and not a fact about the company.
    .filter(([key, value]) => key && value && !key.startsWith("_") && !shown.has(value.toLocaleLowerCase()))
    .slice(0, 12);
}

function CompanyProfile({ detail, loading }: { detail: CompanyDetail | null; loading: boolean }) {
  const [expanded, setExpanded] = useState(false);
  if (loading && !detail) return <div className="company-profile"><div className="company-prospect-loading">Loading company details…</div></div>;
  if (!detail) return null;

  const description = String(detail.short_description ?? "").trim();
  const extras = extraUploadedFacts(detail);
  const facts = [
    { label: "Industry", value: String(detail.industry ?? "") },
    { label: "Number of employees", value: employeeRangeText(detail) },
    { label: "Founding year", value: detail.founded_year == null ? "" : String(detail.founded_year) },
    { label: "Location", value: String(detail.location ?? "") || [detail.city, detail.state, detail.country].filter(Boolean).join(", ") },
    { label: "Total funding", value: String(detail.total_funding ?? "") },
    { label: "Email provider", value: String(detail.esp ?? "") },
    { label: "Provider type", value: String(detail.email_provider_type ?? "").replace(/^Unknown$/, "") },
  ];
  const keywords = (detail.keywords ?? []).map((value) => String(value ?? "").trim()).filter(Boolean);
  const technologies = (detail.technologies ?? []).map((value) => String(value ?? "").trim()).filter(Boolean);
  const empty = !description && !keywords.length && !technologies.length && !extras.length && facts.every((fact) => !fact.value.trim());

  return <section className="company-profile" aria-label="Company details">
    <div className="company-profile-head"><strong>Company details</strong><small>Everything stored about this company</small></div>
    {empty ? <p className="company-profile-empty">Nothing beyond the name and website was uploaded for this company.</p> : <>
      {description ? <div className={`company-description ${expanded ? "expanded" : ""}`}>
        <p>{description}</p>
        {description.length > 260 ? <button type="button" aria-expanded={expanded} onClick={() => setExpanded((open) => !open)}>{expanded ? "Show less" : "Show more"}</button> : null}
      </div> : null}
      <div className="company-facts">
        {facts.map((fact) => <Fact key={fact.label} label={fact.label} value={fact.value}/>)}
        <ChipList id="keyword" label="Keywords" values={keywords}/>
        <ChipList id="tech" label="Technologies" values={technologies}/>
        {extras.map(([key, value]) => <Fact key={`extra-${key}`} label={key} value={value}/>)}
      </div>
    </>}
  </section>;
}

function CompanyDrawer({ company, detail, loadingDetail, prospects, total, loading, error, onLoadMore, onClose }: { company: Company; detail: CompanyDetail | null; loadingDetail: boolean; prospects: Prospect[]; total: number; loading: boolean; error: string; onLoadMore: () => void; onClose: () => void }) {
  useEffect(() => {
    function closeOnEscape(event: globalThis.KeyboardEvent) { if (event.key === "Escape") onClose(); }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);

  return <div className="drawer-backdrop">
    <button className="drawer-dismiss" aria-label="Close company details" onClick={onClose}/>
    <aside className="drawer company-drawer" role="dialog" aria-modal="true" aria-labelledby="company-drawer-title">
      <div className="company-drawer-header">
        <button className="drawer-close" aria-label="Close company details" onClick={onClose}><AppIcon name="close" size={14}/></button>
        <div className="drawer-person company-drawer-identity"><span className={`tone-${colorTone(company.id)}`}>{initials(company.name)}</span><div><p className="eyebrow">COMPANY DETAILS</p><h2 id="company-drawer-title">{company.name || company.domain || "Unnamed company"}</h2>{company.domain ? <a href={`https://${company.domain}`} target="_blank" rel="noreferrer">{company.domain}</a> : <p>No website saved</p>}</div></div>
        <div className="drawer-summary"><span><b>{formatNumber(company.prospect_count)}</b>prospects</span><span><b>{formatNumber(company.client_count)}</b>clients</span><span><b>{new Date(company.created_at).toLocaleDateString("en-IN", { month: "short", year: "numeric" })}</b>added</span></div>
      </div>
      <div className="company-drawer-body">
        <CompanyProfile detail={detail} loading={loadingDetail}/>
        <div className="company-drawer-title"><div><strong>Linked prospects</strong><small>People connected to this company</small></div><span>{formatNumber(prospects.length)} of {formatNumber(total)}</span></div>
        {loading && !prospects.length ? <div className="company-prospect-loading">Loading prospects…</div> : prospects.length ? <><div className="company-prospect-list"><table><thead><tr><th>Name</th><th>Title</th><th>Email</th><th>Seniority</th><th>Location</th></tr></thead><tbody>{prospects.map((prospect) => <tr key={prospect.id}><td><div className="compact-person"><span className={`tone-${colorTone(prospect.id)}`}>{initials(prospect.full_name)}</span><strong>{prospect.full_name || "Unnamed prospect"}</strong></div></td><td>{prospect.title || "-"}</td><td>{prospect.work_email || prospect.personal_email || "-"}</td><td>{String(prospect.seniority || "-")}</td><td>{[prospect.city, prospect.country].filter(Boolean).join(", ") || "-"}</td></tr>)}</tbody></table></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{prospects.length < total ? <button className="load-more-prospects" disabled={loading} onClick={onLoadMore}>{loading ? "Loading…" : `Load ${Math.min(50, total - prospects.length)} more prospects (${formatNumber(total - prospects.length)} remaining)`}</button> : <div className="all-prospects-loaded"><AppIcon name="check" size={14}/> All {formatNumber(total)} prospects loaded</div>}</> : error ? <div className="inline-error" role="alert">{error}</div> : <div className="drawer-empty">No linked prospects found.</div>}
      </div>
    </aside>
  </div>;
}
