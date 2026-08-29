"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { splitPastedValues } from "../../lib/bulk-values.ts";
import type { BlocklistEntry, ClientRecord } from "../../lib/types";
import { EmptyCompact } from "./DashboardUi";
import { AppIcon } from "./DashboardUi";

// The blocklist is per client and it suppresses rather than deletes: a blocked
// record keeps its place in the client database with a badge, so the decision
// and its reason survive. Nothing here touches the master People DB.
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

  const pending = useMemo(() => splitPastedValues(text).length, [text]);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (search.trim()) params.set("search", search.trim());
      const data = await api<{ entries: BlocklistEntry[]; total: number }>(
        `/api/clients/${encodeURIComponent(client.id)}/blocklist?${params}`);
      setEntries(data.entries); setTotal(data.total); setError("");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load the blocklist."); }
    finally { setLoading(false); }
  }, [client.id, search]);

  useEffect(() => {
    const timer = window.setTimeout(() => { void load(); }, search ? 300 : 0);
    return () => window.clearTimeout(timer);
  }, [load, search]);

  async function addEntries() {
    setBusy(true); setNotice(""); setError("");
    try {
      const data = await api<{
        result: { added: number; suppressed: number };
        domains: number; emails: number; unrecognised: string[]; unrecognisedCount: number;
      }>(`/api/clients/${encodeURIComponent(client.id)}/blocklist`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, reason }),
      });
      const parts = [`${formatNumber(data.result.added)} added`];
      if (data.domains) parts.push(`${formatNumber(data.domains)} domains`);
      if (data.emails) parts.push(`${formatNumber(data.emails)} emails`);
      if (data.result.suppressed) parts.push(`${formatNumber(data.result.suppressed)} records suppressed`);
      if (data.unrecognisedCount) parts.push(`${formatNumber(data.unrecognisedCount)} unrecognised (${data.unrecognised.slice(0, 3).join(", ")})`);
      setNotice(`${parts.join(" · ")}.`);
      setText("");
      await load();
      onChanged();
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to update the blocklist."); }
    finally { setBusy(false); }
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
      await load();
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
        <p>Domains and email addresses this client is off-limits for. Matching records stay in the database but are excluded from exports and pushes, so you keep the reason. Other clients are unaffected.</p>
      </div>
      <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search the blocklist" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search blocked domains and emails…"/></label>
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
        <button className="primary" disabled={busy || !pending} onClick={() => void addEntries()}>
          {busy ? "Blocking…" : `Block ${pending ? formatNumber(pending) : ""}`}
        </button>
      </div>
      {notice ? <p className="blocklist-note" role="status">{notice}</p> : null}
    </article>

    <article className="panel table-panel">
      <div className="panel-head">
        <div><h3>Blocked entries</h3><p>{formatNumber(total)} total{client.blocked_count ? ` · ${formatNumber(client.blocked_count)} records currently suppressed` : ""}</p></div>
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
    </article>
  </section>;
}
