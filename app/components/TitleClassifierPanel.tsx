"use client";

import { useCallback, useEffect, useState } from "react";
import { formatNumber, readImportTable } from "../../lib/dashboard-helpers";
import { keywordKindLabels, keywordKinds, keywordRowsFromTable, type KeywordKind, type KeywordRow } from "../../lib/title-keywords";

// The maintenance surface for the deterministic job title classifier.
//
// Two jobs, and they are the same loop: see which titles the keyword lists could
// not resolve (ranked by how many people each fix would cover, so the next keyword
// added is always the one that buys the most), then re-run the classifier over the
// backlog once those lists have changed. The lists themselves are downloaded,
// extended and uploaded here (20261008100000); an upload is checked first and only
// adds or updates keywords.
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

type KeywordCheck = {
  added: Array<{ keyword: string; value: string }>;
  changed: Array<{ keyword: string; value: string; was: string }>;
  unchanged: number;
  problems: Array<{ line: number; problem: string }>;
};

type PendingUpload = { kind: KeywordKind; fileName: string; rows: KeywordRow[]; check: KeywordCheck };

async function postKeywords(kind: KeywordKind, rows: KeywordRow[], apply: boolean) {
  const response = await fetch("/api/prospects/title-keywords", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ kind, rows, apply }) });
  const data = await response.json() as KeywordCheck & { error?: string };
  if (!response.ok) throw new Error(data.error || "The keyword list could not be checked.");
  return data;
}

// Each POST commits one checkpoint and reports whether more is waiting; keep
// re-posting so a backlog of any size finishes from one click.
const maxReruns = 5000;

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
  const [upload, setUpload] = useState<PendingUpload | null>(null);
  const [uploading, setUploading] = useState(false);

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
    let completed = false;
    try {
      for (let run = 0; run < maxReruns; run += 1) {
        const response = await fetch("/api/prospects/classify", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) });
        const data = await response.json() as { reclassified?: number; remaining?: boolean; remainingCount?: number; error?: string };
        if (!response.ok) throw new Error(data.error || "The classifier run failed.");
        total += Number(data.reclassified ?? 0);
        setProgress(`Re-classified ${formatNumber(total)} prospects${data.remainingCount ? ` · ${formatNumber(data.remainingCount)} remaining` : ""}…`);
        if (!data.remaining) { completed = true; break; }
      }
      if (!completed) throw new Error("The classifier reached its safety limit before the backlog was empty. Run it again to resume.");
      setProgress(total ? `Done - ${formatNumber(total)} prospects re-classified.` : "Done - every prospect was already classified against the current keyword lists.");
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
      setCopied("Copying is blocked in this browser - select the column instead.");
    }
  }

  async function pickKeywordFile(kind: KeywordKind, input: HTMLInputElement) {
    const file = input.files?.[0];
    input.value = "";
    if (!file) return;
    setUploading(true); setError(""); setProgress(""); setUpload(null);
    try {
      const table = await readImportTable(file);
      const rows = keywordRowsFromTable(kind, table.headers, table.rows);
      if (!rows.length) throw new Error("The file has no keyword rows.");
      setUpload({ kind, fileName: file.name, rows, check: await postKeywords(kind, rows, false) });
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "The keyword list could not be read.");
    } finally {
      setUploading(false);
    }
  }

  // Saves the checked upload, then re-runs the classifier so people pick it up.
  async function applyUpload() {
    if (!upload) return;
    setUploading(true); setError("");
    let saved: KeywordCheck;
    try {
      saved = await postKeywords(upload.kind, upload.rows, true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "The keyword list could not be saved.");
      setUploading(false);
      return;
    }
    setUpload(null);
    setUploading(false);
    setCopied(`Saved ${formatNumber(saved.added.length)} new and ${formatNumber(saved.changed.length)} changed keywords in the ${keywordKindLabels[upload.kind].toLowerCase()} list.`);
    await reclassify();
  }

  const covered = gaps.reduce((sum, gap) => sum + gap.occurrences, 0);

  return <article className="panel title-classifier">
    <div className="classifier-head">
      <div>
        <strong>Undefined job titles</strong>
        <p>Titles the keyword lists could not fully resolve, biggest first. Download the seniority or department list below, add keywords for these titles, and upload it; the classifier re-runs after you save. A title only counts as missing a department when a keyword could give it one. Top management (Founder, Director, CEO), titles that are only a rank (Manager, Assistant Manager, VP, AGM) and things that are not titles (Pvt Ltd, Contact) are left out: they name no department.</p>
      </div>
      <div className="classifier-actions">
        <label><span className="sr-only">Which side is missing</span><select value={missing} disabled={running} onChange={(event) => { setLoading(true); setMissing(event.target.value as MissingOption); }}>{missingOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <button className="outline-button" disabled={loading || running} onClick={reload}>↻ Refresh</button>
        <button className="outline-button" disabled={!gaps.length || running} onClick={() => void copyTitles()}>⧉ Copy titles</button>
        {/* Every unresolved title for the chosen filter, not just the 200 shown. */}
        <a className="outline-button" href={`/api/prospects/classify/export?missing=${missing}`} download aria-disabled={running} onClick={(event) => { if (running) event.preventDefault(); }}>⤓ Export all</a>
        <button className="primary" disabled={running} onClick={() => void reclassify()}>{running ? "Re-classifying…" : "Re-run classifier"}</button>
      </div>
    </div>

    <div className="classifier-summary">
      <div><strong>{formatNumber(gaps.length)}</strong><span>Distinct titles unresolved</span></div>
      <div><strong>{formatNumber(covered)}</strong><span>People they cover</span></div>
      <div><strong>{gaps.length ? formatNumber(gaps[0].occurrences) : "-"}</strong><span>People the top fix covers</span></div>
    </div>

    <div className="keyword-lists">
      <strong>Keyword lists</strong>
      <span>Download a list, add rows in the same columns, and upload it. Keywords you leave out are kept: an upload only adds or updates. Top management uses both of its lists: a title with an include keyword is top management unless a longer exclude phrase covers it.</span>
      <div className="keyword-list-grid">
        {keywordKinds.map((kind) => <div key={kind} className="keyword-list-row">
          <span>{keywordKindLabels[kind]}</span>
          <a className="outline-button" href={`/api/prospects/title-keywords?kind=${kind}`} download>⤓ Download</a>
          <label className={`outline-button keyword-upload ${uploading || running ? "disabled" : ""}`}><input type="file" accept=".csv,.xlsx,text/csv" aria-label={`Upload the ${keywordKindLabels[kind].toLowerCase()} list`} disabled={uploading || running} onChange={(event) => void pickKeywordFile(kind, event.currentTarget)}/>⤒ Upload</label>
        </div>)}
      </div>
      {uploading && !upload ? <p className="source-selected-note" role="status">Checking the keyword list…</p> : null}
      {upload ? <div className="keyword-check" role="region" aria-label="Keyword list check">
        <p><strong>{upload.fileName}</strong> ({keywordKindLabels[upload.kind].toLowerCase()} list): {formatNumber(upload.check.added.length)} new, {formatNumber(upload.check.changed.length)} changed, {formatNumber(upload.check.unchanged)} unchanged{upload.check.problems.length ? <>, <span className="keyword-problem-count">{formatNumber(upload.check.problems.length)} rows skipped</span></> : null}.</p>
        {upload.check.changed.length ? <ul>{upload.check.changed.slice(0, 20).map((row) => <li key={row.keyword}><code>{row.keyword}</code>: {row.was} → {row.value}</li>)}{upload.check.changed.length > 20 ? <li>…and {formatNumber(upload.check.changed.length - 20)} more changes</li> : null}</ul> : null}
        {upload.check.problems.length ? <ul className="keyword-problems">{upload.check.problems.slice(0, 20).map((row) => <li key={row.line}>Row {row.line}: {row.problem}</li>)}{upload.check.problems.length > 20 ? <li>…and {formatNumber(upload.check.problems.length - 20)} more</li> : null}</ul> : null}
        <div className="classifier-actions">
          <button className="primary" disabled={uploading || running || !(upload.check.added.length + upload.check.changed.length)} onClick={() => void applyUpload()}>{uploading ? "Saving…" : `Save ${formatNumber(upload.check.added.length + upload.check.changed.length)} keywords and re-run`}</button>
          <button className="outline-button" disabled={uploading} onClick={() => setUpload(null)}>Cancel</button>
        </div>
      </div> : null}
    </div>

    {progress ? <p className="source-selected-note" role="status">{progress}</p> : null}
    {copied ? <p className="source-selected-note" role="status">{copied}</p> : null}
    {error ? <p className="form-error" role="alert">{error}</p> : null}

    {loading ? <p className="classifier-empty">Loading the undefined log…</p>
      : gaps.length ? <div className="master-table-wrap"><table className="master-data-table"><thead><tr><th>Job title</th><th>Normalized</th><th>People</th><th>Missing</th></tr></thead><tbody>{gaps.map((gap) => <tr key={gap.normalizedTitle}><td><span title={gap.sampleTitle}>{gap.sampleTitle}</span></td><td><code>{gap.normalizedTitle}</code></td><td>{formatNumber(gap.occurrences)}</td><td><span className={`classifier-missing ${gap.missingSeniority && gap.missingDepartment ? "both" : ""}`}>{gapLabel(gap)}</span></td></tr>)}</tbody></table></div>
        : <p className="classifier-empty">Nothing unresolved for this filter - every job title resolved to both a seniority tier and a department.</p>}
  </article>;
}
