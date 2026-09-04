"use client";

import { useEffect, useState, type CSSProperties } from "react";
import { formatNumber, initials } from "../../lib/dashboard-helpers";
import { formatShare } from "../../lib/quality-issues";
import { emptyStats, type ClientRecord, type ImportRecord, type ProspectImportRecord } from "../../lib/types";
import { AppIcon, EmptyCompact, type IconName } from "./DashboardUi";
import CountUp from "./CountUp";

// Whether the Overview figures have already counted up during this run of the
// app. Deliberately a module-level flag rather than component state: navigating
// to People and back UNMOUNTS this component, so anything held inside it would
// be gone by the time the question is asked, and the numbers would count
// themselves up again on every visit. A full page load is a new run and gets
// the animation again, which is the intent - it is an arrival, not a decoration.
let countsHavePlayed = false;

export default function OverviewWorkspace({ stats, recentImports, clients, onImport, onViewMaster, onDeleteImport }: { stats: typeof emptyStats; recentImports: ImportRecord[]; clients: ClientRecord[]; onImport: () => void; onViewMaster: () => void; onDeleteImport: (item: ProspectImportRecord) => void }) {
  const cards = [
    { label: "Unique prospects", value: stats.prospects, note: "Clean master records", icon: "database" as IconName },
    { label: "Known companies", value: stats.companies, note: "Matched by name or domain", icon: "company" as IconName },
    { label: "Client lists", value: stats.lists, note: `${stats.clients} active clients`, icon: "clients" as IconName },
    { label: "Cross-client overlaps", value: stats.duplicatesDetected, note: "Reused across client databases", icon: "quality" as IconName },
  ];
  const uniqueRate = stats.rowsImported ? Math.round((stats.prospects / stats.rowsImported) * 100) : 0;
  // formatShare, not Math.round: 5,384 of 724,991 is 0.74%, which rounds to
  // "1%" and reads as a rounding artefact rather than a real figure.
  const reuseShare = formatShare(stats.duplicatesDetected, stats.rowsImported);
  // Captured once per mount, before the effect below can set the flag, so every
  // figure in this render agrees about whether it is animating.
  const [countUp] = useState(() => !countsHavePlayed);
  // Only a render that actually had numbers counts as the animation having
  // happened. Stats arrive after the first paint, and marking it played against
  // a screen full of zeroes would spend the animation on nothing.
  const hasNumbers = stats.prospects > 0 || stats.companies > 0 || stats.rowsImported > 0;
  useEffect(() => { if (hasNumbers) countsHavePlayed = true; }, [hasNumbers]);
  return <>
    <div className="welcome"><div><p className="eyebrow">PEOPLE DATABASE</p><h2>All your prospects, organized in one place.</h2><p>Search the people database, review client coverage, or import a new list.</p></div><div className="welcome-actions"><button className="primary" onClick={onImport}><AppIcon name="upload" size={15}/> Import client list</button><button className="secondary" onClick={onViewMaster}>Open people database <AppIcon name="arrow" size={15}/></button></div></div>
    <div className={`metric-grid${countUp ? " counts-arriving" : ""}`}>{cards.map((card, index) => <article className="metric-card" key={card.label} style={{ "--stagger": index } as CSSProperties}><div className="metric-icon"><AppIcon name={card.icon} size={17}/></div><p>{card.label}</p><strong><CountUp value={card.value} enabled={countUp}/></strong><small>{card.note}</small></article>)}</div>
    <div className="dashboard-grid"><article className="panel"><div className="panel-head"><div><h3>Recent imports</h3><p>People and company files imported recently</p></div><button onClick={onImport}>Import CSV</button></div>{recentImports.length ? <div className="activity-list">{recentImports.map((item) => <div className="activity" key={`${item.kind}-${item.id}`}><span className="csv-icon">{item.kind === "companies" ? "CO" : "CSV"}</span><div><strong>{item.file_name}</strong><small>{item.kind === "companies" ? `Company database · ${item.data_source}` : `${item.client_name ?? "Unassigned"} · ${item.list_name ?? "Unassigned"} · ${item.data_source}`}</small></div><div className="activity-result"><strong>{formatNumber(item.processed_rows)} rows</strong><small>{item.kind === "companies" ? `${formatNumber(item.added_count)} added · ${formatNumber(item.updated_count)} updated · ${formatNumber(item.skipped_count)} skipped` : `${formatNumber(item.duplicates_linked)} cross-client overlaps`}</small></div><div className="activity-actions"><span className="status">Complete</span>{item.kind === "prospects" ? <button className="text-danger" onClick={() => onDeleteImport(item)}>Undo</button> : null}</div></div>)}</div> : <EmptyCompact text="Your completed imports will appear here." action="Import a CSV" onAction={onImport} />}</article>
      <article className={`panel coverage${countUp ? " counts-arriving" : ""}`}><div className="panel-head"><div><h3>Time and money saved</h3><p>See how often existing data was reused</p></div></div><div className="coverage-spotlight"><strong><CountUp value={stats.duplicatesDetected} enabled={countUp}/></strong><span>prospects you already owned, matched instead of scraped again</span></div><div className="coverage-row"><span>Rows processed</span><strong><CountUp value={stats.rowsImported} enabled={countUp}/></strong></div><div className="coverage-row"><span>Matched on import</span><strong>{reuseShare}</strong></div><div className="coverage-row"><span>Unique-record ratio</span><strong><CountUp value={uniqueRate} enabled={countUp}/>%</strong></div><div className="coverage-row"><span>Known companies</span><strong><CountUp value={stats.companies} enabled={countUp}/></strong></div><div className="coverage-track"><i style={{ "--fill": `${Math.min(100, uniqueRate)}%` } as CSSProperties}/></div><p className="coverage-note">{uniqueRate}% of every row you have ever imported became a distinct person. Each match on the rest is one prospect you did not pay for twice.</p><div className="client-mini"><span>Active client workspaces</span><div>{clients.slice(0, 4).map((client) => <i key={client.id}>{initials(client.name)}</i>)}{clients.length > 4 && <i>+{clients.length - 4}</i>}</div></div></article></div>
  </>;
}
