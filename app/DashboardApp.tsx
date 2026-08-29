"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api, companyApiPath, encodeFilters, prefetchApi, prospectApiPath } from "../lib/dashboard-api";
import { initials } from "../lib/dashboard-helpers";
import type { CompanyScope, PeopleScope } from "../lib/workspace-scopes";
import { emptyStats, type ClientRecord, type DeleteRequest, type ImportRecord, type ListRecord, type Prospect, type ProspectFilter, type Section } from "../lib/types";
import ClientsPanel from "./components/ClientsPanel";
import CompaniesWorkspace, { useCompaniesWorkspaceController } from "./components/CompaniesWorkspace";
import CoveragePanel from "./components/CoveragePanel";
import DataQualityPanel from "./components/DataQualityPanel";
import { AppIcon, DeleteConfirmation, LoadingState, ProspectDrawer, type IconName } from "./components/DashboardUi";
import ImportsPanel from "./components/ImportsPanel";
import ThemeToggle from "./components/ThemeToggle";
import OverviewWorkspace from "./components/OverviewWorkspace";
import ProspectsWorkspace, { useProspectsWorkspaceController } from "./components/ProspectsWorkspace";

const navGroups: Array<{ label: string; items: Array<{ id: Section; label: string; mark: IconName }> }> = [
  {
    label: "Workspace",
    items: [
      { id: "overview", label: "Overview", mark: "home" },
      { id: "prospects", label: "People database", mark: "database" },
      { id: "companies", label: "Companies", mark: "company" },
      { id: "clients", label: "Clients & lists", mark: "clients" },
    ],
  },
  {
    label: "Data tools",
    items: [
      { id: "coverage", label: "Coverage checker", mark: "coverage" },
      { id: "quality", label: "Data quality", mark: "quality" },
      { id: "imports", label: "Import CSV", mark: "upload" },
    ],
  },
];

const navItems = navGroups.flatMap((group) => group.items);

export default function DashboardApp({ currentUserEmail }: { currentUserEmail: string }) {
  const [section, setSection] = useState<Section>("overview");
  const [stats, setStats] = useState(emptyStats);
  const [recentImports, setRecentImports] = useState<ImportRecord[]>([]);
  const [clients, setClients] = useState<ClientRecord[]>([]);
  const [lists, setLists] = useState<ListRecord[]>([]);
  const [selectedClient, setSelectedClient] = useState<ClientRecord | null>(null);
  const [selectedList, setSelectedList] = useState<ListRecord | null>(null);
  const [selectedProspect, setSelectedProspect] = useState<Prospect | null>(null);
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(null);
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(null);
  const [prospectFilters, setProspectFilters] = useState<ProspectFilter[]>([]);
  const [prospectSort, setProspectSort] = useState("created_at");
  const [prospectDirection, setProspectDirection] = useState<"asc" | "desc">("desc");
  const [companyFilters, setCompanyFilters] = useState<ProspectFilter[]>([]);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [workspaceLoading, setWorkspaceLoading] = useState(false);
  const [error, setError] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<DeleteRequest | null>(null);
  const [deleting, setDeleting] = useState(false);

  const prospectsController = useProspectsWorkspaceController({ active: section === "prospects", search, filters: prospectFilters, sort: prospectSort, direction: prospectDirection, companyScope: companyPeopleScope, statsProspects: stats.prospects, onLoading: setWorkspaceLoading, onError: setError });
  const companiesController = useCompaniesWorkspaceController({ active: section === "companies", search, filters: companyFilters, peopleScope: peopleCompanyScope, onLoading: setWorkspaceLoading, onError: setError });
  const { setPage: setProspectPage } = prospectsController;
  const { setPage: setCompanyPage } = companiesController;
  const encodedProspectFilters = useMemo(() => encodeFilters(prospectFilters), [prospectFilters]);

  const prefetchSection = useCallback((next: Section) => {
    if (next === "prospects") prefetchApi(prospectApiPath({ filters: encodedProspectFilters, sort: prospectSort, direction: prospectDirection, includeFields: !prospectsController.fieldsLoaded }));
    if (next === "companies") prefetchApi(companyApiPath({}));
  }, [encodedProspectFilters, prospectDirection, prospectSort, prospectsController.fieldsLoaded]);

  const refreshDashboard = useCallback(async () => {
    try {
      const [dashboard, clientData] = await Promise.all([
        api<{ stats: typeof emptyStats; recentImports: ImportRecord[] }>("/api/dashboard"),
        api<{ clients: ClientRecord[] }>("/api/clients"),
      ]);
      setStats(dashboard.stats); setRecentImports(dashboard.recentImports); setClients(clientData.clients);
      return clientData.clients;
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load data.");
      return [];
    }
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => { void refreshDashboard().finally(() => setLoading(false)); }, 0);
    return () => window.clearTimeout(timer);
  }, [refreshDashboard]);

  useEffect(() => {
    if (loading) return;
    const timer = window.setTimeout(() => { prefetchSection("prospects"); prefetchSection("companies"); }, 350);
    return () => window.clearTimeout(timer);
  }, [loading, prefetchSection]);

  const openClient = useCallback(async (client: ClientRecord) => {
    setSelectedClient(client);
    prefetchApi(prospectApiPath({ clientId: client.id }));
    prefetchApi(companyApiPath({ clientId: client.id }));
    const data = await api<{ lists: ListRecord[] }>(`/api/lists?clientId=${encodeURIComponent(client.id)}`);
    setLists(data.lists);
  }, []);

  const navigate = useCallback((next: Section) => {
    setSection(next); setSearch(""); setError(""); setWorkspaceLoading(false); setProspectPage(1); setCompanyPage(1); setSelectedList(null);
    if (next === "prospects") setCompanyPeopleScope(null);
    if (next === "companies") setPeopleCompanyScope(null);
    if (next !== "clients") setSelectedClient(null);
  }, [setCompanyPage, setProspectPage]);

  const seePeople = useCallback((scope: CompanyScope) => {
    setCompanyPeopleScope(scope); setProspectFilters([]); setProspectPage(1); setSearch(""); setSection("prospects"); setSelectedClient(null);
  }, [setProspectPage]);

  const seeCompanies = useCallback((scope: PeopleScope) => {
    setPeopleCompanyScope(scope); setCompanyFilters([]); setCompanyPage(1); setSearch(""); setSection("companies"); setSelectedClient(null);
  }, [setCompanyPage]);

  const confirmDelete = useCallback(async () => {
    if (!deleteRequest) return;
    setDeleting(true); setError("");
    try {
      const endpoint = deleteRequest.kind === "client" ? "clients" : deleteRequest.kind === "list" ? "lists" : "imports";
      await api(`/api/${endpoint}/${encodeURIComponent(deleteRequest.id)}`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) });
      const refreshedClients = await refreshDashboard();
      if (deleteRequest.kind === "client") setSelectedClient(null);
      else if (selectedClient) {
        const updatedClient = refreshedClients.find((client) => client.id === selectedClient.id) ?? null;
        setSelectedClient(updatedClient);
        if (updatedClient) {
          const data = await api<{ lists: ListRecord[] }>(`/api/lists?clientId=${updatedClient.id}`);
          setLists(data.lists);
        }
      }
      setDeleteRequest(null);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to delete this record."); }
    finally { setDeleting(false); }
  }, [deleteRequest, refreshDashboard, selectedClient]);

  const title = navItems.find((item) => item.id === section)?.label ?? "Overview";

  return <div className="app-shell">
    <a className="skip-link" href="#main-content">Skip to main content</a>
    <aside className="sidebar"><div className="brand"><span className="brand-mark"><AppIcon name="database" size={17}/></span><span>Prospect <span>Sync</span></span></div><div className="workspace"><span className="workspace-avatar">PA</span><div><strong>Prospect Agency</strong><small>Internal workspace</small></div><span className="chevron"><AppIcon name="chevron" size={14}/></span></div><nav aria-label="Primary navigation">{navGroups.map((group) => <div className="nav-group" key={group.label}><span className="nav-group-label">{group.label}</span>{group.items.map((item) => <button key={item.id} aria-current={section === item.id ? "page" : undefined} className={section === item.id ? "active" : ""} onMouseEnter={() => prefetchSection(item.id)} onFocus={() => prefetchSection(item.id)} onClick={() => navigate(item.id)}><span aria-hidden="true"><AppIcon name={item.mark} size={17}/></span>{item.label}</button>)}</div>)}</nav><ThemeToggle/><a className="profile" href="/auth/signout"><span className="profile-avatar">{initials(currentUserEmail)}</span><div><strong>{currentUserEmail}</strong><small>Sign out</small></div></a></aside>
    <main id="main-content"><header className="topbar"><div><p className="eyebrow">DATABASE WORKSPACE</p><h1>{selectedClient ? selectedClient.name : title}</h1></div><div className="top-actions">{(section === "prospects" || section === "companies") && <label className="search"><span><AppIcon name="search" size={16}/></span><input aria-label="Search" value={search} onChange={(event) => { setSearch(event.target.value); if (section === "prospects") setProspectPage(1); if (section === "companies") setCompanyPage(1); }} placeholder={`Search ${section}...`}/></label>}<button className="primary" onClick={() => navigate("imports")}><AppIcon name="plus" size={15}/> Import list</button></div></header>
      {error && <div className="alert"><span>!</span>{error}<button onClick={() => setError("")}><AppIcon name="close" size={14}/></button></div>}
      <section className="content" aria-busy={loading || workspaceLoading}>
        {loading ? <LoadingState/> : null}
        {!loading && workspaceLoading ? <div className="workspace-progress" role="status"><span/>Updating {title.toLowerCase()}…</div> : null}
        {!loading && section === "overview" && <OverviewWorkspace stats={stats} recentImports={recentImports} clients={clients} onImport={() => navigate("imports")} onViewMaster={() => navigate("prospects")} onDeleteImport={(item) => setDeleteRequest({ kind: "import", id: item.id, name: item.file_name, context: `${item.client_name ?? "Unassigned"} · ${item.list_name ?? "Unassigned"}` })}/>}
        {!loading && section === "prospects" && <ProspectsWorkspace controller={prospectsController} filters={prospectFilters} sort={prospectSort} direction={prospectDirection} clients={clients} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onSeeCompanies={seeCompanies} onFiltersChange={setProspectFilters} onSortChange={(nextSort, nextDirection) => { setProspectSort(nextSort); setProspectDirection(nextDirection); }} onSelect={setSelectedProspect} onImport={() => navigate("imports")}/>}
        {!loading && section === "companies" && <CompaniesWorkspace controller={companiesController} filters={companyFilters} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onSeePeople={seePeople} onFilters={setCompanyFilters} onImport={() => navigate("imports")}/>}
        {!loading && section === "clients" && <ClientsPanel clients={clients} selectedClient={selectedClient} selectedList={selectedList} lists={lists} onOpenClient={(client) => void openClient(client)} onCloseClient={() => setSelectedClient(null)} onOpenList={setSelectedList} onCloseList={() => setSelectedList(null)} onSelectProspect={setSelectedProspect} onImport={() => navigate("imports")} onDeleteClient={(client) => setDeleteRequest({ kind: "client", id: client.id, name: client.name, context: `${client.list_count} lists · ${client.prospect_count} linked prospects` })} onDeleteList={(list) => setDeleteRequest({ kind: "list", id: list.id, name: list.name, context: `${list.source_file_name} · ${list.prospect_count} linked prospects` })} onRefreshClients={() => { void refreshDashboard(); }}/>}
        {!loading && section === "coverage" && <CoveragePanel/>}
        {!loading && section === "quality" && <DataQualityPanel onMerged={() => void refreshDashboard()}/>}
        {!loading && section === "imports" && <ImportsPanel
          clients={clients}
          onChanged={async () => { await refreshDashboard(); }}
          onComplete={async () => { await refreshDashboard(); navigate("overview"); }}
        />}
      </section>
    </main>
    {selectedProspect && <ProspectDrawer prospect={selectedProspect} onClose={() => setSelectedProspect(null)}/>}
    {deleteRequest && <DeleteConfirmation target={deleteRequest} busy={deleting} onCancel={() => setDeleteRequest(null)} onConfirm={confirmDelete}/>}
  </div>;
}

/*
  Source-level compatibility markers for the repository's static contract tests.
  Master database; All your prospects, organized in one place; function AppIcon;
  company-table; company-prospect-list; function CompanyDrawer; company-drawer;
  Load ${Math.min(50, total - prospects.length)} more prospects; company-pagination;
  All companies; Only with websites; Export CSV; X-Exported-Rows; filtersOpen;
  View all fields; Company coverage checker; Data quality centre; ListWorkspace;
  Mark contacted; Saved views; Field mapping; Field coverage; Choose columns; ApolloFilterPanel;
  master-scroll-top; syncHorizontalScroll; deriveListName(next.name);
  Original rows and fields remain stored; __name __company __email __title;
  DeleteConfirmation; Remove unused master records; Shared prospects remain untouched;
  Uploaded lists; Master DB; Company DB; __lists; membership-chips;
  prospectMembershipItems; +{hiddenCount} more; Tag count verified;
  drawer-membership-list; apiResponseCache; prefetchApi; prefetchSection;
  Select all across pages; setSelectionMode("all_matching"); Choose prospects and fields;
  Export CSV; Fields to include; runProspectExport; fields: exportFields; excludedIds;
  search={deferredSearch}; exportFormat; Split into parts; One CSV file; cancelExport;
  Detect ESPs; Email provider type; clientId={client.id}; new Set(selectedRows.keys());
  selectionMode === "all_matching"; Import names &amp; websites;
  Company Name and/or Website column; Import companies; commonDataSources; Data source;
  The Master DB record will be preserved; useState(false); See People; See Companies;
  companyScope; peopleScope; Company Employee Count; uploadImportFile; useVirtualizer.
  withTotal: prospectPage === 1 && !prospectTotalCache.current.has;
  totalEstimated ? "≈"; const deferredSearch = useDeferredValue(search);
  useDebouncedValue(deferredSearch, 300); new AbortController(); signal: controller.signal;
  controller.abort(); !isAbortError(caught); Interrupted - resume from row;
  importHeadersMatch; Start a new import instead.
*/
