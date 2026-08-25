"use client";

import { useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber, initials, parseAllData, prospectMembershipItems } from "../../lib/dashboard-helpers";
import type { DeleteRequest, Prospect } from "../../lib/types";

export type IconName = "home" | "database" | "company" | "clients" | "coverage" | "quality" | "upload" | "search" | "plus" | "filter" | "columns" | "check" | "arrow"
  | "chevron" | "close" | "star" | "download" | "tag" | "target" | "hash" | "alert" | "back" | "rows" | "refresh" | "warning" | "grid" | "sun" | "moon" | "monitor";

export function AppIcon({ name, size = 18 }: { name: IconName; size?: number }) {
  const common = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
  if (name === "home") return <svg {...common}><path d="m3 11 9-8 9 8"/><path d="M5.5 9.5V21h13V9.5"/><path d="M9.5 21v-6h5v6"/></svg>;
  if (name === "database") return <svg {...common}><ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v7c0 1.7 3.6 3 8 3s8-1.3 8-3V5"/><path d="M4 12v7c0 1.7 3.6 3 8 3s8-1.3 8-3v-7"/></svg>;
  if (name === "company") return <svg {...common}><path d="M4 21V4h10v17"/><path d="M14 9h6v12"/><path d="M8 8h2M8 12h2M8 16h2M17 13h1M17 17h1"/></svg>;
  if (name === "clients") return <svg {...common}><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></svg>;
  if (name === "coverage") return <svg {...common}><circle cx="11" cy="11" r="7"/><path d="m20 20-4-4M8 11h6M11 8v6"/></svg>;
  if (name === "quality") return <svg {...common}><path d="M12 3 4.5 6v5.5c0 4.7 3.2 8 7.5 9.5 4.3-1.5 7.5-4.8 7.5-9.5V6z"/><path d="m8.5 12 2.2 2.2 4.8-5"/></svg>;
  if (name === "upload") return <svg {...common}><path d="M12 16V3M7 8l5-5 5 5"/><path d="M5 14v6h14v-6"/></svg>;
  if (name === "search") return <svg {...common}><circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/></svg>;
  if (name === "plus") return <svg {...common}><path d="M12 5v14M5 12h14"/></svg>;
  if (name === "filter") return <svg {...common}><path d="M4 6h16M7 12h10M10 18h4"/></svg>;
  if (name === "columns") return <svg {...common}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M15 4v16"/></svg>;
  if (name === "check") return <svg {...common}><path d="m5 12 4 4L19 6"/></svg>;
  // Added so no surface has to fall back to a unicode glyph. Glyphs render
  // differently on every OS and read as placeholder art.
  if (name === "chevron") return <svg {...common}><path d="m6 9 6 6 6-6"/></svg>;
  if (name === "close") return <svg {...common}><path d="M6 6l12 12M18 6 6 18"/></svg>;
  if (name === "star") return <svg {...common}><path d="m12 3.5 2.6 5.4 5.9.8-4.3 4.2 1 5.9-5.2-2.8-5.2 2.8 1-5.9L3.5 9.7l5.9-.8z"/></svg>;
  if (name === "download") return <svg {...common}><path d="M12 3v13M7 11l5 5 5-5"/><path d="M5 20h14"/></svg>;
  if (name === "tag") return <svg {...common}><path d="M3 12.5V4h8.5L21 13.5 13.5 21z"/><circle cx="7.5" cy="7.5" r="1.3"/></svg>;
  if (name === "target") return <svg {...common}><circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3"/></svg>;
  if (name === "hash") return <svg {...common}><path d="M9 3.5 7 20.5M17 3.5l-2 17M4 9h16M3 15h16"/></svg>;
  if (name === "alert") return <svg {...common}><circle cx="12" cy="12" r="9"/><path d="M12 7.5v5.5"/><path d="M12 16.3v.2"/></svg>;
  if (name === "back") return <svg {...common}><path d="M19 12H5M11 6l-6 6 6 6"/></svg>;
  if (name === "rows") return <svg {...common}><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18"/></svg>;
  if (name === "refresh") return <svg {...common}><path d="M20 11a8 8 0 0 0-13.7-5.3L3 9"/><path d="M4 13a8 8 0 0 0 13.7 5.3L21 15"/><path d="M3 4v5h5M21 20v-5h-5"/></svg>;
  if (name === "warning") return <svg {...common}><path d="M12 4 2.8 20h18.4z"/><path d="M12 10v4"/><path d="M12 17v.2"/></svg>;
  if (name === "grid") return <svg {...common}><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>;
  if (name === "sun") return <svg {...common}><circle cx="12" cy="12" r="4.2"/><path d="M12 2.6v2.2M12 19.2v2.2M2.6 12h2.2M19.2 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M18.7 5.3l-1.6 1.6M6.9 17.1l-1.6 1.6"/></svg>;
  if (name === "moon") return <svg {...common}><path d="M20 13.5A8.2 8.2 0 0 1 10.5 4a8.2 8.2 0 1 0 9.5 9.5z"/></svg>;
  if (name === "monitor") return <svg {...common}><rect x="2.5" y="4" width="19" height="13" rx="2"/><path d="M8.5 21h7M12 17v4"/></svg>;
  return <svg {...common}><path d="M5 12h14M13 6l6 6-6 6"/></svg>;
}
export function LoadingState() {
  return <div className="loading-state"><div className="loading-bar"/><div className="loading-grid"><span/><span/><span/><span/></div></div>;
}

export function ProspectDrawer({ prospect, onClose }: { prospect: Prospect; onClose: () => void }) {
  const data = parseAllData(prospect.all_data);
  const memberships = prospectMembershipItems(prospect, true);
  const membershipCountMatches = memberships.length === Number(prospect.list_count ?? 0);
  const [tab, setTab] = useState<"data" | "history">("data");
  const [events, setEvents] = useState<Array<{ id: string; contacted_at: string; campaign_name: string; outcome: string; client: { name?: string } | Array<{ name?: string }> }>>([]);
  useEffect(() => {
    const closeOnEscape = (event: globalThis.KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", closeOnEscape);
    void api<{ events: typeof events }>(`/api/operations?prospectId=${encodeURIComponent(prospect.id)}`).then((result) => setEvents(result.events)).catch(() => setEvents([]));
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [prospect.id, onClose]);
  return <div className="drawer-backdrop"><button className="drawer-dismiss" aria-label="Close prospect details" onClick={onClose}/><aside className="drawer" role="dialog" aria-modal="true" aria-labelledby="prospect-drawer-title"><button className="drawer-close" aria-label="Close prospect details" onClick={onClose}><AppIcon name="close" size={14}/></button><div className="drawer-person"><span>{initials(prospect.full_name)}</span><div><p className="eyebrow">PROSPECT DETAILS</p><h2 id="prospect-drawer-title">{prospect.full_name || "Unnamed prospect"}</h2><p>{prospect.title || "No title"} {prospect.company_name ? `at ${prospect.company_name}` : ""}</p></div></div><div className="drawer-summary"><span><b>{formatNumber(prospect.client_count)}</b>clients</span><span><b>{formatNumber(prospect.list_count)}</b>lists</span><span><b>{Object.keys(data).length}</b>data fields</span></div><div className="drawer-tabs" role="tablist"><button role="tab" aria-selected={tab === "data"} className={tab === "data" ? "active" : ""} onClick={() => setTab("data")}>Saved data</button><button role="tab" aria-selected={tab === "history"} className={tab === "history" ? "active" : ""} onClick={() => setTab("history")}>Contact history <span>{events.length}</span></button></div>{tab === "data" ? <div className="drawer-saved-data"><section className="drawer-memberships"><div><span>LIST MEMBERSHIPS</span><strong>{formatNumber(memberships.length)} linked</strong><small className={membershipCountMatches ? "verified" : "review"}>{membershipCountMatches ? "Tag count verified" : "Review membership count"}</small></div>{memberships.length ? <div className="drawer-membership-list">{memberships.map((membership) => <div key={membership.key}><span>{membership.clientName || "Client"}</span><strong>{membership.listName}</strong></div>)}</div> : <p>No master-list membership is linked to this prospect.</p>}</section><div className="field-list">{Object.entries(data).map(([field, value]) => <div key={field}><span>{field}</span><strong>{value || "-"}</strong></div>)}</div></div> : <div className="contact-timeline">{events.length ? events.map((event) => { const client = Array.isArray(event.client) ? event.client[0] : event.client; return <div key={event.id}><i/><span>{new Date(event.contacted_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</span><strong>{client?.name || "Unknown client"}</strong><p>{event.campaign_name || event.outcome || "Contacted"}</p></div>; }) : <div className="drawer-empty">No contact history recorded yet.</div>}</div>}</aside></div>;
}


export function DeleteConfirmation({ target, busy, onCancel, onConfirm }: { target: DeleteRequest; busy: boolean; onCancel: () => void; onConfirm: () => Promise<void> }) {
  const action = target.kind === "import" ? "Undo import" : target.kind === "list" ? "Delete list" : "Delete client";
  const explanation = target.kind === "import"
    ? "This removes the import and its client-list links. The list is also removed when nothing else uses it."
    : target.kind === "list"
      ? "This removes the list and its import history — only the links between this list and the People database."
      : "This removes the client workspace, every list under it, and its import history — only the client-side links.";
  return <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="delete-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="delete-title">{action}?</h2><p>{explanation}</p><div className="delete-target"><strong>{target.name}</strong><span>{target.context}</span></div><p className="shared-safety">Your People and Company databases are never affected by this. Every prospect and company stays in place — only this client-side data is removed.</p><div className="modal-actions"><button className="secondary" disabled={busy} onClick={onCancel}>Cancel</button><button className="danger-button solid" disabled={busy} onClick={() => void onConfirm()}>{busy ? "Working…" : action}</button></div></section></div>;
}


export function EmptyState({ title, text, action, onAction }: { title: string; text: string; action: string; onAction: () => void }) {
  return <div className="empty"><span><AppIcon name="target" size={14}/></span><h3>{title}</h3><p>{text}</p><button className="primary" onClick={onAction}>{action}</button></div>;
}

export function EmptyCompact({ text, action, onAction }: { text: string; action?: string; onAction?: () => void }) {
  return <div className="empty compact"><span><AppIcon name="upload" size={14}/></span><p>{text}</p>{action && onAction ? <button onClick={onAction}>{action}</button> : null}</div>;
}
