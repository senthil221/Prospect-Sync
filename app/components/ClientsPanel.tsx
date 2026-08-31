"use client";

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import { api, encodeFilters, fetchCompanies, fetchProspects, filterPayload, isAbortError } from "../../lib/dashboard-api";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientRecord, Company, ListRecord, Prospect, ProspectFilter } from "../../lib/types";
import { AppIcon, EmptyCompact, EmptyState } from "./DashboardUi";
import { CompanyTable } from "./CompaniesWorkspace";
import BlocklistPanel from "./BlocklistPanel";
import ListsPanel from "./ListsPanel";
import ProspectTable from "./ProspectTable";
import Tabs from "./Tabs";
import { useDebouncedValue } from "./useDebouncedValue";

export default function ClientsPanel({ clients, selectedClient, selectedList, lists, onOpenClient, onCloseClient, onOpenList, onCloseList, onSelectProspect, onImport, onDeleteClient, onDeleteList, onRefreshClients }: { clients: ClientRecord[]; selectedClient: ClientRecord | null; selectedList: ListRecord | null; lists: ListRecord[]; onOpenClient: (client: ClientRecord) => void; onCloseClient: () => void; onOpenList: (list: ListRecord) => void; onCloseList: () => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: (client: ClientRecord) => void; onDeleteList: (list: ListRecord) => void; onRefreshClients: () => void }) {
  if (!selectedClient) return <ClientsView clients={clients} onOpen={onOpenClient} onImport={onImport} onRefresh={onRefreshClients}/>;
  if (selectedList) return <ListsPanel client={selectedClient} list={selectedList} onBack={onCloseList} onSelect={onSelectProspect}/>;
  return <ClientDetail client={selectedClient} clients={clients} lists={lists} onBack={onCloseClient} onOpenList={onOpenList} onSelectProspect={onSelectProspect} onImport={onImport} onDeleteClient={() => onDeleteClient(selectedClient)} onDeleteList={onDeleteList} onRefreshClients={onRefreshClients}/>;
}
function ClientsView({ clients, onOpen, onImport, onRefresh }: { clients: ClientRecord[]; onOpen: (client: ClientRecord) => void; onImport: () => void; onRefresh: () => void }) {
  const [createOpen, setCreateOpen] = useState(false);
  const [clientName, setClientName] = useState("");
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState("");

  async function createClient() {
    const name = clientName.trim();
    if (!name) return;
    setCreating(true); setCreateError("");
    try {
      const result = await api<{ client: { id: string; name: string } }>("/api/clients", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name }),
      });
      const created: ClientRecord = { ...result.client, list_count: 0, prospect_count: 0, cooldown_days: 90, icp_verified_count: 0, blocked_count: 0 };
      setCreateOpen(false); setClientName(""); onRefresh(); onOpen(created);
    } catch (caught) { setCreateError(caught instanceof Error ? caught.message : "Unable to create the client."); }
    finally { setCreating(false); }
  }

  return <>
    <div className="section-intro"><div><p className="eyebrow">CLIENT WORKSPACES</p><h2>Keep every ICP list organized.</h2><p>Create the client, prepare its blocklist, then import lists when you are ready.</p></div><div className="section-intro-actions"><button className="secondary" onClick={() => setCreateOpen(true)}><AppIcon name="plus" size={14}/> New client</button><button className="primary" onClick={onImport}><AppIcon name="upload" size={14}/> Import client list</button></div></div>
    {clients.length ? <div className="clients-grid">{clients.map((client, index) => <button className="client-card" key={client.id} onClick={() => onOpen(client)}><span className={`client-logo tone-${index % 4}`}>{initials(client.name)}</span><div className="client-title"><strong>{client.name}</strong><small>Active workspace</small></div><div className="client-stats"><span><b>{formatNumber(client.prospect_count)}</b>prospects</span><span><b>{formatNumber(client.list_count)}</b>lists</span></div><div className="client-link">Open client <span><AppIcon name="arrow" size={14}/></span></div></button>)}</div> : <EmptyState title="Create your first client" text="Create a client first, add its blocklist, then import prospect lists." action="Create client" onAction={() => setCreateOpen(true)} />}
    {createOpen ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal create-client-modal" role="dialog" aria-modal="true" aria-labelledby="create-client-title"><p className="eyebrow">NEW CLIENT WORKSPACE</p><h2 id="create-client-title">Create a client</h2><p>You can add the blocklist before importing any prospects.</p><div className="form-field"><label htmlFor="standalone-client-name">Client name</label><input id="standalone-client-name" value={clientName} onChange={(event) => { setClientName(event.target.value); setCreateError(""); }} onKeyDown={(event) => { if (event.key === "Enter") void createClient(); }} placeholder="e.g. Acme Recruitment" /></div>{createError ? <p className="form-error" role="alert">{createError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={creating} onClick={() => { setCreateOpen(false); setClientName(""); setCreateError(""); }}>Cancel</button><button className="primary" disabled={creating || !clientName.trim()} onClick={() => void createClient()}>{creating ? "Creating…" : "Create client"}</button></div></section></div> : null}
  </>;
}

function ClientDetail({ client, clients, lists, onBack, onOpenList, onSelectProspect, onImport, onDeleteClient, onDeleteList, onRefreshClients }: { client: ClientRecord; clients: ClientRecord[]; lists: ListRecord[]; onBack: () => void; onOpenList: (list: ListRecord) => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: () => void; onDeleteList: (list: ListRecord) => void; onRefreshClients: () => void }) {
  const [cooldown, setCooldown] = useState(client.cooldown_days ?? 90);
  const [cooldownState, setCooldownState] = useState("");
  const [tab, setTab] = useState<"lists" | "prospects" | "companies" | "blocklist">("lists");
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(null);
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(null);
  async function saveCooldown() {
    setCooldownState("Saving…");
    try { const result = await api<{ cooldownDays: number }>(`/api/clients/${encodeURIComponent(client.id)}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cooldownDays: cooldown }) }); setCooldown(result.cooldownDays); setCooldownState("Saved"); }
    catch (caught) { setCooldownState(caught instanceof Error ? caught.message : "Unable to save"); }
  }
  return <><button className="back" onClick={onBack}><AppIcon name="back" size={14}/> All clients</button><div className="client-hero"><span className="client-logo tone-0">{initials(client.name)}</span><div><p className="eyebrow">CLIENT WORKSPACE</p><h2>{client.name}</h2><p>{formatNumber(client.prospect_count)} prospects across {formatNumber(client.list_count)} lists{client.icp_verified_count !== undefined ? <> · <strong className="icp-count">{formatNumber(client.icp_verified_count)} ICP verified</strong></> : null}</p></div><div className="cooldown-setting"><label htmlFor="cooldown-days">Contact cooldown</label><div><input id="cooldown-days" type="number" min="0" max="730" value={cooldown} onChange={(event) => setCooldown(Number(event.target.value))}/><span>days</span><button onClick={() => void saveCooldown()}>Save</button></div><small role="status">{cooldownState || "Used when checking reuse eligibility"}</small></div><div className="client-actions"><button className="primary" onClick={onImport}><AppIcon name="plus" size={14}/> Import another list</button><button className="danger-button" onClick={onDeleteClient}>Delete client</button></div></div>
    <Tabs
      label={`${client.name} databases`}
      variant="segmented"
      value={tab}
      onChange={setTab}
      items={[
        { id: "lists" as const, label: "Uploaded lists", count: formatNumber(client.list_count), icon: <AppIcon name="upload" size={15}/> },
        { id: "prospects" as const, label: "People DB", count: formatNumber(client.prospect_count), icon: <AppIcon name="database" size={15}/> },
        { id: "companies" as const, label: "Company DB", icon: <AppIcon name="company" size={15}/> },
        { id: "blocklist" as const, label: "Blocklist", count: client.blocked_count ? formatNumber(client.blocked_count) : undefined, icon: <AppIcon name="quality" size={15}/> },
      ]}
    />
    <div className={`client-tab-panel ${tab === "lists" ? "active" : ""}`}><article className="panel table-panel"><div className="panel-head"><div><h3>Uploaded lists</h3><p>Open any list to search its original rows and inspect preserved fields.</p></div></div>{lists.length ? <div className="table-wrap"><table><thead><tr><th>List</th><th>Data source</th><th>Source file</th><th>Rows</th><th>Fields preserved</th><th>New to master</th><th>Cross-client duplicates</th><th>Imported</th><th>Actions</th></tr></thead><tbody>{lists.map((list) => <tr key={list.id}><td><button className="list-open-button" onClick={() => onOpenList(list)}><strong>{list.name}</strong><span>Open</span></button></td><td><span className="data-source-badge">{list.data_source}</span></td><td>{list.source_file_name}</td><td>{formatNumber(list.uploaded_rows)}</td><td><span className="field-verified"><AppIcon name="check" size={14}/> {formatNumber(list.field_count)} fields</span></td><td><span className="data-pill green">+{formatNumber(list.unique_added)}</span></td><td>{formatNumber(list.duplicates_linked)}</td><td>{new Date(list.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><button className="row-danger" onClick={() => onDeleteList(list)}>Delete</button></td></tr>)}</tbody></table></div> : <EmptyCompact text="No lists have been imported for this client." action="Import list" onAction={onImport} />}</article></div>
    <div className={`client-tab-panel ${tab === "prospects" ? "active" : ""}`}><ClientMasterDatabase key={`people:${client.prospect_count}:${client.blocked_count ?? 0}:${JSON.stringify(companyPeopleScope)}`} client={client} clients={clients} active={tab === "prospects"} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onSeeCompanies={(scope) => { setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/></div>
    <div className={`client-tab-panel ${tab === "companies" ? "active" : ""}`}><ClientCompanyDatabase key={`companies:${client.prospect_count}:${client.blocked_count ?? 0}:${JSON.stringify(peopleCompanyScope)}`} client={client} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onSeePeople={(scope) => { setCompanyPeopleScope(scope); setTab("prospects"); }} onImport={onImport}/></div>
    <div className={`client-tab-panel ${tab === "blocklist" ? "active" : ""}`}>{tab === "blocklist" ? <BlocklistPanel client={client} onChanged={onRefreshClients}/> : null}</div>
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
  const encodedFilters = useMemo(() => encodeFilters(filters), [filters]);
  const countKey = useMemo(() => JSON.stringify([client.id, debouncedSearch.trim(), encodedFilters, companyScope, refresh, client.prospect_count]), [client.id, client.prospect_count, companyScope, debouncedSearch, encodedFilters, refresh]);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      setRefreshing(true);
      try {
        const data = await fetchProspects<{ prospects: Prospect[]; total: number | null; totalEstimated: boolean; fields?: string[] }>({ search: debouncedSearch, page, sort, direction, filters: encodedFilters, clientId: client.id, includeFields: !fieldsLoaded.current, companyScope, withTotal: page === 1 && !totalCache.current.has(countKey) }, { signal: controller.signal });
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
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT MASTER DB</p><h3>{client.name} prospects</h3><p>Every master prospect connected to this client, across all uploaded lists.</p></div><button className="secondary" title="Safely scope up to 250,000 matching people" onClick={() => onSeeCompanies({ search: deferredSearch.trim(), filters: filterPayload(filters), limit: 250000 })}>See Companies <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label={`Search ${client.name} prospects`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this client database…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client prospects…</div> : null}{loading ? <div className="workspace-loading">Preparing client database…</div> : <ProspectTable prospects={prospects} total={total} fields={fields} filters={filters} page={page} clients={clients} search={deferredSearch} sort={sort} direction={direction} clientId={client.id} companyScope={companyScope} onClearCompanyScope={onClearCompanyScope} onSeeCompanies={onSeeCompanies} onRemoveFromClient={removeFromClient} onSortChange={(nextSort, nextDirection) => { setSort(nextSort); setDirection(nextDirection); setPage(1); }} onFiltersChange={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onSelect={onSelect} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)} active={active}/>}</section>;
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
  const [refresh, setRefresh] = useState(0);
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      setRefreshing(true);
      try {
        const data = await fetchCompanies<{ companies: Company[]; total: number; covered: number; prospectTotal: number; pageSize: number }>({ search: debouncedSearch, clientId: client.id, page, filters, peopleScope }, { signal: controller.signal });
        if (current) { setCompanies(data.companies); setSummary({ total: data.total, covered: data.covered, prospectTotal: data.prospectTotal, pageSize: data.pageSize }); setError(""); }
      } catch (caught) { if (current && !isAbortError(caught)) setError(caught instanceof Error ? caught.message : "Unable to load the client company database."); }
      finally { if (current) { setLoading(false); setRefreshing(false); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [client.id, client.prospect_count, deferredSearch, debouncedSearch, page, filters, peopleScope, refresh]);
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT COMPANY DB</p><h3>{client.name} companies</h3><p>Companies pushed to this client or represented by its prospects.</p></div><button className="secondary" title="Safely scope up to 250,000 matching companies" onClick={() => onSeePeople({ search: deferredSearch.trim(), filters, limit: 250000 })}>See People <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label={`Search ${client.name} companies`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search client companies…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client companies…</div> : null}{loading ? <div className="workspace-loading">Preparing company database…</div> : <CompanyTable companies={companies} total={summary.total} covered={summary.covered} prospectTotal={summary.prospectTotal} page={page} pageSize={summary.pageSize} clientId={client.id} search={deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onSeePeople={onSeePeople} onFilters={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)}/>}</section>;
}
