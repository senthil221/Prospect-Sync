"use client";

import { useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { ClientRecord } from "../../lib/types";
import { AppIcon, ConfirmDialog, EmptyCompact } from "./DashboardUi";

type RecentPerson = { id: string; full_name?: string | null; title?: string | null; work_email?: string | null; company_name?: string | null; added_at: string; added_via?: string | null };
type RecentCompany = { id: string; name?: string | null; domain?: string | null; prospect_count?: number | null; added_at: string };
type RecentRecord = RecentPerson & RecentCompany;

// 24 hours is the question as asked. The other two exist because imports arrive
// in batches rather than daily - on this database the newest membership row is
// routinely several days old, so a tab that could only answer "last 24 hours"
// would be empty most of the time it was opened.
const windowOptions = [
  { id: "24h", label: "Last 24 hours" },
  { id: "7d", label: "Last 7 days" },
  { id: "30d", label: "Last 30 days" },
];

function addedAgo(value: string) {
  const elapsed = Date.now() - new Date(value).getTime();
  const hours = Math.floor(elapsed / 3_600_000);
  if (hours < 1) return "under an hour ago";
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export default function RecentlyAddedPanel({ client, onChanged }: { client: ClientRecord; onChanged: () => void }) {
  const [entity, setEntity] = useState<"people" | "companies">("people");
  const [windowKey, setWindowKey] = useState("24h");
  const [records, setRecords] = useState<RecentRecord[]>([]);
  const [total, setTotal] = useState(0);
  const [pageSize, setPageSize] = useState(50);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [removeOpen, setRemoveOpen] = useState(false);
  const [removing, setRemoving] = useState(false);
  const [refresh, setRefresh] = useState(0);

  const people = entity === "people";
  const totalPages = Math.max(1, Math.ceil(total / pageSize));

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    void (async () => {
      setLoading(true);
      try {
        const data = await api<{ records: RecentRecord[]; total: number; pageSize: number }>(
          `/api/clients/${encodeURIComponent(client.id)}/recent?entity=${entity}&window=${windowKey}&page=${page}`,
          { signal: controller.signal, cache: "no-store" },
        );
        if (current) { setRecords(data.records ?? []); setTotal(data.total ?? 0); setPageSize(data.pageSize || 50); setError(""); }
      } catch (caught) {
        if (current && !(caught instanceof DOMException && caught.name === "AbortError")) {
          setError(caught instanceof Error ? caught.message : "Unable to load recently added records.");
        }
      } finally { if (current) setLoading(false); }
    })();
    return () => { current = false; controller.abort(); };
  }, [client.id, entity, windowKey, page, refresh]);

  function switchTo(nextEntity: "people" | "companies", nextWindow: string) {
    setEntity(nextEntity); setWindowKey(nextWindow);
    setSelected(new Set()); setPage(1); setNotice("");
  }

  function toggle(id: string) {
    setSelected((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; });
  }

  function togglePage() {
    const ids = records.map((record) => record.id);
    const allOn = ids.length > 0 && ids.every((id) => selected.has(id));
    setSelected((current) => { const next = new Set(current); ids.forEach((id) => allOn ? next.delete(id) : next.add(id)); return next; });
  }

  // Client-scoped, always. Both endpoints leave the master People and Company
  // databases untouched - this only unlinks the record from this client.
  async function removeSelected() {
    if (!selected.size) return;
    setRemoving(true); setError(""); setNotice("");
    const ids = [...selected];
    try {
      if (people) {
        const result = await api<{ result?: { removed?: number } }>(`/api/clients/${encodeURIComponent(client.id)}/prospects`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "remove", prospectIds: ids }),
        });
        setNotice(`Removed ${formatNumber(Number(result.result?.removed ?? ids.length))} ${ids.length === 1 ? "person" : "people"} from ${client.name}. The People database keeps every record.`);
      } else {
        const result = await api<{ result?: { removedCompanies?: number; removedPeople?: number } }>(`/api/clients/${encodeURIComponent(client.id)}/companies`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "remove", companyIds: ids }),
        });
        const companies = Number(result.result?.removedCompanies ?? ids.length);
        const removedPeople = Number(result.result?.removedPeople ?? 0);
        setNotice(`Removed ${formatNumber(companies)} compan${companies === 1 ? "y" : "ies"} and ${formatNumber(removedPeople)} of their ${removedPeople === 1 ? "person" : "people"} from ${client.name}. Both databases keep every record.`);
      }
      setSelected(new Set()); setRemoveOpen(false); setRefresh((value) => value + 1); onChanged();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to remove these records from the client.");
      setRemoveOpen(false);
    } finally { setRemoving(false); }
  }

  const windowLabel = windowOptions.find((option) => option.id === windowKey)?.label.toLowerCase() ?? "this window";

  return <section className="recently-added">
    <div className="client-database-heading">
      <div>
        <p className="eyebrow">RECENTLY ADDED</p>
        <h3>{people ? "People" : "Companies"} added to {client.name}</h3>
        <p>What the last imports and pushes actually put into this client. Removing here only unlinks from {client.name}.</p>
      </div>
    </div>

    <div className="company-quick-filter-row">
      <div className="icp-quick-filters" role="group" aria-label="Show people or companies">
        <button className={people ? "active" : ""} aria-pressed={people} onClick={() => switchTo("people", windowKey)}>People</button>
        <button className={!people ? "active" : ""} aria-pressed={!people} onClick={() => switchTo("companies", windowKey)}>Companies</button>
      </div>
      <div className="icp-quick-filters" role="group" aria-label="How far back to look">
        {windowOptions.map((option) => <button key={option.id} className={windowKey === option.id ? "active" : ""} aria-pressed={windowKey === option.id} onClick={() => switchTo(entity, option.id)}>{option.label}</button>)}
      </div>
    </div>

    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {notice ? <div className="inline-notice" role="status">{notice}<button aria-label="Dismiss" onClick={() => setNotice("")}><AppIcon name="close" size={14}/></button></div> : null}

    {selected.size ? <div className="bulk-bar">
      <div className="bulk-selection-summary"><strong>{formatNumber(selected.size)} selected</strong></div>
      <div className="bulk-action-group bulk-action-group-danger">
        <button className="row-danger" disabled={removing} onClick={() => setRemoveOpen(true)}>
          {people ? "Remove from client" : "Remove company + its people from client"}
        </button>
      </div>
      <button className="bulk-clear" disabled={removing} onClick={() => setSelected(new Set())}>Clear</button>
    </div> : null}

    {loading ? <div className="workspace-loading">Looking for recent additions…</div>
      : records.length ? <>
        <div className="table-wrap"><table className="company-table">
          <thead><tr>
            <th className="select-column"><input type="checkbox" aria-label="Select every record on this page" checked={records.length > 0 && records.every((record) => selected.has(record.id))} onChange={togglePage}/></th>
            <th>{people ? "Name" : "Company"}</th>
            <th>{people ? "Title" : "Website"}</th>
            <th>{people ? "Company" : "Prospects"}</th>
            <th>Added</th>
          </tr></thead>
          <tbody>{records.map((record) => <tr key={record.id}>
            <td className="select-column"><input type="checkbox" aria-label={`Select ${people ? record.full_name ?? "this person" : record.name ?? "this company"}`} checked={selected.has(record.id)} onChange={() => toggle(record.id)}/></td>
            <td>{people ? (record.full_name || "Unnamed") : (record.name || record.domain || "Unnamed company")}</td>
            <td>{people ? (record.title || "—") : (record.domain || "—")}</td>
            <td>{people ? (record.company_name || "—") : formatNumber(Number(record.prospect_count ?? 0))}</td>
            <td>{addedAgo(record.added_at)}</td>
          </tr>)}</tbody>
        </table></div>
        <div className="company-pagination">
          <span>Page {page} of {totalPages} · {formatNumber(total)} added in the {windowLabel}</span>
          <div>
            <button disabled={page <= 1} onClick={() => setPage(page - 1)}><AppIcon name="back" size={14}/> Previous</button>
            <button disabled={page >= totalPages} onClick={() => setPage(page + 1)}>Next</button>
          </div>
        </div>
      </> : <EmptyCompact text={`Nothing was added to ${client.name} in the ${windowLabel}. Try a longer window.`} />}

    {removeOpen ? <ConfirmDialog
      title={people
        ? `Remove ${formatNumber(selected.size)} ${selected.size === 1 ? "person" : "people"} from this client?`
        : `Remove ${formatNumber(selected.size)} compan${selected.size === 1 ? "y" : "ies"} and their people from this client?`}
      body={people
        ? "They stop being part of this client's lists and counts."
        : "This client's people at these companies are removed with them - a company cannot stay in a client without them."}
      scopeNote="Nothing is deleted. The People and Company databases keep every record, and other clients keep their own links."
      confirmLabel={removing ? "Removing…" : `Remove ${formatNumber(selected.size)}`}
      busy={removing}
      onCancel={() => setRemoveOpen(false)}
      onConfirm={() => void removeSelected()}
    /> : null}
  </section>;
}
