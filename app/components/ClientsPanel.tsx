"use client";

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import { api, companyApiPath, isAbortError, prospectApiPath } from "../../lib/dashboard-api";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientRecord, Company, ListRecord, Prospect, ProspectFilter } from "../../lib/types";
import { AppIcon, EmptyCompact, EmptyState } from "./DashboardUi";
import { CompanyTable } from "./CompaniesWorkspace";
import ListsPanel from "./ListsPanel";
import ProspectTable from "./ProspectTable";
import { useDebouncedValue } from "./useDebouncedValue";

export default function ClientsPanel({ clients, selectedClient, selectedList, lists, onOpenClient, onCloseClient, onOpenList, onCloseList, onSelectProspect, onImport, onDeleteClient, onDeleteList }: { clients: ClientRecord[]; selectedClient: ClientRecord | null; selectedList: ListRecord | null; lists: ListRecord[]; onOpenClient: (client: ClientRecord) => void; onCloseClient: () => void; onOpenList: (list: ListRecord) => void; onCloseList: () => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: (client: ClientRecord) => void; onDeleteList: (list: ListRecord) => void }) {
  if (!selectedClient) return <ClientsView clients={clients} onOpen={onOpenClient} onImport={onImport}/>;
  if (selectedList) return <ListsPanel client={selectedClient} list={selectedList} onBack={onCloseList} onSelect={onSelectProspect}/>;
  return <ClientDetail client={selectedClient} clients={clients} lists={lists} onBack={onCloseClient} onOpenList={onOpenList} onSelectProspect={onSelectProspect} onImport={onImport} onDeleteClient={() => onDeleteClient(selectedClient)} onDeleteList={onDeleteList}/>;
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
    <div className="client-database-tabs" role="tablist" aria-label={`${client.name} databases`}><button role="tab" aria-selected={tab === "lists"} className={tab === "lists" ? "active" : ""} onClick={() => setTab("lists")}><AppIcon name="upload" size={15}/> Uploaded lists <span>{formatNumber(client.list_count)}</span></button><button role="tab" aria-selected={tab === "prospects"} className={tab === "prospects" ? "active" : ""} onClick={() => setTab("prospects")}><AppIcon name="database" size={15}/> People DB <span>{formatNumber(client.prospect_count)}</span></button><button role="tab" aria-selected={tab === "companies"} className={tab === "companies" ? "active" : ""} onClick={() => setTab("companies")}><AppIcon name="company" size={15}/> Company DB</button></div>
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
  const totalCache = useRef(new Map<string, number>());
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  const encodedFilters = useMemo(() => JSON.stringify(filters.map(({ field, operator, values }) => ({ field, operator, values }))), [filters]);
  const countKey = useMemo(() => JSON.stringify([client.id, debouncedSearch.trim(), encodedFilters, companyScope, refresh, client.prospect_count]), [client.id, client.prospect_count, companyScope, debouncedSearch, encodedFilters, refresh]);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    const path = prospectApiPath({ search: debouncedSearch, page, sort, direction, filters: encodedFilters, clientId: client.id, includeFields: !fieldsLoaded.current, companyScope, withTotal: page === 1 && !totalCache.current.has(countKey) });
    void (async () => {
      setRefreshing(true);
      try {
        const data = await api<{ prospects: Prospect[]; total: number | null; fields?: string[] }>(path, { signal: controller.signal });
        if (current) {
          setProspects(data.prospects);
          if (data.total !== null) { totalCache.current.set(countKey, data.total); setTotal(data.total); }
          else if (totalCache.current.has(countKey)) setTotal(totalCache.current.get(countKey) ?? client.prospect_count);
          if (data.fields?.length) { fieldsLoaded.current = true; setFields(data.fields); }
          setError("");
        }
      } catch (caught) { if (current && !isAbortError(caught)) setError(caught instanceof Error ? caught.message : "Unable to load the client people database."); }
      finally { if (current) { setLoading(false); setRefreshing(false); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [client.id, client.prospect_count, deferredSearch, debouncedSearch, page, sort, direction, encodedFilters, refresh, companyScope, countKey]);
  const removeFromClient = useCallback(async (prospect: Prospect) => {
    if (!window.confirm(`Remove ${prospect.full_name || "this prospect"} from ${client.name}? The People DB record will be preserved.`)) return;
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}/prospects/${encodeURIComponent(prospect.id)}`, { method: "DELETE" });
      setRefresh((value) => value + 1);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to remove this prospect from the client."); }
  }, [client.id, client.name]);
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
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    const path = companyApiPath({ search: debouncedSearch, clientId: client.id, page, filters, peopleScope });
    void (async () => {
      setRefreshing(true);
      try {
        const data = await api<{ companies: Company[]; total: number; covered: number; prospectTotal: number; pageSize: number }>(path, { signal: controller.signal });
        if (current) { setCompanies(data.companies); setSummary({ total: data.total, covered: data.covered, prospectTotal: data.prospectTotal, pageSize: data.pageSize }); setError(""); }
      } catch (caught) { if (current && !isAbortError(caught)) setError(caught instanceof Error ? caught.message : "Unable to load the client company database."); }
      finally { if (current) { setLoading(false); setRefreshing(false); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [client.id, client.prospect_count, deferredSearch, debouncedSearch, page, filters, peopleScope]);
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT COMPANY DB</p><h3>{client.name} companies</h3><p>Companies represented by prospects in this client workspace.</p></div><button className="secondary" onClick={() => onSeePeople({ search: deferredSearch.trim(), filters })}>See People <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span>⌕</span><input aria-label={`Search ${client.name} companies`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search client companies…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client companies…</div> : null}{loading ? <div className="workspace-loading">Preparing company database…</div> : <CompanyTable companies={companies} total={summary.total} covered={summary.covered} prospectTotal={summary.prospectTotal} page={page} pageSize={summary.pageSize} clientId={client.id} search={deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onSeePeople={onSeePeople} onFilters={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onImport={onImport}/>}</section>;
}
