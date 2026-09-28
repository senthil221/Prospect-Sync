"use client";

import { useDeferredValue, useEffect, useState } from "react";
import { api, isAbortError } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { ClientAdditionBatch, ClientRecord } from "../../lib/types";
import { AppIcon, EmptyCompact } from "./DashboardUi";
import { useDebouncedValue } from "./useDebouncedValue";

function sourceLabel(batch: ClientAdditionBatch) {
  if (batch.outcome_kind === "historical_source_unavailable") return "Source unavailable";
  if (batch.source_kind === "import") return "Import";
  if (batch.source_kind === "client") return "Pushed from Client DB";
  return "Pushed from Master DB";
}

function sourceDetail(batch: ClientAdditionBatch) {
  if (batch.outcome_kind === "historical_source_unavailable") return "Original source was not recorded";
  if (batch.source_kind === "import") return batch.source_label || "Imported file";
  if (batch.source_kind === "client") return batch.source_client_name || batch.source_label || "Client DB";
  return "Master DB";
}

type SourceFilter = "all" | "import" | "master" | "client";

type BatchRecord = {
  record_id: string;
  display_name: string | null;
  secondary_text: string | null;
  added_at: string;
};

export default function RecentlyAddedPanel({ client }: { client: ClientRecord; onChanged: () => void }) {
  const [entity, setEntity] = useState<"" | "people" | "companies">("");
  const [source, setSource] = useState<SourceFilter>("all");
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

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    const params = new URLSearchParams({ page: String(page) });
    params.set("source", source);
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
  }, [client.id, debouncedSearch, entity, page, source]);

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
      <div><p className="eyebrow">RECENTLY ADDED</p><h3>Latest additions to {client.name}</h3><p>Activity from the past 48 hours, kept together by import or push source.</p></div>
      <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search recently added records or sources" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); setExpanded(null); }} placeholder="Search records, files or sources…"/></label>
    </div>
    <div className="recent-filter-bar"><div className="icp-quick-filters recent-source-tabs" role="group" aria-label="Filter recent batches by source">
      {([{"id":"all","label":"All sources"},{"id":"import","label":"Import"},{"id":"master","label":"Pushed from Master DB"},{"id":"client","label":"Pushed from Client DB"}] as const).map((option) => <button key={option.id} className={source === option.id ? "active" : ""} aria-pressed={source === option.id} onClick={() => { setSource(option.id); setPage(1); setExpanded(null); }}>{option.label}</button>)}
    </div>
    <div className="icp-quick-filters recent-entity-filters" role="group" aria-label="Filter recent batches by record type">
      {([{"id":"","label":"All records"},{"id":"people","label":"People"},{"id":"companies","label":"Companies"}] as const).map((option) => <button key={option.id} className={entity === option.id ? "active" : ""} aria-pressed={entity === option.id} onClick={() => { setEntity(option.id); setPage(1); setExpanded(null); }}>{option.label}</button>)}
    </div></div>
    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    <article className="panel table-panel">
      {loading ? <div className="workspace-loading">Loading recent batches…</div> : batches.length ? <div className="table-wrap"><table>
        <thead><tr><th>Source</th><th>Type</th><th>Records</th><th>Added</th><th>Action</th></tr></thead>
        <tbody>{batches.map((batch) => <tr key={batch.id}>
          <td className="recent-source-cell"><strong>{sourceLabel(batch)}</strong><small>{sourceDetail(batch)}</small></td>
          <td><span className="data-source-badge">{batch.entity_type === "people" ? "People" : "Companies"}</span></td>
          <td>{formatNumber(Number(batch.record_count ?? 0))}</td>
          <td><time dateTime={batch.created_at}>{new Date(batch.created_at).toLocaleString("en-IN", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" })}</time></td>
          <td><button className="outline-button" aria-expanded={expanded === batch.id} onClick={() => { const opening = expanded !== batch.id; setExpanded(opening ? batch.id : null); setRecordPage(1); setRecordsLoading(opening); if (!opening) { setRecords([]); setRecordTotal(0); setRecordsError(""); } }}>{expanded === batch.id ? "Hide records" : "View records"}</button></td>
        </tr>)}</tbody>
      </table></div> : <EmptyCompact text={search
        ? `No addition in the past 48 hours contains “${search}”.`
        : "No additions from this source in the past 48 hours."}/>}
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
