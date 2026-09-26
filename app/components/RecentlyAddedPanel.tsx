"use client";

import { useDeferredValue, useEffect, useState } from "react";
import { api, isAbortError } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { ClientAdditionBatch, ClientRecord } from "../../lib/types";
import { AppIcon, EmptyCompact } from "./DashboardUi";
import { useDebouncedValue } from "./useDebouncedValue";

function sourceGroup(batch: ClientAdditionBatch) {
  if (batch.source_kind === "import") return { key: "import", label: "Import" };
  if (batch.source_kind === "client") return { key: "client", label: "Pushed from Client DB" };
  return { key: "master", label: "Pushed from Master DB" };
}

function sourceDetail(batch: ClientAdditionBatch) {
  if (batch.source_kind === "import") return batch.source_label || "Imported file";
  if (batch.source_kind === "client") return batch.source_client_name || batch.source_label || "Client DB";
  return "Master DB";
}

type BatchRecord = {
  record_id: string;
  display_name: string | null;
  secondary_text: string | null;
  added_at: string;
};

export default function RecentlyAddedPanel({ client }: { client: ClientRecord; onChanged: () => void }) {
  const [entity, setEntity] = useState<"" | "people" | "companies">("");
  const [windowKey, setWindowKey] = useState<"24h" | "7d" | "30d" | "all">("30d");
  const [search, setSearch] = useState("");
  const deferredSearch = useDeferredValue(search);
  const debouncedSearch = useDebouncedValue(deferredSearch, 300);
  const [batches, setBatches] = useState<ClientAdditionBatch[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(50);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState<string | null>(null);
  const [records, setRecords] = useState<BatchRecord[]>([]);
  const [recordTotal, setRecordTotal] = useState(0);
  const [recordPage, setRecordPage] = useState(1);
  const [recordsLoading, setRecordsLoading] = useState(false);
  const [recordsError, setRecordsError] = useState("");
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const batchGroups = batches.reduce<Array<{ key: string; label: string; batches: ClientAdditionBatch[] }>>((groups, batch) => {
    const source = sourceGroup(batch);
    const existing = groups.find((group) => group.key === source.key);
    if (existing) existing.batches.push(batch);
    else groups.push({ ...source, batches: [batch] });
    return groups;
  }, []);

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    const params = new URLSearchParams({ page: String(page) });
    params.set("window", windowKey);
    if (entity) params.set("entity", entity);
    if (debouncedSearch.trim()) params.set("search", debouncedSearch.trim());
    void Promise.resolve().then(() => { if (current) setLoading(true); });
    void api<{ batches: ClientAdditionBatch[]; total: number; pageSize: number }>(
      `/api/clients/${encodeURIComponent(client.id)}/recent?${params}`,
      { signal: controller.signal, cache: "no-store" },
    ).then((data) => {
      if (!current) return;
      setBatches(data.batches ?? []); setTotal(data.total ?? 0); setPageSize(data.pageSize || 50); setError("");
    }).catch((caught) => {
      if (current && !isAbortError(caught)) setError(caught instanceof Error ? caught.message : "Unable to load recent batches.");
    }).finally(() => { if (current) setLoading(false); });
    return () => { current = false; controller.abort(); };
  }, [client.id, debouncedSearch, entity, page, windowKey]);

  useEffect(() => {
    if (!expanded) return;
    let current = true;
    const controller = new AbortController();
    void api<{ records: BatchRecord[]; total: number }>(
      `/api/clients/${encodeURIComponent(client.id)}/recent?batchId=${encodeURIComponent(expanded)}&page=${recordPage}`,
      { signal: controller.signal, cache: "no-store" },
    ).then((data) => {
      if (!current) return;
      setRecords(data.records ?? []); setRecordTotal(data.total ?? 0); setRecordsError("");
    }).catch((caught) => {
      if (current && !isAbortError(caught)) setRecordsError(caught instanceof Error ? caught.message : "Unable to load batch records.");
    }).finally(() => { if (current) setRecordsLoading(false); });
    return () => { current = false; controller.abort(); };
  }, [client.id, expanded, recordPage]);

  return <section className="recently-added">
    <div className="client-database-heading">
      <div><p className="eyebrow">RECENTLY ADDED</p><h3>Batches added to {client.name}</h3><p>Each import or push is kept together with its source and time.</p></div>
      <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search recently added records or sources" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search records, files or sources…"/></label>
    </div>
    <div className="recent-filter-bar"><div className="icp-quick-filters" role="group" aria-label="Filter recent batches by record type">
      {([{"id":"","label":"All"},{"id":"people","label":"People"},{"id":"companies","label":"Companies"}] as const).map((option) => <button key={option.id} className={entity === option.id ? "active" : ""} aria-pressed={entity === option.id} onClick={() => { setEntity(option.id); setPage(1); }}>{option.label}</button>)}
    </div>
    <div className="icp-quick-filters" role="group" aria-label="Filter recent batches by time">
      {([{"id":"24h","label":"24 hours"},{"id":"7d","label":"7 days"},{"id":"30d","label":"30 days"},{"id":"all","label":"All time"}] as const).map((option) => <button key={option.id} className={windowKey === option.id ? "active" : ""} aria-pressed={windowKey === option.id} onClick={() => { setWindowKey(option.id); setPage(1); setExpanded(null); }}>{option.label}</button>)}
    </div></div>
    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    <article className="panel table-panel">
      {loading ? <div className="workspace-loading">Loading recent batches…</div> : batches.length ? <div className="table-wrap"><table>
        <thead><tr><th>Source</th><th>Type</th><th>Records</th><th>Added</th><th>Action</th></tr></thead>
        {batchGroups.map((group) => <tbody key={group.key}>
        <tr className="recent-source-group"><th colSpan={5} scope="rowgroup">{group.label}</th></tr>
        {group.batches.map((batch) => <tr key={batch.id}>
          <td>{sourceDetail(batch)}</td>
          <td><span className="data-source-badge">{batch.entity_type === "people" ? "People" : "Companies"}</span></td>
          <td>{formatNumber(Number(batch.record_count ?? 0))}</td>
          <td><time dateTime={batch.created_at}>{new Date(batch.created_at).toLocaleString("en-IN", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" })}</time></td>
          <td><button className="outline-button" aria-expanded={expanded === batch.id} onClick={() => { const opening = expanded !== batch.id; setExpanded(opening ? batch.id : null); setRecordPage(1); setRecordsLoading(opening); if (!opening) { setRecords([]); setRecordTotal(0); setRecordsError(""); } }}>{expanded === batch.id ? "Hide records" : "View records"}</button></td>
        </tr>)}</tbody>)}
      </table></div> : <EmptyCompact text={search ? `No recent batch contains “${search}”.` : "No import or push batches have been recorded for this client yet."}/>}
      {totalPages > 1 ? <div className="company-pagination"><span>Page {page} of {totalPages} · {formatNumber(total)} batches</span><div><button disabled={loading || page <= 1} onClick={() => setPage((value) => value - 1)}><AppIcon name="back" size={14}/> Previous</button><button disabled={loading || page >= totalPages} onClick={() => setPage((value) => value + 1)}>Next</button></div></div> : null}
    </article>
    {expanded ? <article className="panel table-panel">
      <div className="panel-head"><div><h3>Batch records</h3><p>Records captured when this batch was added.</p></div><button className="secondary" onClick={() => setExpanded(null)}>Close</button></div>
      {recordsError ? <div className="inline-error" role="alert">{recordsError}</div> : null}
      {recordsLoading ? <div className="workspace-loading">Loading batch records…</div> : records.length ? <div className="table-wrap"><table><thead><tr><th>Record</th><th>Company / domain</th><th>Added</th></tr></thead><tbody>{records.map((record) => <tr key={record.record_id}><td><strong>{record.display_name || "Unnamed record"}</strong></td><td>{record.secondary_text || "—"}</td><td><time dateTime={record.added_at}>{new Date(record.added_at).toLocaleString("en-IN", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" })}</time></td></tr>)}</tbody></table></div> : <EmptyCompact text="No records were captured for this batch."/>}
      {recordTotal > pageSize ? <div className="company-pagination"><span>Page {recordPage} of {Math.max(1, Math.ceil(recordTotal / pageSize))} · {formatNumber(recordTotal)} records</span><div><button disabled={recordsLoading || recordPage <= 1} onClick={() => setRecordPage((value) => value - 1)}><AppIcon name="back" size={14}/> Previous</button><button disabled={recordsLoading || recordPage >= Math.ceil(recordTotal / pageSize)} onClick={() => setRecordPage((value) => value + 1)}>Next</button></div></div> : null}
    </article> : null}
  </section>;
}
