"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { BLOCKLIST_REQUEST_VALUES, MAX_BLOCKLIST_PASTE_VALUES, partitionBlocklistValues } from "../../lib/bulk-values.ts";
import type { BlocklistEntry, ClientRecord } from "../../lib/types";
import { EmptyCompact } from "./DashboardUi";
import { AppIcon } from "./DashboardUi";

// The blocklist is per client. Matching memberships are retained internally for
// audit/restore, but disappear from the client's People and Company databases.
// Nothing here deletes the shared master People DB record.
export default function BlocklistPanel({ client, onChanged }: { client: ClientRecord; onChanged: () => void }) {
  const [entries, setEntries] = useState<BlocklistEntry[]>([]);
  const [total, setTotal] = useState(0);
  const [search, setSearch] = useState("");
  const [text, setText] = useState("");
  const [reason, setReason] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [page, setPage] = useState(1);
  const [progress, setProgress] = useState<{ entries: number; total: number; records: number } | null>(null);

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
      params.set("page", String(requestedPage));
      const data = await api<{ entries: BlocklistEntry[]; total: number }>(
        `/api/clients/${encodeURIComponent(client.id)}/blocklist?${params}`);
      setEntries(data.entries); setTotal(data.total); setError("");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load the blocklist."); }
    finally { setLoading(false); }
  }, [client.id, page, search]);

  useEffect(() => {
    const timer = window.setTimeout(() => { void load(); }, search ? 300 : 0);
    return () => window.clearTimeout(timer);
  }, [load, search]);

  async function submitBlocklistChunk(chunk: string[], requestId: string) {
    let lastError: unknown;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      try {
        return await api<{
          result: { added: number; suppressed: number; remaining: boolean; reindexed: number; queued: number };
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
      if (queuedReindexes) parts.push(`${formatNumber(queuedReindexes)} index updates queued safely`);
      if (parsedPending.invalidCount) parts.push(`${formatNumber(parsedPending.invalidCount)} unrecognised (${parsedPending.invalid.slice(0, 3).join(", ")})`);
      setNotice(`${parts.join(" · ")}.`);
      setText("");
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
    if (!selected.size) return;
    setBusy(true); setNotice(""); setError("");
    try {
      const data = await api<{ result: { removed: number; restored: number } }>(
        `/api/clients/${encodeURIComponent(client.id)}/blocklist`, {
          method: "DELETE",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ids: [...selected] }),
        });
      setNotice(`Removed ${formatNumber(data.result.removed)} entries · ${formatNumber(data.result.restored)} records restored to this client.`);
      setSelected(new Set());
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

  return <section className="client-database-workspace">
    <div className="client-database-heading">
      <div>
        <p className="eyebrow">CLIENT BLOCKLIST</p>
        <h3>Never contact for {client.name}</h3>
        <p>Domains and emails this client is off-limits for. Matching records are removed from this client&apos;s People and Company databases immediately, while the shared master records and original list history stay safe. Other clients are unaffected.</p>
      </div>
      <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search the blocklist" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search blocked domains and emails…"/></label>
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
        <input aria-label="Reason (optional)" value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Reason (optional) - e.g. existing customer"/>
        <button className="primary" disabled={busy || !pending || !validPending || pasteTooLarge} onClick={() => void addEntries()}>
          {busy ? `Blocking… ${formatNumber(progress?.records ?? 0)} records` : `Block ${pending ? formatNumber(pending) : ""}`}
        </button>
      </div>
      {pasteTooLarge ? <p className="form-error" role="alert">Maximum {formatNumber(MAX_BLOCKLIST_PASTE_VALUES)} entries per operation. Split this paste into smaller groups.</p> : null}
      {progress ? <p className="blocklist-note" role="status">Processing {formatNumber(progress.entries)} of {formatNumber(progress.total)} valid entries · {formatNumber(progress.records)} client records removed so far.</p> : null}
      {notice ? <p className="blocklist-note" role="status">{notice}</p> : null}
    </article>

    <article className="panel table-panel">
      <div className="panel-head">
        <div><h3>Blocked entries</h3><p>{formatNumber(total)} total{client.blocked_count ? ` · ${formatNumber(client.blocked_count)} client records currently removed` : ""}</p></div>
        {selected.size ? <button className="row-danger" disabled={busy} onClick={() => void removeSelected()}>Remove {formatNumber(selected.size)} selected</button> : null}
      </div>
      {loading ? <div className="workspace-loading">Loading the blocklist…</div> : entries.length ? <div className="table-wrap"><table>
        <thead><tr><th className="select-column"><span className="visually-hidden">Select</span></th><th>Value</th><th>Type</th><th>Reason</th><th>Added</th></tr></thead>
        <tbody>{entries.map((entry) => <tr key={entry.id}>
          <td className="select-column"><input type="checkbox" aria-label={`Select ${entry.value}`} checked={selected.has(entry.id)} onChange={() => toggle(entry.id)}/></td>
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
