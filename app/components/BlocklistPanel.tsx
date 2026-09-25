"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { BLOCKLIST_REQUEST_VALUES, MAX_BLOCKLIST_PASTE_VALUES, partitionBlocklistValues } from "../../lib/bulk-values.ts";
import type { BlocklistEntry, ClientRecord } from "../../lib/types";
import { EmptyCompact } from "./DashboardUi";
import { AppIcon } from "./DashboardUi";

const blocklistReasons = ["Client Provided", "ICP Invalid", "Campaign Reply"] as const;
type BlocklistShare = { id: string; label: string; created_at: string; expires_at: string | null; revoked_at: string | null; last_submitted_at: string | null };

// The blocklist is per client. Matching memberships are retained internally for
// audit/restore, but disappear from the client's People and Company databases.
// Nothing here deletes the shared master People DB record.
export default function BlocklistPanel({ client, onChanged }: { client: ClientRecord; onChanged: () => void }) {
  const [entries, setEntries] = useState<BlocklistEntry[]>([]);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState("");
  const [text, setText] = useState("");
  const [reason, setReason] = useState("");
  const [bulkReason, setBulkReason] = useState<(typeof blocklistReasons)[number]>("Client Provided");
  const [kind, setKind] = useState("");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [allMatching, setAllMatching] = useState(false);
  const [selectedBefore, setSelectedBefore] = useState("");
  const [page, setPage] = useState(1);
  const [progress, setProgress] = useState<{ entries: number; total: number; records: number } | null>(null);
  const [shares, setShares] = useState<BlocklistShare[]>([]);
  const [shareQueue, setShareQueue] = useState({ pending: 0, failed: 0 });
  const [shareLabel, setShareLabel] = useState("Client blocklist form");
  const [shareUrl, setShareUrl] = useState("");

  const parsedPending = useMemo(() => partitionBlocklistValues(text), [text]);
  const pending = parsedPending.submitted;
  const validPending = parsedPending.domains.length + parsedPending.emails.length;
  const pasteTooLarge = pending > MAX_BLOCKLIST_PASTE_VALUES;
  const totalPages = Math.max(1, Math.ceil(total / 100));

  const load = useCallback(async (requestedPage = page) => {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (search.trim()) params.set("search", search.trim());
      if (kind) params.set("kind", kind);
      if (dateFrom) params.set("dateFrom", dateFrom);
      if (dateTo) params.set("dateTo", dateTo);
      params.set("page", String(requestedPage));
      const data = await api<{ entries: BlocklistEntry[]; total: number }>(
        `/api/clients/${encodeURIComponent(client.id)}/blocklist?${params}`);
      setEntries(data.entries); setTotal(data.total); setError("");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load the blocklist."); }
    finally { setLoading(false); }
  }, [client.id, page, search, kind, dateFrom, dateTo]);

  useEffect(() => {
    const timer = window.setTimeout(() => { void load(); }, search ? 300 : 0);
    return () => window.clearTimeout(timer);
  }, [load, search, kind, dateFrom, dateTo]);

  const loadShares = useCallback(async () => {
    try {
      const data = await api<{ shares: BlocklistShare[]; queue?: { pending: number; failed: number } }>(`/api/clients/${encodeURIComponent(client.id)}/blocklist-shares`);
      setShares(data.shares ?? []); setShareQueue(data.queue ?? { pending: 0, failed: 0 });
    } catch { setShares([]); setShareQueue({ pending: 0, failed: 0 }); }
  }, [client.id]);
  useEffect(() => { void Promise.resolve().then(loadShares); }, [loadShares]);

  async function submitBlocklistChunk(chunk: string[], requestId: string) {
    let lastError: unknown;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      try {
        return await api<{
          result: { added: number; suppressed: number; remaining: boolean; reindexed: number; queued: number; companiesBlocked?: number };
        }>(`/api/clients/${encodeURIComponent(client.id)}/blocklist`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text: chunk.join("\n"), reason, requestId }),
        });
      } catch (caught) {
        lastError = caught;
        if (attempt < 3) await new Promise((resolve) => window.setTimeout(resolve, attempt * 500));
      }
    }
    throw lastError instanceof Error ? lastError : new Error("Unable to process this blocklist batch.");
  }

  async function addEntries() {
    if (pasteTooLarge) {
      setError(`For safety, one operation can contain up to ${formatNumber(MAX_BLOCKLIST_PASTE_VALUES)} domains and emails. Split this paste into smaller groups.`);
      return;
    }
    if (!validPending) {
      setError("No valid domains or email addresses were found.");
      return;
    }
    setBusy(true); setNotice(""); setError("");
    let processedEntries = 0;
    let blockedRecords = 0;
    let addedEntries = 0;
    let queuedReindexes = 0;
    let blockedCompanies = 0;
    try {
      const values = [...parsedPending.domains, ...parsedPending.emails];
      for (let offset = 0; offset < values.length; offset += BLOCKLIST_REQUEST_VALUES) {
        const chunk = values.slice(offset, offset + BLOCKLIST_REQUEST_VALUES);
        let remaining = true;
        let passes = 0;
        while (remaining) {
          setProgress({ entries: Math.min(offset + chunk.length, values.length), total: values.length, records: blockedRecords });
          const data = await submitBlocklistChunk(chunk, crypto.randomUUID());
          addedEntries += Number(data.result.added ?? 0);
          blockedRecords += Number(data.result.suppressed ?? 0);
          queuedReindexes += Number(data.result.queued ?? 0);
          blockedCompanies += Number(data.result.companiesBlocked ?? 0);
          remaining = Boolean(data.result.remaining);
          passes += 1;
          setProgress({ entries: Math.min(offset + chunk.length, values.length), total: values.length, records: blockedRecords });
          if (passes >= 200 && remaining) throw new Error("This operation reached the one-million-record safety boundary.");
        }
        processedEntries = Math.min(offset + chunk.length, values.length);
      }
      const parts = [`${formatNumber(addedEntries)} added`];
      if (parsedPending.domains.length) parts.push(`${formatNumber(parsedPending.domains.length)} domains`);
      if (parsedPending.emails.length) parts.push(`${formatNumber(parsedPending.emails.length)} emails`);
      if (parsedPending.duplicates) parts.push(`${formatNumber(parsedPending.duplicates)} duplicates ignored`);
      if (blockedRecords) parts.push(`${formatNumber(blockedRecords)} existing client records removed`);
      if (blockedCompanies) parts.push(`${formatNumber(blockedCompanies)} compan${blockedCompanies === 1 ? "y" : "ies"} removed`);
      if (queuedReindexes) parts.push(`${formatNumber(queuedReindexes)} index updates queued safely`);
      if (parsedPending.invalidCount) parts.push(`${formatNumber(parsedPending.invalidCount)} unrecognised (${parsedPending.invalid.slice(0, 3).join(", ")})`);
      setNotice(`${parts.join(" · ")}.`);
      setText("");
      setReason("");
      setPage(1);
      await load(1);
      onChanged();
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : "Unable to update the blocklist.";
      setError(`${message}${processedEntries || blockedRecords ? ` Progress was saved (${formatNumber(processedEntries)} entries processed, ${formatNumber(blockedRecords)} records removed); click Block again to continue safely.` : ""}`);
      if (processedEntries || blockedRecords) { await load(1); onChanged(); }
    }
    finally { setBusy(false); setProgress(null); }
  }

  async function removeSelected() {
    if (!allMatching && !selected.size) return;
    setBusy(true); setNotice(""); setError("");
    try {
      const data = await api<{ result: { removed: number; restored: number; companiesRestored?: number } }>(
        `/api/clients/${encodeURIComponent(client.id)}/blocklist`, {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(selectionPayload()),
        });
      const companiesRestored = Number(data.result.companiesRestored ?? 0);
      setNotice(`Removed ${formatNumber(data.result.removed)} entries · ${formatNumber(data.result.restored)} records${companiesRestored ? ` and ${formatNumber(companiesRestored)} compan${companiesRestored === 1 ? "y" : "ies"}` : ""} restored to this client.`);
      setSelected(new Set());
      setAllMatching(false);
      setPage(1);
      await load(1);
      onChanged();
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to remove those entries."); }
    finally { setBusy(false); }
  }

  function toggle(id: string) {
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  function selectionPayload() {
    return allMatching
      ? { allMatching: true, search: search.trim(), kind, dateFrom, dateTo, excludedIds: [...selected], selectedBefore }
      : { ids: [...selected] };
  }

  async function updateSelectedReason() {
    if (!allMatching && !selected.size) return;
    setBusy(true); setNotice(""); setError("");
    try {
      const data = await api<{ result: { updated: number } }>(`/api/clients/${encodeURIComponent(client.id)}/blocklist`, {
        method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...selectionPayload(), reason: bulkReason }),
      });
      setNotice(`Updated ${formatNumber(data.result.updated)} blocklist reasons.`);
      setSelected(new Set()); setAllMatching(false); await load(1);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to update those reasons."); }
    finally { setBusy(false); }
  }

  const selectedCount = allMatching ? Math.max(0, total - selected.size) : selected.size;
  const hasSelection = allMatching || selected.size > 0;
  const pageSelected = entries.length > 0 && entries.every((entry) => allMatching ? !selected.has(entry.id) : selected.has(entry.id));

  async function exportEntries() {
    setBusy(true); setError("");
    try {
      const selection = hasSelection
        ? selectionPayload()
        : { allMatching: true, search: search.trim(), kind, dateFrom, dateTo, excludedIds: [], selectedBefore: new Date().toISOString() };
      const response = await fetch(`/api/clients/${encodeURIComponent(client.id)}/blocklist`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "export", ...selection }),
      });
      if (!response.ok) {
        const decoded = await response.json().catch(() => null) as { error?: string } | null;
        throw new Error(decoded?.error || "Unable to export the blocklist.");
      }
      const blob = await response.blob();
      const href = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = href;
      link.download = `${client.name.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "").toLowerCase() || "client"}-blocklist-${new Date().toISOString().slice(0, 10)}.csv`;
      document.body.appendChild(link); link.click(); link.remove(); URL.revokeObjectURL(href);
      const exportedCount = hasSelection ? selectedCount : total;
      setNotice(`Exported ${formatNumber(exportedCount)} blocklist entr${exportedCount === 1 ? "y" : "ies"} from a fixed snapshot.`);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to export the blocklist."); }
    finally { setBusy(false); }
  }

  async function createShare() {
    setBusy(true); setError(""); setShareUrl("");
    try {
      const data = await api<{ share: BlocklistShare; url: string }>(`/api/clients/${encodeURIComponent(client.id)}/blocklist-shares`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ label: shareLabel }) });
      setShares((current) => [data.share, ...current]); setShareUrl(data.url);
      try { await navigator.clipboard.writeText(data.url); setNotice("A new submission-only link was created and copied."); } catch { setNotice("A new submission-only link was created."); }
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to create a share link."); }
    finally { setBusy(false); }
  }

  async function revokeShare(shareId: string) {
    setBusy(true); setError("");
    try {
      await api(`/api/clients/${encodeURIComponent(client.id)}/blocklist-shares`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ shareId }) });
      setShares((current) => current.map((share) => share.id === shareId ? { ...share, revoked_at: new Date().toISOString() } : share));
      setNotice("The client submission link was revoked.");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to revoke the share link."); }
    finally { setBusy(false); }
  }

  async function retryFailedShares() {
    setBusy(true); setError("");
    try {
      const data = await api<{ retried: number }>(`/api/clients/${encodeURIComponent(client.id)}/blocklist-shares`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ retryFailed: true }) });
      setNotice(`${formatNumber(data.retried)} failed client submission${data.retried === 1 ? "" : "s"} queued for retry.`); await loadShares();
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to retry failed submissions."); }
    finally { setBusy(false); }
  }

  return <section className="client-database-workspace">
    <div className="client-database-heading">
      <div>
        <p className="eyebrow">CLIENT BLOCKLIST</p>
        <h3>Never contact for {client.name}</h3>
        <p>Domains and emails this client is off-limits for. Matching records are removed from this client&apos;s People and Company databases immediately, while the shared master records and original list history stay safe. Other clients are unaffected.</p>
      </div>
      <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search the blocklist" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); setSelected(new Set()); setAllMatching(false); }} placeholder="Search blocked domains and emails…"/></label>
    </div>
    <div className="blocklist-add-actions">
      <select aria-label="Filter blocklist type" value={kind} onChange={(event) => { setKind(event.target.value); setPage(1); setSelected(new Set()); setAllMatching(false); }}><option value="">All types</option><option value="domain">Domains</option><option value="email">Emails</option></select>
      <label>Date added from <input type="date" value={dateFrom} onChange={(event) => { setDateFrom(event.target.value); setPage(1); setSelected(new Set()); setAllMatching(false); }}/></label>
      <label>Date added to <input type="date" value={dateTo} onChange={(event) => { setDateTo(event.target.value); setPage(1); setSelected(new Set()); setAllMatching(false); }}/></label>
      <button className="secondary" disabled={busy || total === 0 || (hasSelection && selectedCount === 0)} onClick={() => void exportEntries()}>{hasSelection ? `Export ${formatNumber(selectedCount)} selected` : "Export CSV"}</button>
    </div>

    {error ? <div className="inline-error" role="alert">{error}</div> : null}

    <article className="panel blocklist-add">
      <div className="panel-head"><div><h3>Add to the blocklist</h3><p>Paste domains and email addresses together - they are sorted by shape. URLs are trimmed to the domain, so a pasted link matches the stored company.</p></div></div>
      <textarea
        value={text}
        onChange={(event) => { setText(event.target.value); if (notice) setNotice(""); }}
        aria-label="Paste domains and email addresses to block"
        spellCheck={false}
        placeholder={"acme.com\nhttps://www.competitor.co.uk/about\nno-contact@bigco.com\n\nOne per line, or comma-separated."}
      />
      <div className="blocklist-add-actions">
        <select aria-label="Blocklist reason" value={reason} onChange={(event) => setReason(event.target.value)} required><option value="">Choose a reason…</option>{blocklistReasons.map((option) => <option key={option} value={option}>{option}</option>)}</select>
        <button className="primary" disabled={busy || !reason || !pending || !validPending || pasteTooLarge} onClick={() => void addEntries()}>
          {busy ? `Blocking… ${formatNumber(progress?.records ?? 0)} records` : `Block ${pending ? formatNumber(pending) : ""}`}
        </button>
      </div>
      {pasteTooLarge ? <p className="form-error" role="alert">Maximum {formatNumber(MAX_BLOCKLIST_PASTE_VALUES)} entries per operation. Split this paste into smaller groups.</p> : null}
      {progress ? <p className="blocklist-note" role="status">Processing {formatNumber(progress.entries)} of {formatNumber(progress.total)} valid entries · {formatNumber(progress.records)} client records removed so far.</p> : null}
      {notice ? <p className="blocklist-note" role="status">{notice}</p> : null}
    </article>

    <article className="panel blocklist-add">
      <div className="panel-head"><div><h3>Client submission links</h3><p>Create a revocable link clients can use only to submit new blocklist entries. Existing entries are never exposed.</p></div></div>
      {shareQueue.failed ? <div className="inline-error" role="alert"><span>{formatNumber(shareQueue.failed)} client submission{shareQueue.failed === 1 ? "" : "s"} failed after retries.</span><button disabled={busy} onClick={() => void retryFailedShares()}>Retry failed</button></div> : shareQueue.pending ? <p className="blocklist-note" role="status">{formatNumber(shareQueue.pending)} client submission{shareQueue.pending === 1 ? " is" : "s are"} queued for secure processing.</p> : null}
      <div className="blocklist-add-actions"><input aria-label="Submission link label" value={shareLabel} onChange={(event) => setShareLabel(event.target.value)} maxLength={120}/><button disabled={busy || !shareLabel.trim()} onClick={() => void createShare()}>Create &amp; copy link</button></div>
      {shareUrl ? <div className="selection-scope"><code>{shareUrl}</code><button onClick={() => void navigator.clipboard.writeText(shareUrl)}>Copy</button></div> : null}
      {shares.length ? <div className="table-wrap"><table><thead><tr><th>Label</th><th>Created</th><th>Last submission</th><th>Status</th><th>Action</th></tr></thead><tbody>{shares.map((share) => <tr key={share.id}><td>{share.label}</td><td>{new Date(share.created_at).toLocaleDateString("en-IN")}</td><td>{share.last_submitted_at ? new Date(share.last_submitted_at).toLocaleString("en-IN") : "—"}</td><td>{share.revoked_at ? "Revoked" : "Active"}</td><td>{share.revoked_at ? "—" : <button className="row-danger" disabled={busy} onClick={() => void revokeShare(share.id)}>Revoke</button>}</td></tr>)}</tbody></table></div> : <p className="blocklist-note">No client submission links created yet.</p>}
    </article>

    <article className="panel table-panel">
      <div className="panel-head">
        <div><h3>Blocked entries</h3><p>{formatNumber(total)} total{client.blocked_count ? ` · ${formatNumber(client.blocked_count)} client records currently removed` : ""}</p></div>
        {selectedCount ? <div className="blocklist-add-actions"><select aria-label="New reason for selected entries" value={bulkReason} onChange={(event) => setBulkReason(event.target.value as (typeof blocklistReasons)[number])}>{blocklistReasons.map((option) => <option key={option} value={option}>{option}</option>)}</select><button disabled={busy} onClick={() => void updateSelectedReason()}>Update reason</button><button className="row-danger" disabled={busy} onClick={() => void removeSelected()}>Remove {formatNumber(selectedCount)} selected</button></div> : null}
      </div>
      {!allMatching && selected.size > 0 && selected.size < total ? <div className="selection-scope"><span>{formatNumber(selected.size)} on this page selected.</span><button onClick={() => { setAllMatching(true); setSelectedBefore(new Date().toISOString()); setSelected(new Set()); }}>Select all {formatNumber(total)} matching entries</button></div> : null}
      {allMatching ? <div className="selection-scope"><span>All {formatNumber(total)} matching entries selected{selected.size ? ` except ${formatNumber(selected.size)}` : ""}.</span><button onClick={() => { setAllMatching(false); setSelected(new Set()); }}>Clear selection</button></div> : null}
      {loading ? <div className="workspace-loading">Loading the blocklist…</div> : entries.length ? <div className="table-wrap"><table>
        <thead><tr><th className="select-column"><input type="checkbox" aria-label="Select all entries on this page" checked={pageSelected} onChange={() => { if (pageSelected) { setSelected((current) => { const next = new Set(current); entries.forEach((entry) => allMatching ? next.add(entry.id) : next.delete(entry.id)); return next; }); } else { setSelected((current) => { const next = new Set(current); entries.forEach((entry) => allMatching ? next.delete(entry.id) : next.add(entry.id)); return next; }); } }}/></th><th>Value</th><th>Type</th><th>Reason</th><th>Added</th></tr></thead>
        <tbody>{entries.map((entry) => <tr key={entry.id}>
          <td className="select-column"><input type="checkbox" aria-label={`Select ${entry.value}`} checked={allMatching ? !selected.has(entry.id) : selected.has(entry.id)} onChange={() => toggle(entry.id)}/></td>
          <td><strong>{entry.value}</strong></td>
          <td><span className={`data-source-badge ${entry.kind}`}>{entry.kind === "domain" ? "Domain" : "Email"}</span></td>
          <td>{entry.reason || <span className="missing-value">-</span>}</td>
          <td>{new Date(entry.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td>
        </tr>)}</tbody>
      </table></div> : <EmptyCompact text={search ? `No blocked entries match “${search}”.` : "Nothing is blocked for this client yet."} />}
      {totalPages > 1 ? <div className="company-pagination"><span>Page {page} of {totalPages}</span><div><button disabled={loading || page <= 1} onClick={() => setPage((current) => Math.max(1, current - 1))}><AppIcon name="back" size={14}/> Previous</button><button disabled={loading || page >= totalPages} onClick={() => setPage((current) => Math.min(totalPages, current + 1))}>Next</button></div></div> : null}
    </article>
  </section>;
}
