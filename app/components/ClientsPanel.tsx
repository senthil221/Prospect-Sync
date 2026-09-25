"use client";

import { useCallback, useDeferredValue, useEffect, useId, useMemo, useRef, useState } from "react";
import type { CompanyScope, PeopleScope } from "../../lib/workspace-scopes";
import { api, encodeFilters, fetchCompanies, fetchProspects, filterPayload, isAbortError } from "../../lib/dashboard-api";
import { filterPayloadWithSets } from "../../lib/filter-set-client";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientFolder, ClientRecord, Company, ListRecord, Prospect, ProspectFilter } from "../../lib/types";
import { AppIcon, ConfirmDialog, EmptyCompact, EmptyState, TabPanel } from "./DashboardUi";
import { CompanyTable } from "./CompaniesWorkspace";
import BlocklistPanel from "./BlocklistPanel";
import ClientIcpPanel from "./ClientIcpPanel";
import ListsPanel from "./ListsPanel";
import ProspectTable from "./ProspectTable";
import RecentlyAddedPanel from "./RecentlyAddedPanel";
import Tabs from "./Tabs";
import { useClientIcps } from "./use-client-icps";
import { useClientLists } from "./use-client-lists";
import { useDebouncedValue } from "./useDebouncedValue";
import { useDismiss } from "../use-dismiss";
import { needsCompanyPreparation, type PreparationProgress } from "../../lib/prepared-search";
import SearchPreparation from './SearchPreparation';

function distinctSourceFile(list: ListRecord) {
  const filename = list.source_file_name?.trim() ?? "";
  return filename && filename.replace(/\.[^.]+$/, "").toLocaleLowerCase() !== list.name.trim().toLocaleLowerCase() ? filename : "";
}

export default function ClientsPanel({ clients, selectedClient, selectedList, lists, onOpenClient, onCloseClient, onOpenList, onCloseList, listPivot, onConsumeListPivot, onSeeListRecords, onSelectProspect, onImport, onDeleteClient, onDeleteList, onRefreshClients }: { clients: ClientRecord[]; selectedClient: ClientRecord | null; selectedList: ListRecord | null; lists: ListRecord[]; onOpenClient: (client: ClientRecord) => void; onCloseClient: () => void; onOpenList: (list: ListRecord) => void; onCloseList: () => void; listPivot: { clientId: string; listId: string; listName: string; target: "prospects" | "companies" } | null; onConsumeListPivot: () => void; onSeeListRecords: (clientId: string, list: ListRecord, target: "prospects" | "companies") => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: (client: ClientRecord) => void; onDeleteList: (list: ListRecord) => void; onRefreshClients: () => void }) {
  // Keep the directory context above the list/detail switch. Opening a client
  // unmounts ClientsView, but returning should land in the folder the user was
  // working from rather than silently resetting to All clients.
  const [folders, setFolders] = useState<ClientFolder[]>([]);
  const [folderSelection, setFolderSelection] = useState("all");
  const [folderError, setFolderError] = useState("");
  const [folderRefresh, setFolderRefresh] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    void api<{ folders: ClientFolder[] }>("/api/client-folders", { cache: "no-store", signal: controller.signal })
      .then((data) => setFolders(data.folders ?? []))
      .catch((caught) => {
        if (!isAbortError(caught)) setFolderError(caught instanceof Error ? caught.message : "Unable to load client folders.");
      });
    return () => controller.abort();
  }, [folderRefresh]);

  if (!selectedClient) return <ClientsView clients={clients} folders={folders} folderSelection={folderSelection} folderError={folderError} onFolderSelection={setFolderSelection} onFolderCreated={(folder) => setFolders((current) => current.some((item) => item.id === folder.id) ? current : [...current, folder].sort((a, b) => a.name.localeCompare(b.name)))} onFolderRenamed={(folder) => setFolders((current) => current.map((item) => item.id === folder.id ? folder : item).sort((a, b) => a.name.localeCompare(b.name)))} onRetryFolders={() => { setFolderError(""); setFolderRefresh((value) => value + 1); }} onOpen={onOpenClient} onImport={onImport} onRefresh={onRefreshClients}/>;
  if (selectedList) return <ListsPanel client={selectedClient} list={selectedList} onBack={onCloseList} onSelect={onSelectProspect}
    onSeePeople={() => onSeeListRecords(selectedClient.id, selectedList, "prospects")}
    onSeeCompanies={() => onSeeListRecords(selectedClient.id, selectedList, "companies")}/>;
  return <ClientDetail client={selectedClient} clients={clients} lists={lists} onBack={onCloseClient} onOpenList={onOpenList} onSelectProspect={onSelectProspect} onImport={onImport} onDeleteClient={() => onDeleteClient(selectedClient)} onDeleteList={onDeleteList} onRefreshClients={onRefreshClients}
    listPivot={listPivot && listPivot.clientId === selectedClient.id ? listPivot : null} onConsumeListPivot={onConsumeListPivot}/>;
}
function ClientsView({ clients, folders, folderSelection, folderError, onFolderSelection, onFolderCreated, onFolderRenamed, onRetryFolders, onOpen, onImport, onRefresh }: { clients: ClientRecord[]; folders: ClientFolder[]; folderSelection: string; folderError: string; onFolderSelection: (selection: string) => void; onFolderCreated: (folder: ClientFolder) => void; onFolderRenamed: (folder: ClientFolder) => void; onRetryFolders: () => void; onOpen: (client: ClientRecord) => void; onImport: () => void; onRefresh: () => void }) {
  const [createOpen, setCreateOpen] = useState(false);
  const [folderOpen, setFolderOpen] = useState(false);
  const [renameOpen, setRenameOpen] = useState(false);
  const [clientName, setClientName] = useState("");
  const [folderName, setFolderName] = useState("");
  const [renameName, setRenameName] = useState("");
  const [creating, setCreating] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [createError, setCreateError] = useState("");
  const [renameError, setRenameError] = useState("");

  const activeClients = clients.filter((client) => !client.archived_at);
  const archivedClients = clients.filter((client) => Boolean(client.archived_at));
  const unfiledClients = activeClients.filter((client) => !client.folder_id);
  const selectedFolder = folders.find((folder) => folder.id === folderSelection) ?? null;
  const visibleClients = folderSelection === "archived" ? archivedClients
    : folderSelection === "unfiled" ? unfiledClients
    : selectedFolder ? activeClients.filter((client) => client.folder_id === selectedFolder.id)
    : activeClients;
  const selectedLabel = folderSelection === "archived" ? "Archived"
    : folderSelection === "unfiled" ? "Unfiled"
    : selectedFolder?.name ?? "All clients";

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

  async function createFolder() {
    const name = folderName.trim();
    if (!name) return;
    setCreating(true); setCreateError("");
    try {
      const result = await api<{ folder: ClientFolder }>("/api/client-folders", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name }),
      });
      onFolderCreated(result.folder);
      onFolderSelection(result.folder.id);
      setFolderOpen(false); setFolderName("");
    } catch (caught) { setCreateError(caught instanceof Error ? caught.message : "Unable to create the folder."); }
    finally { setCreating(false); }
  }

  async function moveClient(client: ClientRecord, folderId: string | null) {
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ folderId }),
      });
      onRefresh();
    } catch (caught) { setCreateError(caught instanceof Error ? caught.message : "Unable to move the client."); }
  }

  async function renameFolder() {
    const name = renameName.trim();
    if (!selectedFolder || !name) return;
    setRenaming(true); setRenameError("");
    try {
      const result = await api<{ folder: ClientFolder }>(`/api/client-folders/${encodeURIComponent(selectedFolder.id)}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name }),
      });
      onFolderRenamed(result.folder);
      setRenameOpen(false); setRenameName("");
    } catch (caught) { setRenameError(caught instanceof Error ? caught.message : "Unable to rename the folder."); }
    finally { setRenaming(false); }
  }

  async function setArchived(client: ClientRecord, archived: boolean) {
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}`, {
        method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ archived }),
      });
      onRefresh();
    } catch (caught) { setCreateError(caught instanceof Error ? caught.message : "Unable to update the client."); }
  }

  function clientRow(client: ClientRecord, index: number, archived = false) {
    return <div className="client-row" role="listitem" key={client.id}>
      <span className={`client-logo tone-${index % 4}`} aria-hidden="true">{initials(client.name)}</span>
      <div className="client-row-identity"><button type="button" className="row-open" onClick={() => onOpen(client)}>{client.name}</button><small>{archived ? "Archived" : client.blocked_count ? `${formatNumber(client.blocked_count)} blocked` : "Active workspace"}</small></div>
      <div className="client-row-stats"><span className="client-row-metric"><b>{formatNumber(client.prospect_count)}</b> people</span><span className="client-row-metric"><b>{formatNumber(client.company_count ?? 0)}</b> companies</span><span className="client-row-metric"><b>{formatNumber(client.list_count)}</b> lists</span></div>
      <div className="client-row-actions">
        {!archived ? <select aria-label={`Folder for ${client.name}`} value={client.folder_id ?? ""} onChange={(event) => void moveClient(client, event.target.value || null)}><option value="">No folder</option>{folders.map((folder) => <option key={folder.id} value={folder.id}>{folder.name}</option>)}</select> : null}
        <button type="button" className="client-row-archive" onClick={() => void setArchived(client, !archived)}>{archived ? "Restore" : "Archive"}</button>
        <button type="button" className="outline-button client-row-open" onClick={() => onOpen(client)}>Open <AppIcon name="arrow" size={14}/></button>
      </div>
    </div>;
  }

  return <>
    <div className="section-intro"><div><p className="eyebrow">CLIENT WORKSPACES</p><h2>Keep every ICP list organized.</h2><p>Group clients by account manager, or archive a workspace without deleting its data.</p></div><div className="section-intro-actions"><button className="secondary" onClick={() => setFolderOpen(true)}><AppIcon name="plus" size={14}/> New folder</button><button className="secondary" onClick={() => setCreateOpen(true)}><AppIcon name="plus" size={14}/> New client</button><button className="primary" onClick={onImport}><AppIcon name="upload" size={14}/> Import client list</button></div></div>
    {folderError ? <div className="inline-error client-folder-error" role="alert"><span>Folders could not be loaded: {folderError}</span><button type="button" onClick={onRetryFolders}>Retry</button></div> : null}
    {createError ? <div className="inline-error" role="alert">{createError}</div> : null}
    {activeClients.length || archivedClients.length || folders.length ? <div className="client-folder-workspace">
      <aside className="panel client-folder-navigator" aria-label="Client folders">
        <div className="client-folder-navigator-head"><p className="eyebrow">FOLDERS</p><strong>Client directory</strong></div>
        <nav>
          <button type="button" className={folderSelection === "all" ? "active" : ""} aria-current={folderSelection === "all" ? "page" : undefined} onClick={() => onFolderSelection("all")}><span>All clients</span><b>{formatNumber(activeClients.length)}</b></button>
          <div className="client-folder-nav-group" aria-label="Named folders">
            <small>Named folders</small>
            {folders.map((folder) => { const count = activeClients.filter((client) => client.folder_id === folder.id).length; return <button type="button" key={folder.id} className={folderSelection === folder.id ? "active" : ""} aria-current={folderSelection === folder.id ? "page" : undefined} onClick={() => onFolderSelection(folder.id)}><span>{folder.name}</span><b>{formatNumber(count)}</b></button>; })}
            {!folders.length ? <p>No named folders yet.</p> : null}
          </div>
          <button type="button" className={folderSelection === "unfiled" ? "active" : ""} aria-current={folderSelection === "unfiled" ? "page" : undefined} onClick={() => onFolderSelection("unfiled")}><span>Unfiled</span><b>{formatNumber(unfiledClients.length)}</b></button>
          <button type="button" className={folderSelection === "archived" ? "active" : ""} aria-current={folderSelection === "archived" ? "page" : undefined} onClick={() => onFolderSelection("archived")}><span>Archived</span><b>{formatNumber(archivedClients.length)}</b></button>
        </nav>
      </aside>
      <section className="panel table-panel client-folder-contents" aria-labelledby="selected-folder-title">
        <nav className="client-folder-breadcrumbs" aria-label="Folder breadcrumb"><button type="button" onClick={() => onFolderSelection("all")}>Clients</button><span aria-hidden="true">/</span><span aria-current="page">{selectedLabel}</span></nav>
        <div className="panel-head"><div><h3 id="selected-folder-title">{selectedLabel}</h3><p>{folderSelection === "archived" ? "Archived workspaces are hidden from active folders but keep all of their data." : selectedFolder ? `Clients assigned to ${selectedFolder.name}.` : folderSelection === "unfiled" ? "Active clients that have not been assigned to a folder." : "Every active client workspace, across all folders."}</p></div><div className="client-folder-heading-actions"><strong className="client-folder-total">{formatNumber(visibleClients.length)} client{visibleClients.length === 1 ? "" : "s"}</strong>{selectedFolder ? <button type="button" className="outline-button" onClick={() => { setRenameName(selectedFolder.name); setRenameError(""); setRenameOpen(true); }}>Rename folder</button> : null}</div></div>
        {visibleClients.length
          ? <div className="client-directory" role="list">{visibleClients.map((client, index) => clientRow(client, index, folderSelection === "archived"))}</div>
          : <EmptyCompact
              text={folderSelection === "archived" ? "No archived clients." : selectedFolder ? "No clients in this folder yet. Use the folder picker on a client row to move one here." : folderSelection === "unfiled" ? "Every active client is filed." : "No active clients."}
            />}
      </section>
    </div> : <EmptyState title="Create your first client" text="Create a client first, add its blocklist, then import prospect lists." action="Create client" onAction={() => setCreateOpen(true)} />}
    {createOpen ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal create-client-modal" role="dialog" aria-modal="true" aria-labelledby="create-client-title"><p className="eyebrow">NEW CLIENT WORKSPACE</p><h2 id="create-client-title">Create a client</h2><p>You can add the blocklist before importing any prospects.</p><div className="form-field"><label htmlFor="standalone-client-name">Client name</label><input id="standalone-client-name" value={clientName} onChange={(event) => { setClientName(event.target.value); setCreateError(""); }} onKeyDown={(event) => { if (event.key === "Enter") void createClient(); }} placeholder="e.g. Acme Recruitment" /></div>{createError ? <p className="form-error" role="alert">{createError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={creating} onClick={() => { setCreateOpen(false); setClientName(""); setCreateError(""); }}>Cancel</button><button className="primary" disabled={creating || !clientName.trim()} onClick={() => void createClient()}>{creating ? "Creating…" : "Create client"}</button></div></section></div> : null}
    {folderOpen ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal create-client-modal" role="dialog" aria-modal="true" aria-labelledby="create-folder-title"><p className="eyebrow">CLIENT FOLDER</p><h2 id="create-folder-title">Create a folder</h2><p>Use folders for account managers, teams, or any other client grouping.</p><div className="form-field"><label htmlFor="client-folder-name">Folder name</label><input id="client-folder-name" value={folderName} onChange={(event) => { setFolderName(event.target.value); setCreateError(""); }} onKeyDown={(event) => { if (event.key === "Enter") void createFolder(); }} placeholder="e.g. Priya's accounts" /></div>{createError ? <p className="form-error" role="alert">{createError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={creating} onClick={() => { setFolderOpen(false); setFolderName(""); setCreateError(""); }}>Cancel</button><button className="primary" disabled={creating || !folderName.trim()} onClick={() => void createFolder()}>{creating ? "Creating…" : "Create folder"}</button></div></section></div> : null}
    {renameOpen && selectedFolder ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal create-client-modal" role="dialog" aria-modal="true" aria-labelledby="rename-folder-title"><p className="eyebrow">CLIENT FOLDER</p><h2 id="rename-folder-title">Rename folder</h2><p>Client assignments stay unchanged.</p><div className="form-field"><label htmlFor="rename-folder-name">Folder name</label><input id="rename-folder-name" maxLength={120} value={renameName} onChange={(event) => { setRenameName(event.target.value); setRenameError(""); }} onKeyDown={(event) => { if (event.key === "Enter") void renameFolder(); }}/></div>{renameError ? <p className="form-error" role="alert">{renameError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={renaming} onClick={() => { setRenameOpen(false); setRenameName(""); setRenameError(""); }}>Cancel</button><button className="primary" disabled={renaming || !renameName.trim() || renameName.trim() === selectedFolder.name} onClick={() => void renameFolder()}>{renaming ? "Renaming…" : "Rename folder"}</button></div></section></div> : null}
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

// Replaces a native <select> (TOOLTIP-01's sibling problem): the open list of
// a <select> is drawn by the browser itself, and no CSS reaches its padding,
// radius, hover colour or font - see the By-ICP dropdown polish attempt this
// replaces. A button + role="listbox" popup, styled with the same .ds-menu
// primitives as the View/Actions menus, is the only way to make this control
// look like the rest of the product.
function IcpPicker({ clientName, icps, value, onChange }: { clientName: string; icps: Array<{ id: string; name: string }>; value: string; onChange: (next: string) => void }) {
  const [open, setOpen] = useState(false);
  const wrapper = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const listId = useId();

  const options = useMemo(() => [
    // Reselecting this clears the filter, the same as the native <select> this
    // replaces let you pick its own placeholder to reset.
    { value: "", label: "By ICP…" },
    ...icps.map((icp) => ({ value: icp.id, label: icp.name })),
    // Last and separated: it is the complement of everything above it, not
    // another ICP. Offered even with no ICPs defined, where it answers "all
    // of them" and says so in the panel.
    { value: unassignedIcp, label: icps.length ? "Unassigned" : "Unassigned (no ICPs yet)" },
  ], [icps]);
  const selectedLabel = options.find((option) => option.value === value)?.label ?? "By ICP…";

  const close = useCallback((returnFocus = true) => {
    setOpen((wasOpen) => {
      if (wasOpen && returnFocus) trigger.current?.focus();
      return false;
    });
  }, []);
  useDismiss(wrapper, () => close(), open);

  const focusFirst = useRef(false);
  useEffect(() => {
    if (!open || !focusFirst.current) return;
    focusFirst.current = false;
    panel.current?.querySelector<HTMLElement>('[role="option"]')?.focus();
  }, [open]);

  function onTriggerKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    focusFirst.current = true;
    setOpen(true);
  }

  function onPanelKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const stops = [...(panel.current?.querySelectorAll<HTMLElement>('[role="option"]') ?? [])];
    const at = stops.findIndex((node) => node === document.activeElement);
    const next = event.key === "ArrowDown" ? (at + 1) % stops.length : (at - 1 + stops.length) % stops.length;
    stops[next]?.focus();
  }

  return <div className={`client-icp-picker ds-menu ds-menu-end${value ? " is-active" : ""}`} ref={wrapper}>
    <button
      type="button"
      ref={trigger}
      className="client-icp-trigger"
      aria-haspopup="listbox"
      aria-expanded={open}
      aria-controls={open ? listId : undefined}
      aria-label={`Filter ${clientName} prospects by ICP, currently ${selectedLabel}`}
      onClick={() => setOpen((current) => !current)}
      onKeyDown={onTriggerKeyDown}
    >
      <AppIcon name="target" size={14}/>
      <span>{selectedLabel}</span>
      <AppIcon name="chevron" size={12}/>
    </button>
    {open ? <div
      id={listId}
      ref={panel}
      role="listbox"
      // Not itself a tab stop - the options are real, individually focusable
      // buttons (the same roving-focus-by-real-elements pattern MenuButton
      // uses for its role="group" panels), so the listbox container's own
      // tabIndex only needs to exist, never to be reached.
      tabIndex={-1}
      aria-label={`Filter ${clientName} prospects by ICP`}
      className="ds-menu-panel client-icp-panel"
      onKeyDown={onPanelKeyDown}
    >
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          role="option"
          aria-selected={option.value === value}
          className="ds-menu-item"
          onClick={() => { onChange(option.value); close(); }}
        >{option.label}</button>
      ))}
    </div> : null}
  </div>;
}

function ClientDetail({ client, clients, lists, onBack, onOpenList, onSelectProspect, onImport, onDeleteClient, onDeleteList, onRefreshClients, listPivot, onConsumeListPivot }:{ client: ClientRecord; clients: ClientRecord[]; lists: ListRecord[]; onBack: () => void; onOpenList: (list: ListRecord) => void; onSelectProspect: (prospect: Prospect) => void; onImport: () => void; onDeleteClient: () => void; onDeleteList: (list: ListRecord) => void; onRefreshClients: () => void; listPivot: { listId: string; listName: string; target: "prospects" | "companies" } | null; onConsumeListPivot: () => void }) {
  const [cooldown, setCooldown] = useState(client.cooldown_days ?? 90);
  const [savedCooldown, setSavedCooldown] = useState(client.cooldown_days ?? 90);
  const [cooldownState, setCooldownState] = useState("");
  const [tab, setTab] = useState<"lists" | "prospects" | "recent" | "by_icp" | "companies" | "incomplete" | "icp" | "blocklist">(() => listPivot?.target ?? "lists");
  const [listSearch, setListSearch] = useState("");
  const deferredListSearch = useDeferredValue(listSearch);
  const [searchedLists, setSearchedLists] = useState<ListRecord[]>([]);
  const [listSearchPage, setListSearchPage] = useState(1);
  const [listSearchTotal, setListSearchTotal] = useState(0);
  const [listSearchLoading, setListSearchLoading] = useState(false);
  const [listSearchError, setListSearchError] = useState("");
  const listSearchQuery = deferredListSearch.trim();
  const visibleLists = listSearchQuery ? searchedLists : lists;
  useEffect(() => {
    if (!listSearchQuery) return;
    const controller = new AbortController();
    void api<{ lists: ListRecord[]; total: number }>(`/api/lists?clientId=${encodeURIComponent(client.id)}&q=${encodeURIComponent(listSearchQuery)}&page=${listSearchPage}`, { cache: "no-store", signal: controller.signal })
      .then((data) => { setSearchedLists(data.lists ?? []); setListSearchTotal(data.total ?? 0); })
      .catch((caught) => { if (!isAbortError(caught)) setListSearchError(caught instanceof Error ? caught.message : "Unable to search lists."); })
      .finally(() => { if (!controller.signal.aborted) setListSearchLoading(false); });
    return () => controller.abort();
  }, [client.id, listSearchPage, listSearchQuery]);
  const [companyPeopleScope, setCompanyPeopleScope] = useState<CompanyScope | null>(null);
  // Seeded once from a "See Companies" pivot out of the List workspace, using
  // the exact mechanism a People→Company pivot inside this workspace already
  // uses - a list is just another people-side scope (__list_ids), so nothing
  // downstream needs to know this scope came from a list rather than a search.
  const [peopleCompanyScope, setPeopleCompanyScope] = useState<PeopleScope | null>(() =>
    listPivot?.target === "companies"
      ? { search: "", filters: [{ field: "__list_ids", operator: "contains", values: [listPivot.listId] }], limit: 250000 }
      : null);
  // Captured the same way, for the same reason: the "prospects" TabPanel below
  // used to read `listPivot` directly for both its key and initialFilters, but
  // the one-shot useEffect a few lines down clears listPivot back to null right
  // after this mount, which changed that key on the very next render and
  // silently remounted ClientMasterDatabase with initialFilters=[] - the list
  // filter vanished a tick after it appeared. Reading it from captured state
  // instead means it survives listPivot resetting to null.
  const [peopleListPivot] = useState<{ listId: string; filters: ProspectFilter[] } | null>(() =>
    listPivot?.target === "prospects"
      ? { listId: listPivot.listId, filters: [{ id: `__list_ids:${listPivot.listId}`, field: "__list_ids", operator: "contains", values: [listPivot.listId] }] }
      : null);
  // A pivot is consumed exactly once, right after the mount that reads it into
  // the state above - otherwise a later ordinary remount of this same
  // component (switching clients and back, without going through ListsPanel)
  // could silently reopen a stale pivot. Deliberately not reactive to later
  // changes in listPivot or onConsumeListPivot's identity: this only ever
  // means to consume the one value the state initializers above already read.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (listPivot) onConsumeListPivot(); }, []);
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
  return <><button className="back" onClick={onBack}><AppIcon name="back" size={14}/> All clients</button><div className="client-hero client-hero-compact"><span className="client-logo tone-0">{initials(client.name)}</span><div className="client-hero-identity"><p className="eyebrow">CLIENT WORKSPACE</p><h2>{client.name}</h2><p>{formatNumber(client.prospect_count)} people · {formatNumber(client.company_count ?? 0)} companies · {formatNumber(client.list_count)} lists{client.icp_verified_count !== undefined ? <> · <strong className="icp-count">{formatNumber(client.icp_verified_count)} ICP verified</strong></> : null}</p></div><div className="client-actions"><button className="primary" onClick={onImport}><AppIcon name="plus" size={14}/> Import list</button><details className="client-settings"><summary>Settings</summary><div className="client-settings-panel"><div className="cooldown-setting"><label htmlFor="cooldown-days">Contact cooldown</label><div><input id="cooldown-days" type="number" min="0" max="730" value={cooldown} onChange={(event) => setCooldown(Number(event.target.value))}/><span>days</span><button onClick={() => void saveCooldown()}>Save</button></div><small role="status">{cooldownState || "Used when checking reuse eligibility"}</small></div><button className="danger-button" onClick={onDeleteClient}>Delete client</button></div></details></div></div>
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
        { id: "recent" as const, label: "Recently Added", icon: <AppIcon name="calendar" size={15}/> },
        { id: "companies" as const, label: "Company DB", count: formatNumber(client.company_count ?? 0), icon: <AppIcon name="company" size={15}/> },
        { id: "incomplete" as const, label: "Incomplete Info", icon: <AppIcon name="quality" size={15}/> },
        { id: "icp" as const, label: "ICPs", icon: <AppIcon name="target" size={15}/> },
        { id: "blocklist" as const, label: "Blocklist", count: client.blocked_count ? formatNumber(client.blocked_count) : undefined, icon: <AppIcon name="quality" size={15}/> },
      ]}
    />
      <IcpPicker
        clientName={client.name}
        icps={icps}
        value={tab === "by_icp" ? icpChoice : ""}
        onChange={(next) => {
          setIcpChoice(next);
          if (next) setTab("by_icp");
        }}
      />
    </div>
    <TabPanel id="lists" active={tab === "lists"} keepMounted className="client-tab-panel"><article className="panel table-panel"><div className="panel-head"><div><h3>Uploaded lists</h3><p>Open a list to inspect its records.</p></div><label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search uploaded list names" value={listSearch} onChange={(event) => { const value = event.target.value; setListSearch(value); setListSearchPage(1); setListSearchLoading(Boolean(value.trim())); setListSearchError(""); }} placeholder="Search list names…"/></label></div>{listSearchQuery && listSearchError ? <div className="inline-error" role="alert">{listSearchError}</div> : null}{listSearchQuery && listSearchLoading ? <p className="muted-copy" role="status">Searching lists…</p> : visibleLists.length ? <><div className="table-wrap uploaded-list-table"><table><thead><tr><th>List and source</th><th>Rows</th><th>Import results</th><th>Imported</th><th>Actions</th></tr></thead><tbody>{visibleLists.map((list) => <tr key={list.id}><td><button className="list-open-button" onClick={() => onOpenList(list)} title={`${list.name}${list.source_file_name ? ` · ${list.source_file_name}` : ""}`}><strong>{list.name}</strong><span>{list.data_source}{distinctSourceFile(list) ? ` · ${distinctSourceFile(list)}` : ""}</span></button></td><td>{formatNumber(list.uploaded_rows)}</td><td><div className="list-result-metrics"><span>{formatNumber(list.field_count)} fields</span><span className="data-pill green">+{formatNumber(list.unique_added)} new</span><span>{formatNumber(list.duplicates_linked)} linked duplicates</span></div></td><td>{new Date(list.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><button className="row-danger" onClick={() => onDeleteList(list)}>Delete</button></td></tr>)}</tbody></table></div>{listSearchQuery && listSearchTotal > 50 ? <div className="pagination"><button disabled={listSearchPage <= 1} onClick={() => { setListSearchLoading(true); setListSearchPage((page) => Math.max(1, page - 1)); }}>Previous</button><span>Page {listSearchPage} of {Math.ceil(listSearchTotal / 50)}</span><button disabled={listSearchPage * 50 >= listSearchTotal} onClick={() => { setListSearchLoading(true); setListSearchPage((page) => page + 1); }}>Next</button></div> : null}</> : <EmptyCompact text={listSearchQuery ? `No list matches “${listSearch}”.` : "No lists have been imported for this client."} action={listSearchQuery ? undefined : "Import list"} onAction={listSearchQuery ? undefined : onImport} />}</article></TabPanel>
    <TabPanel id="prospects" active={tab === "prospects"} keepMounted className="client-tab-panel"><ClientMasterDatabase key={`people:${client.prospect_count}:${client.blocked_count ?? 0}:${peopleListPivot?.listId ?? ""}`} client={{ ...client, cooldown_days: savedCooldown }} clients={clients.map((item) => item.id === client.id ? { ...item, cooldown_days: savedCooldown } : item)} active={tab === "prospects"} initialFilters={peopleListPivot?.filters ?? []} companyScope={companyPeopleScope} onClearCompanyScope={() => setCompanyPeopleScope(null)} onSeeCompanies={(scope) => { if (companyPeopleScope) { setCompanyPeopleScope(null); setPeopleCompanyScope(null); } else setPeopleCompanyScope(scope); setTab("companies"); }} onSelect={onSelectProspect} onImport={onImport}/></TabPanel>
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
    <TabPanel id="companies" active={tab === "companies"} keepMounted className="client-tab-panel"><ClientCompanyDatabase key={`companies:${client.prospect_count}:${client.blocked_count ?? 0}`} client={client} clients={clients} peopleScope={peopleCompanyScope} onClearPeopleScope={() => setPeopleCompanyScope(null)} onSelectListScope={(listId) => setPeopleCompanyScope(listId ? { search: "", filters: [{ field: "__list_ids", operator: "contains", values: [listId] }], limit: 250000 } : null)} onSeePeople={(scope) => { if (peopleCompanyScope) { setPeopleCompanyScope(null); setCompanyPeopleScope(null); } else setCompanyPeopleScope(scope); setTab("prospects"); }} onImport={onImport}/></TabPanel>
    <TabPanel id="incomplete" active={tab === "incomplete"} keepMounted className="client-tab-panel">{tab === "incomplete" ? <IncompleteInfoPanel client={client} clients={clients} onSelect={onSelectProspect} onImport={onImport}/> : null}</TabPanel>
    {/* Its own fetch against a narrow time window, so it is mounted only while
        open rather than on every client screen. */}
    <TabPanel id="recent" active={tab === "recent"} keepMounted className="client-tab-panel">{tab === "recent" ? <RecentlyAddedPanel client={client} onChanged={onRefreshClients}/> : null}</TabPanel>
    {/* Mounted only while open, like the blocklist: the ICP list is its own
        fetch and there is no reason to pay for it on every client screen. */}
    <TabPanel id="icp" active={tab === "icp"} keepMounted className="client-tab-panel">{tab === "icp" ? <ClientIcpPanel client={client}/> : null}</TabPanel>
    <TabPanel id="blocklist" active={tab === "blocklist"} keepMounted className="client-tab-panel">{tab === "blocklist" ? <BlocklistPanel client={client} onChanged={onRefreshClients}/> : null}</TabPanel>
  </>;
}

const incompleteCompanyFilters: ProspectFilter[] = [
  { id: "incomplete:keywords", field: "__keywords", operator: "empty", values: [] },
  { id: "incomplete:description", field: "__short_description", operator: "empty", values: [] },
];
const incompletePeopleFilters: ProspectFilter[] = [
  { id: "incomplete:company-profile", field: "__incomplete_company_profile", operator: "equals", values: ["true"] },
];

function IncompleteInfoPanel({ client, clients, onSelect, onImport }: { client: ClientRecord; clients: ClientRecord[]; onSelect: (prospect: Prospect) => void; onImport: () => void }) {
  const [entity, setEntity] = useState<"people" | "companies">("companies");
  return <section className="incomplete-info-panel">
    <p className="incomplete-scope">Companies missing both keywords and a short description. Linked people appear in the People view.</p>
    <div className="icp-quick-filters" role="group" aria-label="Choose incomplete information record type"><button className={entity === "companies" ? "active" : ""} aria-pressed={entity === "companies"} onClick={() => setEntity("companies")}>Companies</button><button className={entity === "people" ? "active" : ""} aria-pressed={entity === "people"} onClick={() => setEntity("people")}>People</button></div>
    {entity === "people" ? <ClientMasterDatabase client={client} clients={clients} active companyScope={null} onClearCompanyScope={() => {}} onSeeCompanies={() => {}} onSelect={onSelect} onImport={onImport} initialFilters={incompletePeopleFilters} forcedFilters={incompletePeopleFilters} allowEntityPivot={false}/> : <ClientCompanyDatabase client={client} clients={clients} peopleScope={null} onClearPeopleScope={() => {}} onSelectListScope={() => {}} onSeePeople={() => {}} onImport={onImport} initialFilters={incompleteCompanyFilters} forcedFilters={incompleteCompanyFilters} allowEntityPivot={false}/>}
  </section>;
}

function ClientMasterDatabase({ client, clients, active, companyScope, onClearCompanyScope, onSeeCompanies, onSelect, onImport, initialFilters = [], forcedFilters = [], allowEntityPivot = true, lockedCompanyScope = false }: { client: ClientRecord; clients: ClientRecord[]; active: boolean; companyScope: CompanyScope | null; onClearCompanyScope: () => void; onSeeCompanies: (scope: PeopleScope) => void; onSelect: (prospect: Prospect) => void; onImport: () => void; initialFilters?: ProspectFilter[]; forcedFilters?: ProspectFilter[]; allowEntityPivot?: boolean; lockedCompanyScope?: boolean }) {
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
  const enforceForcedFilters = useCallback((next: ProspectFilter[]) => forcedFilters.length
    ? [...next.filter((candidate) => !forcedFilters.some((forced) => forced.field === candidate.field)), ...forcedFilters]
    : next, [forcedFilters]);
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
  return <><SearchPreparation progress={preparation} error={preparationError} onRetry={() => setRefresh(value => value + 1)} onClear={onClearCompanyScope} clearLabel="Clear company scope"/><section hidden={Boolean(preparation || preparationError)} className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT MASTER DB</p><h3>{client.name} prospects</h3><p>Every master prospect connected to this client, across all uploaded lists.</p></div>{allowEntityPivot ? <button className="secondary" title="Safely scope up to 250,000 matching people" onClick={() => onSeeCompanies({ search: deferredSearch.trim(), filters: filterPayload(filters), limit: 250000 })}>See Companies <AppIcon name="arrow" size={14}/></button> : null}<label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label={`Search ${client.name} prospects`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this client database…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client prospects…</div> : null}{loading ? <div className="workspace-loading">Preparing client database…</div> : <ProspectTable prospects={prospects} total={total} totalCapped={totalCapped} fields={fields} filters={filters} page={page} clients={clients} search={deferredSearch} sort={sort} direction={direction} clientId={client.id} companyScope={companyScope} onClearCompanyScope={onClearCompanyScope} onSeeCompanies={onSeeCompanies} onRemoveFromClient={removeFromClient} onSortChange={(nextSort, nextDirection) => { setSort(nextSort); setDirection(nextDirection); setPage(1); }} onFiltersChange={(next) => { setFilters(enforceForcedFilters(next)); setPage(1); }} onPageChange={setPage} onSelect={onSelect} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)} active={active} allowEntityPivot={allowEntityPivot} lockedCompanyScope={lockedCompanyScope}/>}{pendingRemoval ? <ConfirmDialog title={`Remove ${pendingRemoval.full_name || "this prospect"} from ${client.name}?`} body="This removes the link between this prospect and this client, along with its list membership for this client." scopeNote="The People database record is preserved. Every other client keeps its own link to this person." confirmLabel="Remove from client" busy={removing} onCancel={() => setPendingRemoval(null)} onConfirm={() => void confirmRemoval()} /> : null}</section></>;
}

function ClientCompanyDatabase({ client, clients, peopleScope, onClearPeopleScope, onSelectListScope, onSeePeople, onImport, initialFilters = [], forcedFilters = [], allowEntityPivot = true }: { client: ClientRecord; clients: ClientRecord[]; peopleScope: PeopleScope | null; onClearPeopleScope: () => void; onSelectListScope: (listId: string) => void; onSeePeople: (scope: CompanyScope) => void; onImport: () => void; initialFilters?: ProspectFilter[]; forcedFilters?: ProspectFilter[]; allowEntityPivot?: boolean }) {
  const [companies, setCompanies] = useState<Company[]>([]);
  const [summary, setSummary] = useState({ total: 0, covered: 0, prospectTotal: 0, pageSize: 50 });
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [filters, setFilters] = useState<ProspectFilter[]>(initialFilters);
  const enforceForcedFilters = useCallback((next: ProspectFilter[]) => forcedFilters.length
    ? [...next.filter((candidate) => !forcedFilters.some((forced) => forced.field === candidate.field)), ...forcedFilters]
    : next, [forcedFilters]);
  const [refresh, setRefresh] = useState(0);
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  const encodedFilters = useMemo(() => encodeFilters(filters), [filters]);
  const lists = useClientLists(client.id);
  // The dropdown reflects an active scope only when it is exactly one
  // __list_ids value - a peopleScope built by search or by a People DB pivot
  // is real and current, but is not one of these options and should not make
  // the picker claim a list that is not actually selected.
  const selectedListScope = !peopleScope?.search && peopleScope?.filters.length === 1 && peopleScope.filters[0].field === "__list_ids" && peopleScope.filters[0].values.length === 1
    ? peopleScope.filters[0].values[0] : "";
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
  return <section className="client-database-workspace" aria-busy={refreshing}><div className="client-database-heading"><div><p className="eyebrow">CLIENT COMPANY DB</p><h3>{client.name} companies</h3><p>Companies pushed to this client or represented by its prospects.</p></div>{allowEntityPivot ? <button className="secondary" title="Safely scope up to 250,000 matching companies" onClick={() => onSeePeople({ search: deferredSearch.trim(), filters, limit: 250000 })}>See People <AppIcon name="arrow" size={14}/></button> : null}{allowEntityPivot && lists.length ? <select aria-label="Filter companies by list" title="Show only companies represented by one uploaded list" value={selectedListScope} onChange={(event) => { onSelectListScope(event.target.value); setPage(1); }}><option value="">Filter by list…</option>{lists.map((list) => <option key={list.id} value={list.id}>{list.name}</option>)}</select> : null}<label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label={`Search ${client.name} companies`} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search client companies…"/></label></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{refreshing && !loading ? <div className="workspace-progress compact" role="status"><span/>Updating client companies…</div> : null}{loading ? <div className="workspace-loading">Preparing company database…</div> : <CompanyTable companies={companies} clients={clients} total={summary.total} covered={summary.covered} prospectTotal={summary.prospectTotal} page={page} pageSize={summary.pageSize} clientId={client.id} search={deferredSearch} filters={filters} peopleScope={peopleScope} onClearPeopleScope={onClearPeopleScope} onSeePeople={onSeePeople} onFilters={(next) => { setFilters(enforceForcedFilters(next)); setPage(1); }} onPageChange={setPage} onImport={onImport} onRefresh={() => setRefresh((value) => value + 1)} allowEntityPivot={allowEntityPivot}/>}</section>;
}
