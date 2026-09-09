"use client";

import { Fragment, useCallback, useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { LogEntry, LogLevel } from "../../lib/types";
import { AppIcon, LoadingState, StatusMessage } from "./DashboardUi";

const pageSize = 50;
const levelLabel: Record<LogLevel, string> = { error: "Error", warn: "Warning", info: "Info" };

function formatTime(value: string) {
  return new Date(value).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });
}

/**
 * ADMIN-LOG-01: a readable window onto lib/observability.ts's failure signal
 * (over-cap, overloaded, timed-out and server-error request outcomes) plus
 * readiness-check and background-import failures, all persisted to
 * public.system_event_log by lib/server-log.ts. Everything here was already
 * being decided server-side (which outcomes count as a failure worth a line)
 * - this panel does not re-classify anything, it only renders the rows.
 */
export default function LogsPanel() {
  const [entries, setEntries] = useState<LogEntry[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [level, setLevel] = useState("");
  const [source, setSource] = useState("");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [expanded, setExpanded] = useState<number | null>(null);

  const load = useCallback(async () => {
    setLoading(true); setError("");
    try {
      const params = new URLSearchParams({ page: String(page) });
      if (level) params.set("level", level);
      if (source) params.set("source", source);
      if (search) params.set("search", search);
      const data = await api<{ entries: LogEntry[]; total: number }>(`/api/admin/logs?${params.toString()}`, { cache: "no-store" });
      setEntries(data.entries); setTotal(data.total);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to load logs.");
    } finally { setLoading(false); }
  }, [page, level, source, search]);

  useEffect(() => { const timer = window.setTimeout(() => { void load(); }, 0); return () => window.clearTimeout(timer); }, [load]);

  const totalPages = Math.max(1, Math.ceil(total / pageSize));

  return <section className="operations-page logs-page">
    <div className="section-intro compact-intro"><div>
      <p className="eyebrow">DIAGNOSE FAILURES</p>
      <h2>Server logs</h2>
      <p>Refused requests, timeouts and background job failures, kept for 30 days so you can tell why something broke after the fact.</p>
    </div><button className="secondary" onClick={() => void load()}><AppIcon name="refresh" size={14}/> Refresh</button></div>

    <article className="panel logs-toolbar-panel">
      <div className="logs-toolbar">
        <label>Level
          <select value={level} onChange={(event) => { setLevel(event.target.value); setPage(1); }}>
            <option value="">All</option>
            <option value="error">Error</option>
            <option value="warn">Warning</option>
            <option value="info">Info</option>
          </select>
        </label>
        <label>Source
          <input value={source} onChange={(event) => { setSource(event.target.value); setPage(1); }} placeholder="api, health, imports…"/>
        </label>
        <label>Search message
          <input value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search…"/>
        </label>
      </div>
    </article>

    {error ? <StatusMessage tone="alert">{error}</StatusMessage> : null}

    <article className="panel">
      <div className="panel-head">
        <div><h3>{formatNumber(total)} logged events</h3><p>Newest first · page {page} of {formatNumber(totalPages)}</p></div>
      </div>
      {loading ? <LoadingState label="Loading logs"/> : entries.length === 0 ? <StatusMessage>No log entries match these filters.</StatusMessage> : <div className="table-wrap logs-table">
        <table>
          <thead><tr><th>Time</th><th>Level</th><th>Source</th><th>Route</th><th>Status</th><th>Duration</th><th>Message</th></tr></thead>
          <tbody>{entries.map((entry) => <Fragment key={entry.id}>
            <tr className="logs-row" onClick={() => setExpanded(expanded === entry.id ? null : entry.id)}>
              <td>{formatTime(entry.created_at)}</td>
              <td><span className={`log-level ${entry.level}`}>{levelLabel[entry.level]}</span></td>
              <td>{entry.source}</td>
              <td>{entry.route ?? "-"}</td>
              <td>{entry.status_code ?? "-"}</td>
              <td>{entry.duration_ms != null ? `${formatNumber(entry.duration_ms)} ms` : "-"}</td>
              <td className="logs-message">{entry.message}</td>
            </tr>
            {expanded === entry.id ? <tr className="logs-detail-row"><td colSpan={7}>
              <dl className="logs-detail">
                {entry.request_id ? <><dt>Request ID</dt><dd>{entry.request_id}</dd></> : null}
                <dt>Detail</dt><dd><pre>{JSON.stringify(entry.detail, null, 2)}</pre></dd>
              </dl>
            </td></tr> : null}
          </Fragment>)}</tbody>
        </table>
      </div>}
      <div className="table-footer">
        <span>Showing {entries.length ? (page - 1) * pageSize + 1 : 0} to {(page - 1) * pageSize + entries.length} of {formatNumber(total)} events</span>
        <div>
          <button disabled={page <= 1} onClick={() => setPage((current) => current - 1)}><AppIcon name="back" size={14}/> Previous</button>
          <span>Page {page} of {formatNumber(totalPages)}</span>
          <button disabled={page >= totalPages} onClick={() => setPage((current) => current + 1)}>Next</button>
        </div>
      </div>
    </article>
  </section>;
}
