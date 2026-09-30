"use client";

import { useCallback, useEffect, useState } from "react";
import { AppIcon } from "./DashboardUi";
import { Segmented, durationText, relativeTime } from "./IcpValidatorViews";

// Email verification, watched: is MailTester being called right now, how fast,
// how long until the queue is empty, what the results look like, and every
// run's progress. Data from /api/verifications/dashboard, polled while open.
// Controls reuse the existing routes: runs for anyone, dispatch for admins.

export type EvProvider = {
  enabled: boolean; manually_paused: boolean; pause_reason: string | null; cooldown_until: string | null; quota_wait_until: string | null;
  daily_limit: number; daily_attempts: number; worker_configured: boolean; worker_alive: boolean; worker_seen_at: string | null;
  consecutive_failures: number; now: string;
};
export type EvRun = {
  id: string; source: string; scope: string; status: string; priority: number; force_reverify: boolean; max_emails: number | null;
  total_count: number; processed_count: number; reused_count: number; skipped_count: number; error_count: number; cancelled_count: number;
  eligible_email_count: number | null; selected_email_count: number | null; snapshot_complete: boolean; last_error: string | null;
  created_at: string; started_at: string | null; completed_at: string | null; filter_count: number;
};
export type EvDashboard = {
  provider: EvProvider | null;
  queue: Record<string, number> | null;
  results: Record<string, number>;
  results_24h: Record<string, number>;
  throughput: { last_10m: number; last_60m: number; hourly: Array<{ hour: string; checks: number }> };
  runs: EvRun[];
};

const outcomes = [
  { key: "valid", label: "Valid", tone: "valid", hint: "Mailbox exists and accepts mail - safe to send." },
  { key: "catch_all", label: "Catch-all", tone: "catch", hint: "Domain accepts everything - the mailbox cannot be confirmed." },
  { key: "invalid", label: "Invalid", tone: "invalid", hint: "Mailbox does not exist - do not send." },
  { key: "unverifiable", label: "Unverifiable", tone: "unknown", hint: "The mail server would not give a clear answer." },
] as const;

const n = (value: unknown) => { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; };
const fmt = (value: number) => new Intl.NumberFormat("en-IN").format(Math.round(value));
const pct = (part: number, whole: number) => whole > 0 ? (part / whole) * 100 : 0;

export function etaText(minutes: number) {
  if (!Number.isFinite(minutes) || minutes <= 0) return "";
  if (minutes < 60) return `~${Math.max(1, Math.round(minutes))} min`;
  const hours = minutes / 60;
  if (hours < 48) return `~${Math.floor(hours)}h ${String(Math.round(minutes % 60)).padStart(2, "0")}m`;
  return `~${Math.floor(hours / 24)}d ${Math.round(hours % 24)}h`;
}

// One sentence for "what is it doing right now", worst condition first.
export function dispatchState(provider: EvProvider | null, queued: number) {
  const now = provider ? new Date(provider.now).getTime() : Date.now();
  const future = (value: string | null) => Boolean(value && new Date(value).getTime() > now);
  if (!provider) return { tone: "off", label: "Status unavailable", detail: "" };
  if (!provider.worker_configured) return { tone: "warn", label: "MailTester key missing", detail: "The verification worker has no provider key." };
  if (!provider.worker_alive) return { tone: "bad", label: "Worker offline", detail: provider.worker_seen_at ? `Last heartbeat ${relativeTime(provider.worker_seen_at)}.` : "" };
  if (!provider.enabled) return { tone: "off", label: "Dispatch is off", detail: "An admin has to start provider dispatch." };
  if (provider.manually_paused) return { tone: "warn", label: "Paused", detail: provider.pause_reason ?? "Paused by an admin." };
  if (future(provider.cooldown_until)) return { tone: "warn", label: "Cooling down", detail: `${provider.pause_reason ?? "Provider cooldown"} - resumes ${new Date(provider.cooldown_until as string).toLocaleTimeString()}.` };
  if (future(provider.quota_wait_until)) return { tone: "warn", label: "Waiting for quota", detail: `Daily limit reached - resumes ${new Date(provider.quota_wait_until as string).toLocaleString()}.` };
  if (queued > 0) return { tone: "live", label: "Verifying", detail: "" };
  return { tone: "idle", label: "Idle", detail: "The queue is empty." };
}

export function EvHero({ data, isAdmin, busy, onProvider }: {
  data: EvDashboard; isAdmin: boolean; busy: string; onProvider: (action: "start" | "pause" | "continue" | "stop") => void;
}) {
  const queued = n(data.queue?.queued) + n(data.queue?.running);
  const rate = n(data.throughput.last_10m) / 10;
  const state = dispatchState(data.provider, queued);
  const eta = state.tone === "live" && rate > 0 ? etaText(queued / rate) : "";
  const provider = data.provider;
  return <header className="icpx-hero evx-hero">
    <div className="icpx-hero-copy">
      <p className="icpx-eyebrow"><AppIcon name="check" size={14}/> Email verification</p>
      <h3>{queued ? <>{fmt(queued)} emails in the queue{eta ? <span className="evx-eta"> · done in {eta}</span> : null}</> : "Every queued email has been checked"}</h3>
      {state.detail ? <p>{state.detail}</p> : null}
    </div>
    <div className="icpx-hero-side">
      <span className={`evx-state is-${state.tone}`}><span className="icpx-pulse" aria-hidden="true"/>{state.label}</span>
      {isAdmin && provider ? <div className="evx-controls" role="group" aria-label="Provider dispatch">
        {!provider.enabled ? <button type="button" className="icpx-primary" disabled={!!busy} onClick={() => onProvider("start")}>Start dispatch</button>
          : provider.manually_paused ? <button type="button" className="icpx-primary" disabled={!!busy} onClick={() => onProvider("continue")}>Continue</button>
            : <button type="button" className="icpx-ghost" disabled={!!busy} onClick={() => onProvider("pause")}>Pause dispatch</button>}
        {provider.enabled ? <button type="button" className="icpx-ghost evx-stop" disabled={!!busy} onClick={() => onProvider("stop")}>Stop</button> : null}
      </div> : null}
    </div>
  </header>;
}

export function EvKpis({ data }: { data: EvDashboard }) {
  const rate = n(data.throughput.last_10m) / 10;
  const completed = n(data.queue?.completed);
  const queued = n(data.queue?.queued) + n(data.queue?.running);
  const used = n(data.provider?.daily_attempts);
  const limit = n(data.provider?.daily_limit);
  const valid = n(data.results.valid);
  return <div className="icpx-kpis">
    <div className="icpx-kpi is-live"><span>Speed now</span><strong>{fmt(rate)}<small className="evx-unit">/min</small></strong><small>last 10 minutes</small></div>
    <div className="icpx-kpi"><span>Verified</span><strong>{fmt(completed)}</strong><small>{Math.round(pct(valid, completed))}% valid</small></div>
    <div className="icpx-kpi"><span>Today&apos;s quota</span><strong>{Math.round(pct(used, limit))}%</strong>
      <span className="evx-meter" aria-label={`${fmt(used)} of ${fmt(limit)} checks used in the last 24 hours`}><i style={{ width: `${Math.min(100, pct(used, limit))}%` }}/></span>
      <small>{fmt(used)} of {fmt(limit)} daily</small></div>
    <div className="icpx-kpi"><span>In the queue</span><strong>{fmt(queued)}</strong><small>{n(data.queue?.error) ? `${fmt(n(data.queue?.error))} failed` : "waiting"}</small></div>
  </div>;
}

function Donut({ values }: { values: Array<{ tone: string; value: number }> }) {
  const total = values.reduce((sum, item) => sum + item.value, 0);
  const radius = 42;
  const circumference = 2 * Math.PI * radius;
  let offset = 0;
  return <svg className="evx-donut" viewBox="0 0 100 100" role="img" aria-label="Result mix">
    <circle cx="50" cy="50" r={radius} className="evx-donut-track"/>
    {total ? values.map((item) => {
      const length = (item.value / total) * circumference;
      const segment = <circle key={item.tone} cx="50" cy="50" r={radius} className={`evx-donut-seg is-${item.tone}`}
        strokeDasharray={`${Math.max(0, length - 1.2)} ${circumference}`} strokeDashoffset={-offset}/>;
      offset += length;
      return segment;
    }) : null}
  </svg>;
}

export function EvResults({ data }: { data: EvDashboard }) {
  const [period, setPeriod] = useState<"all" | "24h">("all");
  const source = period === "all" ? data.results : data.results_24h;
  const total = outcomes.reduce((sum, outcome) => sum + n(source[outcome.key]), 0);
  const valid = n(source.valid);
  return <section className="icpx-card evx-results" aria-labelledby="evx-results-title">
    <div className="icpx-section-head"><div><h4 id="evx-results-title">Email status</h4></div>
      <Segmented<"all" | "24h"> label="Period" value={period} onChange={setPeriod} options={[{ value: "all", label: "All time" }, { value: "24h", label: "Last 24h" }]}/></div>
    <div className="evx-results-body">
      <div className="evx-donut-wrap">
        <Donut values={outcomes.map((outcome) => ({ tone: outcome.tone, value: n(source[outcome.key]) }))}/>
        <div className="evx-donut-center"><strong>{total ? `${Math.round(pct(valid, total))}%` : "-"}</strong><span>valid</span></div>
      </div>
      <ul className="evx-legend">{outcomes.map((outcome) => {
        const value = n(source[outcome.key]);
        return <li key={outcome.key} title={outcome.hint}>
          <i className={`is-${outcome.tone}`} aria-hidden="true"/>
          <span><strong>{outcome.label}</strong></span>
          <b>{fmt(value)}</b><em>{total ? `${pct(value, total).toFixed(1)}%` : "-"}</em>
        </li>;
      })}</ul>
    </div>
  </section>;
}

export function EvThroughput({ data }: { data: EvDashboard }) {
  const hours = data.throughput.hourly ?? [];
  const max = Math.max(1, ...hours.map((hour) => n(hour.checks)));
  return <section className="icpx-card evx-throughput" aria-labelledby="evx-throughput-title">
    <div className="icpx-section-head"><div><h4 id="evx-throughput-title">Checks per hour</h4></div><span className="evx-peak">peak {fmt(max)}/h</span></div>
    <div className="evx-bars" role="img" aria-label={`Checks per hour for the last 24 hours, peak ${fmt(max)}`}>
      {hours.map((hour, index) => {
        const value = n(hour.checks);
        const label = new Date(hour.hour).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" });
        return <div key={hour.hour} className={`evx-bar${index === hours.length - 1 ? " is-now" : ""}`} title={`${label} - ${fmt(value)} checks`}>
          <i style={{ height: `${Math.max(value ? 3 : 0, (value / max) * 100)}%` }}/>
          {index % 6 === 0 || index === hours.length - 1 ? <span>{index === hours.length - 1 ? "now" : label}</span> : null}
        </div>;
      })}
    </div>
  </section>;
}

const runStatusText: Record<string, string> = {
  preparing: "Preparing", running: "Running", paused: "Paused", completed: "Done", completed_with_errors: "Done with errors", cancelled: "Cancelled", failed: "Failed",
};

function runTitle(run: EvRun) {
  if (run.source === "import") return "Imported list";
  if (run.scope === "all") return "All prospects";
  const size = n(run.selected_email_count) || n(run.total_count);
  return `Filtered selection${size ? ` · ${fmt(size)} emails` : ""}`;
}

export function EvRuns({ runs, busy, onRun }: { runs: EvRun[]; busy: string; onRun: (run: EvRun, action: "pause" | "continue" | "cancel") => void }) {
  if (!runs.length) return <div className="icpx-empty is-quiet"><AppIcon name="check" size={20}/><div><strong>No verification runs yet</strong><p>Start one from the People database with Verify emails.</p></div></div>;
  return <ol className="icpx-runs evx-runs">{runs.map((run) => {
    const total = n(run.total_count), done = n(run.processed_count), share = total ? Math.min(1, done / total) : 0;
    const active = run.status === "running" || run.status === "preparing";
    const radius = 15, circumference = 2 * Math.PI * radius;
    const took = durationText(run.started_at, run.completed_at);
    const ringTone = run.status === "completed" ? "completed" : run.status === "paused" ? "paused" : run.status === "cancelled" || run.status === "failed" ? "cancelled" : run.status === "completed_with_errors" ? "paused" : "running";
    return <li key={run.id} className={`icpx-run is-${run.status}`}>
      <span className={`icpx-ring is-${ringTone}`} aria-hidden="true">
        <svg viewBox="0 0 36 36" width="36" height="36"><circle cx="18" cy="18" r={radius} className="icpx-ring-track"/><circle cx="18" cy="18" r={radius} className="icpx-ring-value" strokeDasharray={`${circumference * share} ${circumference}`}/></svg>
        <b>{run.status === "completed" ? <AppIcon name="check" size={14}/> : Math.floor(share * 100)}</b>
      </span>
      <div className="icpx-run-main">
        <div className="icpx-run-title"><strong>{runTitle(run)}</strong>
          <span className={`icpx-status is-${run.status === "completed" ? "completed" : run.status === "running" ? "running" : run.status === "paused" || run.status === "completed_with_errors" ? "paused" : "queued"}`}>{runStatusText[run.status] ?? run.status}</span>
          {took ? <span className={`icpx-duration${active ? " is-live" : ""}`}><AppIcon name="calendar" size={12}/>{run.completed_at ? `Took ${took}` : active ? `Running ${took}` : `${took} so far`}</span> : null}
        </div>
        <div className="evx-run-bar" aria-hidden="true"><i style={{ width: `${share * 100}%` }}/></div>
        <div className="icpx-run-meta">
          <span><b>{fmt(done)}</b> of {fmt(total)} people</span>
          {n(run.error_count) ? <span className="icpx-run-failed">{fmt(n(run.error_count))} errors</span> : null}
          <span>started {relativeTime(run.started_at ?? run.created_at)}</span>
        </div>
        {run.last_error ? <p className="icpx-run-message"><AppIcon name="alert" size={14}/>{run.last_error}</p> : null}
      </div>
      <div className="icpx-run-actions">
        {run.status === "running" ? <button type="button" disabled={busy === run.id} onClick={() => onRun(run, "pause")}>Pause</button> : null}
        {run.status === "paused" ? <button type="button" className="is-primary" disabled={busy === run.id} onClick={() => onRun(run, "continue")}>Continue</button> : null}
        {active || run.status === "paused" ? <button type="button" className="icpx-icon-button" aria-label="Cancel this run" title="Cancel" disabled={busy === run.id} onClick={() => onRun(run, "cancel")}><AppIcon name="close" size={15}/></button> : null}
      </div>
    </li>;
  })}</ol>;
}

async function post(path: string, body: unknown) {
  const response = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((result as { error?: string }).error ?? "That did not work.");
  return result;
}

export default function EmailVerificationWorkspace({ isAdmin }: { isAdmin: boolean }) {
  const [data, setData] = useState<EvDashboard | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState("");
  const [tick, setTick] = useState(0);

  const load = useCallback(async (signal?: AbortSignal) => {
    const response = await fetch("/api/verifications/dashboard", { cache: "no-store", signal });
    const body = await response.json();
    if (!response.ok) throw new Error(body.error ?? "Verification status is unavailable.");
    setData(body as EvDashboard);
    setError("");
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      load(controller.signal).catch((caught) => { if (!controller.signal.aborted) setError(caught instanceof Error ? caught.message : "Verification status is unavailable."); });
    }, 0);
    return () => { window.clearTimeout(timer); controller.abort(); };
  }, [load, tick]);

  // Live while open: every 10 seconds, paused when the tab is hidden.
  useEffect(() => {
    const timer = window.setInterval(() => { if (document.visibilityState === "visible") setTick((value) => value + 1); }, 10_000);
    return () => window.clearInterval(timer);
  }, []);

  async function act(key: string, path: string, body: unknown, message: string) {
    setBusy(key); setNotice(""); setError("");
    try { await post(path, body); setNotice(message); setTick((value) => value + 1); }
    catch (caught) { setError(caught instanceof Error ? caught.message : "That did not work."); }
    finally { setBusy(""); }
  }

  return <article className="icpx evx">
    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {notice ? <div className="icpx-notice" role="status"><AppIcon name="check" size={15}/><span>{notice}</span><button type="button" aria-label="Dismiss" onClick={() => setNotice("")}><AppIcon name="close" size={14}/></button></div> : null}
    {!data ? (error ? null : <div className="icpx-skeleton" aria-busy="true"><span/><span/><span/></div>) : <>
      <EvHero data={data} isAdmin={isAdmin} busy={busy}
        onProvider={(action) => void act("provider", "/api/verifications/provider", { action }, action === "pause" ? "Dispatch paused. Calls in flight finish; nothing new starts." : action === "stop" ? "Dispatch stopped." : "Dispatch is running.")}/>
      <EvKpis data={data}/>
      <div className="evx-grid">
        <EvResults data={data}/>
        <EvThroughput data={data}/>
      </div>
      <section className="icpx-card" aria-labelledby="evx-runs-title">
        <div className="icpx-section-head"><div><h4 id="evx-runs-title">Runs</h4></div></div>
        <EvRuns runs={data.runs} busy={busy} onRun={(run, action) => void act(run.id, `/api/verifications/${run.id}`, { action },
          action === "pause" ? "Run paused." : action === "continue" ? "Run continued." : "Run cancelled.")}/>
      </section>
    </>}
  </article>;
}
