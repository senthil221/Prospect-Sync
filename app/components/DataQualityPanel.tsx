"use client";

import { useCallback, useEffect, useState } from "react";
import { api, clearApiCache } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { describeMerge, describeProspect } from "../../lib/duplicate-compare";
import { qualityIssues, severityLabel } from "../../lib/quality-issues";
import type { DuplicateCandidate, EnrichmentPreview, IndexDrift, Prospect, QualitySummary } from "../../lib/types";
import DuplicatesPanel from "./DuplicatesPanel";
import { AppIcon, ConfirmDialog, EmptyCompact, StatusMessage } from "./DashboardUi";

type PendingMerge = { key: string; keep: Prospect; remove: Prospect };
type RowState = { status: "busy" | "done" | "error"; message?: string };

const pairKey = (candidate: DuplicateCandidate) => `${candidate.left.id}:${candidate.right.id}`;

export default function DataQualityPanel({ onMerged }: { onMerged: () => void }) {
  const [quality, setQuality] = useState<QualitySummary | null>(null);
  const [candidates, setCandidates] = useState<DuplicateCandidate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [drift, setDrift] = useState<IndexDrift | null>(null);
  const [draining, setDraining] = useState(false);
  const [driftNotice, setDriftNotice] = useState("");
  const [enrichment, setEnrichment] = useState<EnrichmentPreview | null>(null);
  const [enriching, setEnriching] = useState(false);
  const [enrichNotice, setEnrichNotice] = useState("");
  const [showAffected, setShowAffected] = useState(false);
  // QUALITY-05: state per pair, not one global "merging" string. A failure on
  // one row used to blank out the whole panel's error slot and leave every
  // other row looking untouched.
  const [rowStates, setRowStates] = useState<Record<string, RowState>>({});
  const [skipped, setSkipped] = useState<string[]>([]);
  const [pending, setPending] = useState<PendingMerge | null>(null);

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

  async function confirmMerge() {
    if (!pending) return;
    const { key, keep, remove } = pending;
    setRowStates((current) => ({ ...current, [key]: { status: "busy" } }));
    try {
      await api("/api/duplicates", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ keepId: keep.id, mergeId: remove.id }) });
      setPending(null);
      setRowStates((current) => ({ ...current, [key]: { status: "done", message: `Merged into ${describeProspect(keep)}.` } }));
      await load();
      onMerged();
    } catch (caught) {
      // QUALITY-AC-04: the pair stays on screen and both buttons stay live.
      setPending(null);
      setRowStates((current) => ({ ...current, [key]: { status: "error", message: caught instanceof Error ? caught.message : "The merge failed. Both records are unchanged." } }));
    }
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

  const issues = quality ? qualityIssues(quality) : [];
  const openIssues = issues.filter((issue) => issue.severity !== "clear");
  const clearIssues = issues.filter((issue) => issue.severity === "clear");
  const reviewable = candidates.filter((candidate) => !skipped.includes(pairKey(candidate)));

  return <section className="operations-page">
    <div className="section-intro compact-intro">
      <div><p className="eyebrow">DATABASE HEALTH</p><h2>Data quality centre</h2><p>Review incomplete records and duplicate candidates found across different clients.</p></div>
      <button className="secondary" onClick={() => { clearApiCache(); setSkipped([]); setRowStates({}); void load(); }}><AppIcon name="refresh" size={14}/> Refresh</button>
    </div>
    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {loading ? <div className="workspace-loading">Analyzing master data…</div> : quality ? <>
      {drift ? <article className={`panel index-health ${indexHealthy ? "healthy" : "degraded"}`}>
        <div className="index-health-head">
          <div><h3>Search index{indexHealthy ? " is up to date" : " needs attention"}</h3><p>{indexHealthy
            ? `All ${formatNumber(Number(drift.prospects ?? 0))} prospects are indexed and current.`
            : countsDrifted && !indexGap && !drift.staleInIndex && !drift.queued
              ? "Company prospect and client totals are stored rather than counted on every read. Some no longer match the underlying records, so those figures will read wrong until re-indexed."
              : "Filters and search read a denormalized copy of the database. These records are missing from it or out of date, so they may not appear in results until re-indexed."}</p></div>
          {indexHealthy ? <span className="index-health-badge ok"><AppIcon name="check" size={14}/> Healthy</span> : <button className="primary" disabled={draining} onClick={() => void drainBacklog()}>{draining ? "Re-indexing…" : "Re-index now"}</button>}
        </div>
        {indexHealthy ? null : <div className="index-health-metrics">
          <div><span>Queued for re-index</span><strong>{formatNumber(Number(drift.queued ?? 0))}</strong>{drift.queuedFailing ? <small>{formatNumber(Number(drift.queuedFailing))} retrying after an error</small> : null}</div>
          <div><span>Missing from index</span><strong>{formatNumber(indexGap)}</strong><small>of {formatNumber(Number(drift.prospects ?? 0))} prospects</small></div>
          <div><span>Out of date</span><strong>{formatNumber(Number(drift.staleInIndex ?? 0))}</strong><small>indexed before their last edit</small></div>
          {countsDrifted ? <div><span>Company counts drifted</span><strong>{formatNumber(countsDrifted)}</strong><small>in a sample of {formatNumber(Number(drift.companyCountsSampled ?? 0))} companies</small></div> : null}
        </div>}
        {driftNotice ? <p className="index-health-note" role="status">{driftNotice}</p> : null}
      </article> : null}

      {enrichment && enrichment.companies > 0 ? <article className="panel enrichment-panel">
        <div className="index-health-head">
          <div><h3>Fill gaps from company records</h3><p>{formatNumber(enrichment.fields)} empty fields across {formatNumber(enrichment.companies)} companies can be filled from other records that share the same website. Blanks only - a value that is already there is never overwritten, and person-level fields like title and email are never copied between people.</p></div>
          <button className="primary" disabled={enriching} onClick={() => void fillGaps()}>{enriching ? "Filling…" : `Fill ${formatNumber(enrichment.fields)} fields`}</button>
        </div>
        {/* QUALITY-02: eight company chips were the loudest thing in the panel
            and the least useful - a sample tells you nothing you act on. */}
        {enrichment.sample.length ? <>
          <button type="button" className="link-button" aria-expanded={showAffected} onClick={() => setShowAffected((open) => !open)}>
            {showAffected ? "Hide affected companies" : `View affected companies (${formatNumber(enrichment.companies)})`}
          </button>
          {showAffected ? <div className="enrichment-sample">
            {enrichment.sample.slice(0, 8).map((item) => <span key={item.companyId} title={item.domain}><strong>{item.company || item.domain}</strong>{item.fields} field{item.fields === 1 ? "" : "s"}</span>)}
            {enrichment.companies > 8 ? <span className="enrichment-more">+{formatNumber(enrichment.companies - 8)} more</span> : null}
          </div> : null}
        </> : null}
        {enrichNotice ? <p className="index-health-note" role="status">{enrichNotice}</p> : null}
      </article> : null}

      {/* QUALITY-01: the six counts, ranked by what they cost, with the master
          total kept alongside rather than as a seventh identical tile. */}
      <article className="panel quality-queue">
        <div className="panel-head">
          <div>
            <h3>Record quality</h3>
            <p>{openIssues.length ? `${openIssues.length} of ${issues.length} checks need work` : "Every check is clear"} · {formatNumber(quality.total)} master prospects</p>
          </div>
        </div>
        {openIssues.length ? <ul className="quality-issue-list">
          {openIssues.map((issue) => <li key={issue.id} className={`quality-issue ${issue.severity}`}>
            <span className={`quality-severity ${issue.severity}`}>{severityLabel(issue.severity)}</span>
            <div className="quality-issue-body">
              <strong>{issue.label}</strong>
              <p>{issue.impact}</p>
              <p className="quality-issue-action"><AppIcon name="arrow" size={12}/> {issue.action}</p>
            </div>
            <div className="quality-issue-count">
              <strong>{formatNumber(issue.count)}</strong>
              {/* QUALITY-03: 412 records are not "0% of database". */}
              <small>{issue.shareText} of database</small>
            </div>
          </li>)}
        </ul> : null}
        {clearIssues.length ? <p className="quality-clear">Clear: {clearIssues.map((issue) => issue.label.toLowerCase()).join(", ")}.</p> : null}
      </article>

      <article className="panel duplicate-panel">
        <div className="panel-head"><div>
          <h3>Cross-client duplicate review</h3>
          <p>{formatNumber(reviewable.length)} candidate pair{reviewable.length === 1 ? "" : "s"} require review{skipped.length ? ` · ${skipped.length} skipped this session` : ""}</p>
        </div></div>
        {reviewable.length ? <ul className="duplicate-list">{reviewable.map((candidate) => {
          const key = pairKey(candidate);
          const state = rowStates[key];
          const busy = state?.status === "busy";
          return <li className="duplicate-pair" key={key}>
            <div className="duplicate-pair-head">
              <div className="duplicate-confidence"><strong>{candidate.confidence}%</strong><span>{candidate.reason}</span></div>
              {/* QUALITY-05: the label names the record, so it stays true
                  whichever order the API returned the pair in. */}
              <div className="duplicate-actions">
                <button disabled={busy} onClick={() => setPending({ key, keep: candidate.left, remove: candidate.right })}>Keep {describeProspect(candidate.left)}</button>
                <button disabled={busy} onClick={() => setPending({ key, keep: candidate.right, remove: candidate.left })}>Keep {describeProspect(candidate.right)}</button>
                <button className="ghost" disabled={busy} onClick={() => setSkipped((current) => [...current, key])}>Skip</button>
              </div>
            </div>
            <DuplicatesPanel candidate={candidate}/>
            {busy ? <StatusMessage>Merging…</StatusMessage> : null}
            {state?.status === "done" ? <StatusMessage>{state.message}</StatusMessage> : null}
            {state?.status === "error" ? <StatusMessage tone="alert">{state.message} Both records are unchanged — choose again to retry.</StatusMessage> : null}
          </li>;
        })}</ul> : <EmptyCompact
          text={skipped.length ? "Every remaining pair was skipped this session." : "No cross-client duplicate groups need review."}
          action="Refresh"
          onAction={() => { clearApiCache(); setSkipped([]); void load(); }}
        />}
      </article>
    </> : null}

    {pending ? <ConfirmDialog
      title={`Keep ${describeProspect(pending.keep)}?`}
      body={describeMerge(pending.keep, pending.remove)}
      scopeNote="Merging cannot be undone from here. Nothing is deleted from any client workspace - the lists and client links on the merged record move to the one you keep."
      confirmLabel="Merge records"
      busy={rowStates[pending.key]?.status === "busy"}
      onCancel={() => setPending(null)}
      onConfirm={() => void confirmMerge()}
    /> : null}
  </section>;
}
