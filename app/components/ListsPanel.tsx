"use client";

import { useDeferredValue, useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientRecord, ListRecord, Prospect } from "../../lib/types";
import { EmptyCompact } from "./DashboardUi";
import { AppIcon } from "./DashboardUi";

export default function ListsPanel({ client, list, onBack, onSelect, onSeePeople, onSeeCompanies }: { client: ClientRecord; list: ListRecord; onBack: () => void; onSelect: (prospect: Prospect) => void; onSeePeople: () => void; onSeeCompanies: () => void }) {
  const [rows, setRows] = useState<Prospect[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [copying, setCopying] = useState(false);
  const [notice, setNotice] = useState("");
  const deferredSearch = useDeferredValue(search);
  useEffect(() => {
    let active = true;
    void api<{ rows: Prospect[]; total: number }>(`/api/lists/${encodeURIComponent(list.id)}/rows?search=${encodeURIComponent(deferredSearch)}&page=${page}`).then((data) => { if (active) { setRows(data.rows); setTotal(data.total); setError(""); } }).catch((caught) => { if (active) setError(caught instanceof Error ? caught.message : "Unable to load this list."); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [list.id, deferredSearch, page]);
  const totalPages = Math.max(1, Math.ceil(total / 50));

  // The domains of every company this list's prospects belong to - the whole
  // list, not just this page. Resolved server-side the same way the Company
  // DB's own Copy Domains does (resolve_company_action_selection_v1, which
  // already accepts a people-side scope), just scoped by __list_ids instead of
  // an explicit company selection.
  async function copyDomains() {
    setCopying(true); setError(""); setNotice("");
    try {
      const result = await api<{ domains: string[]; matched: number; truncated: boolean }>("/api/companies/domains", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
          allMatching: true, clientId: client.id,
          peopleScope: { search: "", filters: [{ field: "__list_ids", operator: "contains", values: [list.id] }], limit: 250000 },
        }),
      });
      if (!result.domains.length) { setNotice("None of this list's companies have a recorded website."); return; }
      await navigator.clipboard.writeText(result.domains.join("\n"));
      setNotice(`Copied ${formatNumber(result.domains.length)} domain${result.domains.length === 1 ? "" : "s"} to your clipboard.${result.truncated ? ` The list has more than ${formatNumber(result.domains.length)} companies; only the first ${formatNumber(result.domains.length)} domains were copied.` : ""}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to copy domains. Your browser may be blocking clipboard access.");
    } finally { setCopying(false); }
  }

  return <section className="operations-page"><button className="back" onClick={onBack}><AppIcon name="back" size={14}/> {client.name} lists</button><div className="section-intro compact-intro"><div><p className="eyebrow">LIST WORKSPACE</p><h2>{list.name}</h2><p>{formatNumber(total)} linked prospects · {formatNumber(list.field_count)} preserved fields · {list.source_file_name}</p></div>
    {/* Every action here pivots the whole list into the real client
        databases (or, for domains, resolves it there and copies the result) -
        not a second, smaller copy of their bulk actions built on this table. */}
    <div className="list-workspace-actions">
      <button className="secondary" title={`Open ${client.name}'s People database, filtered to this list`} onClick={onSeePeople}><AppIcon name="database" size={14}/> See People</button>
      <button className="secondary" title={`Open ${client.name}'s Company database, filtered to the companies behind this list`} onClick={onSeeCompanies}><AppIcon name="company" size={14}/> See Companies</button>
      <button className="secondary" disabled={copying} title="Copy the website of every company behind this list to your clipboard, one per line" onClick={() => void copyDomains()}><AppIcon name="download" size={14}/> {copying ? "Copying…" : "Copy Domains"}</button>
      <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search this list" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this list…"/></label>
    </div></div>
    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {notice ? <div className="inline-notice" role="status">{notice}<button aria-label="Dismiss" onClick={() => setNotice("")}><AppIcon name="close" size={14}/></button></div> : null}
    <article className="panel list-workspace-panel">{loading ? <div className="workspace-loading">Loading list records…</div> : rows.length ? <div className="table-wrap"><table><thead><tr><th>Name</th><th>Company</th><th>Email</th><th>Title</th><th>Last contacted</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id} onClick={() => onSelect(row)}><td><div className="compact-person"><span aria-hidden="true">{initials(row.full_name)}</span><button type="button" className="row-open" onClick={(event) => { event.stopPropagation(); onSelect(row); }}>{row.full_name || "Unnamed prospect"}</button></div></td><td>{row.company_name || "-"}</td><td>{row.work_email || "-"}</td><td>{row.title || "-"}</td><td>{row.last_contacted_at ? new Date(row.last_contacted_at).toLocaleDateString("en-IN") : "Never"}</td></tr>)}</tbody></table></div> : <EmptyCompact text="No prospects match this search." action="Clear search" onAction={() => setSearch("")} />}<div className="table-footer"><span>{formatNumber(total)} records</span><div><button disabled={page <= 1} onClick={() => setPage((current) => current - 1)}><AppIcon name="back" size={14}/> Previous</button><span>Page {page} of {totalPages}</span><button disabled={page >= totalPages} onClick={() => setPage((current) => current + 1)}>Next</button></div></div></article>
  </section>;
}
