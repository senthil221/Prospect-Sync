import type { ReactNode } from "react";
import { formatNumber } from "../../lib/dashboard-helpers";
import { AppIcon } from "./DashboardUi";

// The ICP Validator's presentational pieces. Data in, callbacks out - no
// fetching - so the panel owns state and these stay easy to reason about (and
// to render with fixtures).

export type ValidatorSource = { source: string; kind: "reference" | "model"; total: number; fit: number; non_fit: number; stale: number; last_decided_at: string | null };
export type RunStatus = "queued" | "running" | "paused" | "completed" | "cancelled";
export type ValidatorRun = {
  id: string; model: string; reasoning_effort: string; scope: string; scope_detail: string; status: RunStatus; status_message: string;
  total_items: number; done_items: number; cached_items: number; fit_items: number; non_fit_items: number; failed_items: number;
  cost_usd: number; request_count: number; request_ms: number; created_by: string; created_at: string; started_at: string | null;
  finished_at: string | null; icp_current: boolean;
};
export type WorkerState = { configured: boolean; seen_at: string | null; alive: boolean };
export type Verdict = { verdict: "FIT" | "NON_FIT"; reason: string; current: boolean };
export type ResultRow = {
  company_id: string; name: string; domain: string; industry: string; short_description: string; keywords: string;
  verdicts: Record<string, Verdict | undefined>;
};

const num = (value: unknown) => { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; };
export const money = (value: number) => value >= 100 ? `$${Math.round(value).toLocaleString("en-US")}` : `$${value.toFixed(value < 1 ? 3 : 2)}`;
const pct = (part: number, whole: number) => whole > 0 ? Math.round((part / whole) * 100) : 0;

export function relativeTime(value: string | null, now = Date.now()) {
  if (!value) return "-";
  const then = new Date(value).getTime();
  if (Number.isNaN(then)) return "-";
  const minutes = Math.round((now - then) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return new Date(value).toLocaleDateString("en-IN", { day: "2-digit", month: "short" });
}

// "12m 30s", "1h 04m", "45s" - how long a run took, or has been running.
export function durationText(fromIso: string | null, toIso: string | null, now = Date.now()) {
  if (!fromIso) return "";
  const from = new Date(fromIso).getTime();
  const to = toIso ? new Date(toIso).getTime() : now;
  if (Number.isNaN(from) || Number.isNaN(to) || to < from) return "";
  const seconds = Math.round((to - from) / 1000);
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

export function Segmented<T extends string>({ label, value, options, onChange }: {
  label: string; value: T; options: Array<{ value: T; label: ReactNode; hint?: string }>; onChange: (value: T) => void;
}) {
  return <div className="icpx-segmented" role="radiogroup" aria-label={label}>
    {options.map((option) => <button key={option.value} type="button" role="radio" aria-checked={value === option.value}
      title={option.hint} className={value === option.value ? "is-on" : undefined} onClick={() => onChange(option.value)}>
      {option.label}
    </button>)}
  </div>;
}

export function Switch({ checked, onChange, label, hint }: { checked: boolean; onChange: (next: boolean) => void; label: string; hint?: string }) {
  return <label className="icpx-switch">
    <input type="checkbox" role="switch" checked={checked} onChange={(event) => onChange(event.target.checked)}/>
    <span className="icpx-switch-track" aria-hidden="true"><span/></span>
    <span className="icpx-switch-copy"><strong>{label}</strong>{hint ? <small>{hint}</small> : null}</span>
  </label>;
}

// FIT and NON_FIT as one bar: the share each model rejects is the thing to compare.
export function VerdictBar({ fit, nonFit, compact = false }: { fit: number; nonFit: number; compact?: boolean }) {
  const total = fit + nonFit;
  const fitShare = pct(fit, total);
  return <div className={`icpx-verdict-bar${compact ? " is-compact" : ""}`} role="img"
    aria-label={`${formatNumber(fit)} FIT, ${formatNumber(nonFit)} NON_FIT`}>
    <span className="is-fit" style={{ width: `${total ? fitShare : 0}%` }}/>
    <span className="is-non-fit" style={{ width: `${total ? 100 - fitShare : 0}%` }}/>
  </div>;
}

export function ProgressRing({ done, total, status }: { done: number; total: number; status: RunStatus }) {
  const share = total > 0 ? Math.min(1, done / total) : 0;
  const radius = 15;
  const circumference = 2 * Math.PI * radius;
  return <span className={`icpx-ring is-${status}`} aria-hidden="true">
    <svg viewBox="0 0 36 36" width="36" height="36">
      <circle cx="18" cy="18" r={radius} className="icpx-ring-track"/>
      <circle cx="18" cy="18" r={radius} className="icpx-ring-value" strokeDasharray={`${circumference * share} ${circumference}`}/>
    </svg>
    <b>{status === "completed" ? <AppIcon name="check" size={14}/> : `${Math.round(share * 100)}`}</b>
  </span>;
}

export function WorkerBadge({ worker }: { worker: WorkerState }) {
  const state = !worker.configured ? "needs-key" : worker.alive ? "live" : "offline";
  const text = state === "live" ? "Worker live" : state === "needs-key" ? "OpenRouter key missing" : "Worker offline";
  return <span className={`icpx-worker is-${state}`} title={worker.seen_at ? `Last heartbeat ${new Date(worker.seen_at).toLocaleString()}` : undefined}>
    <span className="icpx-pulse" aria-hidden="true"/>{text}
  </span>;
}

export function KpiStrip({ companyCount, sources, runs }: { companyCount: number; sources: ValidatorSource[]; runs: ValidatorRun[] }) {
  const models = sources.filter((source) => source.kind === "model");
  const covered = Math.max(0, ...models.map((source) => num(source.total)));
  const spend = runs.reduce((sum, run) => sum + num(run.cost_usd), 0);
  const active = runs.filter((run) => run.status === "queued" || run.status === "running");
  const activeDone = active.reduce((sum, run) => sum + num(run.done_items), 0);
  const activeTotal = active.reduce((sum, run) => sum + num(run.total_items), 0);
  const tiles: Array<{ label: string; value: string; detail: string; tone?: string }> = [
    { label: "Checkable companies", value: formatNumber(companyCount), detail: "with a description or keywords" },
    { label: "Checked", value: formatNumber(covered), detail: companyCount ? `${pct(covered, companyCount)}% coverage by the widest model` : "no companies yet" },
    { label: "Models compared", value: formatNumber(models.length), detail: models.length ? models.map((model) => model.source.split("/")[1] ?? model.source).slice(0, 3).join(" · ") : "run a check to start" },
    { label: active.length ? "In progress" : "Spend to date", value: active.length ? `${pct(activeDone, activeTotal)}%` : money(spend),
      detail: active.length ? `${formatNumber(activeDone)} of ${formatNumber(activeTotal)} across ${active.length} run${active.length === 1 ? "" : "s"}` : `${runs.length} run${runs.length === 1 ? "" : "s"} · reported by OpenRouter`,
      tone: active.length ? "live" : undefined },
  ];
  return <div className="icpx-kpis">{tiles.map((tile) => <div key={tile.label} className={`icpx-kpi${tile.tone ? ` is-${tile.tone}` : ""}`}>
    <span>{tile.label}</span><strong>{tile.value}</strong><small>{tile.detail}</small>
  </div>)}</div>;
}

export function ModelScoreboard({ sources, labelFor, onDelete }: {
  sources: ValidatorSource[]; labelFor: (source: string) => string; onDelete: (source: ValidatorSource) => void;
}) {
  if (!sources.length) return <div className="icpx-empty"><AppIcon name="target" size={22}/><div><strong>No verdicts yet</strong><p>Start a check below. Each model you pick judges the same companies, so their results line up here side by side.</p></div></div>;
  return <div className="icpx-scoreboard">{sources.map((source) => {
    const fit = num(source.fit), nonFit = num(source.non_fit), total = num(source.total), stale = num(source.stale);
    return <article key={source.source} className="icpx-model">
      <header>
        <div><strong>{labelFor(source.source)}</strong><code>{source.source}</code></div>
        <button type="button" className="icpx-icon-button" aria-label={`Delete ${labelFor(source.source)} verdicts`} title="Delete these verdicts" onClick={() => onDelete(source)}><AppIcon name="trash" size={15}/></button>
      </header>
      <div className="icpx-model-rate"><strong>{pct(nonFit, total)}%</strong><span>rejected as NON_FIT</span></div>
      <VerdictBar fit={fit} nonFit={nonFit}/>
      <dl>
        <div><dt><i className="is-fit"/>FIT</dt><dd>{formatNumber(fit)}</dd></div>
        <div><dt><i className="is-non-fit"/>NON_FIT</dt><dd>{formatNumber(nonFit)}</dd></div>
        <div><dt>Judged</dt><dd>{formatNumber(total)}</dd></div>
      </dl>
      <footer>{stale ? <span className="icpx-chip is-warn" title="Judged against an older version of the brief">{formatNumber(stale)} stale</span> : <span className="icpx-chip">Current brief</span>}
        <span>{relativeTime(source.last_decided_at)}</span></footer>
    </article>;
  })}</div>;
}

const statusText: Record<RunStatus, string> = { queued: "Queued", running: "Running", paused: "Paused", completed: "Done", cancelled: "Cancelled" };

function scopeText(run: ValidatorRun) {
  if (run.scope === "all") return "All companies";
  if (run.scope === "unchecked") return "Unchecked only";
  if (run.scope === "sample") return `Sample of ${formatNumber(num(run.total_items))}`;
  if (run.scope === "same_as") return "Same sample";
  if (run.scope === "selection") return "Company DB selection";
  if (run.scope === "reference") return "Reference set";
  return run.scope;
}

export function RunTimeline({ runs, labelFor, busyRun, onAction }: {
  runs: ValidatorRun[]; labelFor: (source: string) => string; busyRun: string;
  onAction: (run: ValidatorRun, action: "pause" | "resume" | "cancel" | "retry_failed") => void;
}) {
  if (!runs.length) return <div className="icpx-empty is-quiet"><AppIcon name="calendar" size={20}/><div><strong>No runs yet</strong><p>Runs appear here with live progress and cost.</p></div></div>;
  return <ol className="icpx-runs">{runs.map((run) => {
    const total = num(run.total_items), done = num(run.done_items), failed = num(run.failed_items), calls = num(run.request_count);
    const active = run.status === "queued" || run.status === "running";
    const busy = busyRun === run.id;
    // Completed and cancelled runs have a finish time; a paused one is shown
    // as time spent so far, a live one as running time.
    const took = durationText(run.started_at, run.finished_at);
    return <li key={run.id} className={`icpx-run is-${run.status}`}>
      <ProgressRing done={done} total={total} status={run.status}/>
      <div className="icpx-run-main">
        <div className="icpx-run-title"><strong>{labelFor(run.model)}</strong><span className={`icpx-status is-${run.status}`}>{statusText[run.status]}</span>
          {took ? <span className={`icpx-duration${active ? " is-live" : ""}`} title={run.finished_at ? `${new Date(run.started_at ?? run.created_at).toLocaleString()} → ${new Date(run.finished_at).toLocaleString()}` : undefined}>
            <AppIcon name="calendar" size={12}/>{run.finished_at ? `Took ${took}` : active ? `Running ${took}` : `${took} so far`}</span> : null}
          {!run.icp_current ? <span className="icpx-chip is-warn" title="The ICP brief changed after this run">older brief</span> : null}</div>
        <div className="icpx-run-meta">
          <span>{scopeText(run)}</span>
          <span>{formatNumber(done)} / {formatNumber(total)}{num(run.cached_items) ? ` · ${formatNumber(num(run.cached_items))} reused` : ""}</span>
          <span className="icpx-run-split"><i className="is-fit"/>{formatNumber(num(run.fit_items))}<i className="is-non-fit"/>{formatNumber(num(run.non_fit_items))}</span>
          {failed ? <span className="icpx-run-failed">{formatNumber(failed)} failed</span> : null}
          <span>{money(num(run.cost_usd))}</span>
          {calls ? <span>{(num(run.request_ms) / calls / 1000).toFixed(1)}s / call</span> : null}
          <span>effort {run.reasoning_effort}</span>
          <span title={run.created_by}>{relativeTime(run.started_at ?? run.created_at)}</span>
        </div>
        {run.status_message ? <p className="icpx-run-message" role="status"><AppIcon name="alert" size={14}/>{run.status_message}</p> : null}
      </div>
      <div className="icpx-run-actions">
        {active ? <button type="button" disabled={busy} onClick={() => onAction(run, "pause")}>Pause</button> : null}
        {run.status === "paused" ? <button type="button" className="is-primary" disabled={busy} onClick={() => onAction(run, "resume")}>Resume</button> : null}
        {run.status === "completed" && failed > 0 ? <button type="button" disabled={busy} onClick={() => onAction(run, "retry_failed")}>Retry failed</button> : null}
        {active || run.status === "paused" ? <button type="button" className="icpx-icon-button" aria-label={`Cancel ${labelFor(run.model)} run`} title="Cancel" disabled={busy} onClick={() => onAction(run, "cancel")}><AppIcon name="close" size={15}/></button> : null}
      </div>
    </li>;
  })}</ol>;
}

function initialsOf(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase() ?? "").join("") || "?";
}

export function ResultsTable({ rows, columns, labelFor }: { rows: ResultRow[]; columns: string[]; labelFor: (source: string) => string }) {
  return <div className="icpx-table-wrap"><table className="icpx-table">
    <thead><tr><th>Company</th>{columns.map((source) => <th key={source}>{labelFor(source)}</th>)}</tr></thead>
    <tbody>{rows.map((row) => {
      const verdicts = columns.map((source) => row.verdicts[source]?.verdict).filter(Boolean);
      const split = new Set(verdicts).size > 1;
      return <tr key={row.company_id} className={split ? "is-split" : undefined}>
        <td className="icpx-company">
          <span className="icpx-avatar" aria-hidden="true">{initialsOf(row.name)}</span>
          <div>
            <strong>{row.name}</strong>
            <small>{[row.domain, row.industry].filter(Boolean).join(" · ") || "-"}</small>
            {split ? <span className="icpx-chip is-warn">Models disagree</span> : null}
            {row.short_description || row.keywords ? <details>
              <summary>What the models read</summary>
              {row.short_description ? <p>{row.short_description}</p> : null}
              {row.keywords ? <p className="icpx-keywords">{row.keywords}</p> : null}
            </details> : null}
          </div>
        </td>
        {columns.map((source) => {
          const verdict = row.verdicts[source];
          return <td key={source} className="icpx-verdict-cell">{verdict ? <>
            <span className={`icpx-verdict ${verdict.verdict === "FIT" ? "is-fit" : "is-non-fit"}`}>{verdict.verdict === "FIT" ? "FIT" : "NON_FIT"}</span>
            {!verdict.current ? <span className="icpx-chip is-warn">stale</span> : null}
            {verdict.reason ? <p>{verdict.reason}</p> : null}
          </> : <span className="icpx-muted">Not checked</span>}</td>;
        })}
      </tr>;
    })}</tbody>
  </table></div>;
}
