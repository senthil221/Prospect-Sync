"use client";

import { useCallback, useEffect, useState } from "react";
import { api, clearApiCache } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { DuplicateCandidate, QualitySummary } from "../../lib/types";
import DuplicatesPanel from "./DuplicatesPanel";
import { EmptyCompact } from "./DashboardUi";

export default function DataQualityPanel({ onMerged }: { onMerged: () => void }) {
  const [quality, setQuality] = useState<QualitySummary | null>(null);
  const [candidates, setCandidates] = useState<DuplicateCandidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [merging, setMerging] = useState("");
  const load = useCallback(async () => {
    setLoading(true);
    try {
      const [qualityData, duplicateData] = await Promise.all([api<{ quality: QualitySummary }>("/api/data-quality"), api<{ candidates: DuplicateCandidate[] }>("/api/duplicates")]);
      setQuality(qualityData.quality); setCandidates(duplicateData.candidates); setError("");
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
  const issues = quality ? [
    ["Missing email", quality.missingEmail], ["Missing title", quality.missingTitle], ["Missing LinkedIn", quality.missingLinkedin], ["Missing company", quality.missingCompany], ["Missing domain", quality.missingDomain], ["Stale 180+ days", quality.staleRecords],
  ] as Array<[string, number]> : [];
  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">DATABASE HEALTH</p><h2>Data quality centre</h2><p>Review incomplete records and duplicate candidates found across different clients.</p></div><button className="secondary" onClick={() => { clearApiCache(); void load(); }}>↻ Refresh</button></div>{error ? <div className="inline-error" role="alert">{error}</div> : null}{loading ? <div className="workspace-loading">Analyzing master data…</div> : quality ? <><div className="quality-metrics"><div><span>Master prospects</span><strong>{formatNumber(quality.total)}</strong></div>{issues.map(([label, value]) => <div key={label}><span>{label}</span><strong>{formatNumber(value)}</strong><small>{quality.total ? `${Math.round((value / quality.total) * 100)}% of database` : "0%"}</small></div>)}</div><article className="panel duplicate-panel"><div className="panel-head"><div><h3>Cross-client duplicate review</h3><p>{formatNumber(candidates.length)} candidate pairs require review</p></div></div>{candidates.length ? <div className="duplicate-list">{candidates.map((candidate) => <div className="duplicate-pair" key={`${candidate.left.id}-${candidate.right.id}`}><div className="duplicate-confidence"><strong>{candidate.confidence}%</strong><span>{candidate.reason}</span></div><DuplicatesPanel candidate={candidate}/><div className="duplicate-actions"><button disabled={Boolean(merging)} onClick={() => void merge(candidate.left.id, candidate.right.id)}>Keep left</button><span>or</span><button disabled={Boolean(merging)} onClick={() => void merge(candidate.right.id, candidate.left.id)}>Keep right</button></div></div>)}</div> : <EmptyCompact text="No cross-client duplicate groups need review." action="Refresh" onAction={() => { clearApiCache(); void load(); }} />}</article></> : null}</section>;
}
