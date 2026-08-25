"use client";

import { useCallback, useEffect, useState } from "react";
import { formatNumber } from "../../lib/dashboard-helpers";

// The maintenance surface for the deterministic job title classifier.
//
// Two jobs, and they are the same loop: see which titles the keyword lists could
// not resolve (ranked by how many people each fix would cover, so the next edit to
// data/seniority_map.csv or data/department_map.csv is always the one that buys the
// most), then re-run the classifier over the backlog once those lists have changed.
//
// Classification happens automatically on every write, so re-running is only needed
// after a keyword list changes or for rows imported before the classifier existed.

type Gap = {
  normalizedTitle: string;
  sampleTitle: string;
  occurrences: number;
  missingSeniority: boolean;
  missingDepartment: boolean;
};

const missingOptions = [
  ["any", "Missing either"],
  ["both", "Missing both"],
  ["seniority", "Missing seniority"],
  ["department", "Missing department"],
] as const;

type MissingOption = (typeof missingOptions)[number][0];

// The route caps a single POST at 20 batches of 500 and reports whether more is
// waiting; keep re-posting so a backlog of any size finishes from one click.
const maxReruns = 200;

function gapLabel(gap: Gap) {
  if (gap.missingSeniority && gap.missingDepartment) return "Seniority + department";
  return gap.missingSeniority ? "Seniority" : "Department";
}

export default function TitleClassifierPanel({ onGapCount }: { onGapCount?: (count: number) => void }) {
  const [missing, setMissing] = useState<MissingOption>("any");
  const [gaps, setGaps] = useState<Gap[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState("");
  const [copied, setCopied] = useState("");

  // Reloads are requested by bumping `reloadKey`, and whoever bumps it turns
  // `loading` on. The fetch itself stays inside the effect so nothing writes state
  // before the request resolves.
  const [reloadKey, setReloadKey] = useState(0);
  const reload = useCallback(() => { setLoading(true); setReloadKey((current) => current + 1); }, []);

  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    void (async () => {
      try {
        // Deliberately not the cached api() helper: this list is what you watch
        // while editing the keyword lists, so a stale five-minute copy would lie.
        const response = await fetch(`/api/prospects/classify?limit=200&missing=${missing}`, { signal: controller.signal, cache: "no-store" });
        const data = await response.json() as { gaps?: Gap[]; error?: string };
        if (!current) return;
        if (!response.ok) throw new Error(data.error || "Unable to load the undefined titles.");
        const next = data.gaps ?? [];
        setGaps(next);
        setError("");
        onGapCount?.(next.length);
      } catch (caught) {
        if (!current) return;
        setGaps([]);
        onGapCount?.(0);
        setError(caught instanceof Error ? caught.message : "Unable to load the undefined titles.");
      } finally {
        if (current) setLoading(false);
      }
    })();
    return () => { current = false; controller.abort(); };
  }, [missing, onGapCount, reloadKey]);

  async function reclassify() {
    setRunning(true); setError(""); setProgress("Re-classifying…");
    let total = 0;
    try {
      for (let run = 0; run < maxReruns; run += 1) {
        const response = await fetch("/api/prospects/classify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) });
        const data = await response.json() as { reclassified?: number; remaining?: boolean; error?: string };
        if (!response.ok) throw new Error(data.error || "The classifier run failed.");
        total += Number(data.reclassified ?? 0);
        setProgress(`Re-classified ${formatNumber(total)} prospects…`);
        if (!data.remaining) break;
      }
      setProgress(total ? `Done — ${formatNumber(total)} prospects re-classified.` : "Done — every prospect was already classified against the current keyword lists.");
      reload();
    } catch (caught) {
      setProgress("");
      setError(caught instanceof Error ? caught.message : "The classifier run failed.");
    } finally {
      setRunning(false);
    }
  }

  async function copyTitles() {
    try {
      await navigator.clipboard.writeText(gaps.map((gap) => gap.sampleTitle).join("\n"));
      setCopied(`Copied ${formatNumber(gaps.length)} titles.`);
    } catch {
      setCopied("Copying is blocked in this browser — select the column instead.");
    }
  }

  const covered = gaps.reduce((sum, gap) => sum + gap.occurrences, 0);

  return <article className="panel title-classifier">
    <div className="classifier-head">
      <div>
        <strong>Undefined job titles</strong>
        <p>Titles the keyword lists could not fully resolve, biggest first. Add the missing words to <code>data/seniority_map.csv</code> or <code>data/department_map.csv</code>, then re-run. Plenty of real titles name only one side — a “Director” or “Founder” has a seniority and no department — so <strong>Missing both</strong> is the list actually worth working through.</p>
      </div>
      <div className="classifier-actions">
        <label><span className="sr-only">Which side is missing</span><select value={missing} disabled={running} onChange={(event) => { setLoading(true); setMissing(event.target.value as MissingOption); }}>{missingOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <button className="outline-button" disabled={loading || running} onClick={reload}>↻ Refresh</button>
        <button className="outline-button" disabled={!gaps.length || running} onClick={() => void copyTitles()}>⧉ Copy titles</button>
        <button className="primary" disabled={running} onClick={() => void reclassify()}>{running ? "Re-classifying…" : "Re-run classifier"}</button>
      </div>
    </div>

    <div className="classifier-summary">
      <div><strong>{formatNumber(gaps.length)}</strong><span>Distinct titles unresolved</span></div>
      <div><strong>{formatNumber(covered)}</strong><span>People they cover</span></div>
      <div><strong>{gaps.length ? formatNumber(gaps[0].occurrences) : "—"}</strong><span>People the top fix covers</span></div>
    </div>

    {progress ? <p className="source-selected-note" role="status">{progress}</p> : null}
    {copied ? <p className="source-selected-note" role="status">{copied}</p> : null}
    {error ? <p className="form-error" role="alert">{error}</p> : null}

    {loading ? <p className="classifier-empty">Loading the undefined log…</p>
      : gaps.length ? <div className="master-table-wrap"><table className="master-data-table"><thead><tr><th>Job title</th><th>Normalized</th><th>People</th><th>Missing</th></tr></thead><tbody>{gaps.map((gap) => <tr key={gap.normalizedTitle}><td><span title={gap.sampleTitle}>{gap.sampleTitle}</span></td><td><code>{gap.normalizedTitle}</code></td><td>{formatNumber(gap.occurrences)}</td><td><span className={`classifier-missing ${gap.missingSeniority && gap.missingDepartment ? "both" : ""}`}>{gapLabel(gap)}</span></td></tr>)}</tbody></table></div>
        : <p className="classifier-empty">Nothing unresolved for this filter — every job title resolved to both a seniority tier and a department.</p>}
  </article>;
}
