"use client";

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import { api, encodeFilters, fetchCompanies, fetchProspects, filterPayload, isAbortError } from "../../lib/dashboard-api";
import { filterPayloadWithSets } from "../../lib/filter-set-client";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientRecord, Company, ListRecord, Prospect, ProspectFilter } from "../../lib/types";
import { AppIcon, ConfirmDialog, EmptyCompact, EmptyState, TabPanel } from "./DashboardUi";
import { CompanyTable } from "./CompaniesWorkspace";
import BlocklistPanel from "./BlocklistPanel";
import ClientIcpPanel from "./ClientIcpPanel";
import ListsPanel from "./ListsPanel";
import ProspectTable from "./ProspectTable";
import Tabs from "./Tabs";
import { useClientIcps } from "./use-client-icps";
import { useDebouncedValue } from "./useDebouncedValue";
import { needsCompanyPreparation, type PreparationProgress } from "../../lib/prepared-search";
import SearchPreparation from './SearchPreparation';

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
    {clients.length ? <div className="client-directory" role="list">{clients.map((client, index) => <div className="client-row" role="listitem" key={client.id}>
      <span className={`client-logo tone-${index % 4}`} aria-hidden="true">{initials(client.name)}</span>
      <div className="client-row-identity"><button type="button" className="row-open" onClick={() => onOpen(client)}>{client.name}</button><small>{client.blocked_count ? `${formatNumber(client.blocked_count)} blocked` : "Active workspace"}</small></div>
      <span className="client-row-metric"><b>{formatNumber(client.prospect_count)}</b> prospects</span>
      <span className="client-row-metric"><b>{formatNumber(client.list_count)}</b> {client.list_count === 1 ? "list" : "lists"}</span>
      <button type="button" className="outline-button" onClick={() => onOpen(client)}>Open <AppIcon name="arrow" size={14}/></button>
    </div>)}</div> : <EmptyState title="Create your first client" text="Create a client first, add its blocklist, then import prospect lists." action="Create client" onAction={() => setCreateOpen(true)} />}
    {createOpen ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal create-client-modal" role="dialog" aria-modal="true" aria-labelledby="create-client-title"><p className="eyebrow">NEW CLIENT WORKSPACE</p><h2 id="create-client-title">Create a client</h2><p>You can add the blocklist before importing any prospects.</p><div className="form-field"><label htmlFor="standalone-client-name">Client name</label><input id="standalone-client-name" value={clientName} onChange={(event) => { setClientName(event.target.value); setCreateError(""); }} onKeyDown={(event) => { if (event.key === "Enter") void createClient(); }} placeholder="e.g. Acme Recruitment" /></div>{createError ? <p className="form-error" role="alert">{createError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={creating} onClick={() => { setCreateOpen(false); setClientName(""); setCreateError(""); }}>Cancel</button><button className="primary" disabled={creating || !clientName.trim()} onClick={() => void createClient()}>{creating ? "Creating…" : "Create client"}</button></div></section></div> : null}
  </>;
}

// "Show me this ICP" and "show me the people no ICP has claimed", as seeds for
// the People workspace.
//
// Both are ordinary __client_tags filters, the same ones the filter panel's
// Client ICP section writes - same field, same operators, same filter ids - so
// what the picker seeds is editable and clearable in the panel rather than
// being a second, invisible kind of filter. __client_tags matches on tag id,
// never on name, so renaming an ICP does not change what this returns.
//
// Unassigned is "not tagged with ANY of this client's ICPs", which is one
// not_contains carrying every tag id. It is not the same as "untagged": a
// prospect carrying another client's ICP, or one of the retired agency-wide
// tags, is unassigned for THIS client, and that is the question being asked.
export const unassignedIcp = "__unassigned";

export function icpFilterFor(choice: string, icps: Array<{ id: string; name: string }>): ProspectFilter[] {
  if (!choice) return [];
  if (choice === unassignedIcp) {
    // With no ICPs defined, every prospect is unassigned, and a filter with no
    // values is dropped by the workspace anyway - so say nothing rather than
    // seeding an empty filter that would read as "no filter applied".
    return icps.length ? [{ id: "__client_tags:exclude", field: "__client_tags", operator: "not_contains", values: icps.map((icp) => icp.id) }] : [];
  }
  return [{ id: "__client_tags:include", field: "__client_tags", operator: "contains", values: [choice] }];
}

function ClientDetail({ client, clients, lists, onBack, onOpenList, onSelectProspect, onImport, onDeleteClient, onDeleteList, onRefreshClients }:{ client: ClientRecord; clients: ClientRecord[]; lists: ListRecord[]; onBack: () => void; onOpenList: (list: ListRecord) => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: () => void; onDeleteList: (list: ListRecord) => void; onRefreshClients: () => void }) {
  const [cooldown, setCooldown] = useState(client.cooldown_days ?? 90);
  const [savedCooldown, setSavedCooldown] = useState(client.cooldown_days ?? 90);
  const [cooldownState, setCooldownState] = useState("");
  const [tab, setTab] = useState<"lists" | "prospects" | "leads" | "contactable" | "by_icp" | "companies" | "icp" | "blocklist">("lists");
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(null);
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(null);
  // Which ICP the picker beside the tabs is on. "" is nothing chosen and
  // unassignedIcp is "has none of this client's ICPs".
  const [icpChoice, setIcpChoice] = useState("");
  const icps = useClientIcps(client.id);
  const icpFilters = icpFilterFor(icpChoice, icps);
  async function saveCooldown() {
    setCooldownState("Saving…");
    try { const result = await api<{ cooldownDays: number }>(`/api/clients/${encodeURIComponent(client.id)}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cooldownDays: cooldown }) }); setCooldown(result.cooldownDays); setSavedCooldown(result.cooldownDays); setCooldownState("Saved"); onRefreshClients(); }
    catch (caught) { setCooldownState(caught instanceof Error ? caught.message : "Unable to save"); }
  }
  return <><button className="back" onClick={onBack}><AppIcon name="back" size={14}/> All clients</button><div className="client-hero"><span className="client-logo tone-0">{initials(client.name)}</span><div><p className="eyebrow">CLIENT WORKSPACE</p><h2>{client.name}</h2><p>{formatNumber(client.prospect_count)} prospects across {formatNumber(client.list_count)} lists{client.icp_verified_count !== undefined ? <> · <strong className="icp-count">{formatNumber(client.icp_verified_count)} ICP verified</strong></> : null}</p></div><div className="cooldown-setting"><label htmlFor="cooldown-days">Contact cooldown</label><div><input id="cooldown-days" type="number" min="0" max="730" value={cooldown} onChange={(event) => setCooldown(Number(event.target.value))}/><span>days</span><button onClick={() => void saveCooldown()}>Save</button></div><small role="status">{cooldownState || "Used when checking reuse eligibility"}</small></div><div className="client-actions"><button className="primary" onClick={onImport}><AppIcon name="plus" size={14}/> Import another list</button><button className="danger-button" onClick={onDeleteClient}>Delete client</button></div></div>
    {/* The ICP picker sits BESIDE the tablist, not inside it: role="tablist"
        may only contain tabs, and a <select> in there is announced as one more
        tab that does nothing. Choosing an ICP is what activates its panel, and
        moving to any other tab puts the picker back to "By ICP…" so it never
        reads as active while something else is on screen. */}
    <div className="client-tab-row">
    <Tabs
      label={`${client.name} databases`}
      variant="segmented"
      value={tab}
      onChange={(next) => { if (next !== "by_icp") setIcpChoice(""); setTab(next); }}
      items={[
        { id: "lists" as const, label: "Uploaded lists", count: formatNumber(client.list_count), icon: <AppIcon name="upload" size={15}/> },
        { id: "prospects" as const, label: "People DB", count: formatNumber(client.prospect_count), icon: <AppIcon name="database" size={15}/> },
        { id: "leads" as const, label: "Leads", icon: <AppIcon name="star" size={15}/> },
        { id: "contactable" as const, label: "Contactable", icon: <AppIcon name="check" size={15}/> },
        { id: "companies" as const, label: "Company DB", icon: <AppIcon name="company" size={15}/> },
        { id: "icp" as const, label: "ICPs", icon: <AppIcon name="target" size={15}/> },
        { id: "blocklist" as const, label: "Blocklist", count: client.blocked_count ? formatNumber(client.blocked_count) : undefined, icon: <AppIcon name="quality" size={15}/> },
      ]}
    />
      <label className={`client-icp-picker${tab === "by_icp" && icpChoice ? " is-active" : ""}`}>
        <span className="sr-only">Filter {client.name} prospects by ICP</span>
        <AppIcon name="target" size={14}/>
        <select
          aria-label={`Filter ${client.name} prospects by ICP`}
          value={tab === "by_icp" ? icpChoice : ""}
          onChange={(event) => {
            const next = event.target.value;
            setIcpChoice(next);
            if (next) setTab("by_icp");
          }}
        >
          <option value="">By ICP…</option>
          {icps.map((icp) => <option key={icp.id} value={icp.id}>{icp.name}</option>)}
          {/* Last and separated: it is the complement of everything above it,
              not another ICP. Offered even with no ICPs defined, where it
              answers "all of them" and says so in the panel. */}
          <option value={unassignedIcp}>{icps.length ? "Unassigned" : "Unassigned (no ICPs yet)"}</option>
        </select>
      </label>
    </div>
    <TabPanel id="lists" active={tab === "lists"} keepMounted className="client-tab-panel"><article className="panel table-panel"><div className="panel-head"><div><h3>Uploaded lists</h3><p>Open any list to search its original rows and inspect preserved fields.</p></div></div>{lists.length ? <div className="table-wrap"><table><thead><tr><th>List</th><th>Data source</th><th>Source file</th><th>Rows</th><th>Fields preserved</th><th>New to master</th><th>Cross-client duplicates</th><th>Imported</th><th>Actions</th></tr></thead><tbody>{lists.map((list) => <tr key={list.id}><td><button className="list-open-button" onClick={() => onOpenList(list)}><strong>{list.name}</strong><span>Open</span></button></td><td><span className="data-source-badge">{list.data_source}</span></td><td>{list.source_file_name}</td><td>{formatNumber(list.uploaded_rows)}</td><td><span className="field-verified"><AppIcon name="check" size={14}/> {formatNumber(list.field_count)} fields</span></td><td><span className="data-pill green">+{formatNumber(list.unique_added)}</span></td><td>{formatNumber(list.duplicates_linked)}</td><td>{new Date(list.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><button className="row-danger" onClick={() => onDeleteList(list)}>Delete</button></td></tr>)}</tbody></table></div> : <EmptyCompact text="No lists have been imported for this client." action="Import list" onAction={onImport} />}</article></TabPanel>
    <TabPanel id="prospects" active={tab === "prospects"} keepMounted className="client-tab-panel"><ClientMasterDatabase key={`people:${client.prospect_count}:${client.blocked_count ?? 0}`} client={{ ...client, cooldown_days: savedCooldown }} clients={clients.map((item) => item.id === client.id ? { ...item, cooldown_days: savedCooldown } : item)} active={tab === "prospects"} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onSeeCompanies={(scope) => { if (companyPeopleScope) { setCompanyPeopleScope(null); setPeopleCompanyScope(null); } else setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/></TabPanel>
    {/* Leads and Contactable are the People DB with a filter already applied,
        not separate grids. The workspace owns paging, selection, freezing,
        export and the company pivot; a second copy of it would be a second
        copy of all of that, and would drift. Mounted only while open so two
        extra client listings are not fetched on every client screen. */}
    <TabPanel id="leads" active={tab === "leads"} keepMounted className="client-tab-panel">{tab === "leads" ? <ClientMasterDatabase key={`leads:${client.id}`} client={{ ...client, cooldown_days: savedCooldown }} clients={clients} active initialFilters={[{ id: `__lead:${client.id}`, field: "__lead", operator: "contains", values: [client.id] }]} companyScope={null} onClearCompanyScope={() => {}} onSeeCompanies={(scope) => { setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/> : null}</TabPanel>
    <TabPanel id="contactable" active={tab === "contactable"} keepMounted className="client-tab-panel">{tab === "contactable" ? <ClientMasterDatabase key={`contactable:${client.id}`} client={{ ...client, cooldown_days: savedCooldown }} clients={clients} active initialFilters={[{ id: `__contactable:${client.id}`, field: "__contactable", operator: "contains", values: [client.id] }]} companyScope={null} onClearCompanyScope={() => {}} onSeeCompanies={(scope) => { setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/> : null}</TabPanel>
    {/* Same shape as Leads and Contactable: the People DB with a filter already
        applied, keyed on the choice so switching ICPs remounts with its own
        seed rather than keeping the previous one's edits. */}
    <TabPanel id="by_icp" active={tab === "by_icp"} keepMounted className="client-tab-panel">{tab === "by_icp" && icpChoice ? <>
      <p className="client-icp-scope" role="status">{icpChoice === unassignedIcp
        ? icps.length
          ? <>Showing {client.name} prospects carrying <strong>none</strong> of its {icps.length} ICP{icps.length === 1 ? "" : "s"}.</>
          : <>{client.name} has no named ICPs yet, so every prospect is unassigned. Name one on the ICPs tab to start sorting them.</>
        : <>Showing {client.name} prospects tagged <strong>{icps.find((icp) => icp.id === icpChoice)?.name ?? "this ICP"}</strong>.</>}</p>
      <ClientMasterDatabase key={`icp:${client.id}:${icpChoice}`} client={{ ...client, cooldown_days: savedCooldown }} clients={clients} active initialFilters={icpFilters} companyScope={null} onClearCompanyScope={() => {}} onSeeCompanies={(scope) => { setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/>
    </> : null}</TabPanel>
    <TabPanel id="companies" active={tab === "companies"} keepMounted className="client-tab-panel"><ClientCompanyDatabase key={`companies:${client.prospect_count}:${client.blocked_count ?? 0}`} client={client} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onSeePeople={(scope) => { if (peopleCompanyScope) { setPeopleCompanyScope(null); setCompanyPeopleScope(null); } else setCompanyPeopleScope(scope); setTab("prospects"); }} onImport={onImport}/></TabPanel>
    {/* Mounted only while open, like the blocklist: the ICP list is its own
        fetch and there is no reason to pay for it on every client screen. */}
    <TabPanel id="icp" active={tab === "icp"} keepMounted className="client-tab-panel">{tab === "icp" ? <ClientIcpPanel client={client}/> : null}</TabPanel>
    <TabPanel id="blocklist" active={tab === "blocklist"} keepMounted className="client-tab-panel">{tab === "blocklist" ? <BlocklistPanel client={client} onChanged={onRefreshClients}/> : null}</TabPanel>
  </>;
}

function ClientMasterDatabase({ client, clients, active, companyScope, onClearCompanyScope, onSeeCompanies, onSelect, onImport, initialFilters = [] }: { client: ClientRecord; clients: ClientRecord[]; active: boolean; companyScope: CompanyScope | null; onClearCompanyScope: () => void; onSeeCompanies: (scope: PeopleScope) => void; onSelect: (prospect: Prospect) => void; onImport: () => void; initialFilters?: ProspectFilter[] }) {
  const [prospects, setProspects] = useState<Prospect[]>([]);
  const [preparation, setPreparation] = useState<PreparationProgress | null>(null);
  const [preparationError, setPreparationError] = useState('');
  const [total, setTotal] = useState(client.prospect_count);
  const [totalCapped, setTotalCapped] = useState(false);
  const [fields, setFields] = useState<string[]>([]);
  // Seeded, not forced: the Leads and Contactable tabs open pre-filtered, and
  // the filter is then editable and clearable like any other. Each tab passes a
  // distinct key so switching remounts with its own seed rather than inheriting
  // whatever the previous tab was left showing.
  const [filters, setFilters] = useState<ProspectFilter[]>(initialFilters);
  const [page, setPage] = useState(1);
  const [sort, setSort] = useState("created_at");
  const [direction, setDirection] = useState<"asc" | "desc">("desc");
  const [search, setSearch] = useState("");
  const [refresh, setRefresh] = useState(0);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const fieldsLoaded = useRef(false);
  // Total plus the version vector it was counted at; the server recounts when
  // the vector it is given no longer matches the live one.
  const totalCache = useRef(new Map<string, { total: number; versions: Record<string, number> | null }>());
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  const encodedFilters = useMemo(() => encodeFilters(filters), [filters]);
  const countKey = useMemo(() => JSON.stringify([client.id, debouncedSearch.trim(), encodedFilters, companyScope, refresh, client.prospect_count]), [client.id, client.prospect_count, companyScope, debouncedSearch, encodedFilters, refresh]);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (!active) return () => { current = false; controller.abort(); };
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      setRefreshing(true);
      try {
        const cached = totalCache.current.get(countKey);
        setPreparationError('');
        setPreparation(needsCompanyPreparation(companyScope) ? { status: 'checking', message: 'Checking the matching companies…', matchedCompanies: 0 } : null);
        const data = await fetchProspects<{ prospects: Prospect[]; total: number | null; totalEstimated: boolean; totalCapped?: boolean; versions?: Record<string, number> | null; fields?: string[] }>({ search: debouncedSearch, page, sort, direction, filters: encodedFilters, clientId: client.id, includeFields: !fieldsLoaded.current, companyScope, withTotal: page === 1 && !cached, knownVersions: cached?.versions ?? null }, { signal: controller.signal }, progress => { if (current) setPreparation(progress); });
        if (current) {
          setProspects(data.prospects);
          // A client view is never the unfiltered whole database, so its count is
          // always the capped one -- carry the flag through or a bounded number
          // would read here as an exact one.
          setTotalCapped(data.totalCapped === true);
          if (data.total !== null) { totalCache.current.set(countKey, { total: data.total, versions: data.versions ?? null }); setTotal(data.total); }
          else if (cached) setTotal(cached.total);
          if (data.fields?.length) { fieldsLoaded.current = true; setFields(data.fields); }
          setError("");
        }
      } catch (caught) { if (current && !isAbortError(caught)) {
        const message = caught instanceof Error ? caught.message : "Unable to load the client people database.";
        setError(message);
        if (needsCompanyPreparation(companyScope)) setPreparationError(message);
      } }
      finally { if (current) { setLoading(false); setRefreshing(false); setPreparation(null); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [active, client.id, client.prospect_count, deferredSearch, debouncedSearch, page, sort, direction, encodedFilters, refresh, companyScope, countKey]);
  // Asking is a render, not a blocking call: window.confirm freezes the tab,
  // cannot carry the scope sentence that makes this safe to say yes to, and has
  // none of the focus contract every other dialog here keeps.
  const [pendingRemoval, setPendingRemoval] = useState<Prospect | null>(null);
  const [removing, setRemoving] = useState(false);
  const removeFromClient = useCallback(async (prospect: Prospect) => { setPendingRemoval(prospect); }, []);
  const confirmRemoval = useCallback(async () => {
    const prospect = pendingRemoval;
    if (!prospect) return;
    setRemoving(true);
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}/prospects/${encodeURIComponent(prospect.id)}`, { method: "DELETE" });
      setRefresh((value) => value + 1);
      setPendingRemoval(null);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to remove this prospect from the client."); }
    finally { setRemoving(false); }
  }, [client.id, pendingRemoval]);
  return <><SearchPreparation progress={preparation} error={preparationError} onRetry={() => setRefresh(value => value + 1)} onClear={onClearCompanyScope} clearLabel="Clear company scope"/><section hidden={Boolean(preparation || preparationError)} className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT MASTER DB</p><h3>{client.name} prospects</h3><p>Every master prospect connected to this client, across all uploaded lists.</p></div><button className="secondary" title="Safely scope up to 250,000 matching people" onClick={() => onSeeCompanies({ search: deferredSearch.trim(), filters: filterPayload(filters), limit: 250000 })}>See Companies <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label={`Search ${client.name} prospects`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this client database…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client prospects…</div> : null}{loading ? <div className="workspace-loading">Preparing client database…</div> : <ProspectTable prospects={prospects} total={total} totalCapped={totalCapped} fields={fields} filters={filters} page={page} clients={clients} search={deferredSearch} sort={sort} direction={direction} clientId={client.id} companyScope={companyScope} onClearCompanyScope={onClearCompanyScope} onSeeCompanies={onSeeCompanies} onRemoveFromClient={removeFromClient} onSortChange={(nextSort, nextDirection) => { setSort(nextSort); setDirection(nextDirection); setPage(1); }} onFiltersChange={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onSelect={onSelect} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)} active={active}/>}{pendingRemoval ? <ConfirmDialog title={`Remove ${pendingRemoval.full_name || "this prospect"} from ${client.name}?`} body="This removes the link between this prospect and this client, along with its list membership for this client." scopeNote="The People database record is preserved. Every other client keeps its own link to this person." confirmLabel="Remove from client" busy={removing} onCancel={() => setPendingRemoval(null)} onConfirm={() => void confirmRemoval()} /> : null}</section></>;
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
  const encodedFilters = useMemo(() => encodeFilters(filters), [filters]);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    if (deferredSearch !== debouncedSearch) return () => { current = false; controller.abort(); };
    void (async () => {
      setRefreshing(true);
      try {
        // Scoped to this client, and stored that way: resolve_filter_set_v1
        // checks the client scope as well as the owner, so a set made here
        // cannot be replayed against the global company database.
        const requestFilters = JSON.stringify(await filterPayloadWithSets(JSON.parse(encodedFilters), "company", client.id));
        if (!current) return;
        const data = await fetchCompanies<{ companies: Company[]; total: number; covered: number; prospectTotal: number; pageSize: number }>({ search: debouncedSearch, clientId: client.id, page, encodedFilters: requestFilters, peopleScope }, { signal: controller.signal });
        if (current) { setCompanies(data.companies); setSummary({ total: data.total, covered: data.covered, prospectTotal: data.prospectTotal, pageSize: data.pageSize }); setError(""); }
      } catch (caught) { if (current && !isAbortError(caught)) setError(caught instanceof Error ? caught.message : "Unable to load the client company database."); }
      finally { if (current) { setLoading(false); setRefreshing(false); } }
    })();
    return () => { current = false; controller.abort(); };
  }, [client.id, client.prospect_count, deferredSearch, debouncedSearch, page, encodedFilters, peopleScope, refresh]);
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT COMPANY DB</p><h3>{client.name} companies</h3><p>Companies pushed to this client or represented by its prospects.</p></div><button className="secondary" title="Safely scope up to 250,000 matching companies" onClick={() => onSeePeople({ search: deferredSearch.trim(), filters, limit: 250000 })}>See People <AppIcon name="arrow" size={14}/></button><label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label={`Search ${client.name} companies`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search client companies…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client companies…</div> : null}{loading ? <div className="workspace-loading">Preparing company database…</div> : <CompanyTable companies={companies} total={summary.total} covered={summary.covered} prospectTotal={summary.prospectTotal} page={page} pageSize={summary.pageSize} clientId={client.id} search={deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onSeePeople={onSeePeople} onFilters={(next) => { setFilters(next); setPage(1); }} onPageChange={setPage} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)}/>}</section>;
}
