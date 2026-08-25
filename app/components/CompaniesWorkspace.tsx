"use client";

import { useCallback, useDeferredValue, useEffect, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import CompanyFilterPanel, { BulkDomainPaste, addDomainsToWebsiteFilter } from "../CompanyFilterPanel";
import { api, companyApiPath, encodeFilters, isAbortError } from "../../lib/dashboard-api";
import { colorTone, formatNumber, initials } from "../../lib/dashboard-helpers";
import type { Company, Prospect, ProspectFilter } from "../../lib/types";
import { AppIcon, EmptyState } from "./DashboardUi";
import CompanyTableRow from "./CompanyTableRow";
import { useDebouncedValue } from "./useDebouncedValue";

export function useCompaniesWorkspaceController({ active, search, filters, peopleScope, onLoading, onError }: { active: boolean; search: string; filters: ProspectFilter[]; peopleScope: PeopleScope | null; onLoading: (loading: boolean) => void; onError: (error: string) => void }) {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [page, setPage] = useState(1);
  const [summary, setSummary] = useState({ total: 0, covered: 0, prospectTotal: 0, pageSize: 50 });
  const [refresh, setRefresh] = useState(0);
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (!active) return () => { current = false; controller.abort(); };
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      onLoading(true); onError("");
      try {
        const data = await api<{ companies: Company[]; total: number; covered: number; prospectTotal: number; pageSize: number }>(companyApiPath({ search: debouncedSearch, page, filters, peopleScope }), { signal: controller.signal });
        if (current) { setCompanies(data.companies); setSummary({ total: data.total, covered: data.covered, prospectTotal: data.prospectTotal, pageSize: data.pageSize }); }
      } catch (caught) { if (current && !isAbortError(caught)) onError(caught instanceof Error ? caught.message : "Unable to load workspace data."); }
      finally { if (current) onLoading(false); }
    })();
    return () => { current = false; controller.abort(); };
  }, [active, deferredSearch, debouncedSearch, page, filters, refresh, peopleScope, onError, onLoading]);

  const refreshWorkspace = useCallback(() => setRefresh((current) => current + 1), []);
  return { companies, page, setPage, summary, deferredSearch, refreshWorkspace };
}

export default function CompaniesWorkspace({ controller, filters, peopleScope, onClearPeopleScope, onSeePeople, onFilters, onImport }: { controller: ReturnType<typeof useCompaniesWorkspaceController>; filters: ProspectFilter[]; peopleScope: PeopleScope | null; onClearPeopleScope: () => void; onSeePeople: (scope: CompanyScope) => void; onFilters: (filters: ProspectFilter[]) => void; onImport: () => void }) {
  const handleFilters = useCallback((next: ProspectFilter[]) => { onFilters(next); controller.setPage(1); }, [controller, onFilters]);
  return <CompanyTable companies={controller.companies} total={controller.summary.total} covered={controller.summary.covered} prospectTotal={controller.summary.prospectTotal} page={controller.page} pageSize={controller.summary.pageSize} search={controller.deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onSeePeople={onSeePeople} onFilters={handleFilters} onPageChange={controller.setPage} onImport={onImport} onRefresh={controller.refreshWorkspace}/>;
}

export function CompanyTable({ companies, total, covered, prospectTotal, page, pageSize, clientId = "", search = "", filters = [], peopleScope = null, onClearPeopleScope, onSeePeople, onFilters, onPageChange, onImport, onRefresh }: { companies: Company[]; total: number; covered: number; prospectTotal: number; page: number; pageSize: number; clientId?: string; search?: string; filters?: ProspectFilter[]; peopleScope?: PeopleScope | null; onClearPeopleScope?: () => void; onSeePeople: (scope: CompanyScope) => void; onFilters?: (filters: ProspectFilter[]) => void; onPageChange: (page: number) => void; onImport: () => void; onRefresh?: () => void }) {
  const [selectedCompany, setSelectedCompany] = useState<Company | null>(null);
  const [prospectsByCompany, setProspectsByCompany] = useState<Record<string, Prospect[]>>({});
  const [prospectTotalsByCompany, setProspectTotalsByCompany] = useState<Record<string, number>>({});
  const [loadingCompany, setLoadingCompany] = useState("");
  const [companyError, setCompanyError] = useState("");
  const [companyNotice, setCompanyNotice] = useState("");
  const [exportingCompanies, setExportingCompanies] = useState(false);
  const [companyExportScope, setCompanyExportScope] = useState<"all" | "with_websites">("all");
  const [filtersOpen, setFiltersOpen] = useState(true);
  const [bulkOpen, setBulkOpen] = useState(false);
  const activeFilterCount = filters.reduce((count, filter) => count + (filter.operator === "empty" || filter.operator === "not_empty" ? 1 : filter.values.length), 0);
  const domainFilterCount = filters.filter((filter) => filter.field === "__website" && (filter.operator === "contains" || filter.operator === "equals")).reduce((count, filter) => count + filter.values.length, 0);
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const resultStart = total ? (page - 1) * pageSize + 1 : 0;
  const resultEnd = Math.min(page * pageSize, total);

  // Deleting companies is offered only on the main Company DB, never a client-scoped view.
  const canDelete = !clientId;
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [selectionMode, setSelectionMode] = useState<"explicit" | "all_matching">("explicit");
  const [excludedIds, setExcludedIds] = useState<Set<string>>(new Set());
  const [selectionQueryKey, setSelectionQueryKey] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<{ mode: "ids" | "all_matching"; count: number; ids?: string[] } | null>(null);
  const [deleting, setDeleting] = useState(false);
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

  const openCompany = useCallback(async (company: Company) => {
    setSelectedCompany(company);
    setCompanyError("");
    if (prospectsByCompany[company.id] || !company.prospect_count) return;
    setLoadingCompany(company.id);
    try {
      const data = await api<{ prospects: Prospect[]; total: number }>(`/api/companies/${encodeURIComponent(company.id)}/prospects?page=1&pageSize=50${clientId ? `&clientId=${encodeURIComponent(clientId)}` : ""}`);
      setProspectsByCompany((current) => ({ ...current, [company.id]: data.prospects }));
      setProspectTotalsByCompany((current) => ({ ...current, [company.id]: data.total }));
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to load company prospects."); }
    finally { setLoadingCompany(""); }
  }, [clientId, prospectsByCompany]);

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

  async function exportCompanies() {
    setExportingCompanies(true); setCompanyError(""); setCompanyNotice("");
    try {
      const params = new URLSearchParams({ export: "csv" });
      if (search.trim()) params.set("search", search.trim());
      if (companyExportScope === "with_websites") params.set("website", "required");
      if (filters.length) params.set("filters", encodeFilters(filters));
      if (peopleScope) params.set("peopleScope", JSON.stringify(peopleScope));
      const response = await fetch(`/api/companies?${params.toString()}`);
      if (!response.ok) {
        const body = await response.json().catch(() => ({ error: "Unable to export companies." })) as { error?: string };
        throw new Error(body.error || "Unable to export companies.");
      }
      const blobUrl = URL.createObjectURL(await response.blob());
      const link = document.createElement("a");
      link.href = blobUrl;
      link.download = `prospect-sync-companies-${companyExportScope === "with_websites" ? "with-websites" : "all"}-${new Date().toISOString().slice(0, 10)}.csv`;
      link.click();
      URL.revokeObjectURL(blobUrl);
      const exported = Number(response.headers.get("X-Exported-Rows") ?? 0);
      setCompanyNotice(`Exported ${formatNumber(exported)} ${search.trim() || filters.length || peopleScope ? "matching " : ""}companies${companyExportScope === "with_websites" ? " with websites" : ""}.`);
    } catch (caught) { setCompanyError(caught instanceof Error ? caught.message : "Unable to export companies."); }
    finally { setExportingCompanies(false); }
  }

  return <section className="companies-workspace">
    <div className="section-intro company-intro"><div><p className="eyebrow">COMPANIES</p><h2>Companies already in your database.</h2><p>Open a company to see its prospects in a separate panel.</p></div><div className="company-intro-actions">{!clientId ? <div className="company-export-control"><label><span>Export scope</span><select aria-label="Company export scope" value={companyExportScope} disabled={exportingCompanies} onChange={(event) => setCompanyExportScope(event.target.value as "all" | "with_websites")}><option value="all">All companies</option><option value="with_websites">Only with websites</option></select></label><button className="secondary company-export-button" disabled={exportingCompanies} title="Export all matching companies across every page" onClick={() => void exportCompanies()}>{exportingCompanies ? "Exporting…" : "Export CSV"}</button></div> : null}{onFilters ? <button className={`secondary filter-toggle ${filtersOpen ? "active" : ""}`} aria-pressed={filtersOpen} onClick={() => setFiltersOpen((open) => !open)}><AppIcon name="filter" size={14}/> Filters {activeFilterCount ? <span>{activeFilterCount}</span> : null}</button> : null}{onFilters ? <button className={`secondary filter-toggle ${bulkOpen ? "active" : ""}`} aria-pressed={bulkOpen} onClick={() => setBulkOpen((open) => !open)}><AppIcon name="search" size={14}/> Bulk domains {domainFilterCount ? <span>{domainFilterCount}</span> : null}</button> : null}<button className="secondary" onClick={() => onSeePeople({ search: search.trim(), filters })}>See People <AppIcon name="arrow" size={14}/></button><button className="primary" onClick={onImport}><AppIcon name="plus" size={15}/> Add from CSV</button></div></div>
    <div className="company-summary"><div className="summary-violet"><span>Companies in database</span><strong>{formatNumber(total)}</strong><small>Complete company directory</small></div><div className="summary-blue"><span>With prospect coverage</span><strong>{formatNumber(covered)}</strong><small>{total ? `${Math.round((covered / total) * 100)}% of companies` : "No companies yet"}</small></div><div className="summary-green"><span>Total linked prospects</span><strong>{formatNumber(prospectTotal)}</strong><small>Across all matching companies</small></div><p><AppIcon name="quality" size={17}/><span>Matched by normalized domain first, then company name.</span></p></div>
    {peopleScope ? <div className="cross-scope-banner" role="status"><span>Showing companies represented in your previous People DB search.</span><button onClick={onClearPeopleScope}>Clear people scope</button></div> : null}
    {companyError ? <div className="inline-error" role="alert">{companyError}</div> : null}
    {companyNotice ? <div className="inline-notice company-export-notice" role="status">{companyNotice}<button aria-label="Dismiss export notification" onClick={() => setCompanyNotice("")}><AppIcon name="close" size={14}/></button></div> : null}
    {onFilters && bulkOpen ? <div className="panel company-bulk-panel"><div className="company-bulk-panel-head"><div><strong>Filter by a list of domains</strong><small>Paste domains — each is normalized and matched against company websites. They stack with your other filters.</small></div><button className="company-bulk-close" aria-label="Close bulk domains" onClick={() => setBulkOpen(false)}><AppIcon name="close" size={14}/></button></div><BulkDomainPaste onAdd={(domains) => { onFilters(addDomainsToWebsiteFilter(filters, domains)); onPageChange(1); }} />{domainFilterCount ? <button type="button" className="company-bulk-clear" onClick={() => { onFilters(filters.filter((filter) => !(filter.field === "__website" && (filter.operator === "contains" || filter.operator === "equals")))); onPageChange(1); }}>Clear {domainFilterCount} domain{domainFilterCount === 1 ? "" : "s"}</button> : null}</div> : null}
    <div className={`people-layout ${onFilters && filtersOpen ? "" : "filters-collapsed"}`}>
    <article className="panel company-table-panel"><div className="panel-head company-panel-head"><div><h3>Company database</h3><p>Showing {formatNumber(resultStart)}–{formatNumber(resultEnd)} of {formatNumber(total)} companies. Click any row to open its details.</p></div><span className="directory-badge">{formatNumber(total)} total</span></div>{canDelete && selectedCount ? <div className="bulk-bar company-bulk-bar"><strong>{formatNumber(selectedCount)} selected {selectionMode === "all_matching" ? "across all pages" : "across pages"}</strong>{selectionMode === "explicit" && selectedCount < total ? <button onClick={selectAllMatching}>Select all {formatNumber(total)}</button> : null}<button className="row-danger bulk-delete" disabled={deleting} onClick={requestDeleteSelected}>🗑 Delete {selectionMode === "all_matching" ? formatNumber(selectedCount) : "selected"}</button><button onClick={clearSelection}>Clear</button></div> : null}{companies.length ? <><div className="table-wrap"><table className="company-table"><thead><tr>{canDelete ? <th className="select-column"><input aria-label="Select all companies on this page" title="Select all companies on this page" type="checkbox" checked={companies.length > 0 && companies.every((company) => isSelected(company.id))} onChange={togglePageSelection}/></th> : null}<th>Company</th><th>Website</th><th>Prospects</th><th>Client coverage</th><th>Added</th><th>Status</th>{canDelete ? <th className="row-detail-column">Actions</th> : null}</tr></thead><tbody>{companies.map((company) => <CompanyTableRow key={company.id} company={company} selected={isSelected(company.id)} canDelete={canDelete} onOpen={openCompany} onToggleSelected={toggleSelected} onDelete={deleteCompany}/>)}</tbody></table></div><div className="company-pagination"><span>Page {page} of {totalPages}</span><div><button disabled={page <= 1} onClick={() => onPageChange(page - 1)}><AppIcon name="back" size={14}/> Previous</button><button disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Next</button></div></div></> : <EmptyState title="No known companies yet" text="Companies found in imported lists will appear here automatically." action="Import CSV" onAction={onImport} />}</article>
    {onFilters && filtersOpen ? <CompanyFilterPanel filters={filters} onChange={onFilters} /> : null}
    </div>
    {selectedCompany ? <CompanyDrawer company={selectedCompany} prospects={prospectsByCompany[selectedCompany.id] ?? []} total={prospectTotalsByCompany[selectedCompany.id] ?? selectedCompany.prospect_count} loading={loadingCompany === selectedCompany.id} error={companyError} onLoadMore={() => void loadMoreProspects(selectedCompany)} onClose={() => { setSelectedCompany(null); setCompanyError(""); }} /> : null}
    {deleteRequest ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="company-delete-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="company-delete-title">Delete {formatNumber(deleteRequest.count)} {deleteRequest.count === 1 ? "company" : "companies"}?</h2><p>This permanently removes {deleteRequest.count === 1 ? "this company" : "these companies"} from the Company database. Any linked people stay in the People database — they just lose the company link. This cannot be undone.</p>{deleteRequest.mode === "all_matching" && !search.trim() && !filters.length && !excludedIds.size ? <p className="form-error" role="alert"><AppIcon name="warning" size={14}/> No search or filters are applied — this will empty your entire Company database.</p> : null}<div className="modal-actions"><button className="secondary" disabled={deleting} onClick={() => setDeleteRequest(null)}>Cancel</button><button className="danger-button solid" disabled={deleting} onClick={() => void deleteCompanies()}>{deleting ? "Deleting…" : `Delete ${formatNumber(deleteRequest.count)}`}</button></div></section></div> : null}
  </section>;
}

function CompanyDrawer({ company, prospects, total, loading, error, onLoadMore, onClose }: { company: Company; prospects: Prospect[]; total: number; loading: boolean; error: string; onLoadMore: () => void; onClose: () => void }) {
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
        <div className="company-drawer-title"><div><strong>Linked prospects</strong><small>People connected to this company</small></div><span>{formatNumber(prospects.length)} of {formatNumber(total)}</span></div>
      </div>
      <div className="company-drawer-body">
        {loading && !prospects.length ? <div className="company-prospect-loading">Loading prospects…</div> : prospects.length ? <><div className="company-prospect-list"><table><thead><tr><th>Name</th><th>Title</th><th>Email</th><th>Seniority</th><th>Location</th></tr></thead><tbody>{prospects.map((prospect) => <tr key={prospect.id}><td><div className="compact-person"><span className={`tone-${colorTone(prospect.id)}`}>{initials(prospect.full_name)}</span><strong>{prospect.full_name || "Unnamed prospect"}</strong></div></td><td>{prospect.title || "-"}</td><td>{prospect.work_email || prospect.personal_email || "-"}</td><td>{String(prospect.seniority || "-")}</td><td>{[prospect.city, prospect.country].filter(Boolean).join(", ") || "-"}</td></tr>)}</tbody></table></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{prospects.length < total ? <button className="load-more-prospects" disabled={loading} onClick={onLoadMore}>{loading ? "Loading…" : `Load ${Math.min(50, total - prospects.length)} more prospects (${formatNumber(total - prospects.length)} remaining)`}</button> : <div className="all-prospects-loaded"><AppIcon name="check" size={14}/> All {formatNumber(total)} prospects loaded</div>}</> : error ? <div className="inline-error" role="alert">{error}</div> : <div className="drawer-empty">No linked prospects found.</div>}
      </div>
    </aside>
  </div>;
}
