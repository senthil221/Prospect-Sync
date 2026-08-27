"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import ApolloFilterPanel, { filterLabel } from "../ApolloFilterPanel";
import { fileSystemAccessSupported, runProspectExport, type ExportFormat } from "../../lib/export-runner";
import { buildCustomFieldDefinitions } from "../../lib/prospect-fields";
import { api, filterPayload } from "../../lib/dashboard-api";
import { filterChipValue, formatNumber } from "../../lib/dashboard-helpers";
import { defaultProspectColumns, defaultProspectExportFields, standardProspectExportFields, standardProspectFields } from "../../lib/prospect-field-definitions";
import type { ClientRecord, Prospect, ProspectFilter, SavedView } from "../../lib/types";
import { useDismiss } from "../use-dismiss";
import { AppIcon, EmptyState } from "./DashboardUi";
import ProspectTableRow from "./ProspectTableRow";
import Tabs from "./Tabs";
import TitleClassifierPanel from "./TitleClassifierPanel";

const DENSITIES = ["compact", "default", "comfortable"] as const;
type Density = (typeof DENSITIES)[number];
const DENSITY_LABEL: Record<Density, string> = { compact: "Compact rows", default: "Default rows", comfortable: "Comfortable rows" };

export default function ProspectTable({ prospects, total, totalEstimated = false, fields, filters, page, clients, search = "", sort, direction, clientId = "", active = true, companyScope = null, onClearCompanyScope, onSeeCompanies, onRemoveFromClient, onSortChange, onFiltersChange, onPageChange, onSelect, onImport, onRefresh }: { prospects: Prospect[]; total: number; totalEstimated?: boolean; fields: string[]; filters: ProspectFilter[]; page: number; clients: ClientRecord[]; search?: string; sort: string; direction: "asc" | "desc"; clientId?: string; active?: boolean; companyScope?: CompanyScope | null; onClearCompanyScope?: () => void; onSeeCompanies: (scope: PeopleScope) => void; onRemoveFromClient?: (prospect: Prospect) => Promise<void>; onSortChange: (sort: string, direction: "asc" | "desc") => void; onFiltersChange: (filters: ProspectFilter[]) => void; onPageChange: (page: number) => void; onSelect: (row: Prospect) => void; onImport: () => void; onRefresh: () => void }) {
  const [visibleColumns, setVisibleColumns] = useState<string[]>(defaultProspectColumns);
  const [columnMenu, setColumnMenu] = useState(false);
  const columnMenuRef = useRef<HTMLDivElement>(null);
  useDismiss(columnMenuRef, () => setColumnMenu(false), columnMenu);
  const [tab, setTab] = useState<"records" | "coverage" | "titles">("records");
  const [classifierGaps, setClassifierGaps] = useState<number | null>(null);
  // Row density is a viewing preference, not data — it persists per browser.
  const [density, setDensity] = useState<Density>("default");
  const [tableScrollWidth, setTableScrollWidth] = useState(0);
  const topScrollRef = useRef<HTMLDivElement>(null);
  const tableScrollRef = useRef<HTMLDivElement>(null);
  const [selectedRows, setSelectedRows] = useState<Map<string, Prospect>>(new Map());
  const selectedIds = useMemo(() => new Set(selectedRows.keys()), [selectedRows]);
  const [selectionMode, setSelectionMode] = useState<"explicit" | "all_matching">("explicit");
  const [excludedIds, setExcludedIds] = useState<Set<string>>(new Set());
  const [selectionQueryKey, setSelectionQueryKey] = useState("");
  const [savedViews, setSavedViews] = useState<SavedView[]>([]);
  const [bulkClientId, setBulkClientId] = useState("");
  const [pushClientId, setPushClientId] = useState("");
  const [bulkBusy, setBulkBusy] = useState(false);
  const [exportingProspects, setExportingProspects] = useState(false);
  const [exportDialogOpen, setExportDialogOpen] = useState(false);
  const [exportScope, setExportScope] = useState<"all_matching" | "selected">("all_matching");
  const [exportFields, setExportFields] = useState<string[]>(defaultProspectExportFields);
  const [exportFormat, setExportFormat] = useState<ExportFormat>("single");
  const [exportRowsPerFile, setExportRowsPerFile] = useState(50000);
  const [exportProgress, setExportProgress] = useState<{ exported: number; total?: number; files: number } | null>(null);
  const exportAbortRef = useRef<AbortController | null>(null);
  const [espScanning, setEspScanning] = useState(false);
  const [notice, setNotice] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<{ mode: "ids" | "all_matching"; count: number; ids?: string[] } | null>(null);
  const [deletingProspects, setDeletingProspects] = useState(false);
  const [filtersOpen, setFiltersOpen] = useState(true);
  // Deleting from the master People DB is only offered on the main tab, never a client-scoped view.
  const canDeleteMaster = !clientId;
  const allCustomFields = useMemo(() => buildCustomFieldDefinitions(fields), [fields]);
  // Only Industry (and the mandatory Sub Departments) survive in the People filters/columns;
  // every other imported column is dropped from the panel and picker.
  const customFields = useMemo(() => allCustomFields.filter((field) => ["custom:industry", "custom:companyindustry", "custom:subdepartments", "custom:subdepartment"].includes(field.id)), [allCustomFields]);
  // Sub Departments is already a standard column (__sub_department), so keep only Industry among the custom columns.
  const columnCustomFields = useMemo(() => customFields.filter((field) => !["custom:subdepartments", "custom:subdepartment"].includes(field.id)), [customFields]);
  const allColumns = useMemo(() => [...standardProspectFields, ...columnCustomFields], [columnCustomFields]);
  // Export can still reach every preserved field — the trim is only for the on-screen filters/columns.
  const exportFieldCatalog = useMemo(() => [...standardProspectExportFields, ...allCustomFields], [allCustomFields]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      try {
        const saved = JSON.parse(localStorage.getItem("prospecthub-visible-columns") || "[]") as string[];
        if (Array.isArray(saved) && saved.length) {
          // Drop any columns that are no longer part of the mandatory People set
          // (e.g. previously-saved ESP/Lists/Tags) while keeping uploaded custom fields.
          const allowed = new Set(standardProspectFields.map((field) => field.id));
          const filtered = saved.filter((id) => allowed.has(id) || id.startsWith("custom:"));
          const next = filtered.length ? filtered : defaultProspectColumns;
          setVisibleColumns(next);
          localStorage.setItem("prospecthub-visible-columns", JSON.stringify(next));
        }
      } catch { /* Keep the standard columns. */ }
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    // Deferred like the column preference above: localStorage is not readable
    // during the server render, so the restore has to happen after mount.
    const timer = window.setTimeout(() => {
      const stored = localStorage.getItem("prospecthub-row-density");
      if (stored && (DENSITIES as readonly string[]).includes(stored)) setDensity(stored as Density);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  function cycleDensity() {
    setDensity((current) => {
      const next = DENSITIES[(DENSITIES.indexOf(current) + 1) % DENSITIES.length];
      localStorage.setItem("prospecthub-row-density", next);
      return next;
    });
  }

  useEffect(() => {
    void api<{ views: SavedView[] }>("/api/saved-views").then((data) => setSavedViews(data.views)).catch(() => setSavedViews([]));
  }, []);

  function toggleColumn(id: string) {
    setVisibleColumns((current) => {
      const next = current.includes(id) ? current.filter((field) => field !== id) : [...current, id];
      const safe = next.length ? next : ["__name"];
      localStorage.setItem("prospecthub-visible-columns", JSON.stringify(safe));
      return safe;
    });
  }

  function updateFilter(id: string, patch: Partial<ProspectFilter>) {
    onFiltersChange(filters.map((filter) => filter.id === id ? { ...filter, ...patch } : filter));
  }

  const configuredDefinitions = useMemo(() => visibleColumns.map((id) => allColumns.find((column) => column.id === id)).filter((column): column is { id: string; label: string } => Boolean(column)), [allColumns, visibleColumns]);
  const visibleDefinitions = useMemo(() => configuredDefinitions.length ? configuredDefinitions : standardProspectFields.slice(0, 4), [configuredDefinitions]);
  const effectiveFilters = filters.filter((filter) => filter.values.length || filter.operator === "empty" || filter.operator === "not_empty");
  const selectionKey = JSON.stringify({ clientId, search: search.trim(), filters: filterPayload(effectiveFilters) });
  const selectionMatchesQuery = selectionQueryKey === selectionKey;
  const selectedCount = !selectionMatchesQuery ? 0 : selectionMode === "all_matching" ? Math.max(0, total - excludedIds.size) : selectedIds.size;
  const totalPages = Math.max(1, Math.ceil(total / 50));
  const firstRecord = total ? (page - 1) * 50 + 1 : 0;
  const lastRecord = Math.min(page * 50, total);
  const displayedTotal = `${totalEstimated ? "≈" : ""}${formatNumber(total)}`;
  // The unfiltered People DB total comes from PostgreSQL's maintained row estimate
  // rather than a full count, so it can drift by a fraction of a percent until the
  // next autovacuum. Anything narrower than the whole database is counted exactly
  // and loses the "≈" -- say which of the two you are looking at.
  const totalHint = totalEstimated
    ? "Approximate: the whole-database total is PostgreSQL's maintained row estimate, so no full table count runs on every page load. Search or filter and the count becomes exact."
    : "Exact count of the records matching this search and these filters.";

  useEffect(() => {
    if (!active) return;
    const scrollArea = tableScrollRef.current;
    const table = scrollArea?.querySelector("table");
    if (!scrollArea || !table) return;
    const measure = () => setTableScrollWidth(table.scrollWidth);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(table);
    return () => observer.disconnect();
  }, [prospects, visibleDefinitions.length, active]);

  function syncHorizontalScroll(source: HTMLDivElement, target: HTMLDivElement | null) {
    if (target && Math.abs(target.scrollLeft - source.scrollLeft) > 1) target.scrollLeft = source.scrollLeft;
  }

  function clearSelection() {
    setSelectionMode("explicit");
    setSelectedRows(new Map());
    setExcludedIds(new Set());
    setSelectionQueryKey(selectionKey);
  }

  function selectAllMatching() {
    setSelectionMode("all_matching");
    setSelectedRows(new Map());
    setExcludedIds(new Set());
    setSelectionQueryKey(selectionKey);
  }

  function isProspectSelected(id: string) {
    if (!selectionMatchesQuery) return false;
    return selectionMode === "all_matching" ? !excludedIds.has(id) : selectedIds.has(id);
  }

  const toggleSelected = useCallback((id: string) => {
    const prospect = prospects.find((row) => row.id === id);
    if (!prospect) return;
    if (!selectionMatchesQuery) {
      setSelectionMode("explicit");
      setSelectedRows(new Map([[id, prospect]]));
      setExcludedIds(new Set());
      setSelectionQueryKey(selectionKey);
      return;
    }
    if (selectionMode === "all_matching") {
      setExcludedIds((current) => {
        const next = new Set(current);
        if (next.has(id)) next.delete(id); else next.add(id);
        return next;
      });
      return;
    }
    setSelectedRows((current) => {
      const next = new Map(current);
      if (next.has(id)) next.delete(id); else next.set(id, prospect);
      return next;
    });
  }, [prospects, selectionKey, selectionMatchesQuery, selectionMode]);

  const deleteProspect = useCallback((id: string) => {
    setDeleteRequest({ mode: "ids", count: 1, ids: [id] });
  }, []);

  function togglePageSelection() {
    const pageIds = prospects.map((prospect) => prospect.id);
    const allSelected = pageIds.length > 0 && pageIds.every(isProspectSelected);
    if (!selectionMatchesQuery || selectionMode === "explicit") {
      setSelectionMode("explicit");
      setExcludedIds(new Set());
      setSelectionQueryKey(selectionKey);
      setSelectedRows((current) => {
        const next = selectionMatchesQuery ? new Map(current) : new Map<string, Prospect>();
        prospects.forEach((prospect) => allSelected ? next.delete(prospect.id) : next.set(prospect.id, prospect));
        return next;
      });
      return;
    }
    setExcludedIds((current) => {
      const next = new Set(current);
      pageIds.forEach((id) => allSelected ? next.add(id) : next.delete(id));
      return next;
    });
  }

  function openExportDialog(scope: "all_matching" | "selected") {
    if (scope === "selected" && !selectedCount) return;
    const visibleExportFields = visibleColumns.flatMap((field) => field === "__email" ? ["__work_email"] : standardProspectExportFields.some((item) => item.id === field) || field.startsWith("custom:") ? [field] : []);
    setExportFields(visibleExportFields.length ? [...new Set(visibleExportFields)] : defaultProspectExportFields);
    setExportScope(scope);
    setExportDialogOpen(true);
  }

  function toggleExportField(id: string) {
    setExportFields((current) => current.includes(id) ? current.filter((field) => field !== id) : [...current, id]);
  }

  function cancelExport() {
    exportAbortRef.current?.abort();
  }

  async function exportProspectsCsv() {
    if (!exportFields.length) { setNotice("Choose at least one field to export."); return; }
    if (exportScope === "selected" && !selectedCount) { setNotice("Select at least one prospect to export."); return; }
    // Explicit row picks are already in memory — export them without any server round-trip.
    const useSelectedRows = exportScope === "selected" && selectionMode === "explicit";
    const controller = new AbortController();
    exportAbortRef.current = controller;
    setExportingProspects(true); setNotice(""); setExportProgress({ exported: 0, files: 0 });
    try {
      const result = await runProspectExport({
        search: search.trim(),
        filters: filterPayload(effectiveFilters),
        clientId: clientId || null,
        companyScope,
        fields: exportFields,
        customFieldNames: fields,
        mode: useSelectedRows ? "selected" : "all_matching",
        selectedRows: useSelectedRows ? [...selectedRows.values()] : undefined,
        excludedIds: exportScope === "selected" && selectionMode === "all_matching" ? [...excludedIds] : [],
        format: exportFormat,
        rowsPerFile: exportRowsPerFile,
        fileBaseName: `prospect-sync-prospects-${exportScope === "selected" ? "selected" : clientId ? "client" : "all"}-${new Date().toISOString().slice(0, 10)}`,
        signal: controller.signal,
        onProgress: setExportProgress,
      });
      if (result.canceled) { setNotice("Export canceled."); }
      else {
        setExportDialogOpen(false);
        setNotice(`Exported ${formatNumber(result.exported)} prospects${result.files > 1 ? ` across ${formatNumber(result.files)} files` : ""} with ${formatNumber(exportFields.length)} selected fields.`);
      }
    } catch (caught) {
      if (caught instanceof DOMException && caught.name === "AbortError") setNotice("Export canceled.");
      else setNotice(caught instanceof Error ? caught.message : "Unable to export prospects.");
    } finally {
      setExportingProspects(false); setExportProgress(null); exportAbortRef.current = null;
    }
  }

  async function bulkAction(action: "tag" | "mark_contacted") {
    if (!selectedCount) return;
    if (selectionMode === "all_matching") { setNotice("Export supports database-wide selection. Select individual rows for tag or contact updates."); return; }
    const tagName = action === "tag" ? window.prompt("Tag name")?.trim() : "";
    if (action === "tag" && !tagName) return;
    if (action === "mark_contacted" && !bulkClientId) { setNotice("Choose a client before marking prospects as contacted."); return; }
    setBulkBusy(true); setNotice("");
    try {
      const result = await api<{ updated: number }>("/api/operations", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, prospectIds: [...selectedIds], tagName, clientId: bulkClientId }) });
      setNotice(`${formatNumber(result.updated)} prospects updated.`); clearSelection(); onRefresh();
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "Bulk action failed."); }
    finally { setBulkBusy(false); }
  }

  // Client actions take the current selection as either explicit ids or the
  // live search/filters, so "select all 40,000 matching" is one request rather
  // than 40,000 ids — the same contract export already uses.
  function selectionPayload() {
    return selectionMode === "all_matching"
      ? { search, filters: filterPayload(effectiveFilters), excludedIds: [...excludedIds] }
      : { prospectIds: [...selectedIds] };
  }

  async function clientAction(action: "push" | "set_icp_verified" | "clear_icp_verified", targetClientId: string) {
    if (!selectedCount || !targetClientId) return;
    setBulkBusy(true); setNotice("");
    try {
      const data = await api<{ result: { added?: number; alreadyPresent?: number; blocked?: number; updated?: number; queued?: number } }>(
        `/api/clients/${encodeURIComponent(targetClientId)}/prospects`,
        { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, ...selectionPayload() }) },
      );
      const result = data.result ?? {};
      if (action === "push") {
        const parts = [`${formatNumber(Number(result.added ?? 0))} pushed`];
        if (result.alreadyPresent) parts.push(`${formatNumber(Number(result.alreadyPresent))} already there`);
        if (result.blocked) parts.push(`${formatNumber(Number(result.blocked))} skipped — blocked for this client`);
        setNotice(`${parts.join(" · ")}.`);
      } else {
        setNotice(`${formatNumber(Number(result.updated ?? 0))} prospects marked ${action === "set_icp_verified" ? "ICP verified" : "not verified"}.`);
      }
      clearSelection();
      onRefresh();
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "That action could not be completed."); }
    finally { setBulkBusy(false); }
  }

  const toggleVerified = useCallback(async (prospect: Prospect, verified: boolean) => {
    if (!clientId) return;
    try {
      await api(`/api/clients/${encodeURIComponent(clientId)}/prospects`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: verified ? "set_icp_verified" : "clear_icp_verified", prospectIds: [prospect.id] }),
      });
      onRefresh();
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "Unable to update ICP verification."); }
  }, [clientId, onRefresh]);

  function requestDeleteSelected() {
    if (!selectedCount) return;
    if (selectionMode === "all_matching") setDeleteRequest({ mode: "all_matching", count: selectedCount });
    else setDeleteRequest({ mode: "ids", count: selectedIds.size, ids: [...selectedIds] });
  }

  async function confirmDeleteProspects() {
    if (!deleteRequest) return;
    setDeletingProspects(true); setNotice("");
    try {
      const body = deleteRequest.mode === "ids"
        ? { ids: deleteRequest.ids }
        : { allMatching: true, search: search.trim(), filters: filterPayload(effectiveFilters), excludedIds: [...excludedIds] };
      const result = await api<{ deleted: number }>("/api/prospects", { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      setNotice(`Deleted ${formatNumber(result.deleted)} prospect${result.deleted === 1 ? "" : "s"} from the People database.`);
      setDeleteRequest(null); clearSelection(); onRefresh();
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "Unable to delete prospects."); }
    finally { setDeletingProspects(false); }
  }

  async function scanEmailProviders() {
    setEspScanning(true); setNotice("Checking company MX records…");
    let afterId = "";
    let checked = 0;
    let updated = 0;
    let failed = 0;
    let segs = 0;
    try {
      for (;;) {
        const result = await api<{ checked: number; updated: number; failed: number; segs: number; nextCursor: string; hasMore: boolean }>("/api/email-providers/scan", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ afterId, limit: 20 }),
        });
        checked += result.checked; updated += result.updated; failed += result.failed; segs += result.segs;
        setNotice(`Checking MX records… ${formatNumber(checked)} domains processed`);
        if (!result.hasMore || !result.checked) break;
        if (!result.nextCursor || result.nextCursor === afterId) throw new Error("The MX scan did not advance. Please retry.");
        afterId = result.nextCursor;
      }
      setNotice(checked
        ? `MX scan complete: ${formatNumber(updated)} domains updated, ${formatNumber(segs)} SEGs detected${failed ? `, ${formatNumber(failed)} updates failed` : ""}.`
        : "All company domains have already been checked.");
      onRefresh();
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "MX scan failed."); }
    finally { setEspScanning(false); }
  }

  async function saveCurrentView() {
    const name = window.prompt("Name this ICP view")?.trim();
    if (!name) return;
    try {
      const data = await api<{ view: SavedView }>("/api/saved-views", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, definition: { filters, columns: visibleColumns, sort, direction } }) });
      setSavedViews((current) => [data.view, ...current]); setNotice(`Saved view “${name}”.`);
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "Unable to save this view."); }
  }

  function applyView(viewId: string) {
    const view = savedViews.find((item) => item.id === viewId);
    if (!view) return;
    onFiltersChange(view.definition.filters ?? []);
    if (view.definition.columns?.length) {
      setVisibleColumns(view.definition.columns);
      localStorage.setItem("prospecthub-visible-columns", JSON.stringify(view.definition.columns));
    }
    onSortChange(view.definition.sort || "created_at", view.definition.direction || "desc");
  }

  return <section className="people-workspace">
    <div className="people-heading">
      <div><p className="eyebrow">PROSPECTS</p><h2>Find people</h2><p>Search and filter every prospect saved in your people database.</p></div>
      <div className="entity-pivot-actions"><button className="secondary" title="Safely scope up to 250,000 matching people" onClick={() => onSeeCompanies({ search: search.trim(), filters: filterPayload(effectiveFilters), limit: 250000 })}>See Companies <AppIcon name="arrow" size={14}/></button><button className="primary" onClick={onImport}><AppIcon name="upload" size={15}/> Import prospects</button></div>
    </div>
    {companyScope ? <div className="cross-scope-banner" role="status"><span>Showing people inside the companies from your previous Company DB search (safety limit: {formatNumber(companyScope.limit)} matching companies).</span><button onClick={onClearCompanyScope}>Clear company scope</button></div> : null}
    <Tabs
      label="Prospect views"
      value={tab}
      onChange={setTab}
      items={[
        { id: "records" as const, label: "All prospects", count: displayedTotal, hint: totalHint, icon: <AppIcon name="database" size={15}/> },
        { id: "coverage" as const, label: "Field coverage", count: formatNumber(fields.length), icon: <AppIcon name="columns" size={15}/> },
        // Classifier maintenance is database-wide, so it is not offered inside a
        // client workspace where the numbers would be a misleading subset.
        ...(canDeleteMaster ? [{
          id: "titles" as const,
          label: "Job titles",
          count: classifierGaps === null ? undefined : formatNumber(classifierGaps),
          hint: "Maintain the job title classifier: see the titles it could not resolve and re-run it after editing the keyword lists.",
          icon: <AppIcon name="target" size={15}/>,
        }] : []),
      ]}
    />
    {tab === "titles" ? <TitleClassifierPanel onGapCount={setClassifierGaps}/>
      : tab === "coverage" ? <article className="panel field-coverage">
      <div className="coverage-summary"><span className="coverage-symbol"><AppIcon name="check" size={14}/></span><div><strong>{formatNumber(fields.length)} uploaded fields available</strong><p>Every field from your CSV is saved and ready to filter or display.</p></div></div>
      <div className="coverage-groups"><section><h3>Standard columns</h3><div>{standardProspectFields.map((field, index) => <span className={`field-chip tone-${index % 4}`} key={field.id}>{field.label}</span>)}</div></section><section><h3>Uploaded CSV fields</h3><div>{fields.map((field, index) => <span className={`field-chip tone-${index % 4}`} key={field}>{field}</span>)}</div></section></div>
    </article> : <div className={`people-layout ${filtersOpen ? "" : "filters-collapsed"}`}>
      <article className="panel results-panel">
        <div className="results-toolbar">
          <div className="results-count"><strong title={totalHint}>{displayedTotal} people</strong><span>{effectiveFilters.length ? `${effectiveFilters.length} active filter${effectiveFilters.length === 1 ? "" : "s"} · all matching records` : "People database"}</span>{total ? <button className="select-all-matching-button" onClick={selectAllMatching}>{selectionMode === "all_matching" && selectionMatchesQuery && !excludedIds.size ? `All ${displayedTotal} selected` : `Select all ${displayedTotal} across pages`}</button> : null}</div>
          <div className="workspace-actions">
            <label><span className="sr-only">Saved ICP view</span><select defaultValue="" onChange={(event) => applyView(event.target.value)}><option value="">Saved views</option>{savedViews.map((view) => <option key={view.id} value={view.id}>{view.name}</option>)}</select></label>
            <button className="outline-button" onClick={() => void saveCurrentView()}><AppIcon name="star" size={14}/> Save view</button>
            <button className="outline-button" disabled={exportingProspects} title="Choose rows and fields for a CSV export" onClick={() => openExportDialog("all_matching")}>{exportingProspects ? "Exporting…" : "Export CSV"}</button>
            {!clientId ? <button className="outline-button" disabled={espScanning} title="Detect MX-visible gateways and mailbox providers. API-only email security products are not visible in MX records." onClick={() => void scanEmailProviders()}>{espScanning ? "Scanning MX…" : "Detect ESPs"}</button> : null}
            <label><span className="sr-only">Sort prospects</span><select value={`${sort}:${direction}`} onChange={(event) => { const [nextSort, nextDirection] = event.target.value.split(":"); onSortChange(nextSort, nextDirection as "asc" | "desc"); }}><option value="created_at:desc">Newest first</option><option value="name:asc">Name A to Z</option><option value="company:asc">Company A to Z</option><option value="title:asc">Title A to Z</option><option value="last_contacted:desc">Recently contacted</option></select></label>
            <button className={`outline-button filter-toggle ${filtersOpen ? "active" : ""}`} aria-pressed={filtersOpen} onClick={() => setFiltersOpen((open) => !open)}><AppIcon name="filter" size={14}/> Filters {effectiveFilters.length ? <span>{effectiveFilters.length}</span> : null}</button>
            <button className="outline-button density-control" title={DENSITY_LABEL[density]} aria-label={DENSITY_LABEL[density]} onClick={cycleDensity}><AppIcon name="rows" size={14}/> {density === "default" ? "Rows" : DENSITY_LABEL[density].replace(" rows", "")}</button>
            <div className="column-control" ref={columnMenuRef}><button className="outline-button" aria-expanded={columnMenu} onClick={() => setColumnMenu((open) => !open)}><AppIcon name="columns" size={14}/> Columns <span>{visibleDefinitions.length}</span></button>{columnMenu && <div className="column-menu"><div><strong>Choose columns</strong><button onClick={() => { setVisibleColumns(defaultProspectColumns); localStorage.setItem("prospecthub-visible-columns", JSON.stringify(defaultProspectColumns)); }}>Reset</button></div>{allColumns.map((field) => <label key={field.id}><input type="checkbox" checked={visibleColumns.includes(field.id)} onChange={() => toggleColumn(field.id)} />{field.label}</label>)}</div>}</div>
          </div>
        </div>
        {notice ? <div className="inline-notice" role="status">{notice}<button aria-label="Dismiss notification" onClick={() => setNotice("")}><AppIcon name="close" size={14}/></button></div> : null}
        {selectedCount ? <div className="bulk-bar"><strong>{formatNumber(selectedCount)} selected {selectionMode === "all_matching" ? "across all pages" : "across pages"}</strong>{selectionMode === "explicit" && selectedCount < total ? <button onClick={selectAllMatching}>Select all {displayedTotal}</button> : null}<button onClick={() => openExportDialog("selected")}><AppIcon name="download" size={14}/> Export selected</button>{selectionMode === "explicit" ? <><button disabled={bulkBusy} onClick={() => void bulkAction("tag")}><AppIcon name="plus" size={14}/> Add tag</button><select aria-label="Client for contact history" value={bulkClientId} onChange={(event) => setBulkClientId(event.target.value)}><option value="">Choose client</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select><button disabled={bulkBusy || !bulkClientId} onClick={() => void bulkAction("mark_contacted")}><AppIcon name="check" size={14}/> Mark contacted</button></> : null}
          {/* Push and ICP verification take the filter payload, so they work for
              a database-wide selection as well as an explicit one. */}
          {clientId
            ? <><button className="bulk-verify" disabled={bulkBusy} onClick={() => void clientAction("set_icp_verified", clientId)}><AppIcon name="check" size={14}/> Mark ICP verified</button><button disabled={bulkBusy} onClick={() => void clientAction("clear_icp_verified", clientId)}><AppIcon name="close" size={14}/> Clear verified</button></>
            : <><select aria-label="Client to push these prospects into" value={pushClientId} onChange={(event) => setPushClientId(event.target.value)}><option value="">Push to client…</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select><button className="bulk-push" disabled={bulkBusy || !pushClientId} onClick={() => void clientAction("push", pushClientId)}><AppIcon name="arrow" size={14}/> Push {selectionMode === "all_matching" ? formatNumber(selectedCount) : "selected"}</button></>}
          {selectionMode === "all_matching" && !clientId ? <span className="selection-scope-note">Tagging and contact history need an explicit selection</span> : null}{canDeleteMaster ? <button className="row-danger bulk-delete" disabled={deletingProspects} onClick={requestDeleteSelected}>🗑 Delete {selectionMode === "all_matching" ? formatNumber(selectedCount) : "selected"}</button> : null}<button onClick={clearSelection}>Clear</button></div> : null}
        {effectiveFilters.length ? <div className="active-filter-strip">{effectiveFilters.flatMap((filter) => {
          const label = filterLabel(filter.field, allCustomFields);
          if (filter.operator === "empty" || filter.operator === "not_empty") return [<button key={filter.id} onClick={() => onFiltersChange(filters.filter((item) => item.id !== filter.id))}>{label}: {filter.operator === "empty" ? "Empty" : "Not empty"} <span><AppIcon name="close" size={14}/></span></button>];
          const prefix = filter.operator === "not_contains" || filter.operator === "not_equals" ? "Exclude " : filter.operator === "boolean" ? "Boolean " : "";
          return filter.values.map((value) => <button key={`${filter.id}-${value}`} onClick={() => updateFilter(filter.id, { values: filter.values.filter((item) => item !== value) })}>{prefix}{label}: {filterChipValue(filter.field, value)} <span><AppIcon name="close" size={14}/></span></button>);
        })}<button className="clear-filter-chip" onClick={() => onFiltersChange([])}>Clear all</button></div> : null}
        {prospects.length ? <><div className="master-scroll-top" ref={topScrollRef} onScroll={(event) => syncHorizontalScroll(event.currentTarget, tableScrollRef.current)} aria-label="Horizontal table scroll"><div style={{ width: tableScrollWidth }}/></div><div className="master-table-wrap" data-density={density} ref={tableScrollRef} onScroll={(event) => syncHorizontalScroll(event.currentTarget, topScrollRef.current)}><table className="master-data-table"><thead><tr><th className="select-column"><input aria-label="Select all prospects on this page" title="Select all prospects on this page" type="checkbox" checked={prospects.length > 0 && prospects.every((prospect) => isProspectSelected(prospect.id))} onChange={togglePageSelection}/></th>{visibleDefinitions.map((field) => <th key={field.id}>{field.label}</th>)}{clientId ? <><th className="date-added-column">Date added</th><th className="icp-column">ICP verified</th></> : null}<th className="row-detail-column">{onRemoveFromClient || canDeleteMaster ? "Actions" : ""}</th></tr></thead><tbody>{prospects.map((person) => <ProspectTableRow key={person.id} prospect={person} visibleDefinitions={visibleDefinitions} selected={isProspectSelected(person.id)} includeClient={!clientId} canDeleteMaster={canDeleteMaster} clientId={clientId} onSelect={onSelect} onToggleSelected={toggleSelected} onRemoveFromClient={onRemoveFromClient} onToggleVerified={toggleVerified} onDelete={deleteProspect}/>)}</tbody></table></div><div className="table-footer"><span>Showing {formatNumber(firstRecord)} to {formatNumber(lastRecord)} of {displayedTotal} matching records</span><div><button disabled={page <= 1} onClick={() => onPageChange(page - 1)}><AppIcon name="back" size={14}/> Previous</button><span>Page {page} of {totalEstimated ? "≈" : ""}{totalPages}</span><button disabled={totalEstimated ? prospects.length < 50 : page >= totalPages} onClick={() => onPageChange(page + 1)}>Next</button></div></div></> : <EmptyState title="No matching prospects" text={effectiveFilters.length ? "Adjust or clear the filters to see more records." : "Import a CSV and your unique prospects will appear here."} action={effectiveFilters.length ? "Clear filters" : "Import CSV"} onAction={effectiveFilters.length ? () => onFiltersChange([]) : onImport} />}
      </article>
      {filtersOpen ? <ApolloFilterPanel filters={filters} customFields={customFields} clientId={clientId} onChange={onFiltersChange}/> : null}
    </div>}
    {exportDialogOpen ? <div className="modal-backdrop" role="presentation"><section className="export-modal" role="dialog" aria-modal="true" aria-labelledby="prospect-export-title"><div className="export-modal-head"><div><p className="eyebrow">CSV EXPORT</p><h2 id="prospect-export-title">Choose prospects and fields</h2><p>Only the fields checked below will be included in the download.</p></div><button aria-label="Close export dialog" disabled={exportingProspects} onClick={() => setExportDialogOpen(false)}><AppIcon name="close" size={14}/></button></div><fieldset className="export-scope"><legend>Prospects to export</legend><label htmlFor="export-all-matching"><span className="sr-only">All matching prospects</span><input id="export-all-matching" type="radio" name="export-scope" checked={exportScope === "all_matching"} onChange={() => setExportScope("all_matching")}/><span><strong>All {search.trim() || effectiveFilters.length ? "matching " : ""}prospects</strong><small>{formatNumber(total)} records across every page</small></span></label><label htmlFor="export-selected" className={!selectedCount ? "disabled" : ""}><span className="sr-only">Selected prospects</span><input id="export-selected" type="radio" name="export-scope" disabled={!selectedCount} checked={exportScope === "selected"} onChange={() => setExportScope("selected")}/><span><strong>Selected prospects</strong><small>{formatNumber(selectedCount)} currently selected</small></span></label></fieldset><div className="export-fields-head"><div><strong>Fields to include</strong><span>{formatNumber(exportFields.length)} selected</span></div><div><button onClick={() => setExportFields(exportFieldCatalog.map((field) => field.id))}>Select all</button><button onClick={() => setExportFields(defaultProspectExportFields)}>Recommended</button><button onClick={() => setExportFields([])}>Clear</button></div></div><div className="export-field-grid">{exportFieldCatalog.map((field) => <label key={field.id}><input type="checkbox" checked={exportFields.includes(field.id)} onChange={() => toggleExportField(field.id)}/><span>{field.label}</span></label>)}</div><fieldset className="export-scope export-format"><legend>Output</legend><label htmlFor="export-single"><span className="sr-only">Single CSV file</span><input id="export-single" type="radio" name="export-format" checked={exportFormat === "single"} disabled={exportingProspects} onChange={() => setExportFormat("single")}/><span><strong>One CSV file</strong><small>Everything in a single download, any size</small></span></label><label htmlFor="export-parts"><span className="sr-only">Split into multiple files</span><input id="export-parts" type="radio" name="export-format" checked={exportFormat === "parts"} disabled={exportingProspects} onChange={() => setExportFormat("parts")}/><span><strong>Split into parts</strong><small>Multiple CSVs of <select aria-label="Rows per file" disabled={exportingProspects || exportFormat !== "parts"} value={exportRowsPerFile} onClick={(event) => event.stopPropagation()} onChange={(event) => setExportRowsPerFile(Number(event.target.value))}>{[10000, 25000, 50000, 100000].map((size) => <option key={size} value={size}>{formatNumber(size)}</option>)}</select> rows each</small></span></label></fieldset>{!fileSystemAccessSupported() ? <p className="export-hint">Your browser will download the file{exportFormat === "parts" ? "s" : ""} when the export finishes. For very large exports, a Chromium browser streams straight to disk.</p> : null}{exportProgress ? <div className="export-progress" role="status"><span className="export-progress-bar"><i style={{ width: `${exportProgress.total ? Math.min(100, Math.round((exportProgress.exported / Math.max(1, exportProgress.total)) * 100)) : 100}%` }}/></span><span>Exported {formatNumber(exportProgress.exported)}{exportProgress.total ? ` of ${formatNumber(exportProgress.total)}` : ""} rows{exportProgress.files > 1 ? ` · ${formatNumber(exportProgress.files)} files` : ""}</span></div> : null}<div className="modal-actions">{exportingProspects ? <button className="secondary" onClick={cancelExport}>Cancel export</button> : <button className="secondary" onClick={() => setExportDialogOpen(false)}>Close</button>}<button className="primary" disabled={exportingProspects || !exportFields.length || (exportScope === "selected" && !selectedCount)} onClick={() => void exportProspectsCsv()}>{exportingProspects ? "Exporting…" : `Export ${formatNumber(exportScope === "selected" ? selectedCount : total)} prospects`}</button></div></section></div> : null}
    {deleteRequest ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="prospect-delete-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="prospect-delete-title">Delete {formatNumber(deleteRequest.count)} {deleteRequest.count === 1 ? "prospect" : "prospects"}?</h2><p>This permanently removes {deleteRequest.count === 1 ? "this prospect" : "these prospects"} from the People database, including their list links across every client. This cannot be undone. Company records are not affected.</p>{deleteRequest.mode === "all_matching" && !search.trim() && !effectiveFilters.length && !excludedIds.size ? <p className="form-error" role="alert"><AppIcon name="warning" size={14}/> No search or filters are applied — this will empty your entire People database.</p> : null}<div className="modal-actions"><button className="secondary" disabled={deletingProspects} onClick={() => setDeleteRequest(null)}>Cancel</button><button className="danger-button solid" disabled={deletingProspects} onClick={() => void confirmDeleteProspects()}>{deletingProspects ? "Deleting…" : `Delete ${formatNumber(deleteRequest.count)}`}</button></div></section></div> : null}
  </section>;
}
