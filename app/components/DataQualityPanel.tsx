"use client";

import { useCallback, useEffect, useState } from "react";
import { api, clearApiCache } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { DuplicateCandidate, EnrichmentPreview, IndexDrift, QualitySummary } from "../../lib/types";
import DuplicatesPanel from "./DuplicatesPanel";
import { EmptyCompact } from "./DashboardUi";
import { AppIcon } from "./DashboardUi";

export default function DataQualityPanel({ onMerged }: { onMerged: () => void }) {
  const [quality, setQuality] = useState<QualitySummary | null>(null);
  const [candidates, setCandidates] = useState<DuplicateCandidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [merging, setMerging] = useState("");
  const [drift, setDrift] = useState<IndexDrift | null>(null);
  const [draining, setDraining] = useState(false);
  const [driftNotice, setDriftNotice] = useState("");
  const [enrichment, setEnrichment] = useState<EnrichmentPreview | null>(null);
  const [enriching, setEnriching] = useState(false);
  const [enrichNotice, setEnrichNotice] = useState("");
  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [qualityData, duplicateData] = await Promise.all([api<{ quality: QualitySummary; drift: IndexDrift | null }>("/api/data-quality"), api<{ candidates: DuplicateCandidate[] }>("/api/duplicates")]);
      setQuality(qualityData.quality); setDrift(qualityData.drift ?? null); setCandidates(duplicateData.candidates); setError("");
      // Additive: a database one migration behind returns nothing here rather
      // than failing the whole page.
      try {
        const preview = await api<{ preview: EnrichmentPreview }>("/api/enrichment");
        setEnrichment(preview.preview);
      } catch { setEnrichment(null); }
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load data quality."); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { const timer = window.setTimeout(() => { void load(); }, 0); return () => window.clearTimeout(timer); }, [load]);
  async function merge(keepId: string, mergeId: string) {
    setMerging(`${keepId}:${mergeId}`);
    try { await api("/api/duplicates", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ keepId, mergeId }) }); await load(); onMerged(); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "Merge failed."); }
    finally { setMerging(""); }
  }
  async function drainBacklog() {
    setDraining(true);
    setDriftNotice("Re-indexing queued records…");
    try {
      const result = await api<{ processed: number; remaining: number }>("/api/data-quality", { method: "POST" });
      setDriftNotice(result.remaining
        ? `Re-indexed ${formatNumber(result.processed)} records · ${formatNumber(result.remaining)} still queued. Run again to continue.`
        : `Re-indexed ${formatNumber(result.processed)} records. The queue is empty.`);
      clearApiCache();
      await load();
    } catch (caught) { setDriftNotice(caught instanceof Error ? caught.message : "Unable to re-index queued records."); }
    finally { setDraining(false); }
  }

  // The search index is a denormalized copy maintained by every write path. If a
  // re-index ever fails it is queued rather than lost, but the gap has to be
  // visible - a stale index looks exactly like missing data.
  const indexGap = drift ? Math.max(0, Number(drift.prospects ?? 0) - Number(drift.indexed ?? 0)) : 0;
  // Stored company totals are maintained by a trigger on prospect_index, so
  // re-indexing is also what repairs them - which is why this belongs in the same
  // health panel and behind the same button rather than in a report of its own.
  const countsDrifted = Number(drift?.companyCountsDrifted ?? 0);
  const indexHealthy = drift ? !drift.queued && !indexGap && !drift.staleInIndex && !countsDrifted : true;

  async function fillGaps() {
    setEnriching(true);
    setEnrichNotice("Filling company gaps…");
    try {
      const data = await api<{ result: { companies: number } }>("/api/enrichment", { method: "POST" });
      setEnrichNotice(`Filled gaps on ${formatNumber(data.result.companies)} companies.`);
      clearApiCache();
      await load();
    } catch (caught) { setEnrichNotice(caught instanceof Error ? caught.message : "Unable to fill company gaps."); }
    finally { setEnriching(false); }
  }

  const issues = quality ? [
    ["Missing email", quality.missingEmail], ["Missing title", quality.missingTitle], ["Missing LinkedIn", quality.missingLinkedin], ["Missing company", quality.missingCompany], ["Missing domain", quality.missingDomain], ["Stale 180+ days", quality.staleRecords],
  ] as Array<[string, number]> : [];
  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">DATABASE HEALTH</p><h2>Data quality centre</h2><p>Review incomplete records and duplicate candidates found across different clients.</p></div><button className="secondary" onClick={() => { clearApiCache(); void load(); }}><AppIcon name="refresh" size={14}/> Refresh</button></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Analyzing master data…</div> : quality ? <>{drift ? <article className={`panel index-health ${indexHealthy ? "healthy" : "degraded"}`}><div className="index-health-head"><div><h3>Search index{indexHealthy ? " is up to date" : " needs attention"}</h3><p>{indexHealthy
      ? `All ${formatNumber(Number(drift.prospects ?? 0))} prospects are indexed and current.`
      : countsDrifted && !indexGap && !drift.staleInIndex && !drift.queued
        ? "Company prospect and client totals are stored rather than counted on every read. Some no longer match the underlying records, so those figures will read wrong until re-indexed."
        : "Filters and search read a denormalized copy of the database. These records are missing from it or out of date, so they may not appear in results until re-indexed."}</p></div>{indexHealthy ? <span className="index-health-badge ok"><AppIcon name="check" size={14}/> Healthy</span> : <button className="primary" disabled={draining} onClick={() => void drainBacklog()}>{draining ? "Re-indexing…" : "Re-index now"}</button>}</div>{indexHealthy ? null : <div className="index-health-metrics"><div><span>Queued for re-index</span><strong>{formatNumber(Number(drift.queued ?? 0))}</strong>{drift.queuedFailing ? <small>{formatNumber(Number(drift.queuedFailing))} retrying after an error</small> : null}</div><div><span>Missing from index</span><strong>{formatNumber(indexGap)}</strong><small>of {formatNumber(Number(drift.prospects ?? 0))} prospects</small></div><div><span>Out of date</span><strong>{formatNumber(Number(drift.staleInIndex ?? 0))}</strong><small>indexed before their last edit</small></div>{countsDrifted ? <div><span>Company counts drifted</span><strong>{formatNumber(countsDrifted)}</strong><small>in a sample of {formatNumber(Number(drift.companyCountsSampled ?? 0))} companies</small></div> : null}</div>}{driftNotice ? <p className="index-health-note" role="status">{driftNotice}</p> : null}</article> : null}{enrichment && enrichment.companies > 0 ? <article className="panel enrichment-panel"><div className="index-health-head"><div><h3>Fill gaps from company records</h3><p>{formatNumber(enrichment.fields)} empty fields across {formatNumber(enrichment.companies)} companies can be filled from other records that share the same website. Blanks only - a value that is already there is never overwritten, and person-level fields like title and email are never copied between people.</p></div><button className="primary" disabled={enriching} onClick={() => void fillGaps()}>{enriching ? "Filling…" : `Fill ${formatNumber(enrichment.fields)} fields`}</button></div>{enrichment.sample.length ? <div className="enrichment-sample">{enrichment.sample.slice(0, 8).map((item) => <span key={item.companyId} title={item.domain}><strong>{item.company || item.domain}</strong>{item.fields} field{item.fields === 1 ? "" : "s"}</span>)}{enrichment.companies > 8 ? <span className="enrichment-more">+{formatNumber(enrichment.companies - 8)} more</span> : null}</div> : null}{enrichNotice ? <p className="index-health-note" role="status">{enrichNotice}</p> : null}</article> : null}<div className="quality-metrics"><div><span>Master prospects</span><strong>{formatNumber(quality.total)}</strong></div>{issues.map(([label, value]) => <div key={label}><span>{label}</span><strong>{formatNumber(value)}</strong><small>{quality.total ? `${Math.round((value / quality.total) * 100)}% of database` : "0%"}</small></div>)}</div><article className="panel duplicate-panel"><div className="panel-head"><div><h3>Cross-client duplicate review</h3><p>{formatNumber(candidates.length)} candidate pairs require review</p></div></div>{candidates.length ? <div className="duplicate-list">{candidates.map((candidate) => <div className="duplicate-pair" key={`${candidate.left.id}-${candidate.right.id}`}><div className="duplicate-confidence"><strong>{candidate.confidence}%</strong><span>{candidate.reason}</span></div><DuplicatesPanel candidate={candidate}/><div className="duplicate-actions"><button disabled={Boolean(merging)} onClick={() => void merge(candidate.left.id, candidate.right.id)}>Keep left</button><span>or</span><button disabled={Boolean(merging)} onClick={() => void merge(candidate.right.id, candidate.left.id)}>Keep right</button></div></div>)}</div> : <EmptyCompact text="No cross-client duplicate groups need review." action="Refresh" onAction={() => { clearApiCache(); void load(); }} />}</article></> : null}</section>;
}
