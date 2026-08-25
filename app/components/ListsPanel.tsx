"use client";

import { useDeferredValue, useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import type { ClientRecord, ListRecord, Prospect } from "../../lib/types";
import { EmptyCompact } from "./DashboardUi";
import { AppIcon } from "./DashboardUi";

export default function ListsPanel({ client, list, onBack, onSelect }: { client: ClientRecord; list: ListRecord; onBack: () => void; onSelect: (prospect: Prospect) => void }) {
  const [rows, setRows] = useState<Prospect[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const deferredSearch = useDeferredValue(search);
  useEffect(() => {
    let active = true;
    void api<{ rows: Prospect[]; total: number }>(`/api/lists/${encodeURIComponent(list.id)}/rows?search=${encodeURIComponent(deferredSearch)}&page=${page}`).then((data) => { if (active) { setRows(data.rows); setTotal(data.total); setError(""); } }).catch((caught) => { if (active) setError(caught instanceof Error ? caught.message : "Unable to load this list."); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [list.id, deferredSearch, page]);
  const totalPages = Math.max(1, Math.ceil(total / 50));
  return <section className="operations-page"><button className="back" onClick={onBack}><AppIcon name="back" size={14}/> {client.name} lists</button><div className="section-intro compact-intro"><div><p className="eyebrow">LIST WORKSPACE</p><h2>{list.name}</h2><p>{formatNumber(total)} linked prospects · {formatNumber(list.field_count)} preserved fields · {list.source_file_name}</p></div><label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search this list" value={search} onChange={(event) => { setSearch(event.target.value); setPage(1); }} placeholder="Search this list…"/></label></div>
    <article className="panel list-workspace-panel">{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Loading list records…</div> : rows.length ? <div className="table-wrap"><table><thead><tr><th>Name</th><th>Company</th><th>Email</th><th>Title</th><th>Last contacted</th></tr></thead><tbody>{rows.map((row) => <tr key={row.id} onClick={() => onSelect(row)}><td><div className="compact-person"><span>{initials(row.full_name)}</span><strong>{row.full_name || "Unnamed prospect"}</strong></div></td><td>{row.company_name || "-"}</td><td>{row.work_email || "-"}</td><td>{row.title || "-"}</td><td>{row.last_contacted_at ? new Date(row.last_contacted_at).toLocaleDateString("en-IN") : "Never"}</td></tr>)}</tbody></table></div> : <EmptyCompact text="No prospects match this search." action="Clear search" onAction={() => setSearch("")} />}<div className="table-footer"><span>{formatNumber(total)} records</span><div><button disabled={page <= 1} onClick={() => setPage((current) => current - 1)}><AppIcon name="back" size={14}/> Previous</button><span>Page {page} of {totalPages}</span><button disabled={page >= totalPages} onClick={() => setPage((current) => current + 1)}>Next</button></div></div></article>
  </section>;
}
