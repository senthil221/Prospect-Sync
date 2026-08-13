"use client";

import { ChangeEvent, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { mapProspect } from "../db/normalize";
import { buildCustomFieldDefinitions, customFieldValue } from "../lib/prospect-fields";
import { runProspectExport, fileSystemAccessSupported, type ExportFormat } from "../lib/export-runner";
import { commonDataSources } from "../lib/data-source";
import { companyImportFields, missingCompanyImportFields, missingRequiredFields, requiredPersonImportFields, resolvedImportFields, suggestedCompanyImportField, suggestedPersonImportField } from "../lib/import-schema";
import type { CompanyScope, PeopleScope } from "../lib/workspace-scopes";
import ApolloFilterPanel, { filterLabel, type ProspectFilter } from "./ApolloFilterPanel";
import CompanyFilterPanel from "./CompanyFilterPanel";
import { useDismiss } from "./use-dismiss";

type Section = "overview" | "prospects" | "companies" | "clients" | "coverage" | "quality" | "imports";
type ClientRecord = { id: string; name: string; list_count: number; prospect_count: number; cooldown_days?: number };
type ListRecord = { id: string; name: string; data_source: string; source_file_name: string; uploaded_rows: number; unique_added: number; duplicates_linked: number; prospect_count: number; created_at: string; field_count: number; field_headers: string[] };
type ProspectMembership = { listId: string; listName: string; clientId: string; clientName: string };
type Prospect = Record<string, unknown> & { id: string; full_name: string; first_name?: string; last_name?: string; work_email: string; personal_email?: string; title: string; keywords?: string[]; company_name: string; company_domain: string; city?: string; state?: string; country?: string; company_location?: string; company_city?: string; company_state?: string; company_country?: string; employee_count_min?: number; employee_count_max?: number; seniority?: string; department?: string; esp?: string; email_provider_type?: string; mx_records?: string[]; mx_status?: string; mx_checked_at?: string; client_count: number; list_count: number; list_names?: string[]; client_names?: string[]; list_memberships?: ProspectMembership[]; all_data: string | Record<string, string>; last_contacted_at?: string; next_eligible_at?: string; eligible?: boolean; tags?: Array<{ id: string; name: string; color: string }> };
type Company = { id: string; name: string; domain: string; prospect_count: number; client_count: number; created_at: string };
type ImportRecord = { id: string; file_name: string; data_source: string; client_name: string; list_name: string; processed_rows: number; unique_added: number; duplicates_linked: number; status: string; created_at: string };
type DeleteKind = "import" | "list" | "client";
type DeleteRequest = { kind: DeleteKind; id: string; name: string; context: string };
type FileAudit = { headers: string[]; rows: number; populatedCells: number; invalidRows: number };
type SavedView = { id: string; name: string; definition: { filters: ProspectFilter[]; columns: string[]; sort: string; direction: "asc" | "desc" } };

const emptyStats = { prospects: 0, companies: 0, clients: 0, lists: 0, rowsImported: 0, duplicatesDetected: 0 };

function formatNumber(value: unknown) {
  return new Intl.NumberFormat("en-IN").format(Number(value ?? 0));
}

function filterChipValue(field: string, value: string) {
  if (field !== "__employee_count") return value;
  if (value === "unknown") return "Unknown";
  const [minimum, maximum] = value.split(":");
  if (!minimum) return value;
  return maximum ? `${formatNumber(minimum)}–${formatNumber(maximum)}` : `${formatNumber(minimum)}+`;
}

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "CL";
}

function colorTone(value: string) {
  return Array.from(value).reduce((sum, character) => sum + character.charCodeAt(0), 0) % 6;
}

type IconName = "home" | "database" | "company" | "clients" | "coverage" | "quality" | "upload" | "search" | "plus" | "filter" | "columns" | "check" | "arrow";

function AppIcon({ name, size = 18 }: { name: IconName; size?: number }) {
  const common = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
  if (name === "home") return <svg {...common}><path d="m3 11 9-8 9 8"/><path d="M5.5 9.5V21h13V9.5"/><path d="M9.5 21v-6h5v6"/></svg>;
  if (name === "database") return <svg {...common}><ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v7c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12v7c0 1.7 3.6 3 8 3s8-1.3 8-3v-7"/></svg>;
  if (name === "company") return <svg {...common}><path d="M4 21V4h10v17"/><path d="M14 9h6v12"/><path d="M8 8h2M8 12h2M8 16h2M17 13h1M17 17h1"/></svg>;
  if (name === "clients") return <svg {...common}><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></svg>;
  if (name === "coverage") return <svg {...common}><circle cx="11" cy="11" r="7"/><path d="m20 20-4-4M8 11h6M11 8v6"/></svg>;
  if (name === "quality") return <svg {...common}><path d="M12 3 4.5 6v5.5c0 4.7 3.2 8 7.5 9.5 4.3-1.5 7.5-4.8 7.5-9.5V6z"/><path d="m8.5 12 2.2 2.2 4.8-5"/></svg>;
  if (name === "upload") return <svg {...common}><path d="M12 16V3M7 8l5-5 5 5"/><path d="M5 14v6h14v-6"/></svg>;
  if (name === "search") return <svg {...common}><circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/></svg>;
  if (name === "plus") return <svg {...common}><path d="M12 5v14M5 12h14"/></svg>;
  if (name === "filter") return <svg {...common}><path d="M4 6h16M7 12h10M10 18h4"/></svg>;
  if (name === "columns") return <svg {...common}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M15 4v16"/></svg>;
  if (name === "check") return <svg {...common}><path d="m5 12 4 4L19 6"/></svg>;
  return <svg {...common}><path d="M5 12h14M13 6l6 6-6 6"/></svg>;
}

function uniqueHeaders(headers: string[]) {
  const used = new Map<string, number>();
  return headers.map((header, index) => {
    const base = header.trim() || `Column ${index + 1}`;
    const normalized = base.toLowerCase();
    const count = (used.get(normalized) ?? 0) + 1;
    used.set(normalized, count);
    return count === 1 ? base : `${base} (${count})`;
  });
}

function deriveListName(fileName: string) {
  return fileName
    .replace(/^.*[\\/]/, "")
    .replace(/\.csv$/i, "")
    .replace(/[_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

const canonicalImportFields = ["Auto detect", ...requiredPersonImportFields, "First Name", "Last Name", "Personal Email", "Mobile Number", "Keywords", "City", "State", "Country", "Person Location", "Company Website", "Company Employee Count", "Company Location", "Company City", "Company State", "Company Country"];

function parseCsv(text: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') { value += '"'; index += 1; }
      else quoted = !quoted;
    } else if (char === "," && !quoted) {
      row.push(value); value = "";
    } else if ((char === "\n" || char === "\r") && !quoted) {
      if (char === "\r" && text[index + 1] === "\n") index += 1;
      row.push(value); value = "";
      if (row.some((cell) => cell.trim())) rows.push(row);
      row = [];
    } else value += char;
  }
  row.push(value);
  if (row.some((cell) => cell.trim())) rows.push(row);
  if (!rows.length) throw new Error("The CSV is empty.");
  return { headers: uniqueHeaders(rows[0]), rows: rows.slice(1) };
}

const apiResponseCache = new Map<string, { data: unknown; expiresAt: number }>();
const apiRequests = new Map<string, Promise<unknown>>();

function clearApiCache() {
  apiResponseCache.clear();
}

async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const method = String(options?.method ?? "GET").toUpperCase();
  if (method === "GET") {
    const cached = apiResponseCache.get(path);
    if (cached && cached.expiresAt > Date.now()) return cached.data as T;
    const pending = apiRequests.get(path);
    if (pending) return pending as Promise<T>;
  }
  const request = (async () => {
    const response = await fetch(path, options);
    const data = await response.json() as T & { error?: string };
    if (!response.ok) throw new Error(data.error || "Something went wrong.");
    if (method === "GET") apiResponseCache.set(path, { data, expiresAt: Date.now() + 5 * 60_000 });
    else clearApiCache();
    return data;
  })();
  if (method === "GET") apiRequests.set(path, request);
  try { return await request; }
  finally { if (method === "GET") apiRequests.delete(path); }
}

function prefetchApi(path: string) {
  void api(path).catch(() => undefined);
}

function prospectApiPath({ search = "", page = 1, sort = "created_at", direction = "desc", filters = "[]", clientId = "", includeFields = true, companyScope = null }: { search?: string; page?: number; sort?: string; direction?: "asc" | "desc"; filters?: string; clientId?: string; includeFields?: boolean; companyScope?: CompanyScope | null }) {
  const params = new URLSearchParams({ search, page: String(page), sort, direction, filters, includeFields: includeFields ? "1" : "0" });
  if (clientId) params.set("clientId", clientId);
  if (companyScope) params.set("companyScope", JSON.stringify(companyScope));
  return `/api/prospects?${params.toString()}`;
}

function encodeFilters(filters: ProspectFilter[]) {
  return JSON.stringify(filters.map(({ field, operator, values }) => ({ field, operator, values })));
}

function companyApiPath({ search = "", page = 1, clientId = "", filters = [], peopleScope = null }: { search?: string; page?: number; clientId?: string; filters?: ProspectFilter[]; peopleScope?: PeopleScope | null }) {
  const params = new URLSearchParams({ search, page: String(page), pageSize: "50" });
  if (clientId) params.set("clientId", clientId);
  if (filters.length) params.set("filters", encodeFilters(filters));
  if (peopleScope) params.set("peopleScope", JSON.stringify(peopleScope));
  return `/api/companies?${params.toString()}`;
}

const navGroups: Array<{ label: string; items: Array<{ id: Section; label: string; mark: IconName }> }> = [
  {
    label: "Workspace",
    items: [
      { id: "overview", label: "Overview", mark: "home" },
      { id: "prospects", label: "Master database", mark: "database" },
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
  const [prospects, setProspects] = useState<Prospect[]>([]);
  const [prospectTotal, setProspectTotal] = useState(0);
  const [prospectFields, setProspectFields] = useState<string[]>([]);
  const [prospectFilters, setProspectFilters] = useState<ProspectFilter[]>([]);
  const [prospectPage, setProspectPage] = useState(1);
  const [prospectSort, setProspectSort] = useState("created_at");
  const [prospectDirection, setProspectDirection] = useState<"asc" | "desc">("desc");
  const [prospectRefresh, setProspectRefresh] = useState(0);
  const [companies, setCompanies] = useState<Company[]>([]);
  const [companyPage, setCompanyPage] = useState(1);
  const [companySummary, setCompanySummary] = useState({ total: 0, covered: 0, prospectTotal: 0, pageSize: 50 });
  const [companyFilters, setCompanyFilters] = useState<ProspectFilter[]>([]);
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(null);
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(null);
  const [lists, setLists] = useState<ListRecord[]>([]);
  const [selectedClient, setSelectedClient] = useState<ClientRecord | null>(null);
  const [selectedList, setSelectedList] = useState<ListRecord | null>(null);
  const [selectedProspect, setSelectedProspect] = useState<Prospect | null>(null);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [workspaceLoading, setWorkspaceLoading] = useState(false);
  const [error, setError] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<DeleteRequest | null>(null);
  const [deleting, setDeleting] = useState(false);
  const prospectFieldsLoaded = useRef(false);
  const deferredSearch = useDeferredValue(search);
  const encodedProspectFilters = useMemo(() => JSON.stringify(prospectFilters.map(({ field, operator, values }) => ({ field, operator, values }))), [prospectFilters]);

  const prefetchSection = useCallback((next: Section) => {
    if (next === "prospects") prefetchApi(prospectApiPath({ filters: encodedProspectFilters, sort: prospectSort, direction: prospectDirection, includeFields: prospectFields.length === 0 }));
    if (next === "companies") prefetchApi(companyApiPath({}));
  }, [encodedProspectFilters, prospectDirection, prospectFields.length, prospectSort]);

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
    const timer = window.setTimeout(() => {
      prefetchSection("prospects");
      prefetchSection("companies");
    }, 350);
    return () => window.clearTimeout(timer);
  }, [loading, prefetchSection]);

  useEffect(() => {
    let active = true;
    if (section !== "prospects" && section !== "companies") {
      return () => { active = false; };
    }
    void (async () => {
      setWorkspaceLoading(true);
      setError("");
      try {
        if (section === "prospects") {
          const data = await api<{ prospects: Prospect[]; total: number; fields?: string[] }>(prospectApiPath({ search: deferredSearch, page: prospectPage, sort: prospectSort, direction: prospectDirection, filters: encodedProspectFilters, includeFields: !prospectFieldsLoaded.current, companyScope: companyPeopleScope }));
          if (active) { setProspects(data.prospects); setProspectTotal(data.total); if (data.fields?.length) { prospectFieldsLoaded.current = true; setProspectFields(data.fields); } }
        }
        if (section === "companies") {
          const data = await api<{ companies: Company[]; total: number; covered: number; prospectTotal: number; pageSize: number }>(companyApiPath({ search: deferredSearch, page: companyPage, filters: companyFilters, peopleScope: peopleCompanyScope }));
          if (active) { setCompanies(data.companies); setCompanySummary({ total: data.total, covered: data.covered, prospectTotal: data.prospectTotal, pageSize: data.pageSize }); }
        }
      } catch (caught) { if (active) setError(caught instanceof Error ? caught.message : "Unable to load workspace data."); }
      finally { if (active) setWorkspaceLoading(false); }
    })();
    return () => { active = false; };
  }, [section, deferredSearch, stats.prospects, prospectPage, encodedProspectFilters, prospectSort, prospectDirection, prospectRefresh, companyPage, companyFilters, companyPeopleScope, peopleCompanyScope]);

  async function openClient(client: ClientRecord) {
    setSelectedClient(client);
    prefetchApi(prospectApiPath({ clientId: client.id }));
    prefetchApi(companyApiPath({ clientId: client.id }));
    const data = await api<{ lists: ListRecord[] }>(`/api/lists?clientId=${encodeURIComponent(client.id)}`);
    setLists(data.lists);
  }

  function navigate(next: Section) {
    setSection(next); setSearch(""); setError(""); setWorkspaceLoading(false); setProspectPage(1); setCompanyPage(1); setSelectedList(null);
    if (next === "prospects") setCompanyPeopleScope(null);
    if (next === "companies") setPeopleCompanyScope(null);
    if (next !== "clients") setSelectedClient(null);
  }

  function seePeople(scope: CompanyScope) {
    setCompanyPeopleScope(scope); setProspectFilters([]); setProspectPage(1); setSearch(""); setSection("prospects"); setSelectedClient(null);
  }

  function seeCompanies(scope: PeopleScope) {
    setPeopleCompanyScope(scope); setCompanyFilters([]); setCompanyPage(1); setSearch(""); setSection("companies"); setSelectedClient(null);
  }

  async function confirmDelete(deleteOrphans: boolean) {
    if (!deleteRequest) return;
    setDeleting(true); setError("");
    try {
      const endpoint = deleteRequest.kind === "client" ? "clients" : deleteRequest.kind === "list" ? "lists" : "imports";
      await api(`/api/${endpoint}/${encodeURIComponent(deleteRequest.id)}`, {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ deleteOrphans }),
      });
      const refreshedClients = await refreshDashboard();
      if (deleteRequest.kind === "client") {
        setSelectedClient(null);
      } else if (selectedClient) {
        const updatedClient = refreshedClients.find((client) => client.id === selectedClient.id) ?? null;
        setSelectedClient(updatedClient);
        if (updatedClient) {
          const data = await api<{ lists: ListRecord[] }>(`/api/lists?clientId=${updatedClient.id}`);
          setLists(data.lists);
        }
      }
      setDeleteRequest(null);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to delete this record.");
    } finally {
      setDeleting(false);
    }
  }

  const title = navItems.find((item) => item.id === section)?.label ?? "Overview";

  return (
    <div className="app-shell">
      <a className="skip-link" href="#main-content">Skip to main content</a>
      <aside className="sidebar">
        <div className="brand"><span className="brand-mark"><AppIcon name="database" size={17}/></span><span>Prospect <span>Sync</span></span></div>
        <div className="workspace"><span className="workspace-avatar">PA</span><div><strong>Prospect Agency</strong><small>Internal workspace</small></div><span className="chevron">⌄</span></div>
        <nav aria-label="Primary navigation">{navGroups.map((group) => <div className="nav-group" key={group.label}><span className="nav-group-label">{group.label}</span>{group.items.map((item) => <button key={item.id} aria-current={section === item.id ? "page" : undefined} className={section === item.id ? "active" : ""} onMouseEnter={() => prefetchSection(item.id)} onFocus={() => prefetchSection(item.id)} onClick={() => navigate(item.id)}><span aria-hidden="true"><AppIcon name={item.mark} size={17}/></span>{item.label}</button>)}</div>)}</nav>
        <a className="profile" href="/auth/signout"><span className="profile-avatar">{initials(currentUserEmail)}</span><div><strong>{currentUserEmail}</strong><small>Sign out</small></div></a>
      </aside>

      <main id="main-content">
        <header className="topbar">
          <div><p className="eyebrow">DATABASE WORKSPACE</p><h1>{selectedClient ? selectedClient.name : title}</h1></div>
          <div className="top-actions">
            {(section === "prospects" || section === "companies") && <label className="search"><span><AppIcon name="search" size={16}/></span><input aria-label="Search" value={search} onChange={(event) => { setSearch(event.target.value); if (section === "prospects") setProspectPage(1); if (section === "companies") setCompanyPage(1); }} placeholder={`Search ${section}...`} /></label>}
            <button className="primary" onClick={() => navigate("imports")}><AppIcon name="plus" size={15}/> Import list</button>
          </div>
        </header>

        {error && <div className="alert"><span>!</span>{error}<button onClick={() => setError("")}>×</button></div>}
        <section className="content" aria-busy={loading || workspaceLoading}>
          {loading ? <LoadingState /> : null}
          {!loading && workspaceLoading ? <div className="workspace-progress" role="status"><span/>Updating {title.toLowerCase()}…</div> : null}
          {!loading && section === "overview" && <Overview stats={stats} recentImports={recentImports} clients={clients} onImport={() => navigate("imports")} onViewMaster={() => navigate("prospects")} onDeleteImport={(item) => setDeleteRequest({ kind: "import", id: item.id, name: item.file_name, context: `${item.client_name} · ${item.list_name}` })} />}
          {!loading && section === "prospects" && <ProspectTable prospects={prospects} total={prospectTotal} fields={prospectFields} filters={prospectFilters} page={prospectPage} clients={clients} search={deferredSearch} sort={prospectSort} direction={prospectDirection} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onSeeCompanies={(scope) => seeCompanies(scope)} onSortChange={(nextSort, nextDirection) => { setProspectSort(nextSort); setProspectDirection(nextDirection); setProspectPage(1); }} onFiltersChange={(next) => { setProspectFilters(next); setProspectPage(1); }} onPageChange={setProspectPage} onSelect={setSelectedProspect} onImport={() => navigate("imports")} onRefresh={() => setProspectRefresh((current) => current + 1)} />}
          {!loading && section === "companies" && <CompanyTable companies={companies} total={companySummary.total} covered={companySummary.covered} prospectTotal={companySummary.prospectTotal} page={companyPage} pageSize={companySummary.pageSize} search={deferredSearch} filters={companyFilters} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onSeePeople={seePeople} onFilters={(next) => { setCompanyFilters(next); setCompanyPage(1); }} onPageChange={setCompanyPage} onImport={() => navigate("imports")} />}
          {!loading && section === "clients" && !selectedClient && <ClientsView clients={clients} onOpen={openClient} onImport={() => navigate("imports")} />}
          {!loading && section === "clients" && selectedClient && !selectedList && <ClientDetail client={selectedClient} clients={clients} lists={lists} onBack={() => setSelectedClient(null)} onOpenList={setSelectedList} onSelectProspect={setSelectedProspect} onImport={() => navigate("imports")} onDeleteClient={() => setDeleteRequest({ kind: "client", id: selectedClient.id, name: selectedClient.name, context: `${selectedClient.list_count} lists · ${selectedClient.prospect_count} linked prospects` })} onDeleteList={(list) => setDeleteRequest({ kind: "list", id: list.id, name: list.name, context: `${list.source_file_name} · ${list.prospect_count} linked prospects` })} />}
          {!loading && section === "clients" && selectedClient && selectedList && <ListWorkspace client={selectedClient} list={selectedList} onBack={() => setSelectedList(null)} onSelect={setSelectedProspect} />}
          {!loading && section === "coverage" && <CoverageChecker />}
          {!loading && section === "quality" && <DataQualityCenter onMerged={() => void refreshDashboard()} />}
          {!loading && section === "imports" && <ImportView clients={clients} onComplete={async () => { await refreshDashboard(); navigate("overview"); }} />}
        </section>
      </main>
      {selectedProspect && <ProspectDrawer prospect={selectedProspect} onClose={() => setSelectedProspect(null)} />}
      {deleteRequest && <DeleteConfirmation target={deleteRequest} busy={deleting} onCancel={() => setDeleteRequest(null)} onConfirm={confirmDelete} />}
    </div>
  );
}

function LoadingState() {
  return <div className="loading-state"><div className="loading-bar"/><div className="loading-grid"><span/><span/><span/><span/></div></div>;
}

function Overview({ stats, recentImports, clients, onImport, onViewMaster, onDeleteImport }: { stats: typeof emptyStats; recentImports: ImportRecord[]; clients: ClientRecord[]; onImport: () => void; onViewMaster: () => void; onDeleteImport: (item: ImportRecord) => void }) {
  const cards = [
    { label: "Unique prospects", value: stats.prospects, note: "Clean master records", color: "violet", icon: "database" as IconName },
    { label: "Known companies", value: stats.companies, note: "Matched by name or domain", color: "blue", icon: "company" as IconName },
    { label: "Client lists", value: stats.lists, note: `${stats.clients} active clients`, color: "amber", icon: "clients" as IconName },
    { label: "Cross-client overlaps", value: stats.duplicatesDetected, note: "Reused across client databases", color: "green", icon: "quality" as IconName },
  ];
  const uniqueRate = stats.rowsImported ? Math.round((stats.prospects / stats.rowsImported) * 100) : 0;
  const reuseRate = stats.rowsImported ? Math.round((stats.duplicatesDetected / stats.rowsImported) * 100) : 0;
  return <>
    <div className="welcome"><div><div className="hero-status"><span/><strong>Database healthy</strong><small>Live sync active</small></div><p className="eyebrow">MASTER DATABASE</p><h2>All your prospects, organized in one place.</h2><p>Search the master database, review client coverage, or import a new list.</p></div><div className="welcome-actions"><button className="primary" onClick={onImport}><AppIcon name="upload" size={15}/> Import client list</button><button className="secondary" onClick={onViewMaster}>Open master database <AppIcon name="arrow" size={15}/></button></div></div>
    <div className="metric-grid">{cards.map((card) => <article className={`metric-card ${card.color}`} key={card.label}><div className="metric-icon"><AppIcon name={card.icon} size={17}/></div><p>{card.label}</p><strong>{formatNumber(card.value)}</strong><small>{card.note}</small><span className="metric-arrow"><AppIcon name="arrow" size={14}/></span></article>)}</div>
    <div className="dashboard-grid"><article className="panel"><div className="panel-head"><div><h3>Recent imports</h3><p>Lists you imported recently</p></div><button onClick={onImport}>Import CSV</button></div>{recentImports.length ? <div className="activity-list">{recentImports.map((item) => <div className="activity" key={item.id}><span className="csv-icon">CSV</span><div><strong>{item.file_name}</strong><small>{item.client_name} · {item.list_name} · {item.data_source}</small></div><div className="activity-result"><strong>{formatNumber(item.processed_rows)} rows</strong><small>{formatNumber(item.duplicates_linked)} cross-client overlaps</small></div><div className="activity-actions"><span className="status">Complete</span><button className="text-danger" onClick={() => onDeleteImport(item)}>Undo</button></div></div>)}</div> : <EmptyCompact text="Your completed imports will appear here." action="Import a CSV" onAction={onImport} />}</article>
      <article className="panel coverage"><div className="panel-head"><div><h3>Time and money saved</h3><p>See how often existing data was reused</p></div><span className="health-badge"><i/> Healthy</span></div><div className="coverage-spotlight"><strong>{reuseRate}%</strong><span>of imported rows matched data you already owned</span></div><div className="coverage-row"><span>Rows processed</span><strong>{formatNumber(stats.rowsImported)}</strong></div><div className="coverage-row"><span>Unique-record ratio</span><strong>{uniqueRate}%</strong></div><div className="coverage-row"><span>Known companies</span><strong>{formatNumber(stats.companies)}</strong></div><div className="coverage-track"><i style={{ width: `${Math.min(100, reuseRate)}%` }}/></div><p className="coverage-note">Each match means one less prospect you need to scrape again.</p><div className="client-mini"><span>Active client workspaces</span><div>{clients.slice(0, 4).map((client) => <i key={client.id}>{initials(client.name)}</i>)}{clients.length > 4 && <i>+{clients.length - 4}</i>}</div></div></article></div>
  </>;
}

const standardProspectFields = [
  { id: "__name", label: "Name" },
  { id: "__first_name", label: "First name" },
  { id: "__last_name", label: "Last name" },
  { id: "__company", label: "Company" },
  { id: "__email", label: "Email" },
  { id: "__title", label: "Title" },
  { id: "__keywords", label: "Keywords" },
  { id: "__lists", label: "List names" },
  { id: "__clients", label: "Clients" },
  { id: "__linkedin", label: "LinkedIn" },
  { id: "__country", label: "Country" },
  { id: "__person_location", label: "Person location" },
  { id: "__company_location", label: "Company location" },
  { id: "__employee_count", label: "# Employees" },
  { id: "__seniority", label: "Seniority" },
  { id: "__department", label: "Department" },
  { id: "__esp", label: "ESP" },
  { id: "__email_provider_type", label: "Email provider type" },
  { id: "__tags", label: "Tags" },
  { id: "__last_contacted", label: "Last contacted" },
];
const defaultProspectColumns = ["__name", "__company", "__email", "__esp", "__title", "__lists"];
const standardProspectExportFields = [
  { id: "__name", label: "Full Name" },
  { id: "__first_name", label: "First Name" },
  { id: "__last_name", label: "Last Name" },
  { id: "__work_email", label: "Work Email" },
  { id: "__personal_email", label: "Personal Email" },
  { id: "__mobile_number", label: "Mobile Number" },
  { id: "__linkedin", label: "LinkedIn" },
  { id: "__title", label: "Title" },
  { id: "__keywords", label: "Keywords" },
  { id: "__seniority", label: "Seniority" },
  { id: "__department", label: "Department" },
  { id: "__city", label: "City" },
  { id: "__state", label: "State" },
  { id: "__country", label: "Country" },
  { id: "__person_location", label: "Person Location" },
  { id: "__company", label: "Company" },
  { id: "__website", label: "Website" },
  { id: "__employee_count", label: "# Employees" },
  { id: "__employee_count_min", label: "Employee Count Min" },
  { id: "__employee_count_max", label: "Employee Count Max" },
  { id: "__company_location", label: "Company Location" },
  { id: "__company_city", label: "Company City" },
  { id: "__company_state", label: "Company State" },
  { id: "__company_country", label: "Company Country" },
  { id: "__esp", label: "ESP" },
  { id: "__email_provider_type", label: "Email Provider Type" },
  { id: "__mx_records", label: "MX Records" },
  { id: "__mx_status", label: "MX Status" },
  { id: "__mx_checked_at", label: "MX Checked At" },
  { id: "__lists", label: "List Names" },
  { id: "__clients", label: "Client Names" },
  { id: "__tags", label: "Tags" },
  { id: "__last_contacted", label: "Last Contacted" },
  { id: "__created_at", label: "Created At" },
  { id: "__updated_at", label: "Updated At" },
];
const defaultProspectExportFields = ["__name", "__work_email", "__company", "__website", "__title", "__esp"];

function prospectFieldValue(prospect: Prospect, field: string) {
  if (field === "__name") return String(prospect.full_name || "");
  if (field === "__first_name") return String(prospect.first_name || "");
  if (field === "__last_name") return String(prospect.last_name || "");
  if (field === "__company") return String(prospect.company_name || "");
  if (field === "__email") return String(prospect.work_email || prospect.personal_email || "");
  if (field === "__title") return String(prospect.title || "");
  if (field === "__keywords") return Array.isArray(prospect.keywords) ? prospect.keywords.join(", ") : "";
  if (field === "__lists") return Array.isArray(prospect.list_names) ? prospect.list_names.join(", ") : "";
  if (field === "__clients") return Array.isArray(prospect.client_names) ? prospect.client_names.join(", ") : "";
  if (field === "__linkedin") return String(prospect.linkedin_url || "");
  if (field === "__country") return String(prospect.country || "");
  if (field === "__person_location") return [prospect.city, prospect.state, prospect.country].filter(Boolean).join(", ");
  if (field === "__company_location") return [prospect.company_location, prospect.company_city, prospect.company_state, prospect.company_country].filter(Boolean).join(", ");
  if (field === "__employee_count") {
    const minimum = prospect.employee_count_min;
    const maximum = prospect.employee_count_max;
    if (minimum == null && maximum == null) return "";
    if (minimum != null && maximum == null) return `${formatNumber(minimum)}+`;
    return minimum === maximum ? formatNumber(minimum) : `${formatNumber(minimum)}–${formatNumber(maximum)}`;
  }
  if (field === "__seniority") return String(prospect.seniority || "");
  if (field === "__department") return String(prospect.department || "");
  if (field === "__esp") return String(prospect.esp || "");
  if (field === "__email_provider_type") return String(prospect.email_provider_type || "Unknown");
  if (field === "__tags") return Array.isArray(prospect.tags) ? prospect.tags.map((tag) => tag.name).join(", ") : "";
  if (field === "__last_contacted") return prospect.last_contacted_at ? new Date(prospect.last_contacted_at).toLocaleDateString("en-IN") : "";
  if (field.startsWith("custom:")) return customFieldValue(parseAllData(prospect.all_data), field.slice(7));
  return String(parseAllData(prospect.all_data)[field] || "");
}

function prospectMembershipItems(prospect: Prospect, includeClient: boolean) {
  const memberships = Array.isArray(prospect.list_memberships) ? prospect.list_memberships : [];
  if (memberships.length) {
    return memberships
      .filter((membership) => membership?.listName)
      .map((membership) => ({
        key: membership.listId || `${membership.clientId}:${membership.listName}`,
        listName: membership.listName,
        clientName: membership.clientName || "Unknown client",
        label: includeClient ? `${membership.clientName || "Unknown client"}: ${membership.listName}` : membership.listName,
      }))
      .sort((left, right) => left.label.localeCompare(right.label));
  }
  return (prospect.list_names ?? []).map((listName) => ({ key: listName, listName, clientName: "", label: listName }));
}

function ListMembershipCell({ prospect, includeClient, onShowAll }: { prospect: Prospect; includeClient: boolean; onShowAll: () => void }) {
  const memberships = prospectMembershipItems(prospect, includeClient);
  if (!memberships.length) return <span className="missing-value">No linked list</span>;
  const hiddenCount = Math.max(0, memberships.length - 2);
  return <div className="membership-chips" title={`${memberships.length} linked ${memberships.length === 1 ? "list" : "lists"}`}>
    {memberships.slice(0, 2).map((membership) => <span key={membership.key}>{membership.label}</span>)}
    {hiddenCount ? <button type="button" aria-label={`Show all ${memberships.length} list memberships for ${prospect.full_name || "this prospect"}`} onClick={(event) => { event.stopPropagation(); onShowAll(); }}>+{hiddenCount} more</button> : null}
  </div>;
}

function ProspectTable({ prospects, total, fields, filters, page, clients, search = "", sort, direction, clientId = "", active = true, companyScope = null, onClearCompanyScope, onSeeCompanies, onRemoveFromClient, onSortChange, onFiltersChange, onPageChange, onSelect, onImport, onRefresh }: { prospects: Prospect[]; total: number; fields: string[]; filters: ProspectFilter[]; page: number; clients: ClientRecord[]; search?: string; sort: string; direction: "asc" | "desc"; clientId?: string; active?: boolean; companyScope?: CompanyScope | null; onClearCompanyScope?: () => void; onSeeCompanies: (scope: PeopleScope) => void; onRemoveFromClient?: (prospect: Prospect) => Promise<void>; onSortChange: (sort: string, direction: "asc" | "desc") => void; onFiltersChange: (filters: ProspectFilter[]) => void; onPageChange: (page: number) => void; onSelect: (row: Prospect) => void; onImport: () => void; onRefresh: () => void }) {
  const [visibleColumns, setVisibleColumns] = useState<string[]>(defaultProspectColumns);
  const [columnMenu, setColumnMenu] = useState(false);
  const columnMenuRef = useRef<HTMLDivElement>(null);
  useDismiss(columnMenuRef, () => setColumnMenu(false), columnMenu);
  const [tab, setTab] = useState<"records" | "coverage">("records");
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
  const [filtersOpen, setFiltersOpen] = useState(true);
  const customFields = useMemo(() => buildCustomFieldDefinitions(fields), [fields]);
  const allColumns = useMemo(() => [...standardProspectFields, ...customFields], [customFields]);
  const exportFieldCatalog = useMemo(() => [...standardProspectExportFields, ...customFields], [customFields]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      try {
        const saved = JSON.parse(localStorage.getItem("prospecthub-visible-columns") || "[]") as string[];
        if (Array.isArray(saved) && saved.length) {
          const withListNames = saved.includes("__lists") ? saved : [...saved, "__lists"];
          setVisibleColumns(withListNames);
          localStorage.setItem("prospecthub-visible-columns", JSON.stringify(withListNames));
        }
      } catch { /* Keep the standard columns. */ }
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

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

  const configuredDefinitions = visibleColumns.map((id) => allColumns.find((column) => column.id === id)).filter((column): column is { id: string; label: string } => Boolean(column));
  const visibleDefinitions = configuredDefinitions.length ? configuredDefinitions : standardProspectFields.slice(0, 4);
  const effectiveFilters = filters.filter((filter) => filter.values.length || filter.operator === "empty" || filter.operator === "not_empty");
  const selectionKey = JSON.stringify({ clientId, search: search.trim(), filters: effectiveFilters.map(({ field, operator, values }) => ({ field, operator, values })) });
  const selectionMatchesQuery = selectionQueryKey === selectionKey;
  const selectedCount = !selectionMatchesQuery ? 0 : selectionMode === "all_matching" ? Math.max(0, total - excludedIds.size) : selectedIds.size;
  const totalPages = Math.max(1, Math.ceil(total / 50));
  const firstRecord = total ? (page - 1) * 50 + 1 : 0;
  const lastRecord = Math.min(page * 50, total);

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

  function toggleSelected(id: string) {
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
  }

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
        filters: effectiveFilters.map(({ field, operator, values }) => ({ field, operator, values })),
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
      <div><p className="eyebrow">PROSPECTS</p><h2>Find people</h2><p>Search and filter every prospect saved in your master database.</p></div>
      <div className="entity-pivot-actions"><button className="secondary" onClick={() => onSeeCompanies({ search: search.trim(), filters: effectiveFilters.map(({ field, operator, values }) => ({ field, operator, values })) })}>See Companies <AppIcon name="arrow" size={14}/></button><button className="primary" onClick={onImport}><AppIcon name="upload" size={15}/> Import prospects</button></div>
    </div>
    {companyScope ? <div className="cross-scope-banner" role="status"><span>Showing people inside the companies from your previous Company DB search.</span><button onClick={onClearCompanyScope}>Clear company scope</button></div> : null}
    <div className="people-tabs">
      <button className={tab === "records" ? "active" : ""} onClick={() => setTab("records")}>All prospects <span>{formatNumber(total)}</span></button>
      <button className={tab === "coverage" ? "active" : ""} onClick={() => setTab("coverage")}>Field coverage <span>{formatNumber(fields.length)}</span></button>
    </div>
    {tab === "coverage" ? <article className="panel field-coverage">
      <div className="coverage-summary"><span className="coverage-symbol">✓</span><div><strong>{formatNumber(fields.length)} uploaded fields available</strong><p>Every field from your CSV is saved and ready to filter or display.</p></div></div>
      <div className="coverage-groups"><section><h3>Standard columns</h3><div>{standardProspectFields.map((field, index) => <span className={`field-chip tone-${index % 4}`} key={field.id}>{field.label}</span>)}</div></section><section><h3>Uploaded CSV fields</h3><div>{fields.map((field, index) => <span className={`field-chip tone-${index % 4}`} key={field}>{field}</span>)}</div></section></div>
    </article> : <div className={`people-layout ${filtersOpen ? "" : "filters-collapsed"}`}>
      <article className="panel results-panel">
        <div className="results-toolbar">
          <div className="results-count"><strong>{formatNumber(total)} people</strong><span>{effectiveFilters.length ? `${effectiveFilters.length} active filter${effectiveFilters.length === 1 ? "" : "s"} · all matching records` : "Master database"}</span>{total ? <button className="select-all-matching-button" onClick={selectAllMatching}>{selectionMode === "all_matching" && selectionMatchesQuery && !excludedIds.size ? `✓ All ${formatNumber(total)} selected` : `Select all ${formatNumber(total)} across pages`}</button> : null}</div>
          <div className="workspace-actions">
            <label><span className="sr-only">Saved ICP view</span><select defaultValue="" onChange={(event) => applyView(event.target.value)}><option value="">Saved views</option>{savedViews.map((view) => <option key={view.id} value={view.id}>{view.name}</option>)}</select></label>
            <button className="outline-button" onClick={() => void saveCurrentView()}>☆ Save view</button>
            <button className="outline-button" disabled={exportingProspects} title="Choose rows and fields for a CSV export" onClick={() => openExportDialog("all_matching")}>{exportingProspects ? "Exporting…" : "↓ Export CSV"}</button>
            {!clientId ? <button className="outline-button" disabled={espScanning} title="Detect MX-visible gateways and mailbox providers. API-only email security products are not visible in MX records." onClick={() => void scanEmailProviders()}>{espScanning ? "Scanning MX…" : "Detect ESPs"}</button> : null}
            <label><span className="sr-only">Sort prospects</span><select value={`${sort}:${direction}`} onChange={(event) => { const [nextSort, nextDirection] = event.target.value.split(":"); onSortChange(nextSort, nextDirection as "asc" | "desc"); }}><option value="created_at:desc">Newest first</option><option value="name:asc">Name A to Z</option><option value="company:asc">Company A to Z</option><option value="title:asc">Title A to Z</option><option value="last_contacted:desc">Recently contacted</option></select></label>
            <button className={`outline-button filter-toggle ${filtersOpen ? "active" : ""}`} aria-pressed={filtersOpen} onClick={() => setFiltersOpen((open) => !open)}><AppIcon name="filter" size={14}/> Filters {effectiveFilters.length ? <span>{effectiveFilters.length}</span> : null}</button>
            <div className="column-control" ref={columnMenuRef}><button className="outline-button" aria-expanded={columnMenu} onClick={() => setColumnMenu((open) => !open)}><AppIcon name="columns" size={14}/> Columns <span>{visibleDefinitions.length}</span></button>{columnMenu && <div className="column-menu"><div><strong>Choose columns</strong><button onClick={() => { setVisibleColumns(defaultProspectColumns); localStorage.setItem("prospecthub-visible-columns", JSON.stringify(defaultProspectColumns)); }}>Reset</button></div>{allColumns.map((field) => <label key={field.id}><input type="checkbox" checked={visibleColumns.includes(field.id)} onChange={() => toggleColumn(field.id)} />{field.label}</label>)}</div>}</div>
          </div>
        </div>
        {notice ? <div className="inline-notice" role="status">{notice}<button aria-label="Dismiss notification" onClick={() => setNotice("")}>×</button></div> : null}
        {selectedCount ? <div className="bulk-bar"><strong>{formatNumber(selectedCount)} selected {selectionMode === "all_matching" ? "across all pages" : "across pages"}</strong>{selectionMode === "explicit" && selectedCount < total ? <button onClick={selectAllMatching}>Select all {formatNumber(total)}</button> : null}<button onClick={() => openExportDialog("selected")}>↓ Export selected</button>{selectionMode === "explicit" ? <><button disabled={bulkBusy} onClick={() => void bulkAction("tag")}>＋ Add tag</button><select aria-label="Client for contact history" value={bulkClientId} onChange={(event) => setBulkClientId(event.target.value)}><option value="">Choose client</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select><button disabled={bulkBusy || !bulkClientId} onClick={() => void bulkAction("mark_contacted")}>✓ Mark contacted</button></> : <span className="selection-scope-note">Database-wide selection is ready to export</span>}<button onClick={clearSelection}>Clear</button></div> : null}
        {effectiveFilters.length ? <div className="active-filter-strip">{effectiveFilters.flatMap((filter) => {
          const label = filterLabel(filter.field, customFields);
          if (filter.operator === "empty" || filter.operator === "not_empty") return [<button key={filter.id} onClick={() => onFiltersChange(filters.filter((item) => item.id !== filter.id))}>{label}: {filter.operator === "empty" ? "Empty" : "Not empty"} <span>×</span></button>];
          const prefix = filter.operator === "not_contains" || filter.operator === "not_equals" ? "Exclude " : filter.operator === "boolean" ? "Boolean " : "";
          return filter.values.map((value) => <button key={`${filter.id}-${value}`} onClick={() => updateFilter(filter.id, { values: filter.values.filter((item) => item !== value) })}>{prefix}{label}: {filterChipValue(filter.field, value)} <span>×</span></button>);
        })}<button className="clear-filter-chip" onClick={() => onFiltersChange([])}>Clear all</button></div> : null}
        {prospects.length ? <><div className="master-scroll-top" ref={topScrollRef} onScroll={(event) => syncHorizontalScroll(event.currentTarget, tableScrollRef.current)} aria-label="Horizontal table scroll"><div style={{ width: tableScrollWidth }}/></div><div className="master-table-wrap" ref={tableScrollRef} onScroll={(event) => syncHorizontalScroll(event.currentTarget, topScrollRef.current)}><table className="master-data-table"><thead><tr><th className="select-column"><input aria-label="Select all prospects on this page" title="Select all prospects on this page" type="checkbox" checked={prospects.length > 0 && prospects.every((prospect) => isProspectSelected(prospect.id))} onChange={togglePageSelection}/></th>{visibleDefinitions.map((field) => <th key={field.id}>{field.label}</th>)}<th className="row-detail-column">{onRemoveFromClient ? "Actions" : ""}</th></tr></thead><tbody>{prospects.map((person) => <tr className={isProspectSelected(person.id) ? "selected" : ""} key={person.id} onClick={() => onSelect(person)}><td className="select-column" onClick={(event) => event.stopPropagation()}><input aria-label={`Select ${person.full_name || "prospect"}`} type="checkbox" checked={isProspectSelected(person.id)} onChange={() => toggleSelected(person.id)}/></td>{visibleDefinitions.map((field) => { const value = prospectFieldValue(person, field.id); return <td key={field.id}>{field.id === "__name" ? <div className="compact-person"><span>{initials(value)}</span><strong>{value || "Unnamed prospect"}</strong></div> : field.id === "__email" ? <span className="email-cell">{value || "-"}</span> : field.id === "__esp" ? <span className={`esp-cell ${person.email_provider_type === "SEG" ? "seg" : ""}`} title={Array.isArray(person.mx_records) && person.mx_records.length ? person.mx_records.join("\n") : "Run Detect ESPs to check this domain"}><strong>{value || "Not checked"}</strong><small>{person.email_provider_type || "Unknown"}</small></span> : field.id === "__lists" ? <ListMembershipCell prospect={person} includeClient={!clientId} onShowAll={() => onSelect(person)} /> : <span title={value}>{value || "-"}</span>}</td>; })}<td className="row-detail-column" onClick={(event) => event.stopPropagation()}>{onRemoveFromClient ? <button className="row-danger client-remove-prospect" onClick={() => void onRemoveFromClient(person)}>Remove</button> : "›"}</td></tr>)}</tbody></table></div><div className="table-footer"><span>Showing {formatNumber(firstRecord)} to {formatNumber(lastRecord)} of {formatNumber(total)} matching records</span><div><button disabled={page <= 1} onClick={() => onPageChange(page - 1)}>← Previous</button><span>Page {page} of {totalPages}</span><button disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Next →</button></div></div></> : <EmptyState title="No matching prospects" text={effectiveFilters.length ? "Adjust or clear the filters to see more records." : "Import a CSV and your unique prospects will appear here."} action={effectiveFilters.length ? "Clear filters" : "Import CSV"} onAction={effectiveFilters.length ? () => onFiltersChange([]) : onImport} />}
      </article>
      {filtersOpen ? <ApolloFilterPanel filters={filters} customFields={customFields} clientId={clientId} onChange={onFiltersChange}/> : null}
    </div>}
    {exportDialogOpen ? <div className="modal-backdrop" role="presentation"><section className="export-modal" role="dialog" aria-modal="true" aria-labelledby="prospect-export-title"><div className="export-modal-head"><div><p className="eyebrow">CSV EXPORT</p><h2 id="prospect-export-title">Choose prospects and fields</h2><p>Only the fields checked below will be included in the download.</p></div><button aria-label="Close export dialog" disabled={exportingProspects} onClick={() => setExportDialogOpen(false)}>×</button></div><fieldset className="export-scope"><legend>Prospects to export</legend><label htmlFor="export-all-matching"><span className="sr-only">All matching prospects</span><input id="export-all-matching" type="radio" name="export-scope" checked={exportScope === "all_matching"} onChange={() => setExportScope("all_matching")}/><span><strong>All {search.trim() || effectiveFilters.length ? "matching " : ""}prospects</strong><small>{formatNumber(total)} records across every page</small></span></label><label htmlFor="export-selected" className={!selectedCount ? "disabled" : ""}><span className="sr-only">Selected prospects</span><input id="export-selected" type="radio" name="export-scope" disabled={!selectedCount} checked={exportScope === "selected"} onChange={() => setExportScope("selected")}/><span><strong>Selected prospects</strong><small>{formatNumber(selectedCount)} currently selected</small></span></label></fieldset><div className="export-fields-head"><div><strong>Fields to include</strong><span>{formatNumber(exportFields.length)} selected</span></div><div><button onClick={() => setExportFields(exportFieldCatalog.map((field) => field.id))}>Select all</button><button onClick={() => setExportFields(defaultProspectExportFields)}>Recommended</button><button onClick={() => setExportFields([])}>Clear</button></div></div><div className="export-field-grid">{exportFieldCatalog.map((field) => <label key={field.id}><input type="checkbox" checked={exportFields.includes(field.id)} onChange={() => toggleExportField(field.id)}/><span>{field.label}</span></label>)}</div><fieldset className="export-scope export-format"><legend>Output</legend><label htmlFor="export-single"><span className="sr-only">Single CSV file</span><input id="export-single" type="radio" name="export-format" checked={exportFormat === "single"} disabled={exportingProspects} onChange={() => setExportFormat("single")}/><span><strong>One CSV file</strong><small>Everything in a single download, any size</small></span></label><label htmlFor="export-parts"><span className="sr-only">Split into multiple files</span><input id="export-parts" type="radio" name="export-format" checked={exportFormat === "parts"} disabled={exportingProspects} onChange={() => setExportFormat("parts")}/><span><strong>Split into parts</strong><small>Multiple CSVs of <select aria-label="Rows per file" disabled={exportingProspects || exportFormat !== "parts"} value={exportRowsPerFile} onClick={(event) => event.stopPropagation()} onChange={(event) => setExportRowsPerFile(Number(event.target.value))}>{[10000, 25000, 50000, 100000].map((size) => <option key={size} value={size}>{formatNumber(size)}</option>)}</select> rows each</small></span></label></fieldset>{!fileSystemAccessSupported() ? <p className="export-hint">Your browser will download the file{exportFormat === "parts" ? "s" : ""} when the export finishes. For very large exports, a Chromium browser streams straight to disk.</p> : null}{exportProgress ? <div className="export-progress" role="status"><span className="export-progress-bar"><i style={{ width: `${exportProgress.total ? Math.min(100, Math.round((exportProgress.exported / Math.max(1, exportProgress.total)) * 100)) : 100}%` }}/></span><span>Exported {formatNumber(exportProgress.exported)}{exportProgress.total ? ` of ${formatNumber(exportProgress.total)}` : ""} rows{exportProgress.files > 1 ? ` · ${formatNumber(exportProgress.files)} files` : ""}</span></div> : null}<div className="modal-actions">{exportingProspects ? <button className="secondary" onClick={cancelExport}>Cancel export</button> : <button className="secondary" onClick={() => setExportDialogOpen(false)}>Close</button>}<button className="primary" disabled={exportingProspects || !exportFields.length || (exportScope === "selected" && !selectedCount)} onClick={() => void exportProspectsCsv()}>{exportingProspects ? "Exporting…" : `Export ${formatNumber(exportScope === "selected" ? selectedCount : total)} prospects`}</button></div></section></div> : null}
  </section>;
}



function CompanyTable({ companies, total, covered, prospectTotal, page, pageSize, clientId = "", search = "", filters = [], peopleScope = null, onClearPeopleScope, onSeePeople, onFilters, onPageChange, onImport }: { companies: Company[]; total: number; covered: number; prospectTotal: number; page: number; pageSize: number; clientId?: string; search?: string; filters?: ProspectFilter[]; peopleScope?: PeopleScope | null; onClearPeopleScope?: () => void; onSeePeople: (scope: CompanyScope) => void; onFilters?: (filters: ProspectFilter[]) => void; onPageChange: (page: number) => void; onImport: () => void }) {
  const [selectedCompany, setSelectedCompany] = useState<Company | null>(null);
  const [prospectsByCompany, setProspectsByCompany] = useState<Record<string, Prospect[]>>({});
  const [prospectTotalsByCompany, setProspectTotalsByCompany] = useState<Record<string, number>>({});
  const [loadingCompany, setLoadingCompany] = useState("");
  const [companyError, setCompanyError] = useState("");
  const [companyNotice, setCompanyNotice] = useState("");
  const [exportingCompanies, setExportingCompanies] = useState(false);
  const [companyExportScope, setCompanyExportScope] = useState<"all" | "with_websites">("all");
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const resultStart = total ? (page - 1) * pageSize + 1 : 0;
  const resultEnd = Math.min(page * pageSize, total);

  async function openCompany(company: Company) {
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
  }

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
    <div className="section-intro company-intro"><div><p className="eyebrow">COMPANIES</p><h2>Companies already in your database.</h2><p>Open a company to see its prospects in a separate panel.</p></div><div className="company-intro-actions">{!clientId ? <div className="company-export-control"><label><span>Export scope</span><select aria-label="Company export scope" value={companyExportScope} disabled={exportingCompanies} onChange={(event) => setCompanyExportScope(event.target.value as "all" | "with_websites")}><option value="all">All companies</option><option value="with_websites">Only with websites</option></select></label><button className="secondary company-export-button" disabled={exportingCompanies} title="Export all matching companies across every page" onClick={() => void exportCompanies()}>{exportingCompanies ? "Exporting…" : "↓ Export CSV"}</button></div> : null}<button className="secondary" onClick={() => onSeePeople({ search: search.trim(), filters })}>See People <AppIcon name="arrow" size={14}/></button><button className="primary" onClick={onImport}><AppIcon name="plus" size={15}/> Add from CSV</button></div></div>
    <div className="company-summary"><div className="summary-violet"><span>Companies in database</span><strong>{formatNumber(total)}</strong><small>Complete company directory</small></div><div className="summary-blue"><span>With prospect coverage</span><strong>{formatNumber(covered)}</strong><small>{total ? `${Math.round((covered / total) * 100)}% of companies` : "No companies yet"}</small></div><div className="summary-green"><span>Total linked prospects</span><strong>{formatNumber(prospectTotal)}</strong><small>Across all matching companies</small></div><p><AppIcon name="quality" size={17}/><span>Matched by normalized domain first, then company name.</span></p></div>
    {peopleScope ? <div className="cross-scope-banner" role="status"><span>Showing companies represented in your previous People DB search.</span><button onClick={onClearPeopleScope}>Clear people scope</button></div> : null}
    {onFilters ? <CompanyFilterPanel filters={filters} onChange={onFilters} /> : null}
    {companyError ? <div className="inline-error" role="alert">{companyError}</div> : null}
    {companyNotice ? <div className="inline-notice company-export-notice" role="status">{companyNotice}<button aria-label="Dismiss export notification" onClick={() => setCompanyNotice("")}>×</button></div> : null}
    <article className="panel company-table-panel"><div className="panel-head company-panel-head"><div><h3>Company database</h3><p>Showing {formatNumber(resultStart)}–{formatNumber(resultEnd)} of {formatNumber(total)} companies. Click any row to open its details.</p></div><span className="directory-badge">{formatNumber(total)} total</span></div>{companies.length ? <><div className="table-wrap"><table className="company-table"><thead><tr><th>Company</th><th>Website</th><th>Prospects</th><th>Client coverage</th><th>Added</th><th>Status</th></tr></thead><tbody>{companies.map((company) => { const tone = colorTone(company.id); return <tr className={`company-row tone-${tone}`} key={company.id} onClick={() => void openCompany(company)}><td><div className="company-identity"><button className="company-open" aria-label={`Open ${company.name || company.domain || "company"} details`} onClick={(event) => { event.stopPropagation(); void openCompany(company); }}><AppIcon name="arrow" size={15}/></button><span className={`company-logo tone-${tone}`}>{initials(company.name)}</span><div><strong>{company.name || company.domain || "Unnamed company"}</strong><small>{company.prospect_count ? `${formatNumber(company.prospect_count)} people available` : "No prospects linked"}</small></div></div></td><td onClick={(event) => event.stopPropagation()}>{company.domain ? <a href={`https://${company.domain}`} target="_blank" rel="noreferrer">{company.domain}</a> : <span className="missing-value">No domain</span>}</td><td><span className="prospect-count-badge">{formatNumber(company.prospect_count)}</span></td><td>{formatNumber(company.client_count)} {company.client_count === 1 ? "client" : "clients"}</td><td>{new Date(company.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><span className={`coverage-status ${company.prospect_count ? "known" : "new"}`}>{company.prospect_count ? "Covered" : "Needs prospects"}</span></td></tr>; })}</tbody></table></div><div className="company-pagination"><span>Page {page} of {totalPages}</span><div><button disabled={page <= 1} onClick={() => onPageChange(page - 1)}>← Previous</button><button disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Next →</button></div></div></> : <EmptyState title="No known companies yet" text="Companies found in imported lists will appear here automatically." action="Import CSV" onAction={onImport} />}</article>
    {selectedCompany ? <CompanyDrawer company={selectedCompany} prospects={prospectsByCompany[selectedCompany.id] ?? []} total={prospectTotalsByCompany[selectedCompany.id] ?? selectedCompany.prospect_count} loading={loadingCompany === selectedCompany.id} error={companyError} onLoadMore={() => void loadMoreProspects(selectedCompany)} onClose={() => { setSelectedCompany(null); setCompanyError(""); }} /> : null}
  </section>;
}

function CompanyDrawer({ company, prospects, total, loading, error, onLoadMore, onClose }: { company: Company; prospects: Prospect[]; total: number; loading: boolean; error: string; onLoadMore: () => void; onClose: () => void }) {
  useEffect(() => {
    function closeOnEscape(event: KeyboardEvent) { if (event.key === "Escape") onClose(); }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);

  return <div className="drawer-backdrop">
    <button className="drawer-dismiss" aria-label="Close company details" onClick={onClose}/>
    <aside className="drawer company-drawer" role="dialog" aria-modal="true" aria-labelledby="company-drawer-title">
      <div className="company-drawer-header">
        <button className="drawer-close" aria-label="Close company details" onClick={onClose}>×</button>
        <div className="drawer-person company-drawer-identity"><span className={`tone-${colorTone(company.id)}`}>{initials(company.name)}</span><div><p className="eyebrow">COMPANY DETAILS</p><h2 id="company-drawer-title">{company.name || company.domain || "Unnamed company"}</h2>{company.domain ? <a href={`https://${company.domain}`} target="_blank" rel="noreferrer">{company.domain} ↗</a> : <p>No website saved</p>}</div></div>
        <div className="drawer-summary"><span><b>{formatNumber(company.prospect_count)}</b>prospects</span><span><b>{formatNumber(company.client_count)}</b>clients</span><span><b>{new Date(company.created_at).toLocaleDateString("en-IN", { month: "short", year: "numeric" })}</b>added</span></div>
        <div className="company-drawer-title"><div><strong>Linked prospects</strong><small>People connected to this company</small></div><span>{formatNumber(prospects.length)} of {formatNumber(total)}</span></div>
      </div>
      <div className="company-drawer-body">
        {loading && !prospects.length ? <div className="company-prospect-loading">Loading prospects…</div> : prospects.length ? <><div className="company-prospect-list"><table><thead><tr><th>Name</th><th>Title</th><th>Email</th><th>Seniority</th><th>Location</th></tr></thead><tbody>{prospects.map((prospect) => <tr key={prospect.id}><td><div className="compact-person"><span className={`tone-${colorTone(prospect.id)}`}>{initials(prospect.full_name)}</span><strong>{prospect.full_name || "Unnamed prospect"}</strong></div></td><td>{prospect.title || "-"}</td><td>{prospect.work_email || prospect.personal_email || "-"}</td><td>{String(prospect.seniority || "-")}</td><td>{[prospect.city, prospect.country].filter(Boolean).join(", ") || "-"}</td></tr>)}</tbody></table></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{prospects.length < total ? <button className="load-more-prospects" disabled={loading} onClick={onLoadMore}>{loading ? "Loading…" : `Load ${Math.min(50, total - prospects.length)} more prospects (${formatNumber(total - prospects.length)} remaining)`}</button> : <div className="all-prospects-loaded"><AppIcon name="check" size={14}/> All {formatNumber(total)} prospects loaded</div>}</> : error ? <div className="inline-error" role="alert">{error}</div> : <div className="drawer-empty">No linked prospects found.</div>}
      </div>
    </aside>
  </div>;
}

function ClientsView({ clients, onOpen, onImport }: { clients: ClientRecord[]; onOpen: (client: ClientRecord) => void; onImport: () => void }) {
  return <><div className="section-intro"><div><p className="eyebrow">CLIENT WORKSPACES</p><h2>Keep every ICP list organized.</h2><p>Each client keeps its original lists while sharing clean prospect records with the master.</p></div><button className="primary" onClick={onImport}>＋ Import client list</button></div>{clients.length ? <div className="clients-grid">{clients.map((client, index) => <button className="client-card" key={client.id} onClick={() => onOpen(client)}><span className={`client-logo tone-${index % 4}`}>{initials(client.name)}</span><div className="client-title"><strong>{client.name}</strong><small>Active workspace</small></div><div className="client-stats"><span><b>{formatNumber(client.prospect_count)}</b>prospects</span><span><b>{formatNumber(client.list_count)}</b>lists</span></div><div className="client-link">Open client <span>→</span></div></button>)}</div> : <EmptyState title="Create your first client" text="Import a list and enter the client name. The workspace will be created automatically." action="Import client list" onAction={onImport} />}</>;
}

function ClientDetail({ client, clients, lists, onBack, onOpenList, onSelectProspect, onImport, onDeleteClient, onDeleteList }: { client: ClientRecord; clients: ClientRecord[]; lists: ListRecord[]; onBack: () => void; onOpenList: (list: ListRecord) => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: () => void; onDeleteList: (list: ListRecord) => void }) {
  const [cooldown, setCooldown] = useState(client.cooldown_days ?? 90);
  const [cooldownState, setCooldownState] = useState("");
  const [tab, setTab] = useState<"lists" | "prospects" | "companies">("lists");
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(null);
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(null);
  async function saveCooldown() {
    setCooldownState("Saving…");
    try { const result = await api<{ cooldownDays: number }>(`/api/clients/${encodeURIComponent(client.id)}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cooldownDays: cooldown }) }); setCooldown(result.cooldownDays); setCooldownState("Saved"); }
    catch (caught) { setCooldownState(caught instanceof Error ? caught.message : "Unable to save"); }
  }
  return <><button className="back" onClick={onBack}>← All clients</button><div className="client-hero"><span className="client-logo tone-0">{initials(client.name)}</span><div><p className="eyebrow">CLIENT WORKSPACE</p><h2>{client.name}</h2><p>{formatNumber(client.prospect_count)} prospects across {formatNumber(client.list_count)} lists</p></div><div className="cooldown-setting"><label htmlFor="cooldown-days">Contact cooldown</label><div><input id="cooldown-days" type="number" min="0" max="730" value={cooldown} onChange={(event) => setCooldown(Number(event.target.value))}/><span>days</span><button onClick={() => void saveCooldown()}>Save</button></div><small role="status">{cooldownState || "Used when checking reuse eligibility"}</small></div><div className="client-actions"><button className="primary" onClick={onImport}>＋ Import another list</button><button className="danger-button" onClick={onDeleteClient}>Delete client</button></div></div>
    <div className="client-database-tabs" role="tablist" aria-label={`${client.name} databases`}><button role="tab" aria-selected={tab === "lists"} className={tab === "lists" ? "active" : ""} onClick={() => setTab("lists")}><AppIcon name="upload" size={15}/> Uploaded lists <span>{formatNumber(client.list_count)}</span></button><button role="tab" aria-selected={tab === "prospects"} className={tab === "prospects" ? "active" : ""} onClick={() => setTab("prospects")}><AppIcon name="database" size={15}/> Master DB <span>{formatNumber(client.prospect_count)}</span></button><button role="tab" aria-selected={tab === "companies"} className={tab === "companies" ? "active" : ""} onClick={() => setTab("companies")}><AppIcon name="company" size={15}/> Company DB</button></div>
    <div className={`client-tab-panel ${tab === "lists" ? "active" : ""}`}><article className="panel table-panel"><div className="panel-head"><div><h3>Uploaded lists</h3><p>Open any list to search its original rows and inspect preserved fields.</p></div></div>{lists.length ? <div className="table-wrap"><table><thead><tr><th>List</th><th>Data source</th><th>Source file</th><th>Rows</th><th>Fields preserved</th><th>New to master</th><th>Cross-client duplicates</th><th>Imported</th><th>Actions</th></tr></thead><tbody>{lists.map((list) => <tr key={list.id}><td><button className="list-open-button" onClick={() => onOpenList(list)}><strong>{list.name}</strong><span>Open →</span></button></td><td><span className="data-source-badge">{list.data_source}</span></td><td>{list.source_file_name}</td><td>{formatNumber(list.uploaded_rows)}</td><td><span className="field-verified">✓ {formatNumber(list.field_count)} fields</span></td><td><span className="data-pill green">+{formatNumber(list.unique_added)}</span></td><td>{formatNumber(list.duplicates_linked)}</td><td>{new Date(list.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><button className="row-danger" onClick={() => onDeleteList(list)}>Delete</button></td></tr>)}</tbody></table></div> : <EmptyCompact text="No lists have been imported for this client." action="Import list" onAction={onImport} />}</article></div>
    <div className={`client-tab-panel ${tab === "prospects" ? "active" : ""}`}><ClientMasterDatabase key={`people:${JSON.stringify(companyPeopleScope)}`} client={client} clients={clients} active={tab === "prospects"} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onSeeCompanies={(scope) => { setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/></div>
    <div className={`client-tab-panel ${tab === "companies" ? "active" : ""}`}><ClientCompanyDatabase key={`companies:${JSON.stringify(peopleCompanyScope)}`} client={client} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onSeePeople={(scope) => { setCompanyPeopleScope(scope); setTab("prospects"); }} onImport={onImport}/></div>
  </>;
}

function ClientMasterDatabase({ client, clients, active, companyScope, onClearCompanyScope, onSeeCompanies, onSelect, onImport }: { client: ClientRecord; clients: ClientRecord[]; active: boolean; companyScope: CompanyScope | null; onClearCompanyScope: () => void; onSeeCompanies: (scope: PeopleScope) => void; onSelect: (prospect: Prospect) => void; onImport: () => void }) {
  const [prospects, setProspects] = useState<Prospect[]>([]);
  const [total, setTotal] = useState(client.prospect_count);
  const [fields, setFields] = useState<string[]>([]);
  const [filters, setFilters] = useState<ProspectFilter[]>([]);
  const [page, setPage] = useState(1);
  const [sort, setSort] = useState("created_at");
  const [direction, setDirection] = useState<"asc" | "desc">("desc");
  const [search, setSearch] = useState("");
  const [refresh, setRefresh] = useState(0);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const fieldsLoaded = useRef(false);
  const deferredSearch = useDeferredValue(search);
  const encodedFilters = useMemo(() => JSON.stringify(filters.map(({ field, operator, values }) => ({ field, operator, values }))), [filters]);
  useEffect(() => {
    let current = true;
    const path = prospectApiPath({ search: deferredSearch, page, sort, direction, filters: encodedFilters, clientId: client.id, includeFields: !fieldsLoaded.current, companyScope });
    void (async () => {
      setRefreshing(true);
      try {
        const data = await api<{ prospects: Prospect[]; total: number; fields?: string[] }>(path);
        if (current) { setProspects(data.prospects); setTotal(data.total); if (data.fields?.length) { fieldsLoaded.current = true; setFields(data.fields); } setError(""); }
      } catch (caught) { if (current) setError(caught instanceof Error ? caught.message : "Unable to load the client master database."); }
      finally { if (current) { setLoading(false); setRefreshing(false); } }
    })();
    return () => { current = false; };
  }, [client.id, client.prospect_count, deferredSearch, page, sort, direction, encodedFilters, refresh, companyScope]);
  async function removeFromClient(prospect: Prospect) {
    if (!window.confirm(`Remove ${prospect.full_name || "this prospect"} from ${client.name}? The Master DB record will be preserved.`)) return;
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}/prospects/${encodeURIComponent(prospect.id)}`, { method: "DELETE" });
      setRefresh((value) => value + 1);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to remove this prospect from the client."); }
  }
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT MASTER DB</p><h3>{client.name} prospects</h3><p>Every master prospect connected to this client, across all uploaded lists.</p></div><button className="secondary" onClick={() => onSeeCompanies({ search: deferredSearch.trim(), filters: filters.map(({ field, operator, values }) => ({ field, operator, values })) })}>See Companies <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span>⌕</span><input aria-label={`Search ${client.name} prospects`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this client database…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client prospects…</div> : null}{loading ? <div className="workspace-loading">Preparing client database…</div> : <ProspectTable prospects={prospects} total={total} fields={fields} filters={filters} page={page} clients={clients} search={deferredSearch} sort={sort} direction={direction} clientId={client.id} companyScope={companyScope} onClearCompanyScope={onClearCompanyScope} onSeeCompanies={onSeeCompanies} onRemoveFromClient={removeFromClient} onSortChange={(nextSort, nextDirection) => { setSort(nextSort); setDirection(nextDirection); setPage(1); }} onFiltersChange={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onSelect={onSelect} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)} active={active}/>}</section>;
}

function ClientCompanyDatabase({ client, peopleScope, onClearPeopleScope, onSeePeople, onImport }: { client: ClientRecord; peopleScope: PeopleScope | null; onClearPeopleScope: () => void; onSeePeople: (scope: CompanyScope) => void; onImport: () => void }) {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [summary, setSummary] = useState({ total: 0, covered: 0, prospectTotal: 0, pageSize: 50 });
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [filters, setFilters] = useState<ProspectFilter[]>([]);
  const deferredSearch = useDeferredValue(search);
  useEffect(() => {
    let current = true;
    const path = companyApiPath({ search: deferredSearch, clientId: client.id, page, filters, peopleScope });
    void (async () => {
      setRefreshing(true);
      try {
        const data = await api<{ companies: Company[]; total: number; covered: number; prospectTotal: number; pageSize: number }>(path);
        if (current) { setCompanies(data.companies); setSummary({ total: data.total, covered: data.covered, prospectTotal: data.prospectTotal, pageSize: data.pageSize }); setError(""); }
      } catch (caught) { if (current) setError(caught instanceof Error ? caught.message : "Unable to load the client company database."); }
      finally { if (current) { setLoading(false); setRefreshing(false); } }
    })();
    return () => { current = false; };
  }, [client.id, client.prospect_count, deferredSearch, page, filters, peopleScope]);
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT COMPANY DB</p><h3>{client.name} companies</h3><p>Companies represented by prospects in this client workspace.</p></div><button className="secondary" onClick={() => onSeePeople({ search: deferredSearch.trim(), filters })}>See People <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span>⌕</span><input aria-label={`Search ${client.name} companies`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search client companies…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client companies…</div> : null}{loading ? <div className="workspace-loading">Preparing company database…</div> : <CompanyTable companies={companies} total={summary.total} covered={summary.covered} prospectTotal={summary.prospectTotal} page={page} pageSize={summary.pageSize} clientId={client.id} search={deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onSeePeople={onSeePeople} onFilters={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onImport={onImport}/>}</section>;
}

function ListWorkspace({ client, list, onBack, onSelect }: { client: ClientRecord; list: ListRecord; onBack: () => void; onSelect: (prospect: Prospect) => void }) {
  const [rows, setRows] = useState<Prospect[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const deferredSearch = useDeferredValue(search);
  useEffect(() => {
    let active = true;
    void api<{ rows: Prospect[]; total: number }>(`/api/lists/${encodeURIComponent(list.id)}/rows?search=${encodeURIComponent(deferredSearch)}&page=${page}`).then((data) => { if (active) { setRows(data.rows); setTotal(data.total); setError(""); } }).catch((caught) => { if (active) setError(caught instanceof Error ? caught.message : "Unable to load this list."); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [list.id, deferredSearch, page]);
  const totalPages = Math.max(1, Math.ceil(total / 50));
  return <section className="operations-page"><button className="back" onClick={onBack}>← {client.name} lists</button><div className="section-intro compact-intro"><div><p className="eyebrow">LIST WORKSPACE</p><h2>{list.name}</h2><p>{formatNumber(total)} linked prospects · {formatNumber(list.field_count)} preserved fields · {list.source_file_name}</p></div><label className="workspace-search"><span>⌕</span><input aria-label="Search this list" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this list…"/></label></div>
    <article className="panel list-workspace-panel">{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Loading list records…</div> : rows.length ? <div className="table-wrap"><table><thead><tr><th>Name</th><th>Company</th><th>Email</th><th>Title</th><th>Last contacted</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id} onClick={() => onSelect(row)}><td><div className="compact-person"><span>{initials(row.full_name)}</span><strong>{row.full_name || "Unnamed prospect"}</strong></div></td><td>{row.company_name || "-"}</td><td>{row.work_email || "-"}</td><td>{row.title || "-"}</td><td>{row.last_contacted_at ? new Date(row.last_contacted_at).toLocaleDateString("en-IN") : "Never"}</td></tr>)}</tbody></table></div> : <EmptyCompact text="No prospects match this search." action="Clear search" onAction={() => setSearch("")} />}<div className="table-footer"><span>{formatNumber(total)} records</span><div><button disabled={page <= 1} onClick={() => setPage((current) => current - 1)}>← Previous</button><span>Page {page} of {totalPages}</span><button disabled={page >= totalPages} onClick={() => setPage((current) => current + 1)}>Next →</button></div></div></article>
  </section>;
}

type CoverageRow = { row: number; name: string; domain: string; status: "known" | "new"; matchedBy: string; matchedCompany: string; prospectCount: number; clientCount: number };

function CoverageChecker() {
  const [file, setFile] = useState<File | null>(null);
  const [headers, setHeaders] = useState<string[]>([]);
  const [nameField, setNameField] = useState("");
  const [domainField, setDomainField] = useState("");
  const [rows, setRows] = useState<CoverageRow[]>([]);
  const [summary, setSummary] = useState<{ total: number; known: number; new: number; covered: number; existingProspects: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function selectCoverageFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null; setFile(next); setRows([]); setSummary(null); setError("");
    if (!next) { setHeaders([]); return; }
    try {
      const parsed = parseCsv(await next.text()); setHeaders(parsed.headers);
      const normalized = (value: string) => value.toLowerCase().replace(/[^a-z0-9]/g, "");
      setDomainField(parsed.headers.find((header) => ["companywebsite", "website", "domain", "companydomain"].includes(normalized(header))) ?? "");
      setNameField(parsed.headers.find((header) => ["company", "companyname", "casualcompanyname", "organization"].includes(normalized(header))) ?? "");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to read this CSV."); }
  }

  async function checkCoverage() {
    if (!file || (!nameField && !domainField)) return;
    setBusy(true); setError("");
    try {
      const parsed = parseCsv(await file.text());
      const nameIndex = parsed.headers.indexOf(nameField); const domainIndex = parsed.headers.indexOf(domainField);
      const companies = parsed.rows.map((row, index) => ({ row: index + 2, name: nameIndex >= 0 ? row[nameIndex] : "", domain: domainIndex >= 0 ? row[domainIndex] : "" }));
      const data = await api<{ rows: CoverageRow[]; summary: NonNullable<typeof summary> }>("/api/coverage", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ companies }) });
      setRows(data.rows); setSummary(data.summary);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Coverage check failed."); }
    finally { setBusy(false); }
  }

  function exportNewCompanies() {
    const newRows = rows.filter((row) => row.status === "new");
    const csv = ["Company,Domain,Source row", ...newRows.map((row) => `"${row.name.replace(/"/g, '""')}","${row.domain.replace(/"/g, '""')}",${row.row}`)].join("\r\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" })); const link = document.createElement("a"); link.href = url; link.download = "net-new-companies.csv"; link.click(); URL.revokeObjectURL(url);
  }

  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">BEFORE YOU SCRAPE</p><h2>Company coverage checker</h2><p>Check a company list against your database before paying for employee emails.</p></div></div>
    <div className="coverage-workspace"><article className="panel coverage-upload"><label className={`dropzone small ${file ? "has-file" : ""}`}><input type="file" accept=".csv,text/csv" onChange={(event) => void selectCoverageFile(event)}/><span className="upload-mark">↑</span><strong>{file ? file.name : "Upload a company CSV"}</strong><small>Up to 5,000 companies per check</small></label>{headers.length ? <div className="mapping-grid"><label>Company name<select value={nameField} onChange={(event) => setNameField(event.target.value)}><option value="">Not mapped</option>{headers.map((header) => <option key={header}>{header}</option>)}</select></label><label>Website or domain<select value={domainField} onChange={(event) => setDomainField(event.target.value)}><option value="">Not mapped</option>{headers.map((header) => <option key={header}>{header}</option>)}</select></label></div> : null}{error ? <p className="form-error" role="alert">{error}</p> : null}<button className="primary" disabled={!file || (!nameField && !domainField) || busy} onClick={() => void checkCoverage()}>{busy ? "Checking master database…" : "Check company coverage"}</button></article>
      <article className="panel coverage-results">{summary ? <><div className="quality-metrics four"><div><span>Total companies</span><strong>{formatNumber(summary.total)}</strong></div><div><span>Already known</span><strong>{formatNumber(summary.known)}</strong></div><div><span>Net new</span><strong>{formatNumber(summary.new)}</strong></div><div><span>Existing prospects</span><strong>{formatNumber(summary.existingProspects)}</strong></div></div><div className="panel-head"><div><h3>Coverage results</h3><p>{summary.covered} companies already contain prospects</p></div><button onClick={exportNewCompanies}>Export net-new CSV</button></div><div className="table-wrap coverage-table"><table><thead><tr><th>Company</th><th>Domain</th><th>Status</th><th>Matched by</th><th>Prospects</th><th>Clients</th></tr></thead><tbody>{rows.map((row) => <tr key={`${row.row}-${row.domain}-${row.name}`}><td><strong>{row.name || row.matchedCompany || "Unnamed"}</strong></td><td>{row.domain || "-"}</td><td><span className={`coverage-status ${row.status}`}>{row.status === "known" ? "Known" : "Net new"}</span></td><td>{row.matchedBy || "-"}</td><td>{formatNumber(row.prospectCount)}</td><td>{formatNumber(row.clientCount)}</td></tr>)}</tbody></table></div></> : <div className="coverage-placeholder"><span>◫</span><h3>Know what already exists</h3><p>Upload company names or domains to see database coverage and export only net-new companies.</p></div>}</article></div>
  </section>;
}

type QualitySummary = { total: number; missingEmail: number; missingTitle: number; missingLinkedin: number; missingCompany: number; missingDomain: number; staleRecords: number; potentialDuplicateGroups: number };
type DuplicateCandidate = { left: Prospect; right: Prospect; reason: string; confidence: number };

function DataQualityCenter({ onMerged }: { onMerged: () => void }) {
  const [quality, setQuality] = useState<QualitySummary | null>(null);
  const [candidates, setCandidates] = useState<DuplicateCandidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [merging, setMerging] = useState("");
  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [qualityData, duplicateData] = await Promise.all([api<{ quality: QualitySummary }>("/api/data-quality"), api<{ candidates: DuplicateCandidate[] }>("/api/duplicates")]);
      setQuality(qualityData.quality); setCandidates(duplicateData.candidates); setError("");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load data quality."); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { const timer = window.setTimeout(() => { void load(); }, 0); return () => window.clearTimeout(timer); }, [load]);
  async function merge(keepId: string, mergeId: string) {
    setMerging(`${keepId}:${mergeId}`);
    try { await api("/api/duplicates", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ keepId, mergeId }) }); await load(); onMerged(); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "Merge failed."); }
    finally { setMerging(""); }
  }
  const issues = quality ? [
    ["Missing email", quality.missingEmail], ["Missing title", quality.missingTitle], ["Missing LinkedIn", quality.missingLinkedin], ["Missing company", quality.missingCompany], ["Missing domain", quality.missingDomain], ["Stale 180+ days", quality.staleRecords],
  ] as Array<[string, number]> : [];
  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">DATABASE HEALTH</p><h2>Data quality centre</h2><p>Review incomplete records and duplicate candidates found across different clients.</p></div><button className="secondary" onClick={() => { clearApiCache(); void load(); }}>↻ Refresh</button></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Analyzing master data…</div> : quality ? <><div className="quality-metrics"><div><span>Master prospects</span><strong>{formatNumber(quality.total)}</strong></div>{issues.map(([label, value]) => <div key={label}><span>{label}</span><strong>{formatNumber(value)}</strong><small>{quality.total ? `${Math.round((value / quality.total) * 100)}% of database` : "0%"}</small></div>)}</div><article className="panel duplicate-panel"><div className="panel-head"><div><h3>Cross-client duplicate review</h3><p>{formatNumber(candidates.length)} candidate pairs require review</p></div></div>{candidates.length ? <div className="duplicate-list">{candidates.map((candidate) => <div className="duplicate-pair" key={`${candidate.left.id}-${candidate.right.id}`}><div className="duplicate-confidence"><strong>{candidate.confidence}%</strong><span>{candidate.reason}</span></div><ProspectCompareCard prospect={candidate.left}/><div className="duplicate-actions"><button disabled={Boolean(merging)} onClick={() => void merge(candidate.left.id, candidate.right.id)}>Keep left</button><span>or</span><button disabled={Boolean(merging)} onClick={() => void merge(candidate.right.id, candidate.left.id)}>Keep right</button></div><ProspectCompareCard prospect={candidate.right}/></div>)}</div> : <EmptyCompact text="No cross-client duplicate groups need review." action="Refresh" onAction={() => { clearApiCache(); void load(); }} />}</article></> : null}</section>;
}

function ProspectCompareCard({ prospect }: { prospect: Prospect }) {
  const [expanded, setExpanded] = useState(false);
  const fields = Object.entries({ "Full name": prospect.full_name, "Title": prospect.title, "Company": prospect.company_name, "Work email": prospect.work_email, "Personal email": prospect.personal_email, "LinkedIn": prospect.linkedin_url, "Mobile": prospect.mobile_number, "Seniority": prospect.seniority, "Department": prospect.department, "City": prospect.city, "State": prospect.state, "Country": prospect.country, ...parseAllData(prospect.all_data) }).filter(([, value]) => String(value ?? "").trim());
  return <div className={`compare-card ${expanded ? "expanded" : ""}`}><div className="compact-person"><span>{initials(prospect.full_name)}</span><strong>{prospect.full_name || "Unnamed"}</strong></div><p>{prospect.title || "No title"}</p><p>{prospect.company_name || "No company"}</p><p>{prospect.work_email || "No work email"}</p>{prospect.client_names?.length ? <div className="compare-client-list">{prospect.client_names.map((name) => <span key={name}>{name}</span>)}</div> : null}<div className="compare-card-footer"><small>{formatNumber(prospect.list_count)} lists · {formatNumber(fields.length)} populated fields</small><button aria-expanded={expanded} onClick={() => setExpanded((open) => !open)}>{expanded ? "Hide fields" : "View all fields"}</button></div>{expanded ? <div className="compare-fields">{fields.map(([field, value]) => <div key={field}><span>{field}</span><strong>{String(value)}</strong></div>)}</div> : null}</div>;
}

function ImportMappingPanel({ audit, fieldMap, onChange }: { audit: FileAudit; fieldMap: Record<string, string>; onChange: (header: string, value: string) => void }) {
  return <div className="import-mapping"><div className="mapping-head"><div><strong>Field mapping</strong><small>Review how CSV columns map to master fields</small></div><span>{audit.invalidRows ? `${audit.invalidRows} rows need identity data` : "All rows identifiable"}</span></div><div className="mapping-list">{audit.headers.map((header) => <label key={header}><span title={header}>{header}</span><b>→</b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Auto detect"} onChange={(event) => onChange(header, event.target.value)}>{canonicalImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div><p>Original headers and values are always preserved, even when mapped to a standard field.</p></div>;
}

function ImportView({ clients, onComplete }: { clients: ClientRecord[]; onComplete: () => Promise<void> }) {
  const [kind, setKind] = useState<"prospects" | "companies">("prospects");
  const [sourceChoice, setSourceChoice] = useState("");
  const [customSource, setCustomSource] = useState("");
  const dataSource = sourceChoice === "Other" ? customSource.trim() : sourceChoice;
  return <section className="import-workspace">
    <div className="import-setup panel">
      <div><p className="eyebrow">IMPORT SETUP</p><h2>What are you importing?</h2><p>Every import must have a data source so its lineage remains auditable.</p></div>
      <div className="import-kind-switch" role="tablist" aria-label="Import type"><button role="tab" aria-selected={kind === "prospects"} className={kind === "prospects" ? "active" : ""} onClick={() => setKind("prospects")}>People / prospects</button><button role="tab" aria-selected={kind === "companies"} className={kind === "companies" ? "active" : ""} onClick={() => setKind("companies")}>Companies</button></div>
      <div className="import-source-fields"><label><span>Data source <b>*</b></span><select aria-label="Data source" value={sourceChoice} onChange={(event) => setSourceChoice(event.target.value)}><option value="">Choose source</option>{commonDataSources.map((source) => <option key={source}>{source}</option>)}<option>Other</option></select></label>{sourceChoice === "Other" ? <label><span>Custom source <b>*</b></span><input value={customSource} maxLength={80} onChange={(event) => setCustomSource(event.target.value)} placeholder="Enter the source name"/></label> : null}</div>
      {!dataSource ? <p className="source-required-note">A data source is required before the import can start.</p> : <p className="source-selected-note">Source: <strong>{dataSource}</strong></p>}
    </div>
    {kind === "prospects" ? <ProspectImportView key="prospects" clients={clients} dataSource={dataSource} onComplete={onComplete}/> : <CompanyImportView key="companies" dataSource={dataSource} onComplete={onComplete}/>}
  </section>;
}

function RequiredFieldList({ title, fields }: { title: string; fields: readonly string[] }) {
  return <div className="required-field-list"><strong>{title}</strong><div>{fields.map((field) => <span key={field}>✓ {field}</span>)}</div></div>;
}

function CompanyImportView({ dataSource, onComplete }: { dataSource: string; onComplete: () => Promise<void> }) {
  const [file, setFile] = useState<File | null>(null);
  const [parsed, setParsed] = useState<{ headers: string[]; rows: string[][] } | null>(null);
  const [fieldMap, setFieldMap] = useState<Record<string, string>>({});
  const [phase, setPhase] = useState<"idle" | "uploading" | "done">("idle");
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState("");
  const [summary, setSummary] = useState<{ processed_rows: number; added_count: number; updated_count: number; skipped_count: number } | null>(null);
  const mappedFields = parsed ? resolvedImportFields(parsed.headers, fieldMap, suggestedCompanyImportField) : [];
  const missingFields = missingCompanyImportFields(mappedFields);
  const canSubmit = Boolean(file && parsed?.rows.length && dataSource && !missingFields.length && phase === "idle");

  async function pickCompanyFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setParsed(null); setFieldMap({}); setMessage(""); setSummary(null); setProgress(0);
    if (!next) return;
    try {
      const nextParsed = parseCsv(await next.text());
      setFieldMap(Object.fromEntries(nextParsed.headers.map((header) => [header, suggestedCompanyImportField(header)])));
      setParsed(nextParsed);
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Unable to read this company CSV."); }
  }

  async function startCompanyImport() {
    if (!file || !parsed || !canSubmit) return;
    setPhase("uploading"); setMessage("Importing companies into the master Company DB…");
    try {
      const started = await api<{ importId: string }>("/api/company-imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fileName: file.name, totalRows: parsed.rows.length, dataSource, headers: parsed.headers, fieldMap }) });
      const columnFor = (field: string) => parsed.headers.findIndex((header) => fieldMap[header] === field);
      const valueFor = (row: string[], field: string) => { const column = columnFor(field); return column >= 0 ? String(row[column] ?? "").trim() : ""; };
      const chunkSize = 100;
      for (let index = 0; index < parsed.rows.length; index += chunkSize) {
        const rows = parsed.rows.slice(index, index + chunkSize).map((row, chunkIndex) => ({
          name: valueFor(row, "Company Name"),
          website: valueFor(row, "Website"),
          employeeCount: valueFor(row, "#employees"),
          industry: valueFor(row, "Industry"),
          city: valueFor(row, "Company City"),
          state: valueFor(row, "Company State"),
          country: valueFor(row, "Company Country"),
          keywords: valueFor(row, "Keywords"),
          shortDescription: valueFor(row, "Short Description"),
          foundedYear: valueFor(row, "Founded Year"),
          technologies: valueFor(row, "Technologies"),
          totalFunding: valueFor(row, "Total Funding"),
          raw: Object.fromEntries(parsed.headers.map((header, column) => [header, String(row[column] ?? "").trim()])),
          sourceRowNumber: index + chunkIndex + 2,
        }));
        await api("/api/company-imports/chunk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: started.importId, rows }) });
        setProgress(Math.round(((index + rows.length) / parsed.rows.length) * 100));
      }
      const completed = await api<{ summary: { processed_rows: number; added_count: number; updated_count: number; skipped_count: number } }>("/api/company-imports/complete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: started.importId }) });
      setSummary(completed.summary); setPhase("done"); setMessage("Company import complete. Names and websites are now available in the Company DB.");
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Company import failed."); setPhase("idle"); }
  }

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark">✓</span><p className="eyebrow">COMPANY IMPORT COMPLETE</p><h2>Your Company DB is updated.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(summary.added_count)}</strong><span>Companies added</span></div><div><strong>{formatNumber(summary.updated_count)}</strong><span>Companies matched</span></div><div><strong>{formatNumber(summary.skipped_count)}</strong><span>Rows skipped</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  return <div className="import-layout company-import-layout"><div className="import-copy"><p className="eyebrow">COMPANY CSV IMPORT</p><h2>Import a complete company dataset.</h2><p>Map a company name or a website (either works), plus the company detail columns. Companies are matched by normalized website first and company name second.</p><RequiredFieldList title="Company columns" fields={companyImportFields}/></div><div className="import-card"><label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,text/csv" onChange={(event) => void pickCompanyFile(event)}/><span className="upload-mark">↑</span>{file ? <><strong>{file.name}</strong><small>{formatNumber(parsed?.rows.length)} company rows ready</small></> : <><strong>Choose a company CSV</strong><small>A company name or website is required</small></>}</label>{parsed ? <><div className="mapping-list company-required-mapping">{parsed.headers.map((header) => <label key={header}><span title={header}>{header}</span><b>→</b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Not mapped"} onChange={(event) => setFieldMap((current) => ({ ...current, [header]: event.target.value }))}><option>Not mapped</option>{companyImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div><p className={missingFields.length ? "form-error" : "source-selected-note"}>{missingFields.length ? `Map required columns: ${missingFields.join(", ")}.` : "All required company columns are mapped."}</p></> : null}{phase === "uploading" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}{message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}<button className="primary import-button" disabled={!canSubmit} onClick={() => void startCompanyImport()}>{phase === "uploading" ? "Processing…" : "Import companies"}</button></div></div>;
}

function ProspectImportView({ clients, onComplete, dataSource }: { clients: ClientRecord[]; onComplete: () => Promise<void>; dataSource: string }) {
  const [file, setFile] = useState<File | null>(null);
  const [clientId, setClientId] = useState("");
  const [newClient, setNewClient] = useState("");
  const [listName, setListName] = useState("");
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState<"idle" | "reading" | "uploading" | "done">("idle");
  const [message, setMessage] = useState("");
  const [summary, setSummary] = useState<{ processed_rows: number; unique_added: number; duplicates_linked: number } | null>(null);
  const [fileAudit, setFileAudit] = useState<FileAudit | null>(null);
  const [fieldMap, setFieldMap] = useState<Record<string, string>>({});
  const mappedFields = fileAudit ? resolvedImportFields(fileAudit.headers, fieldMap, suggestedPersonImportField) : [];
  const missingFields = missingRequiredFields(requiredPersonImportFields, mappedFields);
  const canSubmit = file && fileAudit && dataSource && listName.trim() && (clientId || newClient.trim()) && !missingFields.length && phase === "idle";

  async function pickFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setFileAudit(null); setFieldMap({}); setMessage("");
    if (next) setListName(deriveListName(next.name));
    if (!next) return;
    try {
      const parsed = parseCsv(await next.text());
      const populatedCells = parsed.rows.reduce((count, row) => count + row.filter((value) => value.trim()).length, 0);
      const nextFieldMap = Object.fromEntries(parsed.headers.map((header) => [header, suggestedPersonImportField(header)]));
      const mappedHeaders = parsed.headers.map((header) => nextFieldMap[header] === "Auto detect" ? header : nextFieldMap[header]);
      const invalidRows = parsed.rows.filter((row) => mapProspect(mappedHeaders, row).identifiers.length === 0).length;
      setFieldMap(nextFieldMap);
      setFileAudit({ headers: parsed.headers, rows: parsed.rows.length, populatedCells, invalidRows });
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : "Unable to read this CSV.");
    }
  }

  async function startImport() {
    if (!file || !canSubmit) return;
    try {
      setPhase("reading"); setMessage("Reading CSV and checking the columns…");
      const parsed = parseCsv(await file.text());
      if (!parsed.headers.length || !parsed.rows.length) throw new Error("The CSV needs a header row and at least one data row.");
      const started = await api<{ importId: string; listId: string }>("/api/imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ clientId: clientId || undefined, clientName: newClient || undefined, listName, dataSource, fileName: file.name, totalRows: parsed.rows.length, headers: parsed.headers, fieldMap }) });
      setPhase("uploading"); setMessage(`Synchronizing ${formatNumber(parsed.rows.length)} rows with the master database…`);
      const chunkSize = 100;
      for (let index = 0; index < parsed.rows.length; index += chunkSize) {
        const chunk = parsed.rows.slice(index, index + chunkSize);
        const resolvedFieldMap = Object.fromEntries(Object.entries(fieldMap).filter(([, value]) => value && value !== "Auto detect"));
        await api("/api/imports/chunk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: started.importId, listId: started.listId, headers: parsed.headers, rows: chunk, rowOffset: index, fieldMap: resolvedFieldMap }) });
        setProgress(Math.round(((index + chunk.length) / parsed.rows.length) * 100));
      }
      const completed = await api<{ summary: { processed_rows: number; unique_added: number; duplicates_linked: number } }>("/api/imports/complete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: started.importId, listId: started.listId }) });
      setSummary(completed.summary); setPhase("done"); setMessage("Import complete. Your list is ready and the master database is up to date.");
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Import failed."); setPhase("idle"); }
  }

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark">✓</span><p className="eyebrow">IMPORT COMPLETE</p><h2>Your list is ready.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(fileAudit?.headers.length)}</strong><span>Fields preserved</span></div><div><strong>{formatNumber(summary.unique_added)}</strong><span>Added to master</span></div><div><strong>{formatNumber(summary.duplicates_linked)}</strong><span>Existing prospects linked</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  return <div className="import-layout">
    <div className="import-copy"><p className="eyebrow">CSV IMPORT</p><h2>Bring every list into one clean database.</h2><p>Preview the file, confirm field mapping, choose the client, and synchronize it safely with your master database.</p><RequiredFieldList title="Required person columns" fields={requiredPersonImportFields}/><ol><li><span>1</span><div><strong>Validate before import</strong><p>Review fields, row counts and records without usable identity data.</p></div></li><li><span>2</span><div><strong>Control field mapping</strong><p>Map unusual CSV headers without losing the original source fields.</p></div></li><li><span>3</span><div><strong>Sync with rollback</strong><p>Existing prospects are linked, new records are added once, and imports can be undone.</p></div></li></ol></div>
    <div className="import-card">
      <div className="form-field"><label htmlFor="import-client">Client</label><select id="import-client" value={clientId} onChange={(event) => { setClientId(event.target.value); if (event.target.value) setNewClient(""); }}><option value="">Create a new client</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select></div>
      {!clientId && <div className="form-field"><label htmlFor="new-client-name">New client name</label><input id="new-client-name" value={newClient} onChange={(event) => setNewClient(event.target.value)} placeholder="e.g. Acme Recruitment" /></div>}
      <label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,text/csv" onChange={(event) => void pickFile(event)}/><span className="upload-mark">↑</span>{file ? <><strong>{file.name}</strong><small>{(file.size / 1024 / 1024).toFixed(2)} MB · Ready to review</small></> : <><strong>Choose a CSV file</strong><small>Download your Google Sheet as .csv</small></>}</label>
      <div className="form-field"><label htmlFor="list-name">List name</label><input id="list-name" value={listName} onChange={(event) => setListName(event.target.value)} placeholder="Auto-filled from the CSV filename" /></div>
      {fileAudit && <><div className="file-audit"><div><span className="audit-check">✓</span><p><strong>{formatNumber(fileAudit.headers.length)} fields detected</strong><small>{formatNumber(fileAudit.rows)} rows · {formatNumber(fileAudit.populatedCells)} populated cells</small></p></div><div className="audit-fields">{fileAudit.headers.slice(0, 8).map((header) => <span key={header}>{header}</span>)}{fileAudit.headers.length > 8 && <span>+{fileAudit.headers.length - 8} more</span>}</div><p>{fileAudit.invalidRows ? `${fileAudit.invalidRows} rows do not currently contain email, LinkedIn, or name plus company domain and will be preserved without a master link.` : "Every row has sufficient identity data for master matching."}</p></div><ImportMappingPanel audit={fileAudit} fieldMap={fieldMap} onChange={(header, value) => setFieldMap((current) => ({ ...current, [header]: value }))}/><p className={missingFields.length ? "form-error" : "source-selected-note"}>{missingFields.length ? `Map required columns: ${missingFields.join(", ")}.` : "All required person columns are mapped."}</p></>}
      {phase !== "idle" && <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div>}
      {message && phase === "idle" && <p className="form-error" role="alert">{message}</p>}
      <button className="primary import-button" disabled={!canSubmit} onClick={startImport}>{phase === "idle" ? "Start import & sync" : "Processing…"}</button><p className="privacy-note">Original rows and fields remain stored in your private database.</p>
    </div>
  </div>;
}

function ProspectDrawer({ prospect, onClose }: { prospect: Prospect; onClose: () => void }) {
  const data = parseAllData(prospect.all_data);
  const memberships = prospectMembershipItems(prospect, true);
  const membershipCountMatches = memberships.length === Number(prospect.list_count ?? 0);
  const [tab, setTab] = useState<"data" | "history">("data");
  const [events, setEvents] = useState<Array<{ id: string; contacted_at: string; campaign_name: string; outcome: string; client: { name?: string } | Array<{ name?: string }> }>>([]);
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", closeOnEscape);
    void api<{ events: typeof events }>(`/api/operations?prospectId=${encodeURIComponent(prospect.id)}`).then((result) => setEvents(result.events)).catch(() => setEvents([]));
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [prospect.id, onClose]);
  return <div className="drawer-backdrop"><button className="drawer-dismiss" aria-label="Close prospect details" onClick={onClose}/><aside className="drawer" role="dialog" aria-modal="true" aria-labelledby="prospect-drawer-title"><button className="drawer-close" aria-label="Close prospect details" onClick={onClose}>×</button><div className="drawer-person"><span>{initials(prospect.full_name)}</span><div><p className="eyebrow">PROSPECT DETAILS</p><h2 id="prospect-drawer-title">{prospect.full_name || "Unnamed prospect"}</h2><p>{prospect.title || "No title"} {prospect.company_name ? `at ${prospect.company_name}` : ""}</p></div></div><div className="drawer-summary"><span><b>{formatNumber(prospect.client_count)}</b>clients</span><span><b>{formatNumber(prospect.list_count)}</b>lists</span><span><b>{Object.keys(data).length}</b>data fields</span></div><div className="drawer-tabs" role="tablist"><button role="tab" aria-selected={tab === "data"} className={tab === "data" ? "active" : ""} onClick={() => setTab("data")}>Saved data</button><button role="tab" aria-selected={tab === "history"} className={tab === "history" ? "active" : ""} onClick={() => setTab("history")}>Contact history <span>{events.length}</span></button></div>{tab === "data" ? <div className="drawer-saved-data"><section className="drawer-memberships"><div><span>LIST MEMBERSHIPS</span><strong>{formatNumber(memberships.length)} linked</strong><small className={membershipCountMatches ? "verified" : "review"}>{membershipCountMatches ? "✓ Tag count verified" : "Review membership count"}</small></div>{memberships.length ? <div className="drawer-membership-list">{memberships.map((membership) => <div key={membership.key}><span>{membership.clientName || "Client"}</span><strong>{membership.listName}</strong></div>)}</div> : <p>No master-list membership is linked to this prospect.</p>}</section><div className="field-list">{Object.entries(data).map(([field, value]) => <div key={field}><span>{field}</span><strong>{value || "-"}</strong></div>)}</div></div> : <div className="contact-timeline">{events.length ? events.map((event) => { const client = Array.isArray(event.client) ? event.client[0] : event.client; return <div key={event.id}><i/><span>{new Date(event.contacted_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</span><strong>{client?.name || "Unknown client"}</strong><p>{event.campaign_name || event.outcome || "Contacted"}</p></div>; }) : <div className="drawer-empty">No contact history recorded yet.</div>}</div>}</aside></div>;
}

function DeleteConfirmation({ target, busy, onCancel, onConfirm }: { target: DeleteRequest; busy: boolean; onCancel: () => void; onConfirm: (deleteOrphans: boolean) => Promise<void> }) {
  const [deleteOrphans, setDeleteOrphans] = useState(false);
  const action = target.kind === "import" ? "Undo import" : target.kind === "list" ? "Delete list" : "Delete client";
  const explanation = target.kind === "import"
    ? "This removes the import and its client-list links. The list is also removed when nothing else uses it."
    : target.kind === "list"
      ? "This removes the list, its import history, and all links between this list and the master database."
      : "This removes the client workspace, every list under it, its import history, and its master-database links.";
  return <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="delete-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="delete-title">{action}?</h2><p>{explanation}</p><div className="delete-target"><strong>{target.name}</strong><span>{target.context}</span></div><div className="cleanup-choice"><input id="delete-unused-master-records" type="checkbox" checked={deleteOrphans} onChange={(event) => setDeleteOrphans(event.target.checked)} /><label htmlFor="delete-unused-master-records"><strong>Remove unused master records (optional)</strong><small>Delete prospects and companies only when no other client list uses them.</small></label></div><p className="shared-safety">Shared prospects remain untouched. Default behavior preserves every Master DB prospect and company while removing only client/list links.</p><div className="modal-actions"><button className="secondary" disabled={busy} onClick={onCancel}>Cancel</button><button className="danger-button solid" disabled={busy} onClick={() => void onConfirm(deleteOrphans)}>{busy ? "Working…" : action}</button></div></section></div>;
}

function parseAllData(data: Prospect["all_data"]) {
  if (typeof data === "object" && data) return data as Record<string, string>;
  try { return JSON.parse(String(data || "{}")) as Record<string, string>; } catch { return {}; }
}

function EmptyState({ title, text, action, onAction }: { title: string; text: string; action: string; onAction: () => void }) {
  return <div className="empty"><span>◎</span><h3>{title}</h3><p>{text}</p><button className="primary" onClick={onAction}>{action}</button></div>;
}

function EmptyCompact({ text, action, onAction }: { text: string; action: string; onAction: () => void }) {
  return <div className="empty compact"><span>↑</span><p>{text}</p><button onClick={onAction}>{action}</button></div>;
}
