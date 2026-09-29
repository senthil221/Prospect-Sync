"use client";

import { useEffect, useMemo, useState } from "react";
import { AppIcon } from "./DashboardUi";
import { Segmented, relativeTime } from "./IcpValidatorViews";

// What the Smartlead reply sync added to which client's blocklist, and why.
// The "why" is the Smartlead category of the reply. Every category except Out
// of Office blocks the email; "Not the right fit" also blocks the domain.

export type ReplyBlockReason = { category_id?: number; reason: string; count: number };
export type ReplyBlockClient = {
  client_id: string; client_name: string; total: number; emails: number; domains: number; pending: number; removed: number;
  last_applied_at: string | null; reasons: ReplyBlockReason[] | null;
};
export type ReplyBlockRow = {
  value: string; kind: "email" | "domain"; status: string; client_id: string; client_name: string; reason: string;
  campaign_name: string | null; reply_email: string | null; reply_time: string | null; applied_at: string | null; created_at: string;
};
type Payload = { summary: ReplyBlockClient[]; reasons: ReplyBlockReason[]; total: number; rows: ReplyBlockRow[]; page: number; pageSize: number };
type Kind = "" | "email" | "domain";

const engaged = new Set(["interested", "meeting request", "information request", "fwd to team"]);
const rejected = new Set(["not interested", "do not contact", "wrong person", "not the right fit", "sender originated bounce"]);
export function reasonTone(reason: string) {
  const key = reason.trim().toLowerCase();
  return engaged.has(key) ? "engaged" : rejected.has(key) ? "rejected" : "neutral";
}
const num = (value: unknown) => { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; };
const fmt = (value: number) => new Intl.NumberFormat("en-IN").format(value);

export function ReplyBlockClientCards({ clients, selected, onSelect }: { clients: ReplyBlockClient[]; selected: string; onSelect: (id: string) => void }) {
  return <div className="rbx-clients">{clients.map((client) => {
    const reasons = client.reasons ?? [];
    const total = Math.max(1, num(client.total));
    return <button key={client.client_id} type="button" aria-pressed={selected === client.client_id}
      className={`rbx-client${selected === client.client_id ? " is-on" : ""}`}
      onClick={() => onSelect(selected === client.client_id ? "" : client.client_id)}>
      <span className="rbx-client-head"><strong>{client.client_name}</strong><span>{relativeTime(client.last_applied_at)}</span></span>
      <span className="rbx-client-total"><b>{fmt(num(client.total))}</b> blocked</span>
      <span className="rbx-client-split"><span><AppIcon name="hash" size={12}/>{fmt(num(client.emails))} emails</span><span><AppIcon name="grid" size={12}/>{fmt(num(client.domains))} domains</span></span>
      <span className="rbx-reason-bar" aria-hidden="true">{reasons.map((reason) =>
        <i key={reason.reason} className={`is-${reasonTone(reason.reason)}`} style={{ flexGrow: num(reason.count) / total }}/>)}</span>
      <span className="rbx-client-reasons">{reasons.slice(0, 3).map((reason) =>
        <span key={reason.reason}><i className={`is-${reasonTone(reason.reason)}`}/>{reason.reason}<b>{fmt(num(reason.count))}</b></span>)}</span>
    </button>;
  })}</div>;
}

export function ReplyBlockTable({ rows }: { rows: ReplyBlockRow[] }) {
  return <div className="rbx-table-wrap"><table className="rbx-table">
    <thead><tr><th>Blocked</th><th>Client</th><th>Reason</th><th>Campaign</th><th>Replied</th><th>Added</th></tr></thead>
    <tbody>{rows.map((row) => <tr key={`${row.client_id}:${row.kind}:${row.value}`} className={row.status !== "applied" ? "is-muted" : undefined}>
      <td className="rbx-value"><span className={`rbx-kind is-${row.kind}`}>{row.kind === "domain" ? "Domain" : "Email"}</span><code>{row.value}</code>
        {row.status === "manual_removed" ? <em>removed by hand</em> : row.status !== "applied" ? <em>{row.status.replaceAll("_", " ")}</em> : null}</td>
      <td className="rbx-client-cell">{row.client_name}</td>
      <td><span className={`rbx-reason is-${reasonTone(row.reason)}`}>{row.reason}</span></td>
      <td className="rbx-campaign" title={row.campaign_name ?? undefined}>{row.campaign_name ?? "-"}{row.kind === "domain" && row.reply_email ? <small>from {row.reply_email}</small> : null}</td>
      <td className="rbx-time" title={row.reply_time ? new Date(row.reply_time).toLocaleString() : undefined}>{relativeTime(row.reply_time)}</td>
      <td className="rbx-time" title={new Date(row.applied_at ?? row.created_at).toLocaleString()}>{relativeTime(row.applied_at ?? row.created_at)}</td>
    </tr>)}</tbody>
  </table></div>;
}

export default function ReplyBlocksSummary({ refreshKey = 0 }: { refreshKey?: number }) {
  const [client, setClient] = useState("");
  const [category, setCategory] = useState(0);
  const [kind, setKind] = useState<Kind>("");
  const [search, setSearch] = useState("");
  const [term, setTerm] = useState("");
  const [page, setPage] = useState(1);
  const [data, setData] = useState<{ key: string; payload: Payload } | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    const timer = window.setTimeout(() => { setTerm(search.trim()); setPage(1); }, 300);
    return () => window.clearTimeout(timer);
  }, [search]);

  const query = useMemo(() => {
    const params = new URLSearchParams();
    if (client) params.set("client", client);
    if (category) params.set("category", String(category));
    if (kind) params.set("kind", kind);
    if (term) params.set("search", term);
    return params.toString();
  }, [client, category, kind, term]);
  const key = `${query}|${page}|${refreshKey}`;

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      fetch(`/api/integrations/reply-blocks?${query}&page=${page}`, { cache: "no-store", signal: controller.signal })
        .then(async (response) => {
          const body = await response.json();
          if (!response.ok) throw new Error(body.error ?? "Unable to load reply blocks.");
          setData({ key, payload: body as Payload });
          setError("");
        })
        .catch((caught) => { if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : "Unable to load reply blocks."); });
    }, 0);
    return () => { window.clearTimeout(timer); controller.abort(); };
  }, [query, page, key]);

  const payload = data?.payload ?? null;
  const loading = !data || data.key !== key;
  const totalPages = Math.max(1, Math.ceil(num(payload?.total) / (payload?.pageSize ?? 50)));
  const allBlocked = (payload?.summary ?? []).reduce((sum, item) => sum + num(item.total), 0);

  function reset(next: () => void) { next(); setPage(1); }

  return <section className="panel rbx" aria-labelledby="rbx-title">
    <div className="rbx-head">
      <div><p className="eyebrow">BLOCKED FROM REPLIES</p><h3 id="rbx-title">What was blocked, for whom, and why</h3>
        <p>{payload ? `${fmt(allBlocked)} emails and domains added to ${payload.summary.length} client blocklist${payload.summary.length === 1 ? "" : "s"} by reply sync.` : "Every block the reply sync has made, by client and reason."}</p></div>
      <a className="icpx-ghost" href={`/api/integrations/reply-blocks?${query}&format=csv`} download><AppIcon name="download" size={15}/> Export CSV</a>
    </div>

    {error ? <div className="reply-blocklist-message is-error" role="alert">{error}</div> : null}

    {payload?.summary.length ? <ReplyBlockClientCards clients={payload.summary} selected={client} onSelect={(id) => reset(() => { setClient(id); setCategory(0); })}/> : null}

    {payload?.reasons.length ? <div className="rbx-reasons" role="group" aria-label="Filter by reason">
      <button type="button" aria-pressed={!category} className={!category ? "is-on" : undefined} onClick={() => reset(() => setCategory(0))}>All reasons</button>
      {payload.reasons.map((reason) => <button key={reason.reason} type="button" aria-pressed={category === reason.category_id}
        className={`${category === reason.category_id ? "is-on " : ""}is-${reasonTone(reason.reason)}`}
        onClick={() => reset(() => setCategory(category === reason.category_id ? 0 : num(reason.category_id)))}>
        <i/>{reason.reason}<b>{fmt(num(reason.count))}</b>
      </button>)}
    </div> : null}

    <div className="rbx-toolbar">
      <Segmented<Kind> label="Type" value={kind} onChange={(value) => reset(() => setKind(value))} options={[
        { value: "", label: "Everything" }, { value: "email", label: "Emails" }, { value: "domain", label: "Domains" },
      ]}/>
      <label className="icpx-search"><AppIcon name="search" size={15}/><input aria-label="Search blocked values and campaigns" value={search} placeholder="Search email, domain or campaign" onChange={(event) => setSearch(event.target.value)}/></label>
    </div>

    {loading && !payload ? <div className="icpx-skeleton is-rows" aria-busy="true"><span/><span/><span/></div>
      : payload && payload.rows.length ? <div className={loading ? "rbx-loading" : undefined}><ReplyBlockTable rows={payload.rows}/></div>
        : <div className="icpx-empty is-quiet"><AppIcon name="check" size={20}/><div><strong>{query ? "Nothing matches these filters" : "No reply blocks yet"}</strong><p>{query ? "Clear a filter to see more." : "Blocks appear here as the reply sync processes tagged replies."}</p></div></div>}

    {payload && totalPages > 1 ? <nav className="icpx-pager" aria-label="Pages">
      <button type="button" disabled={page <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}><AppIcon name="back" size={14}/> Previous</button>
      <span>Page <b>{fmt(page)}</b> of {fmt(totalPages)} · {fmt(num(payload.total))} blocks</span>
      <button type="button" disabled={page >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>Next <AppIcon name="arrow" size={14}/></button>
    </nav> : null}
  </section>;
}
