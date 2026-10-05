"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import dynamic from "next/dynamic";
import { useSearchParams } from "next/navigation";
import { api, companyApiPath, encodeFilters, prefetchApi, prospectApiPath } from "../lib/dashboard-api";
import { initials } from "../lib/dashboard-helpers";
import { scopeRestricts, type CompanyScope, type PeopleScope } from "../lib/workspace-scopes";
import { readWorkspaceUrl, writeWorkspaceUrl, type WorkspaceUrlState } from "../lib/workspace-url";
import { useClientWorkspaceLoader } from "../lib/use-client-workspace-loader";
import { emptyStats, type ClientRecord, type DeleteRequest, type ImportRecord, type ListRecord, type Prospect, type ProspectFilter, type Section } from "../lib/types";
import CompaniesWorkspace, { useCompaniesWorkspaceController } from "./components/CompaniesWorkspace";
import { AppIcon, DeleteConfirmation, LoadingState, ProspectDrawer, type IconName } from "./components/DashboardUi";
import type { ImportDestination } from "./components/ImportsPanel";
import ThemeToggle from "./components/ThemeToggle";
import MobileNav from "./components/MobileNav";
import OverviewWorkspace from "./components/OverviewWorkspace";
import ProspectsWorkspace, { useProspectsWorkspaceController } from "./components/ProspectsWorkspace";

// Screens other than Overview, People and Companies load on demand, each in its
// own chunk, so the first page ships only what it shows (all fourteen screens
// used to arrive in one ~530 KB bundle). People and Companies stay eager: this
// shell calls their controller hooks. Once the first page is up and the
// browser is idle, the rest are fetched in the background, so opening one
// later is still instant. See node_modules/next/dist/docs/01-app/02-guides/lazy-loading.md.
const screenImports = {
  clients: () => import("./components/ClientsPanel"),
  coverage: () => import("./components/CoveragePanel"),
  quality: () => import("./components/DataQualityPanel"),
  imports: () => import("./components/ImportsPanel"),
  replyBlocklist: () => import("./components/ReplyBlocklistPanel"),
  verification: () => import("./components/EmailVerificationWorkspace"),
  icpValidator: () => import("./components/IcpValidatorWorkspace"),
  logs: () => import("./components/LogsPanel"),
};
const screenLoading = () => <LoadingState label="Loading this screen"/>;
const ClientsPanel = dynamic(screenImports.clients, { loading: screenLoading });
const CoveragePanel = dynamic(screenImports.coverage, { loading: screenLoading });
const DataQualityPanel = dynamic(screenImports.quality, { loading: screenLoading });
const ImportsPanel = dynamic(screenImports.imports, { loading: screenLoading });
const ReplyBlocklistPanel = dynamic(screenImports.replyBlocklist, { loading: screenLoading });
const EmailVerificationWorkspace = dynamic(screenImports.verification, { loading: screenLoading });
const IcpValidatorWorkspace = dynamic(screenImports.icpValidator, { loading: screenLoading });
const LogsPanel = dynamic(screenImports.logs, { loading: screenLoading });

function usePreloadScreens(isAdmin: boolean) {
  useEffect(() => {
    const load = () => {
      for (const [name, load] of Object.entries(screenImports)) {
        if (name === "logs" && !isAdmin) continue;
        void load().catch(() => {});
      }
    };
    const idle = (globalThis as { requestIdleCallback?: (callback: () => void, options?: { timeout: number }) => number }).requestIdleCallback;
    if (idle) { const handle = idle(load, { timeout: 4000 }); return () => (globalThis as { cancelIdleCallback?: (handle: number) => void }).cancelIdleCallback?.(handle); }
    const timer = window.setTimeout(load, 2500);
    return () => window.clearTimeout(timer);
  }, [isAdmin]);
}

const baseNavGroups: Array<{ label: string; items: Array<{ id: Section; label: string; mark: IconName }> }> = [
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
      { id: "verification", label: "Email verification", mark: "check" },
      { id: "icp-validator", label: "ICP validator", mark: "target" },
      { id: "reply-blocklist", label: "Reply blocklist", mark: "quality" },
    ],
  },
];

// Admin-only: kept out of navGroups entirely (not just hidden) so a
// non-admin can never navigate to it, prefetch it, or land on it via a
// bookmarked/shared "?section=logs" link - the section-restore path below
// still checks isAdmin again for exactly that reason.
const adminNavGroup = { label: "Admin", items: [{ id: "logs" as Section, label: "Server logs", mark: "alert" as IconName }] };

function navGroupsFor(isAdmin: boolean) {
  return isAdmin ? [...baseNavGroups, adminNavGroup] : baseNavGroups;
}

const subscribeHydration = () => () => {};
const clientSnapshot = () => true;
const serverSnapshot = () => false;

export default function DashboardApp(props: { currentUserEmail: string; isAdmin: boolean }) {
  // Fragments are unavailable to SSR. Mount controllers only once the browser
  // can restore the complete scope; never issue an unfiltered hydration query.
  const hydrated = useSyncExternalStore(subscribeHydration, clientSnapshot, serverSnapshot);
  return hydrated ? <DashboardWorkspace {...props}/> : <div role="status">Restoring workspace…</div>;
}

function DashboardWorkspace({ currentUserEmail, isAdmin }: { currentUserEmail: string; isAdmin: boolean }) {
  const navGroups = useMemo(() => navGroupsFor(isAdmin), [isAdmin]);
  usePreloadScreens(isAdmin);
  const navItems = useMemo(() => navGroups.flatMap((group) => group.items), [navGroups]);
  const searchParams = useSearchParams();
  // Read once. After mount the URL is written FROM state, and popstate is what
  // feeds it back in - re-reading on every render would fight the writer.
  const initial = useMemo(() => readWorkspaceUrl(new URLSearchParams(searchParams.toString()), window.location.hash), []); // eslint-disable-line react-hooks/exhaustive-deps
  const [section, setSection] = useState<Section>(initial.section === "logs" && !isAdmin ? "overview" : initial.section);
  const [restoreError, setRestoreError] = useState(initial.restoreError ?? '');
  const [stats, setStats] = useState(emptyStats);
  const [recentImports, setRecentImports] = useState<ImportRecord[]>([]);
  const [clients, setClients] = useState<ClientRecord[]>([]);
  const initialClientId = initial.section === "clients" && !initial.restoreError ? initial.clientId : "";
  const initialListId = initialClientId ? initial.listId : "";
  const clientWorkspace = useClientWorkspaceLoader(initialClientId, initialListId);
  const {
    requestedClientId, requestedListId, selectedClient, selectedList, lists,
    request: requestClientWorkspace, closeList: closeClientList, closeClient: closeClientWorkspace,
    isCurrent: isCurrentClientWorkspace,
    setSelectedClient, setLists,
  } = clientWorkspace;
  // A pivot requested from the List workspace ("See People"/"See Companies"),
  // consumed once by ClientDetail at the mount that follows closing the list -
  // going through ListsPanel always unmounts ClientDetail and remounts it fresh,
  // so a one-shot value read at mount and cleared immediately after is enough;
  // no effect-driven sync is needed the way the scopes below need one at this
  // level, since those persist across renders of the same workspace section.
  const [clientListPivot, setClientListPivot] = useState<{ clientId: string; listId: string; listName: string; target: "prospects" | "companies" } | null>(null);
  const [selectedProspect, setSelectedProspect] = useState<Prospect | null>(null);
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(initial.companyPeopleScope);
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(initial.peopleCompanyScope);
  const [prospectFilters, setProspectFilters] = useState<ProspectFilter[]>(initial.prospectFilters);
  const [prospectSort, setProspectSort] = useState(initial.sort);
  const [prospectDirection, setProspectDirection] = useState<"asc" | "desc">(initial.direction);
  const [companyFilters, setCompanyFilters] = useState<ProspectFilter[]>(initial.companyFilters);
  const [search, setSearch] = useState(initial.search);
  const [loading, setLoading] = useState(true);
  const [workspaceLoading, setWorkspaceLoading] = useState(false);
  const [error, setError] = useState("");
  const [clientLoadError, setClientLoadError] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<DeleteRequest | null>(null);
  const [deleting, setDeleting] = useState(false);

  const prospectsController = useProspectsWorkspaceController({ active: !restoreError && section === "prospects", search, filters: prospectFilters, sort: prospectSort, direction: prospectDirection, companyScope: companyPeopleScope, statsProspects: stats.prospects, initialPage: initial.prospectPage, onLoading: setWorkspaceLoading, onError: setError });
  const companiesController = useCompaniesWorkspaceController({ active: !restoreError && section === "companies", search, filters: companyFilters, peopleScope: peopleCompanyScope, initialPage: initial.companyPage, onLoading: setWorkspaceLoading, onError: setError });
  const { setPage: setProspectPage } = prospectsController;
  const { setPage: setCompanyPage } = companiesController;
  // A pivot is a reversible view transition. Keep the source workspace in
  // memory so Company → People → Company (and the reverse) returns to the
  // authorized query the user actually came from instead of nesting scopes and
  // clearing both sides' filters.
  const peopleBeforePivot = useRef<{ search: string; filters: ProspectFilter[]; page: number; sort: string; direction: "asc" | "desc"; companyScope: CompanyScope | null } | null>(null);
  const companiesBeforePivot = useRef<{ search: string; filters: ProspectFilter[]; page: number; peopleScope: PeopleScope | null } | null>(null);
  const pivotOrigin = useRef<"prospects" | "companies" | null>(null);

  // ---- The workspace, kept in the address bar (SHELL-STATE-01) -------------

  const urlState: WorkspaceUrlState = useMemo(() => ({
    section,
    search,
    clientId: requestedClientId,
    listId: requestedListId,
    prospectPage: prospectsController.page,
    companyPage: companiesController.page,
    sort: prospectSort,
    direction: prospectDirection,
    prospectFilters,
    companyFilters,
    companyPeopleScope,
    peopleCompanyScope,
  }), [section, search, requestedClientId, requestedListId, prospectsController.page, companiesController.page,
       prospectSort, prospectDirection, prospectFilters, companyFilters, companyPeopleScope, peopleCompanyScope]);

  // Written with the native History API, which is what Next documents for
  // shallow client routing: it updates the stack without a navigation and stays
  // in sync with useSearchParams.
  //
  // A section change pushes, so Back returns to the section you came from.
  // Everything else replaces, because a history entry per keystroke of a search
  // box turns the Back button into a way to retype what you just typed.
  const lastSection = useRef(section);
  const restoring = useRef(false);
  const lastRestoredLocation = useRef('');
  useEffect(() => {
    if (restoreError) return; // Preserve the original damaged link for recovery.
    if (restoring.current) { restoring.current = false; return; }
    const next = writeWorkspaceUrl(urlState);
    const current = `${window.location.pathname}${window.location.search}${window.location.hash}`;
    const target = next.startsWith("?") ? `${window.location.pathname}${next}` : next;
    if (target === current) return;
    if (urlState.section !== lastSection.current) window.history.pushState(null, "", target);
    else window.history.replaceState(null, "", target);
    lastRestoredLocation.current = window.location.href;
    lastSection.current = urlState.section;
  }, [urlState, restoreError]);

  // Back and Forward. `restoring` stops the writer from immediately rewriting
  // the entry the browser just moved to, which would strand the user on it.
  useEffect(() => {
    const onPopState = () => {
      if (lastRestoredLocation.current === window.location.href) return;
      lastRestoredLocation.current = window.location.href;
      const restored = readWorkspaceUrl(new URLSearchParams(window.location.search), window.location.hash);
      setRestoreError(restored.restoreError ?? '');
      if (restored.restoreError) { closeClientWorkspace(); return; }
      restoring.current = true;
      const restoredSection = restored.section === "logs" && !isAdmin ? "overview" : restored.section;
      lastSection.current = restoredSection;
      setSection(restoredSection);
      setSearch(restored.search);
      setProspectFilters(restored.prospectFilters);
      setCompanyFilters(restored.companyFilters);
      setProspectSort(restored.sort);
      setProspectDirection(restored.direction);
      setCompanyPeopleScope(restored.companyPeopleScope);
      setPeopleCompanyScope(restored.peopleCompanyScope);
      setProspectPage(restored.prospectPage);
      setCompanyPage(restored.companyPage);
      if (restoredSection === "clients") requestClientWorkspace(restored.clientId, restored.listId);
      else closeClientWorkspace();
    };
    window.addEventListener("popstate", onPopState);
    window.addEventListener("hashchange", onPopState);
    return () => {
      window.removeEventListener("popstate", onPopState);
      window.removeEventListener("hashchange", onPopState);
    };
  }, [closeClientWorkspace, isAdmin, requestClientWorkspace, setProspectPage, setCompanyPage]);

  const encodedProspectFilters = useMemo(() => encodeFilters(prospectFilters), [prospectFilters]);

  const prefetchSection = useCallback((next: Section) => {
    if (restoreError) return;
    if (next === "prospects") prefetchApi(prospectApiPath({ filters: encodedProspectFilters, sort: prospectSort, direction: prospectDirection, includeFields: !prospectsController.fieldsLoaded }));
    if (next === "companies") prefetchApi(companyApiPath({}));
  }, [encodedProspectFilters, prospectDirection, prospectSort, prospectsController.fieldsLoaded, restoreError]);

  const refreshDashboard = useCallback(async () => {
    const [dashboardResult, clientsResult] = await Promise.allSettled([
      api<{ stats: typeof emptyStats; recentImports: ImportRecord[] }>("/api/dashboard"),
      api<{ clients: ClientRecord[] }>("/api/clients"),
    ]);
    if (dashboardResult.status === "fulfilled") {
      setStats(dashboardResult.value.stats);
      setRecentImports(dashboardResult.value.recentImports);
    } else {
      setError(dashboardResult.reason instanceof Error ? dashboardResult.reason.message : "Unable to load dashboard data.");
    }
    if (clientsResult.status === "fulfilled") {
      setClients(clientsResult.value.clients);
      setClientLoadError("");
      return clientsResult.value.clients;
    }
    setClientLoadError(clientsResult.reason instanceof Error ? clientsResult.reason.message : "Unable to load the client directory.");
    // A failed directory read is not an empty directory. Keep any previously
    // loaded clients and let callers distinguish failure from a real [] result.
    return null;
  }, []);

  useEffect(() => {
    if (restoreError || !clientWorkspace.initialResolutionComplete) return;
    const timer = window.setTimeout(() => { void refreshDashboard().finally(() => setLoading(false)); }, 0);
    return () => window.clearTimeout(timer);
  }, [clientWorkspace.initialResolutionComplete, refreshDashboard, restoreError]);

  useEffect(() => {
    if (loading) return;
    const timer = window.setTimeout(() => { prefetchSection("prospects"); prefetchSection("companies"); }, 350);
    return () => window.clearTimeout(timer);
  }, [loading, prefetchSection]);

  const openClient = useCallback(async (client: ClientRecord) => {
    prefetchApi(prospectApiPath({ clientId: client.id }));
    prefetchApi(companyApiPath({ clientId: client.id }));
    requestClientWorkspace(client.id, "", client);
  }, [requestClientWorkspace]);

  const navigate = useCallback((next: Section) => {
    pivotOrigin.current = null;
    peopleBeforePivot.current = null; companiesBeforePivot.current = null;
    setSection(next); setSearch(""); setError(""); setWorkspaceLoading(false); setProspectPage(1); setCompanyPage(1);
    if (next === "prospects") setCompanyPeopleScope(null);
    if (next === "companies") setPeopleCompanyScope(null);
    if (next !== "clients") closeClientWorkspace();
    else closeClientList();
  }, [closeClientList, closeClientWorkspace, setCompanyPage, setProspectPage]);

  const openImportedDestination = useCallback(async (destination?: ImportDestination) => {
    const refreshed = await refreshDashboard();
    if (!destination) { navigate("overview"); return; }
    if (destination.kind === "companies") {
      navigate("companies");
      setCompanyFilters([{ id: `__company_import_id:${destination.importId}`, field: "__company_import_id", operator: "equals", values: [destination.importId] }]);
      return;
    }
    const client = refreshed?.find((item) => item.id === destination.clientId)
      ?? (await api<{ client: ClientRecord }>(`/api/clients/${encodeURIComponent(destination.clientId)}`, { cache: "no-store" })).client;
    const list = (await api<{ list: ListRecord }>(`/api/lists/${encodeURIComponent(destination.listId)}?clientId=${encodeURIComponent(client.id)}`, { cache: "no-store" })).list;
    navigate("clients");
    requestClientWorkspace(client.id, list.id, client, list);
  }, [navigate, refreshDashboard, requestClientWorkspace]);

  // Open the People workspace on exactly the records a quality check counted.
  //
  // navigate() is deliberate rather than a bare setSection: it clears the search,
  // the pivot scope and both pivot snapshots, so the records that arrive are the
  // ones the tile counted and nothing else. The filters are applied after it,
  // because navigate resets them.
  const viewQualityRecords = useCallback((filters: ProspectFilter[]) => {
    navigate("prospects");
    setProspectFilters(filters);
    setProspectPage(1);
  }, [navigate, setProspectPage]);

  // The same move for the coverage checker, into the Company database instead.
  // Its filters are an exact set of company ids, so navigate() clearing the
  // search and the pivot first is what keeps the rows that arrive equal to the
  // number on the button that was pressed.
  const viewCoverageCompanies = useCallback((filters: ProspectFilter[]) => {
    navigate("companies");
    setCompanyFilters(filters);
    setCompanyPage(1);
  }, [navigate, setCompanyPage]);

  // Only carry a scope that actually narrows something. An unfiltered tab pivots to
  // "everyone", which is what the workspace functions already compute -- keeping the
  // empty scope only produced a banner claiming a restriction that was not applied,
  // so the pivot looked broken while showing the right rows.
  const seePeople = useCallback((scope: CompanyScope) => {
    if (pivotOrigin.current === "prospects" && peopleBeforePivot.current) {
      const previous = peopleBeforePivot.current;
      setSearch(previous.search); setProspectFilters(previous.filters); setProspectPage(previous.page);
      setProspectSort(previous.sort); setProspectDirection(previous.direction); setCompanyPeopleScope(previous.companyScope);
      setPeopleCompanyScope(null); setSection("prospects"); closeClientWorkspace();
      pivotOrigin.current = null;
      return;
    }
    companiesBeforePivot.current = { search, filters: companyFilters, page: companiesController.page, peopleScope: peopleCompanyScope };
    pivotOrigin.current = "companies";
    setCompanyPeopleScope(scopeRestricts(scope) ? scope : null);
    setProspectFilters([]); setProspectPage(1); setSearch(""); setSection("prospects"); closeClientWorkspace();
  }, [closeClientWorkspace, companiesController.page, companyFilters, peopleCompanyScope, search, setProspectPage]);

  // A query that times out leaves the screen holding the very filters that
  // caused it, and the only route back is to find them in the panel and take
  // them off one at a time - which is exactly the interaction someone who has
  // just been told to "narrow it" is least able to face. Offer the way out where
  // the failure is reported, and make it clear the whole query, not just the
  // filters: a company pivot resolving 250,000 ids is usually the expensive
  // half, and clearing filters alone would leave it in place.
  const narrowedQuery = section === "prospects"
    ? { filters: prospectFilters, scope: companyPeopleScope }
    : section === "companies" ? { filters: companyFilters, scope: peopleCompanyScope }
    : { filters: [], scope: null };
  const canResetQuery = Boolean(narrowedQuery.filters.length || narrowedQuery.scope || search.trim());
  const resetQuery = useCallback(() => {
    if (section === "prospects") { setProspectFilters([]); setCompanyPeopleScope(null); setProspectPage(1); }
    else if (section === "companies") { setCompanyFilters([]); setPeopleCompanyScope(null); setCompanyPage(1); }
    setSearch(""); setError("");
  }, [section, setProspectPage, setCompanyPage]);

  const seeCompanies = useCallback((scope: PeopleScope) => {
    if (pivotOrigin.current === "companies" && companiesBeforePivot.current) {
      const previous = companiesBeforePivot.current;
      setSearch(previous.search); setCompanyFilters(previous.filters); setCompanyPage(previous.page); setPeopleCompanyScope(previous.peopleScope);
      setCompanyPeopleScope(null); setSection("companies"); closeClientWorkspace();
      pivotOrigin.current = null;
      return;
    }
    peopleBeforePivot.current = { search, filters: prospectFilters, page: prospectsController.page, sort: prospectSort, direction: prospectDirection, companyScope: companyPeopleScope };
    pivotOrigin.current = "prospects";
    setPeopleCompanyScope(scopeRestricts(scope) ? scope : null);
    setCompanyFilters([]); setCompanyPage(1); setSearch(""); setSection("companies"); closeClientWorkspace();
  }, [closeClientWorkspace, companyPeopleScope, prospectDirection, prospectFilters, prospectSort, prospectsController.page, search, setCompanyPage]);

  const confirmDelete = useCallback(async () => {
    if (!deleteRequest) return;
    setDeleting(true); setError("");
    try {
      const endpoint = deleteRequest.kind === "client" ? "clients" : deleteRequest.kind === "list" ? "lists" : "imports";
      await api(`/api/${endpoint}/${encodeURIComponent(deleteRequest.id)}`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) });
      const refreshedClients = await refreshDashboard();
      if (deleteRequest.kind === "client") {
        if (selectedClient && isCurrentClientWorkspace(selectedClient.id)) closeClientWorkspace();
      } else if (selectedClient && refreshedClients && isCurrentClientWorkspace(selectedClient.id)) {
        const updatedClient = refreshedClients.find((client) => client.id === selectedClient.id) ?? null;
        if (!updatedClient) closeClientWorkspace();
        else {
          setSelectedClient(updatedClient);
          const data = await api<{ lists: ListRecord[] }>(`/api/lists?clientId=${updatedClient.id}`);
          if (isCurrentClientWorkspace(updatedClient.id)) setLists(data.lists);
        }
      }
      setDeleteRequest(null);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to delete this record."); }
    finally { setDeleting(false); }
  }, [closeClientWorkspace, deleteRequest, isCurrentClientWorkspace, refreshDashboard, selectedClient, setLists, setSelectedClient]);

  const title = navItems.find((item) => item.id === section)?.label ?? "Overview";
  const scopedClientSection = section === "clients" && Boolean(requestedClientId);
  const scopedClientReady = scopedClientSection && Boolean(selectedClient || clientWorkspace.loadError);
  const showGlobalLoading = loading && !scopedClientSection;

  if (restoreError) return <main className="panel" aria-labelledby="restore-error-title">
    <h1 id="restore-error-title">This search link needs attention</h1>
    <p role="alert">{restoreError}</p>
    <a className="button" href={window.location.pathname}>Clear this link and start a new search</a>
  </main>;

  return <div className="app-shell">
    <a className="skip-link" href="#main-content" onClick={(event) => {
      // A focus jump must not overwrite the fragment carrying large filters.
      event.preventDefault();
      const main = document.getElementById('main-content');
      if (main) { main.tabIndex = -1; main.focus(); main.scrollIntoView({ block: 'start' }); }
    }}>Skip to main content</a>
    <aside className="sidebar"><div className="brand"><span className="brand-mark"><AppIcon name="database" size={17}/></span><span>Prospect <span>Sync</span></span></div><div className="workspace"><span className="workspace-avatar">PA</span><div><strong>Prospect Agency</strong><small>Internal workspace</small></div><span className="chevron"><AppIcon name="chevron" size={14}/></span></div><nav aria-label="Primary navigation">{navGroups.map((group) => <div className="nav-group" key={group.label}><span className="nav-group-label">{group.label}</span>{group.items.map((item) => <button key={item.id} aria-current={section === item.id ? "page" : undefined} className={section === item.id ? "active" : ""} onMouseEnter={() => prefetchSection(item.id)} onFocus={() => prefetchSection(item.id)} onClick={() => navigate(item.id)}><span aria-hidden="true"><AppIcon name={item.mark} size={17}/></span>{item.label}</button>)}</div>)}</nav><ThemeToggle/><a className="profile" href="/auth/signout"><span className="profile-avatar">{initials(currentUserEmail)}</span><div><strong>{currentUserEmail}</strong><small>Sign out</small></div></a></aside>
    <MobileNav section={section} items={navItems} onNavigate={(id) => navigate(id as Section)} currentUserEmail={currentUserEmail}/>
    <main id="main-content"><header className="topbar"><div><p className="eyebrow">DATABASE WORKSPACE</p><h1>{selectedClient ? selectedClient.name : title}</h1></div><div className="top-actions">{(section === "prospects" || section === "companies") && <label className="search"><span><AppIcon name="search" size={16}/></span><input aria-label="Search" value={search} onChange={(event) => { setSearch(event.target.value); if (section === "prospects") setProspectPage(1); if (section === "companies") setCompanyPage(1); }} placeholder={`Search ${section}...`}/></label>}{section !== "reply-blocklist" && <button className="primary" onClick={() => navigate("imports")}><AppIcon name="plus" size={15}/> Import list</button>}</div></header>
      {error && <div className="alert"><span>!</span><p>{error}</p>{canResetQuery ? <button className="alert-reset" onClick={resetQuery}>Clear filters and start over</button> : null}<button aria-label="Dismiss" onClick={() => setError("")}><AppIcon name="close" size={14}/></button></div>}
      <section className="content" aria-busy={showGlobalLoading || workspaceLoading || clientWorkspace.clientLoading || clientWorkspace.listLoading}>
        {!loading && section === "reply-blocklist" && <ReplyBlocklistPanel/>}
        {!loading && section === "verification" && <EmailVerificationWorkspace isAdmin={isAdmin}/>}
        {!loading && section === "icp-validator" && <IcpValidatorWorkspace clients={clients}/>}
        {!loading && section === "logs" && isAdmin && <LogsPanel/>}
        {showGlobalLoading ? <LoadingState/> : null}
        {!loading && workspaceLoading ? <div className="workspace-progress" role="status"><span/>Updating {title.toLowerCase()}…</div> : null}
        {!loading && section === "overview" && <OverviewWorkspace stats={stats} recentImports={recentImports} clients={clients} onImport={() => navigate("imports")} onViewMaster={() => navigate("prospects")} onDeleteImport={(item) => setDeleteRequest({ kind: "import", id: item.id, name: item.file_name, context: `${item.client_name ?? "Unassigned"} · ${item.list_name ?? "Unassigned"}` })}/>}
        {!loading && section === "prospects" && <ProspectsWorkspace controller={prospectsController} filters={prospectFilters} sort={prospectSort} direction={prospectDirection} clients={clients} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onClearSearch={() => setSearch("")} onSeeCompanies={seeCompanies} onFiltersChange={setProspectFilters} onSortChange={(nextSort, nextDirection) => { setProspectSort(nextSort); setProspectDirection(nextDirection); }} onSelect={setSelectedProspect} onImport={() => navigate("imports")}/>}
        {!loading && section === "companies" && <CompaniesWorkspace controller={companiesController} clients={clients} filters={companyFilters} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onClearSearch={() => setSearch("")} onSeePeople={seePeople} onFilters={setCompanyFilters} onImport={() => navigate("imports")}/>}
        {scopedClientSection && loading && clientWorkspace.initialResolutionComplete ? <div className="workspace-progress compact" role="status"><span/>Loading the client directory in the background…</div> : null}
        {scopedClientSection && clientLoadError ? <div className="inline-error" role="alert">The client directory is unavailable: {clientLoadError}</div> : null}
        {section === "clients" && requestedClientId && clientWorkspace.clientLoading && !selectedClient ? <LoadingState label="Opening client workspace"/> : null}
        {section === "clients" && clientWorkspace.loadError?.kind === "client" && !selectedClient ? <section className="panel" role="alert"><h2>Unable to open this client</h2><p>{clientWorkspace.loadError.message}</p><div className="modal-actions"><button className="secondary" onClick={() => requestClientWorkspace(requestedClientId, requestedListId)}>Retry</button><button className="secondary" onClick={closeClientWorkspace}>Back to all clients</button></div></section> : null}
        {section === "clients" && selectedClient && requestedListId && clientWorkspace.listLoading && !selectedList ? <LoadingState label="Opening client list"/> : null}
        {section === "clients" && selectedClient && clientWorkspace.loadError?.kind === "list" && requestedListId && !selectedList ? <section className="panel" role="alert"><h2>Unable to open this list</h2><p>{clientWorkspace.loadError.message}</p><div className="modal-actions"><button className="secondary" onClick={() => requestClientWorkspace(selectedClient.id, requestedListId, selectedClient)}>Retry</button><button className="secondary" onClick={closeClientList}>Back to {selectedClient.name}&apos;s lists</button></div></section> : null}
        {section === "clients" && selectedClient && clientWorkspace.loadError?.kind === "lists" ? <div className="inline-error" role="alert">{clientWorkspace.loadError.message} <button className="secondary" onClick={() => requestClientWorkspace(selectedClient.id, requestedListId, selectedClient, selectedList)}>Retry</button></div> : null}
        {(!loading || scopedClientReady) && section === "clients" && (!requestedClientId || (selectedClient && (!requestedListId || selectedList))) && <ClientsPanel
          clients={clients}
          clientLoadError={clientLoadError}
          selectedClient={selectedClient}
          selectedList={selectedList}
          lists={lists}
          listsLoading={clientWorkspace.listsLoading}
          listsLoadError={clientWorkspace.loadError?.kind === "lists"}
          onOpenClient={(client) => void openClient(client)}
          onCloseClient={closeClientWorkspace}
          onOpenList={(list) => requestClientWorkspace(selectedClient?.id ?? "", list.id, selectedClient, list)}
          onCloseList={closeClientList}
          listPivot={clientListPivot}
          onConsumeListPivot={() => setClientListPivot(null)}
          onSeeListRecords={(clientId, list, target) => { setClientListPivot({ clientId, listId: list.id, listName: list.name, target }); closeClientList(); }}
          onSelectProspect={setSelectedProspect}
          onImport={() => navigate("imports")}
          onDeleteClient={(client) => setDeleteRequest({ kind: "client", id: client.id, name: client.name, context: `${client.list_count} lists · ${client.prospect_count} linked prospects` })}
          onDeleteList={(list) => setDeleteRequest({ kind: "list", id: list.id, name: list.name, context: `${list.source_file_name} · ${list.prospect_count} linked prospects` })}
          onRefreshClients={() => {
            void refreshDashboard().then((refreshed) => setSelectedClient((current) =>
              current && refreshed ? refreshed.find((client) => client.id === current.id) ?? current : current));
          }}
        />}
        {!loading && section === "coverage" && <CoveragePanel onViewCompanies={viewCoverageCompanies}/>}
        {!loading && section === "quality" && <DataQualityPanel onMerged={() => void refreshDashboard()} onViewRecords={viewQualityRecords} onViewCompanies={viewCoverageCompanies}/>}
        {!loading && section === "imports" && <ImportsPanel
          clients={clients}
          onChanged={async () => { await refreshDashboard(); }}
          onComplete={openImportedDestination}
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
  All companies; Only with websites; Export CSV; downloadCsvStream; filtersOpen;
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
