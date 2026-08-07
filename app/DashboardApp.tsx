"use client";

import { ChangeEvent, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { mapProspect } from "../db/normalize";

type Section = "overview" | "prospects" | "companies" | "clients" | "coverage" | "quality" | "imports";
type ClientRecord = { id: string; name: string; list_count: number; prospect_count: number; cooldown_days?: number };
type ListRecord = { id: string; name: string; source_file_name: string; uploaded_rows: number; unique_added: number; duplicates_linked: number; prospect_count: number; created_at: string; field_count: number; field_headers: string[] };
type Prospect = Record<string, unknown> & { id: string; full_name: string; work_email: string; title: string; company_name: string; company_domain: string; client_count: number; list_count: number; all_data: string | Record<string, string>; last_contacted_at?: string; next_eligible_at?: string; eligible?: boolean; tags?: Array<{ id: string; name: string; color: string }> };
type Company = { id: string; name: string; domain: string; prospect_count: number; client_count: number; created_at: string };
type ImportRecord = { id: string; file_name: string; client_name: string; list_name: string; processed_rows: number; unique_added: number; duplicates_linked: number; status: string; created_at: string };
type DeleteKind = "import" | "list" | "client";
type DeleteRequest = { kind: DeleteKind; id: string; name: string; context: string };
type ProspectFilter = { id: string; field: string; operator: "contains" | "equals" | "not_contains" | "not_equals" | "empty" | "not_empty"; values: string[] };
type FileAudit = { headers: string[]; rows: number; populatedCells: number; invalidRows: number };
type SavedView = { id: string; name: string; definition: { filters: ProspectFilter[]; columns: string[]; sort: string; direction: "asc" | "desc" } };

const emptyStats = { prospects: 0, companies: 0, clients: 0, lists: 0, rowsImported: 0, duplicatesDetected: 0 };

function formatNumber(value: unknown) {
  return new Intl.NumberFormat("en-IN").format(Number(value ?? 0));
}

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "CL";
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

const canonicalImportFields = ["Auto detect", "First Name", "Last Name", "Full Name", "Work Email", "Personal Email", "Mobile Number", "LinkedIn", "Title", "Seniority", "Department", "City", "State", "Country", "Company Name", "Company Website"];

function suggestedImportField(header: string) {
  const normalized = header.toLowerCase().replace(/[^a-z0-9]/g, "");
  const aliases: Record<string, string> = {
    firstname: "First Name", lastname: "Last Name", fullname: "Full Name", name: "Full Name",
    email: "Work Email", workemail: "Work Email", businessemail: "Work Email", personalemail: "Personal Email",
    mobile: "Mobile Number", mobilenumber: "Mobile Number", phone: "Mobile Number", phonenumber: "Mobile Number",
    linkedin: "LinkedIn", linkedinurl: "LinkedIn", title: "Title", jobtitle: "Title", seniority: "Seniority",
    department: "Department", city: "City", state: "State", country: "Country", company: "Company Name",
    companyname: "Company Name", casualcompanyname: "Company Name", organization: "Company Name",
    companywebsite: "Company Website", website: "Company Website", domain: "Company Website", companydomain: "Company Website",
  };
  return aliases[normalized] ?? "Auto detect";
}

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

async function api<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(path, options);
  const data = await response.json() as T & { error?: string };
  if (!response.ok) throw new Error(data.error || "Something went wrong.");
  return data;
}

const navItems: Array<{ id: Section; label: string; mark: string }> = [
  { id: "overview", label: "Overview", mark: "⌂" },
  { id: "prospects", label: "Master database", mark: "◉" },
  { id: "companies", label: "Companies", mark: "▦" },
  { id: "clients", label: "Clients & lists", mark: "◇" },
  { id: "coverage", label: "Coverage checker", mark: "◫" },
  { id: "quality", label: "Data quality", mark: "✓" },
  { id: "imports", label: "Import CSV", mark: "↑" },
];

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
  const [lists, setLists] = useState<ListRecord[]>([]);
  const [selectedClient, setSelectedClient] = useState<ClientRecord | null>(null);
  const [selectedList, setSelectedList] = useState<ListRecord | null>(null);
  const [selectedProspect, setSelectedProspect] = useState<Prospect | null>(null);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [deleteRequest, setDeleteRequest] = useState<DeleteRequest | null>(null);
  const [deleting, setDeleting] = useState(false);
  const deferredSearch = useDeferredValue(search);
  const encodedProspectFilters = useMemo(() => JSON.stringify(prospectFilters.map(({ field, operator, values }) => ({ field, operator, values }))), [prospectFilters]);

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
    let active = true;
    const timer = setTimeout(async () => {
      try {
        if (section === "prospects") {
          const data = await api<{ prospects: Prospect[]; total: number; fields: string[] }>(`/api/prospects?search=${encodeURIComponent(deferredSearch)}&page=${prospectPage}&sort=${encodeURIComponent(prospectSort)}&direction=${prospectDirection}&filters=${encodeURIComponent(encodedProspectFilters)}`);
          if (active) { setProspects(data.prospects); setProspectTotal(data.total); setProspectFields(data.fields); }
        }
        if (section === "companies") {
          const data = await api<{ companies: Company[] }>(`/api/companies?search=${encodeURIComponent(deferredSearch)}`);
          if (active) setCompanies(data.companies);
        }
      } catch (caught) { if (active) setError(caught instanceof Error ? caught.message : "Unable to load workspace data."); }
    }, 220);
    return () => { active = false; clearTimeout(timer); };
  }, [section, deferredSearch, stats.prospects, prospectPage, encodedProspectFilters, prospectSort, prospectDirection, prospectRefresh]);

  async function openClient(client: ClientRecord) {
    setSelectedClient(client);
    const data = await api<{ lists: ListRecord[] }>(`/api/lists?clientId=${client.id}`);
    setLists(data.lists);
  }

  function navigate(next: Section) {
    setSection(next); setSearch(""); setError(""); setProspectPage(1); setSelectedList(null);
    if (next !== "clients") setSelectedClient(null);
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
        <div className="brand"><span className="brand-mark">P</span><span>Prospect <span>Sync</span></span></div>
        <div className="workspace"><span className="workspace-avatar">PA</span><div><strong>Prospect Agency</strong><small>Internal workspace</small></div><span className="chevron">⌄</span></div>
        <nav aria-label="Primary navigation">{navItems.map((item) => <button key={item.id} aria-current={section === item.id ? "page" : undefined} className={section === item.id ? "active" : ""} onClick={() => navigate(item.id)}><span aria-hidden="true">{item.mark}</span>{item.label}</button>)}</nav>
        <div className="sidebar-note"><span className="pulse"/><div><strong>Master sync active</strong><small>Every import updates one source of truth</small></div></div>
        <a className="profile" href="/auth/signout"><span className="profile-avatar">{initials(currentUserEmail)}</span><div><strong>{currentUserEmail}</strong><small>Sign out</small></div></a>
      </aside>

      <main id="main-content">
        <header className="topbar">
          <div><p className="eyebrow">DATABASE WORKSPACE</p><h1>{selectedClient ? selectedClient.name : title}</h1></div>
          <div className="top-actions">
            {(section === "prospects" || section === "companies") && <label className="search"><span>⌕</span><input aria-label="Search" value={search} onChange={(event) => { setSearch(event.target.value); if (section === "prospects") setProspectPage(1); }} placeholder={`Search ${section}...`} /></label>}
            <button className="primary" onClick={() => navigate("imports")}><span>＋</span> Import list</button>
          </div>
        </header>

        {error && <div className="alert"><span>!</span>{error}<button onClick={() => setError("")}>×</button></div>}
        <section className="content" aria-busy={loading}>
          {loading ? <LoadingState /> : null}
          {!loading && section === "overview" && <Overview stats={stats} recentImports={recentImports} clients={clients} onImport={() => navigate("imports")} onViewMaster={() => navigate("prospects")} onDeleteImport={(item) => setDeleteRequest({ kind: "import", id: item.id, name: item.file_name, context: `${item.client_name} · ${item.list_name}` })} />}
          {!loading && section === "prospects" && <ProspectTable prospects={prospects} total={prospectTotal} fields={prospectFields} filters={prospectFilters} page={prospectPage} clients={clients} sort={prospectSort} direction={prospectDirection} onSortChange={(nextSort, nextDirection) => { setProspectSort(nextSort); setProspectDirection(nextDirection); setProspectPage(1); }} onFiltersChange={(next) => { setProspectFilters(next); setProspectPage(1); }} onPageChange={setProspectPage} onSelect={setSelectedProspect} onImport={() => navigate("imports")} onRefresh={() => setProspectRefresh((current) => current + 1)} />}
          {!loading && section === "companies" && <CompanyTable companies={companies} onImport={() => navigate("imports")} />}
          {!loading && section === "clients" && !selectedClient && <ClientsView clients={clients} onOpen={openClient} onImport={() => navigate("imports")} />}
          {!loading && section === "clients" && selectedClient && !selectedList && <ClientDetail client={selectedClient} lists={lists} onBack={() => setSelectedClient(null)} onOpenList={setSelectedList} onImport={() => navigate("imports")} onDeleteClient={() => setDeleteRequest({ kind: "client", id: selectedClient.id, name: selectedClient.name, context: `${selectedClient.list_count} lists · ${selectedClient.prospect_count} linked prospects` })} onDeleteList={(list) => setDeleteRequest({ kind: "list", id: list.id, name: list.name, context: `${list.source_file_name} · ${list.prospect_count} linked prospects` })} />}
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
    ["Unique prospects", stats.prospects, "Master records", "violet"],
    ["Known companies", stats.companies, "Matched by domain", "blue"],
    ["Client lists", stats.lists, `${stats.clients} active clients`, "amber"],
    ["Duplicates prevented", stats.duplicatesDetected, "Linked, not copied", "green"],
  ];
  return <>
    <div className="welcome"><div><p className="eyebrow">MASTER DATABASE</p><h2>One clean source for every prospect.</h2><p>Upload a client list. Prospect Sync keeps the list intact, finds existing people, and syncs new data into your master database.</p><div className="welcome-actions"><button className="primary" onClick={onImport}>Import your first CSV</button><button className="secondary" onClick={onViewMaster}>View master database</button></div></div><div className="sync-visual"><div className="file-chip">CSV<span>Client list</span></div><div className="sync-line"><i/><i/><i/></div><div className="database-chip"><b>◉</b><span>Master database<small>Unique & synchronized</small></span></div></div></div>
    <div className="metric-grid">{cards.map(([label, value, note, color]) => <article className={`metric-card ${color}`} key={String(label)}><div className="metric-icon">{color === "violet" ? "◉" : color === "blue" ? "▦" : color === "amber" ? "◇" : "✓"}</div><p>{label}</p><strong>{formatNumber(value)}</strong><small>{note}</small></article>)}</div>
    <div className="dashboard-grid"><article className="panel"><div className="panel-head"><div><h3>Recent imports</h3><p>Latest client lists synchronized with the master</p></div><button onClick={onImport}>Import CSV</button></div>{recentImports.length ? <div className="activity-list">{recentImports.map((item) => <div className="activity" key={item.id}><span className="csv-icon">CSV</span><div><strong>{item.file_name}</strong><small>{item.client_name} · {item.list_name}</small></div><div className="activity-result"><strong>{formatNumber(item.processed_rows)} rows</strong><small>{formatNumber(item.duplicates_linked)} duplicates found</small></div><div className="activity-actions"><span className="status">Complete</span><button className="text-danger" onClick={() => onDeleteImport(item)}>Undo</button></div></div>)}</div> : <EmptyCompact text="Your completed imports will appear here." action="Import a CSV" onAction={onImport} />}</article>
      <article className="panel coverage"><div className="panel-head"><div><h3>Database coverage</h3><p>Current organization</p></div></div><div className="coverage-row"><span>Rows processed</span><strong>{formatNumber(stats.rowsImported)}</strong></div><div className="coverage-row"><span>Unique master records</span><strong>{formatNumber(stats.prospects)}</strong></div><div className="coverage-row"><span>Known companies</span><strong>{formatNumber(stats.companies)}</strong></div><div className="coverage-track"><i style={{ width: stats.rowsImported ? `${Math.min(100, Math.round((stats.prospects / stats.rowsImported) * 100))}%` : "0%" }}/></div><p className="coverage-note">{stats.rowsImported ? `${Math.round((stats.duplicatesDetected / stats.rowsImported) * 100)}% of imported rows matched existing prospects.` : "Import a list to calculate master database coverage."}</p><div className="client-mini"><span>Clients</span><div>{clients.slice(0, 4).map((client) => <i key={client.id}>{initials(client.name)}</i>)}{clients.length > 4 && <i>+{clients.length - 4}</i>}</div></div></article></div>
  </>;
}

const standardProspectFields = [
  { id: "__name", label: "Name" },
  { id: "__company", label: "Company" },
  { id: "__email", label: "Email" },
  { id: "__title", label: "Title" },
  { id: "__linkedin", label: "LinkedIn" },
  { id: "__country", label: "Country" },
  { id: "__seniority", label: "Seniority" },
  { id: "__department", label: "Department" },
  { id: "__tags", label: "Tags" },
  { id: "__last_contacted", label: "Last contacted" },
];
const defaultProspectColumns = ["__name", "__company", "__email", "__title"];

function prospectFieldValue(prospect: Prospect, field: string) {
  if (field === "__name") return String(prospect.full_name || "");
  if (field === "__company") return String(prospect.company_name || "");
  if (field === "__email") return String(prospect.work_email || prospect.personal_email || "");
  if (field === "__title") return String(prospect.title || "");
  if (field === "__linkedin") return String(prospect.linkedin_url || "");
  if (field === "__country") return String(prospect.country || "");
  if (field === "__seniority") return String(prospect.seniority || "");
  if (field === "__department") return String(prospect.department || "");
  if (field === "__tags") return Array.isArray(prospect.tags) ? prospect.tags.map((tag) => tag.name).join(", ") : "";
  if (field === "__last_contacted") return prospect.last_contacted_at ? new Date(prospect.last_contacted_at).toLocaleDateString("en-IN") : "";
  return String(parseAllData(prospect.all_data)[field] || "");
}

function ProspectTable({ prospects, total, fields, filters, page, clients, sort, direction, onSortChange, onFiltersChange, onPageChange, onSelect, onImport, onRefresh }: { prospects: Prospect[]; total: number; fields: string[]; filters: ProspectFilter[]; page: number; clients: ClientRecord[]; sort: string; direction: "asc" | "desc"; onSortChange: (sort: string, direction: "asc" | "desc") => void; onFiltersChange: (filters: ProspectFilter[]) => void; onPageChange: (page: number) => void; onSelect: (row: Prospect) => void; onImport: () => void; onRefresh: () => void }) {
  const [visibleColumns, setVisibleColumns] = useState<string[]>(defaultProspectColumns);
  const [columnMenu, setColumnMenu] = useState(false);
  const [tab, setTab] = useState<"records" | "coverage">("records");
  const [tableScrollWidth, setTableScrollWidth] = useState(0);
  const topScrollRef = useRef<HTMLDivElement>(null);
  const tableScrollRef = useRef<HTMLDivElement>(null);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [savedViews, setSavedViews] = useState<SavedView[]>([]);
  const [bulkClientId, setBulkClientId] = useState("");
  const [bulkBusy, setBulkBusy] = useState(false);
  const [notice, setNotice] = useState("");
  const allColumns = useMemo(() => [...standardProspectFields, ...fields.map((field) => ({ id: field, label: field }))], [fields]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      try {
        const saved = JSON.parse(localStorage.getItem("prospecthub-visible-columns") || "[]") as string[];
        if (Array.isArray(saved) && saved.length) setVisibleColumns(saved);
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
  const suggestedValues = useMemo(() => new Map(allColumns.map((field) => {
    const options = Array.from(new Set(prospects.map((prospect) => prospectFieldValue(prospect, field.id).trim()).filter(Boolean))).sort((left, right) => left.localeCompare(right)).slice(0, 40);
    return [field.id, options];
  })), [allColumns, prospects]);
  const totalPages = Math.max(1, Math.ceil(total / 50));
  const firstRecord = total ? (page - 1) * 50 + 1 : 0;
  const lastRecord = Math.min(page * 50, total);

  useEffect(() => {
    const scrollArea = tableScrollRef.current;
    const table = scrollArea?.querySelector("table");
    if (!scrollArea || !table) return;
    const measure = () => setTableScrollWidth(table.scrollWidth);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(table);
    return () => observer.disconnect();
  }, [prospects, visibleDefinitions.length]);

  function syncHorizontalScroll(source: HTMLDivElement, target: HTMLDivElement | null) {
    if (target && Math.abs(target.scrollLeft - source.scrollLeft) > 1) target.scrollLeft = source.scrollLeft;
  }

  function addFilter(field = "__country") {
    onFiltersChange([...filters, { id: crypto.randomUUID(), field, operator: "contains", values: [] }]);
  }

  function toggleSelected(id: string) {
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function togglePageSelection() {
    const pageIds = prospects.map((prospect) => prospect.id);
    const allSelected = pageIds.length > 0 && pageIds.every((id) => selectedIds.has(id));
    setSelectedIds((current) => {
      const next = new Set(current);
      pageIds.forEach((id) => allSelected ? next.delete(id) : next.add(id));
      return next;
    });
  }

  function exportSelected() {
    const rows = prospects.filter((prospect) => selectedIds.has(prospect.id));
    if (!rows.length) return;
    const escape = (value: string) => `"${value.replace(/"/g, '""')}"`;
    const csv = [visibleDefinitions.map((field) => escape(field.label)).join(","), ...rows.map((prospect) => visibleDefinitions.map((field) => escape(prospectFieldValue(prospect, field.id))).join(","))].join("\r\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a"); link.href = url; link.download = `prospect-sync-selection-${new Date().toISOString().slice(0, 10)}.csv`; link.click(); URL.revokeObjectURL(url);
  }

  async function bulkAction(action: "tag" | "mark_contacted") {
    if (!selectedIds.size) return;
    const tagName = action === "tag" ? window.prompt("Tag name")?.trim() : "";
    if (action === "tag" && !tagName) return;
    if (action === "mark_contacted" && !bulkClientId) { setNotice("Choose a client before marking prospects as contacted."); return; }
    setBulkBusy(true); setNotice("");
    try {
      const result = await api<{ updated: number }>("/api/operations", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, prospectIds: [...selectedIds], tagName, clientId: bulkClientId }) });
      setNotice(`${formatNumber(result.updated)} prospects updated.`); setSelectedIds(new Set()); onRefresh();
    } catch (caught) { setNotice(caught instanceof Error ? caught.message : "Bulk action failed."); }
    finally { setBulkBusy(false); }
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
      <div><p className="eyebrow">PROSPECT INTELLIGENCE</p><h2>Find people</h2><p>Search, segment and reuse every prospect in your master database.</p></div>
      <button className="primary" onClick={onImport}>↑ Import prospects</button>
    </div>
    <div className="people-tabs">
      <button className={tab === "records" ? "active" : ""} onClick={() => setTab("records")}>All prospects <span>{formatNumber(total)}</span></button>
      <button className={tab === "coverage" ? "active" : ""} onClick={() => setTab("coverage")}>Field coverage <span>{formatNumber(fields.length)}</span></button>
    </div>
    {tab === "coverage" ? <article className="panel field-coverage">
      <div className="coverage-summary"><span className="coverage-symbol">✓</span><div><strong>{formatNumber(fields.length)} uploaded fields available</strong><p>Every detected CSV field is synchronized and available for filtering or display.</p></div></div>
      <div className="coverage-groups"><section><h3>Standard columns</h3><div>{standardProspectFields.map((field, index) => <span className={`field-chip tone-${index % 4}`} key={field.id}>{field.label}</span>)}</div></section><section><h3>Uploaded CSV fields</h3><div>{fields.map((field, index) => <span className={`field-chip tone-${index % 4}`} key={field}>{field}</span>)}</div></section></div>
    </article> : <div className="people-layout">
      <article className="panel results-panel">
        <div className="results-toolbar">
          <div><strong>{formatNumber(total)} people</strong><span>{filters.length ? `${filters.length} active filter${filters.length === 1 ? "" : "s"}` : "Master database"}</span></div>
          <div className="workspace-actions">
            <label><span className="sr-only">Saved ICP view</span><select defaultValue="" onChange={(event) => applyView(event.target.value)}><option value="">Saved views</option>{savedViews.map((view) => <option key={view.id} value={view.id}>{view.name}</option>)}</select></label>
            <button className="outline-button" onClick={() => void saveCurrentView()}>☆ Save view</button>
            <label><span className="sr-only">Sort prospects</span><select value={`${sort}:${direction}`} onChange={(event) => { const [nextSort, nextDirection] = event.target.value.split(":"); onSortChange(nextSort, nextDirection as "asc" | "desc"); }}><option value="created_at:desc">Newest first</option><option value="name:asc">Name A–Z</option><option value="company:asc">Company A–Z</option><option value="title:asc">Title A–Z</option><option value="last_contacted:desc">Recently contacted</option></select></label>
            <div className="column-control"><button className="outline-button" onClick={() => setColumnMenu((open) => !open)}>▥ Columns <span>{visibleDefinitions.length}</span></button>{columnMenu && <div className="column-menu"><div><strong>Choose columns</strong><button onClick={() => { setVisibleColumns(defaultProspectColumns); localStorage.setItem("prospecthub-visible-columns", JSON.stringify(defaultProspectColumns)); }}>Reset</button></div>{allColumns.map((field) => <label key={field.id}><input type="checkbox" checked={visibleColumns.includes(field.id)} onChange={() => toggleColumn(field.id)} />{field.label}</label>)}</div>}</div>
          </div>
        </div>
        {notice ? <div className="inline-notice" role="status">{notice}<button aria-label="Dismiss notification" onClick={() => setNotice("")}>×</button></div> : null}
        {selectedIds.size ? <div className="bulk-bar"><strong>{formatNumber(selectedIds.size)} selected</strong><button onClick={exportSelected}>↓ Export CSV</button><button disabled={bulkBusy} onClick={() => void bulkAction("tag")}>＋ Add tag</button><select aria-label="Client for contact history" value={bulkClientId} onChange={(event) => setBulkClientId(event.target.value)}><option value="">Choose client</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select><button disabled={bulkBusy || !bulkClientId} onClick={() => void bulkAction("mark_contacted")}>✓ Mark contacted</button><button onClick={() => setSelectedIds(new Set())}>Clear</button></div> : null}
        {filters.some((filter) => filter.values.length || filter.operator === "empty" || filter.operator === "not_empty") ? <div className="active-filter-strip">{filters.flatMap((filter) => {
          const label = allColumns.find((field) => field.id === filter.field)?.label ?? filter.field;
          if (filter.operator === "empty" || filter.operator === "not_empty") return [<button key={filter.id} onClick={() => onFiltersChange(filters.filter((item) => item.id !== filter.id))}>{label}: {filter.operator === "empty" ? "Empty" : "Not empty"} <span>×</span></button>];
          return filter.values.map((value) => <button key={`${filter.id}-${value}`} onClick={() => updateFilter(filter.id, { values: filter.values.filter((item) => item !== value) })}>{label}: {value} <span>×</span></button>);
        })}<button className="clear-filter-chip" onClick={() => onFiltersChange([])}>Clear all</button></div> : null}
        {prospects.length ? <><div className="master-scroll-top" ref={topScrollRef} onScroll={(event) => syncHorizontalScroll(event.currentTarget, tableScrollRef.current)} aria-label="Horizontal table scroll"><div style={{ width: tableScrollWidth }}/></div><div className="master-table-wrap" ref={tableScrollRef} onScroll={(event) => syncHorizontalScroll(event.currentTarget, topScrollRef.current)}><table className="master-data-table"><thead><tr><th className="select-column"><input aria-label="Select this page" type="checkbox" checked={prospects.length > 0 && prospects.every((prospect) => selectedIds.has(prospect.id))} onChange={togglePageSelection}/></th>{visibleDefinitions.map((field) => <th key={field.id}>{field.label}</th>)}<th className="row-detail-column"/></tr></thead><tbody>{prospects.map((person) => <tr className={selectedIds.has(person.id) ? "selected" : ""} key={person.id} onClick={() => onSelect(person)}><td className="select-column" onClick={(event) => event.stopPropagation()}><input aria-label={`Select ${person.full_name || "prospect"}`} type="checkbox" checked={selectedIds.has(person.id)} onChange={() => toggleSelected(person.id)}/></td>{visibleDefinitions.map((field) => { const value = prospectFieldValue(person, field.id); return <td key={field.id}>{field.id === "__name" ? <div className="compact-person"><span>{initials(value)}</span><strong>{value || "Unnamed prospect"}</strong></div> : field.id === "__email" ? <span className="email-cell">{value || "—"}</span> : <span title={value}>{value || "—"}</span>}</td>; })}<td className="row-detail-column">›</td></tr>)}</tbody></table></div><div className="table-footer"><span>Showing {formatNumber(firstRecord)}–{formatNumber(lastRecord)} of {formatNumber(total)}</span><div><button disabled={page <= 1} onClick={() => onPageChange(page - 1)}>← Previous</button><span>Page {page} of {totalPages}</span><button disabled={page >= totalPages} onClick={() => onPageChange(page + 1)}>Next →</button></div></div></> : <EmptyState title="No matching prospects" text={filters.length ? "Adjust or clear the filters to see more records." : "Import a CSV and every unique prospect will be synchronized here."} action={filters.length ? "Clear filters" : "Import CSV"} onAction={filters.length ? () => onFiltersChange([]) : onImport} />}
      </article>
      <aside className="panel filter-panel">
        <div className="filter-panel-head"><div><span className="filter-icon">≡</span><div><strong>Filters</strong><small>Use multiple values in each rule</small></div></div>{filters.length ? <button onClick={() => onFiltersChange([])}>Clear all</button> : null}</div>
        <div className="filter-body">{filters.length ? filters.map((filter, index) => <div className="filter-rule" key={filter.id}>
          <div className="filter-rule-head"><span>{String(index + 1).padStart(2, "0")}</span><select aria-label={`Filter ${index + 1} field`} value={filter.field} onChange={(event) => updateFilter(filter.id, { field: event.target.value, values: [] })}>{allColumns.map((field) => <option key={field.id} value={field.id}>{field.label}</option>)}</select><button aria-label="Remove filter" onClick={() => onFiltersChange(filters.filter((item) => item.id !== filter.id))}>×</button></div>
          <select className="filter-condition" value={filter.operator} onChange={(event) => updateFilter(filter.id, { operator: event.target.value as ProspectFilter["operator"] })}><option value="contains">Includes any</option><option value="equals">Exactly matches any</option><option value="not_contains">Excludes any</option><option value="not_equals">Does not equal</option><option value="not_empty">Is not empty</option><option value="empty">Is empty</option></select>
          {!["empty", "not_empty"].includes(filter.operator) ? <MultiValueSelect key={`${filter.id}-${filter.field}`} values={filter.values} options={suggestedValues.get(filter.field) ?? []} onChange={(values) => updateFilter(filter.id, { values })} /> : null}
        </div>) : <div className="filter-empty"><span>⌁</span><strong>Build a segment</strong><p>Select a quick filter below or add any uploaded field.</p></div>}
          <button className="add-filter-button" onClick={() => addFilter()}>＋ Add filter</button>
          <div className="quick-filters"><small>QUICK FILTERS</small><button onClick={() => addFilter("__country")}>＋ Country</button><button onClick={() => addFilter("__title")}>＋ Job title</button><button onClick={() => addFilter("__seniority")}>＋ Seniority</button><button onClick={() => addFilter("Industry")}>＋ Industry</button></div>
        </div>
      </aside>
    </div>}
  </section>;
}

function MultiValueSelect({ values, options, onChange }: { values: string[]; options: string[]; onChange: (values: string[]) => void }) {
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const normalizedValues = values.map((value) => value.toLocaleLowerCase());
  const availableOptions = Array.from(new Set([...values, ...options])).filter((option) => option.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())).slice(0, 12);

  function addValue(rawValue: string) {
    const value = rawValue.trim();
    if (!value || normalizedValues.includes(value.toLocaleLowerCase())) return;
    onChange([...values, value]);
    setQuery("");
  }

  function toggleValue(value: string) {
    const selected = normalizedValues.includes(value.toLocaleLowerCase());
    onChange(selected ? values.filter((item) => item.toLocaleLowerCase() !== value.toLocaleLowerCase()) : [...values, value]);
  }

  return <div className="multi-value-field">
    <div className="multi-value-control">
      {values.map((value) => <button type="button" className="value-chip" key={value} onClick={(event) => { event.stopPropagation(); onChange(values.filter((item) => item !== value)); }}>{value}<span>×</span></button>)}
      <input value={query} onChange={(event) => { setQuery(event.target.value); setOpen(true); }} onFocus={() => setOpen(true)} onBlur={() => window.setTimeout(() => setOpen(false), 120)} onKeyDown={(event) => {
        if ((event.key === "Enter" || event.key === ",") && query.trim()) { event.preventDefault(); addValue(query.replace(/,$/, "")); }
        if (event.key === "Backspace" && !query && values.length) onChange(values.slice(0, -1));
      }} placeholder={values.length ? "Add another…" : "Select or type values…"} />
    </div>
    {open && (availableOptions.length || query.trim()) ? <div className="multi-value-menu">
      {availableOptions.map((option) => <button type="button" key={option} className={normalizedValues.includes(option.toLocaleLowerCase()) ? "selected" : ""} onMouseDown={(event) => event.preventDefault()} onClick={() => toggleValue(option)}><span>{normalizedValues.includes(option.toLocaleLowerCase()) ? "✓" : ""}</span>{option}</button>)}
      {query.trim() && !availableOptions.some((option) => option.toLocaleLowerCase() === query.trim().toLocaleLowerCase()) ? <button type="button" className="create-value" onMouseDown={(event) => event.preventDefault()} onClick={() => addValue(query)}>＋ Add “{query.trim()}”</button> : null}
    </div> : null}
    <small>{values.length ? `${values.length} selected · matches any value` : "Press Enter to add a custom value"}</small>
  </div>;
}

function CompanyTable({ companies, onImport }: { companies: Company[]; onImport: () => void }) {
  return <article className="panel table-panel"><div className="panel-head"><div><p className="eyebrow">COMPANY COVERAGE</p><h3>{formatNumber(companies.length)} known companies</h3><p>Companies are matched by normalized website domain, then by name when a domain is missing.</p></div><button onClick={onImport}>＋ Add from CSV</button></div>{companies.length ? <div className="company-grid">{companies.map((company) => <div className="company-card" key={company.id}><span className="company-logo">{initials(company.name)}</span><div><strong>{company.name || company.domain || "Unnamed company"}</strong><a href={company.domain ? `https://${company.domain}` : undefined}>{company.domain || "No domain"}</a></div><div className="company-numbers"><span><b>{formatNumber(company.prospect_count)}</b> prospects</span><span><b>{formatNumber(company.client_count)}</b> clients</span></div><span className="known">Known</span></div>)}</div> : <EmptyState title="No known companies yet" text="Companies found in imported lists will appear here automatically." action="Import CSV" onAction={onImport} />}</article>;
}

function ClientsView({ clients, onOpen, onImport }: { clients: ClientRecord[]; onOpen: (client: ClientRecord) => void; onImport: () => void }) {
  return <><div className="section-intro"><div><p className="eyebrow">CLIENT WORKSPACES</p><h2>Keep every ICP list organized.</h2><p>Each client keeps its original lists while sharing clean prospect records with the master.</p></div><button className="primary" onClick={onImport}>＋ Import client list</button></div>{clients.length ? <div className="clients-grid">{clients.map((client, index) => <button className="client-card" key={client.id} onClick={() => onOpen(client)}><span className={`client-logo tone-${index % 4}`}>{initials(client.name)}</span><div className="client-title"><strong>{client.name}</strong><small>Active workspace</small></div><div className="client-stats"><span><b>{formatNumber(client.prospect_count)}</b>prospects</span><span><b>{formatNumber(client.list_count)}</b>lists</span></div><div className="client-link">Open client <span>→</span></div></button>)}</div> : <EmptyState title="Create your first client" text="Import a list and enter the client name. The workspace will be created automatically." action="Import client list" onAction={onImport} />}</>;
}

function ClientDetail({ client, lists, onBack, onOpenList, onImport, onDeleteClient, onDeleteList }: { client: ClientRecord; lists: ListRecord[]; onBack: () => void; onOpenList: (list: ListRecord) => void; onImport: () => void; onDeleteClient: () => void; onDeleteList: (list: ListRecord) => void }) {
  const [cooldown, setCooldown] = useState(client.cooldown_days ?? 90);
  const [cooldownState, setCooldownState] = useState("");
  async function saveCooldown() {
    setCooldownState("Saving…");
    try { const result = await api<{ cooldownDays: number }>(`/api/clients/${encodeURIComponent(client.id)}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cooldownDays: cooldown }) }); setCooldown(result.cooldownDays); setCooldownState("Saved"); }
    catch (caught) { setCooldownState(caught instanceof Error ? caught.message : "Unable to save"); }
  }
  return <><button className="back" onClick={onBack}>← All clients</button><div className="client-hero"><span className="client-logo tone-0">{initials(client.name)}</span><div><p className="eyebrow">CLIENT WORKSPACE</p><h2>{client.name}</h2><p>{formatNumber(client.prospect_count)} prospects across {formatNumber(client.list_count)} lists</p></div><div className="cooldown-setting"><label htmlFor="cooldown-days">Contact cooldown</label><div><input id="cooldown-days" type="number" min="0" max="730" value={cooldown} onChange={(event) => setCooldown(Number(event.target.value))}/><span>days</span><button onClick={() => void saveCooldown()}>Save</button></div><small role="status">{cooldownState || "Used when checking reuse eligibility"}</small></div><div className="client-actions"><button className="primary" onClick={onImport}>＋ Import another list</button><button className="danger-button" onClick={onDeleteClient}>Delete client</button></div></div><article className="panel table-panel"><div className="panel-head"><div><h3>Uploaded lists</h3><p>Open any list to search its original rows and inspect preserved fields.</p></div></div>{lists.length ? <div className="table-wrap"><table><thead><tr><th>List</th><th>Source file</th><th>Rows</th><th>Fields preserved</th><th>New to master</th><th>Existing prospects</th><th>Imported</th><th>Actions</th></tr></thead><tbody>{lists.map((list) => <tr key={list.id}><td><button className="list-open-button" onClick={() => onOpenList(list)}><strong>{list.name}</strong><span>Open →</span></button></td><td>{list.source_file_name}</td><td>{formatNumber(list.uploaded_rows)}</td><td><span className="field-verified">✓ {formatNumber(list.field_count)} fields</span></td><td><span className="data-pill green">+{formatNumber(list.unique_added)}</span></td><td>{formatNumber(list.duplicates_linked)}</td><td>{new Date(list.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><button className="row-danger" onClick={() => onDeleteList(list)}>Delete</button></td></tr>)}</tbody></table></div> : <EmptyCompact text="No lists have been imported for this client." action="Import list" onAction={onImport} />}</article></>;
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
    <article className="panel list-workspace-panel">{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Loading list records…</div> : rows.length ? <div className="table-wrap"><table><thead><tr><th>Name</th><th>Company</th><th>Email</th><th>Title</th><th>Last contacted</th><th>Reuse eligibility</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id} onClick={() => onSelect(row)}><td><div className="compact-person"><span>{initials(row.full_name)}</span><strong>{row.full_name || "Unnamed prospect"}</strong></div></td><td>{row.company_name || "—"}</td><td>{row.work_email || "—"}</td><td>{row.title || "—"}</td><td>{row.last_contacted_at ? new Date(row.last_contacted_at).toLocaleDateString("en-IN") : "Never"}</td><td><span className={`eligibility ${row.eligible ? "eligible" : "cooling"}`}>{row.eligible ? "Eligible now" : `Wait until ${row.next_eligible_at ? new Date(row.next_eligible_at).toLocaleDateString("en-IN") : "—"}`}</span></td></tr>)}</tbody></table></div> : <EmptyCompact text="No prospects match this search." action="Clear search" onAction={() => setSearch("")} />}<div className="table-footer"><span>{formatNumber(total)} records</span><div><button disabled={page <= 1} onClick={() => setPage((current) => current - 1)}>← Previous</button><span>Page {page} of {totalPages}</span><button disabled={page >= totalPages} onClick={() => setPage((current) => current + 1)}>Next →</button></div></div></article>
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

  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">PRE-SCRAPE INTELLIGENCE</p><h2>Company coverage checker</h2><p>Compare a company-only TAM against your master database before paying to find employee emails.</p></div></div>
    <div className="coverage-workspace"><article className="panel coverage-upload"><label className={`dropzone small ${file ? "has-file" : ""}`}><input type="file" accept=".csv,text/csv" onChange={(event) => void selectCoverageFile(event)}/><span className="upload-mark">↑</span><strong>{file ? file.name : "Upload a company CSV"}</strong><small>Up to 5,000 companies per check</small></label>{headers.length ? <div className="mapping-grid"><label>Company name<select value={nameField} onChange={(event) => setNameField(event.target.value)}><option value="">Not mapped</option>{headers.map((header) => <option key={header}>{header}</option>)}</select></label><label>Website or domain<select value={domainField} onChange={(event) => setDomainField(event.target.value)}><option value="">Not mapped</option>{headers.map((header) => <option key={header}>{header}</option>)}</select></label></div> : null}{error ? <p className="form-error" role="alert">{error}</p> : null}<button className="primary" disabled={!file || (!nameField && !domainField) || busy} onClick={() => void checkCoverage()}>{busy ? "Checking master database…" : "Check company coverage"}</button></article>
      <article className="panel coverage-results">{summary ? <><div className="quality-metrics four"><div><span>Total companies</span><strong>{formatNumber(summary.total)}</strong></div><div><span>Already known</span><strong>{formatNumber(summary.known)}</strong></div><div><span>Net new</span><strong>{formatNumber(summary.new)}</strong></div><div><span>Existing prospects</span><strong>{formatNumber(summary.existingProspects)}</strong></div></div><div className="panel-head"><div><h3>Coverage results</h3><p>{summary.covered} companies already contain prospects</p></div><button onClick={exportNewCompanies}>Export net-new CSV</button></div><div className="table-wrap coverage-table"><table><thead><tr><th>Company</th><th>Domain</th><th>Status</th><th>Matched by</th><th>Prospects</th><th>Clients</th></tr></thead><tbody>{rows.map((row) => <tr key={`${row.row}-${row.domain}-${row.name}`}><td><strong>{row.name || row.matchedCompany || "Unnamed"}</strong></td><td>{row.domain || "—"}</td><td><span className={`coverage-status ${row.status}`}>{row.status === "known" ? "Known" : "Net new"}</span></td><td>{row.matchedBy || "—"}</td><td>{formatNumber(row.prospectCount)}</td><td>{formatNumber(row.clientCount)}</td></tr>)}</tbody></table></div></> : <div className="coverage-placeholder"><span>◫</span><h3>Know what already exists</h3><p>Upload company names or domains to see database coverage and export only net-new companies.</p></div>}</article></div>
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
  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">DATABASE HEALTH</p><h2>Data quality centre</h2><p>Find incomplete records and safely resolve potential duplicate master prospects.</p></div><button className="secondary" onClick={() => void load()}>↻ Refresh</button></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Analyzing master data…</div> : quality ? <><div className="quality-metrics"><div><span>Master prospects</span><strong>{formatNumber(quality.total)}</strong></div>{issues.map(([label, value]) => <div key={label}><span>{label}</span><strong>{formatNumber(value)}</strong><small>{quality.total ? `${Math.round((value / quality.total) * 100)}% of database` : "0%"}</small></div>)}</div><article className="panel duplicate-panel"><div className="panel-head"><div><h3>Duplicate review</h3><p>{formatNumber(candidates.length)} candidate pairs require review</p></div></div>{candidates.length ? <div className="duplicate-list">{candidates.map((candidate) => <div className="duplicate-pair" key={`${candidate.left.id}-${candidate.right.id}`}><div className="duplicate-confidence"><strong>{candidate.confidence}%</strong><span>{candidate.reason}</span></div><ProspectCompareCard prospect={candidate.left}/><div className="duplicate-actions"><button disabled={Boolean(merging)} onClick={() => void merge(candidate.left.id, candidate.right.id)}>Keep left</button><span>or</span><button disabled={Boolean(merging)} onClick={() => void merge(candidate.right.id, candidate.left.id)}>Keep right</button></div><ProspectCompareCard prospect={candidate.right}/></div>)}</div> : <EmptyCompact text="No potential duplicate groups need review." action="Refresh" onAction={() => void load()} />}</article></> : null}</section>;
}

function ProspectCompareCard({ prospect }: { prospect: Prospect }) {
  return <div className="compare-card"><div className="compact-person"><span>{initials(prospect.full_name)}</span><strong>{prospect.full_name || "Unnamed"}</strong></div><p>{prospect.title || "No title"}</p><p>{prospect.company_name || "No company"}</p><p>{prospect.work_email || "No work email"}</p><small>{formatNumber(prospect.list_count)} lists · {formatNumber(Object.keys(parseAllData(prospect.all_data)).length)} fields</small></div>;
}

function ImportMappingPanel({ audit, fieldMap, onChange }: { audit: FileAudit; fieldMap: Record<string, string>; onChange: (header: string, value: string) => void }) {
  return <div className="import-mapping"><div className="mapping-head"><div><strong>Field mapping</strong><small>Review how CSV columns map to master fields</small></div><span>{audit.invalidRows ? `${audit.invalidRows} rows need identity data` : "All rows identifiable"}</span></div><div className="mapping-list">{audit.headers.map((header) => <label key={header}><span title={header}>{header}</span><b>→</b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Auto detect"} onChange={(event) => onChange(header, event.target.value)}>{canonicalImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div><p>Original headers and values are always preserved, even when mapped to a standard field.</p></div>;
}

function ImportView({ clients, onComplete }: { clients: ClientRecord[]; onComplete: () => Promise<void> }) {
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
  const canSubmit = file && fileAudit && listName.trim() && (clientId || newClient.trim()) && phase === "idle";

  async function pickFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setFileAudit(null); setFieldMap({}); setMessage("");
    if (next) setListName(deriveListName(next.name));
    if (!next) return;
    try {
      const parsed = parseCsv(await next.text());
      const populatedCells = parsed.rows.reduce((count, row) => count + row.filter((value) => value.trim()).length, 0);
      const nextFieldMap = Object.fromEntries(parsed.headers.map((header) => [header, suggestedImportField(header)]));
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
      const started = await api<{ importId: string; listId: string }>("/api/imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ clientId: clientId || undefined, clientName: newClient || undefined, listName, fileName: file.name, totalRows: parsed.rows.length, headers: parsed.headers }) });
      setPhase("uploading"); setMessage(`Synchronizing ${formatNumber(parsed.rows.length)} rows with the master database…`);
      const chunkSize = 100;
      for (let index = 0; index < parsed.rows.length; index += chunkSize) {
        const chunk = parsed.rows.slice(index, index + chunkSize);
        const resolvedFieldMap = Object.fromEntries(Object.entries(fieldMap).filter(([, value]) => value && value !== "Auto detect"));
        await api("/api/imports/chunk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: started.importId, listId: started.listId, headers: parsed.headers, rows: chunk, rowOffset: index, fieldMap: resolvedFieldMap }) });
        setProgress(Math.round(((index + chunk.length) / parsed.rows.length) * 100));
      }
      const completed = await api<{ summary: { processed_rows: number; unique_added: number; duplicates_linked: number } }>("/api/imports/complete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: started.importId, listId: started.listId }) });
      setSummary(completed.summary); setPhase("done"); setMessage("Import complete. Your client list and master database are synchronized.");
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Import failed."); setPhase("idle"); }
  }

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark">✓</span><p className="eyebrow">IMPORT COMPLETE</p><h2>Your list is synchronized.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(fileAudit?.headers.length)}</strong><span>Fields preserved</span></div><div><strong>{formatNumber(summary.unique_added)}</strong><span>Added to master</span></div><div><strong>{formatNumber(summary.duplicates_linked)}</strong><span>Existing prospects linked</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  return <div className="import-layout">
    <div className="import-copy"><p className="eyebrow">CSV IMPORT</p><h2>Bring every list into one clean database.</h2><p>Preview the file, confirm field mapping, choose the client, and synchronize it safely with your master database.</p><ol><li><span>1</span><div><strong>Validate before import</strong><p>Review fields, row counts and records without usable identity data.</p></div></li><li><span>2</span><div><strong>Control field mapping</strong><p>Map unusual CSV headers without losing the original source fields.</p></div></li><li><span>3</span><div><strong>Sync with rollback</strong><p>Existing prospects are linked, new records are added once, and imports can be undone.</p></div></li></ol></div>
    <div className="import-card">
      <div className="form-field"><label htmlFor="import-client">Client</label><select id="import-client" value={clientId} onChange={(event) => { setClientId(event.target.value); if (event.target.value) setNewClient(""); }}><option value="">Create a new client</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select></div>
      {!clientId && <div className="form-field"><label htmlFor="new-client-name">New client name</label><input id="new-client-name" value={newClient} onChange={(event) => setNewClient(event.target.value)} placeholder="e.g. Acme Recruitment" /></div>}
      <label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,text/csv" onChange={(event) => void pickFile(event)}/><span className="upload-mark">↑</span>{file ? <><strong>{file.name}</strong><small>{(file.size / 1024 / 1024).toFixed(2)} MB · Ready to review</small></> : <><strong>Choose a CSV file</strong><small>Download your Google Sheet as .csv</small></>}</label>
      <div className="form-field"><label htmlFor="list-name">List name</label><input id="list-name" value={listName} onChange={(event) => setListName(event.target.value)} placeholder="Auto-filled from the CSV filename" /></div>
      {fileAudit && <><div className="file-audit"><div><span className="audit-check">✓</span><p><strong>{formatNumber(fileAudit.headers.length)} fields detected</strong><small>{formatNumber(fileAudit.rows)} rows · {formatNumber(fileAudit.populatedCells)} populated cells</small></p></div><div className="audit-fields">{fileAudit.headers.slice(0, 8).map((header) => <span key={header}>{header}</span>)}{fileAudit.headers.length > 8 && <span>+{fileAudit.headers.length - 8} more</span>}</div><p>{fileAudit.invalidRows ? `${fileAudit.invalidRows} rows do not currently contain email, LinkedIn, or name plus company domain and will be preserved without a master link.` : "Every row has sufficient identity data for master matching."}</p></div><ImportMappingPanel audit={fileAudit} fieldMap={fieldMap} onChange={(header, value) => setFieldMap((current) => ({ ...current, [header]: value }))}/></>}
      {phase !== "idle" && <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div>}
      {message && phase === "idle" && <p className="form-error" role="alert">{message}</p>}
      <button className="primary import-button" disabled={!canSubmit} onClick={startImport}>{phase === "idle" ? "Start import & sync" : "Processing…"}</button><p className="privacy-note">Original rows and fields remain stored in your private database.</p>
    </div>
  </div>;
}

function ProspectDrawer({ prospect, onClose }: { prospect: Prospect; onClose: () => void }) {
  const data = parseAllData(prospect.all_data);
  const [tab, setTab] = useState<"data" | "history">("data");
  const [events, setEvents] = useState<Array<{ id: string; contacted_at: string; campaign_name: string; outcome: string; client: { name?: string } | Array<{ name?: string }> }>>([]);
  useEffect(() => {
    const closeOnEscape = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", closeOnEscape);
    void api<{ events: typeof events }>(`/api/operations?prospectId=${encodeURIComponent(prospect.id)}`).then((result) => setEvents(result.events)).catch(() => setEvents([]));
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [prospect.id, onClose]);
  return <div className="drawer-backdrop"><button className="drawer-dismiss" aria-label="Close prospect details" onClick={onClose}/><aside className="drawer" role="dialog" aria-modal="true" aria-labelledby="prospect-drawer-title"><button className="drawer-close" aria-label="Close prospect details" onClick={onClose}>×</button><div className="drawer-person"><span>{initials(prospect.full_name)}</span><div><p className="eyebrow">MASTER PROSPECT</p><h2 id="prospect-drawer-title">{prospect.full_name || "Unnamed prospect"}</h2><p>{prospect.title || "No title"} {prospect.company_name ? `at ${prospect.company_name}` : ""}</p></div></div><div className="drawer-summary"><span><b>{formatNumber(prospect.client_count)}</b>clients</span><span><b>{formatNumber(prospect.list_count)}</b>lists</span><span><b>{Object.keys(data).length}</b>data fields</span></div><div className="drawer-tabs" role="tablist"><button role="tab" aria-selected={tab === "data"} className={tab === "data" ? "active" : ""} onClick={() => setTab("data")}>Synchronized data</button><button role="tab" aria-selected={tab === "history"} className={tab === "history" ? "active" : ""} onClick={() => setTab("history")}>Contact history <span>{events.length}</span></button></div>{tab === "data" ? <div className="field-list">{Object.entries(data).map(([field, value]) => <div key={field}><span>{field}</span><strong>{value || "—"}</strong></div>)}</div> : <div className="contact-timeline">{events.length ? events.map((event) => { const client = Array.isArray(event.client) ? event.client[0] : event.client; return <div key={event.id}><i/><span>{new Date(event.contacted_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</span><strong>{client?.name || "Unknown client"}</strong><p>{event.campaign_name || event.outcome || "Contacted"}</p></div>; }) : <div className="drawer-empty">No contact history recorded yet.</div>}</div>}</aside></div>;
}

function DeleteConfirmation({ target, busy, onCancel, onConfirm }: { target: DeleteRequest; busy: boolean; onCancel: () => void; onConfirm: (deleteOrphans: boolean) => Promise<void> }) {
  const [deleteOrphans, setDeleteOrphans] = useState(true);
  const action = target.kind === "import" ? "Undo import" : target.kind === "list" ? "Delete list" : "Delete client";
  const explanation = target.kind === "import"
    ? "This removes the import and its client-list links. The list is also removed when nothing else uses it."
    : target.kind === "list"
      ? "This removes the list, its import history, and all links between this list and the master database."
      : "This removes the client workspace, every list under it, its import history, and its master-database links.";
  return <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="delete-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="delete-title">{action}?</h2><p>{explanation}</p><div className="delete-target"><strong>{target.name}</strong><span>{target.context}</span></div><div className="cleanup-choice"><input id="delete-unused-master-records" type="checkbox" checked={deleteOrphans} onChange={(event) => setDeleteOrphans(event.target.checked)} /><label htmlFor="delete-unused-master-records"><strong>Remove unused master records</strong><small>Delete prospects and companies only when no other client list uses them.</small></label></div><p className="shared-safety">Shared prospects remain untouched when they are still linked to another client.</p><div className="modal-actions"><button className="secondary" disabled={busy} onClick={onCancel}>Cancel</button><button className="danger-button solid" disabled={busy} onClick={() => void onConfirm(deleteOrphans)}>{busy ? "Working…" : action}</button></div></section></div>;
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
