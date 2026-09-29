"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { ClientIcpProfile, ClientRecord } from "../../lib/types";
import { ICP_MODELS, estimateRunCost, sourceLabel } from "../../worker/icp-validator-core.mjs";
import { AppIcon, ConfirmDialog, EmptyCompact } from "./DashboardUi";

// The ICP validator: an LLM (run by the ICP worker, never in the browser)
// labels each of a client's companies FIT or NON_FIT against one ICP brief.
// Verdicts are labels only - nothing is hidden or deleted. Verdicts produced
// elsewhere can be compared by exporting the results as CSV, and up to three
// models can be run over the same companies.
//
// One screen, sections stacked: overview -> launch -> runs -> results.
// Each section owns its own form state; the panel owns the
// overview (sources, runs, worker health) and re-fetches it while a run is
// active. Results are keyed by the ICP they were fetched for,
// so switching ICP never shows another brief's numbers.

type Source = { source: string; kind: "reference" | "model"; total: number; fit: number; non_fit: number; stale: number; last_decided_at: string | null };
type RunStatus = "queued" | "running" | "paused" | "completed" | "cancelled";
type Run = {
  id: string; model: string; reasoning_effort: string; scope: string; scope_detail: string; status: RunStatus; status_message: string;
  total_items: number; done_items: number; cached_items: number; fit_items: number; non_fit_items: number; failed_items: number;
  cost_usd: number; prompt_tokens: number; completion_tokens: number; request_count: number; request_ms: number;
  bake_off_id: string | null; created_by: string; created_at: string; started_at: string | null; finished_at: string | null; icp_current: boolean;
};
type Overview = {
  profile: { id: string; name: string; icp_hash: string; description_length: number; company_count: number };
  sources: Source[];
  runs: Run[];
  worker: { configured: boolean; seen_at: string | null; alive: boolean };
};
type OverviewResponse = { overview: Overview; models: { id: string; label: string }[]; efforts: string[] };
type Verdict = { verdict: "FIT" | "NON_FIT"; reason: string; current: boolean };
type ResultRow = { company_id: string; name: string; domain: string; industry: string; short_description: string; keywords: string; verdicts: Record<string, Verdict | undefined> };
type StartScope = "all" | "unchecked" | "sample";

const pageSize = 100;
const maxSources = 8;
const activeStatuses: RunStatus[] = ["queued", "running"];
const filterOptions = [
  { value: "all", label: "All companies" },
  { value: "disagree", label: "Disagreements" },
  { value: "non_fit", label: "Any NON_FIT" },
  { value: "fit", label: "All FIT" },
] as const;

const num = (value: unknown) => { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; };
const percent = (part: number, whole: number) => whole > 0 ? `${(Math.round((part / whole) * 1000) / 10).toLocaleString("en-IN")}%` : "-";
const money = (value: number) => value >= 100 ? `$${Math.round(value).toLocaleString("en-US")}` : `$${value.toFixed(value < 1 ? 3 : 2)}`;
const failure = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback;
const modelLabel = (id: string) => sourceLabel(id) as string;

function whenText(value: string | null) {
  if (!value) return "-";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "-" : date.toLocaleString("en-IN", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
}

function scopeText(run: Run) {
  const detail = run.scope_detail.replace(/^reference:/, "");
  if (run.scope === "all") return "All companies";
  if (run.scope === "unchecked") return "Companies without a current verdict";
  if (run.scope === "reference") return `Companies judged by ${sourceLabel(`reference:${detail}`)}`;
  if (run.scope === "sample") return `Random sample of ${formatNumber(num(run.total_items))}`;
  if (run.scope === "same_as") return "Same sample as the first model";
  return run.scope;
}

function statusClass(status: RunStatus) {
  if (status === "completed") return "green";
  if (status === "running") return "icpv-running";
  if (status === "paused") return "icpv-warn";
  return "";
}

function VerdictPill({ verdict }: { verdict: "FIT" | "NON_FIT" }) {
  return <span className={`data-pill ${verdict === "FIT" ? "green" : "icpv-bad"}`}>{verdict === "FIT" ? "FIT" : "NON_FIT"}</span>;
}

export default function IcpValidatorPanel({ client }: { client: ClientRecord }) {
  const base = `/api/clients/${encodeURIComponent(client.id)}/icp-validator`;
  const [profiles, setProfiles] = useState<ClientIcpProfile[]>([]);
  const [profilesLoading, setProfilesLoading] = useState(true);
  const [profilesError, setProfilesError] = useState("");
  const [chosenIcp, setChosenIcp] = useState("");
  const [loaded, setLoaded] = useState<OverviewResponse | null>(null);
  const [overviewError, setOverviewError] = useState("");
  const [version, setVersion] = useState(0);
  const [notice, setNotice] = useState("");
  const [pendingDelete, setPendingDelete] = useState<Source | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState("");

  const usable = useMemo(() => profiles.filter((profile) => profile.description.trim()), [profiles]);
  const icpId = usable.some((profile) => profile.id === chosenIcp) ? chosenIcp : usable[0]?.id ?? "";
  const profile = profiles.find((item) => item.id === icpId) ?? null;

  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ profiles: ClientIcpProfile[] }>(`/api/clients/${encodeURIComponent(client.id)}/icp`, { cache: "no-store" })
        .then((result) => { if (!cancelled) { setProfiles(result.profiles); setProfilesError(""); } })
        .catch((caught) => { if (!cancelled) setProfilesError(failure(caught, "Unable to load ICPs.")); })
        .finally(() => { if (!cancelled) setProfilesLoading(false); });
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [client.id]);

  const loadOverview = useCallback(async (silent: boolean) => {
    if (!icpId) return;
    try {
      const result = await api<OverviewResponse>(`${base}?icp=${encodeURIComponent(icpId)}`, { cache: "no-store" });
      setLoaded(result);
      setOverviewError("");
    } catch (caught) {
      // A background refresh that fails keeps the last good data on screen.
      if (!silent) setOverviewError(failure(caught, "Unable to load the ICP validator."));
    }
  }, [base, icpId]);

  useEffect(() => {
    const timer = window.setTimeout(() => { void loadOverview(false); }, 0);
    return () => window.clearTimeout(timer);
  }, [loadOverview, version]);

  // Only data fetched for the ICP on screen is shown.
  const current = loaded && loaded.overview.profile.id === icpId ? loaded : null;
  const overview = current?.overview ?? null;
  const hasActive = Boolean(overview?.runs.some((run) => activeStatuses.includes(run.status)));

  useEffect(() => {
    if (!hasActive) return;
    const timer = window.setInterval(() => { void loadOverview(true); }, 4000);
    return () => window.clearInterval(timer);
  }, [hasActive, loadOverview]);

  // Changes whenever a run stops moving, so the comparison and the results
  // refresh once a run finishes without refetching on every progress tick.
  const settledSignature = (overview?.runs ?? []).filter((run) => !activeStatuses.includes(run.status)).map((run) => `${run.id}:${run.status}:${run.done_items}`).join("|");

  function changed(message?: string) {
    if (message) setNotice(message);
    setVersion((value) => value + 1);
  }

  async function confirmDelete() {
    if (!pendingDelete || !icpId) return;
    setDeleting(true); setDeleteError("");
    try {
      const result = await api<{ deleted: number }>(base, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "delete_source", icpId, source: pendingDelete.source }),
      });
      setNotice(`Deleted ${formatNumber(num(result.deleted))} verdicts from ${modelLabel(pendingDelete.source)}.`);
      setPendingDelete(null);
      changed();
    } catch (caught) { setDeleteError(failure(caught, "Unable to delete those verdicts.")); }
    finally { setDeleting(false); }
  }

  return <article className="panel client-icp-panel icpv-panel">
    <div className="panel-head">
      <div>
        <p className="eyebrow">ICP VALIDATOR</p>
        <h3>Check companies against an ICP</h3>
        <p>An AI model reads each company&apos;s description and keywords and labels it FIT or NON_FIT. Labels only &mdash; nothing is hidden or removed.</p>
      </div>
      <div className="icpv-picker">
        <div className="form-field">
          <label htmlFor="icpv-icp">ICP to check against</label>
          <select id="icpv-icp" value={icpId} disabled={!usable.length} onChange={(event) => { setChosenIcp(event.target.value); setNotice(""); }}>
            {profiles.map((item) => {
              const empty = !item.description.trim();
              return <option key={item.id} value={item.id} disabled={empty}>{(item.name.trim() || "Untitled ICP") + (empty ? " - add a brief on the ICPs tab" : "")}</option>;
            })}
          </select>
        </div>
        <span className="icpv-count">{formatNumber(client.company_count ?? 0)} companies in {client.name}</span>
      </div>
    </div>

    {profilesError ? <div className="inline-error" role="alert">{profilesError}</div> : null}
    {overviewError ? <div className="inline-error" role="alert">{overviewError}</div> : null}
    {notice ? <div className="inline-notice" role="status">{notice}</div> : null}

    {profilesLoading ? <div className="workspace-loading">Loading ICPs…</div>
      : !usable.length ? <EmptyCompact text={profiles.length ? "None of this client's ICPs has a brief yet. Add one on the ICPs tab to validate against it." : `No ICPs are recorded for ${client.name} yet. Add one on the ICPs tab.`} />
        : !overview || !profile ? (overviewError ? null : <div className="workspace-loading">Loading the validator…</div>)
          : <div className="icpv-body">
            {!overview.worker.configured
              ? <div className="icpv-banner" role="status">The ICP worker has no OpenRouter key yet. Checks will queue and start once OPENROUTER_API_KEY is set on the server.</div>
              : !overview.worker.alive
                ? <div className="icpv-banner" role="status">The ICP worker has not reported in the last 2 minutes.</div>
                : null}

            <SourcesSection sources={overview.sources} onDelete={(source) => { setDeleteError(""); setPendingDelete(source); }} />
            <LauncherSection base={base} icpId={icpId} overview={overview} efforts={current?.efforts ?? []} onStarted={(message) => changed(message)} />
            <RunsSection base={base} runs={overview.runs} onChanged={() => changed()} onNotice={setNotice} />
            <ResultsSection base={base} icpId={icpId} sources={overview.sources} refresh={`${version}|${settledSignature}`} />
          </div>}

    {pendingDelete ? <ConfirmDialog
      title={`Delete ${modelLabel(pendingDelete.source)} verdicts?`}
      body={`This removes all ${formatNumber(num(pendingDelete.total))} verdicts from ${modelLabel(pendingDelete.source)} for this ICP. Companies themselves are not touched, and the check can be run again.`}
      error={deleteError} confirmLabel="Delete verdicts" busy={deleting}
      onCancel={() => { setPendingDelete(null); setDeleteError(""); }} onConfirm={() => void confirmDelete()} /> : null}
  </article>;
}

function SourcesSection({ sources, onDelete }: { sources: Source[]; onDelete: (source: Source) => void }) {
  return <section className="icpv-section" aria-labelledby="icpv-sources-title">
    <h4 id="icpv-sources-title">Verdicts so far</h4>
    {sources.length ? <div className="table-wrap"><table>
      <thead><tr><th>Source</th><th>Companies</th><th>FIT</th><th>NON_FIT</th><th>Stale</th><th>Last decided</th><th><span className="icpv-sr">Actions</span></th></tr></thead>
      <tbody>{sources.map((source) => {
        const total = num(source.total);
        return <tr key={source.source}>
          <td><strong>{modelLabel(source.source)}</strong><small className="icpv-sub">{source.kind === "reference" ? "Imported reference" : source.source}</small></td>
          <td>{formatNumber(total)}</td>
          <td>{formatNumber(num(source.fit))}</td>
          <td>{formatNumber(num(source.non_fit))} <small className="icpv-sub">{percent(num(source.non_fit), total)}</small></td>
          <td>{num(source.stale) ? <span className="data-pill icpv-warn" title="Judged against an older version of the brief">{formatNumber(num(source.stale))} stale</span> : <span className="icpv-muted">0</span>}</td>
          <td>{whenText(source.last_decided_at)}</td>
          <td><button type="button" className="row-danger" aria-label={`Delete ${modelLabel(source.source)} verdicts`} onClick={() => onDelete(source)}>Delete</button></td>
        </tr>;
      })}</tbody>
    </table></div> : <EmptyCompact text="No verdicts yet. Start a run below." />}
    {sources.some((source) => num(source.stale)) ? <p className="icpv-note">Stale means judged against an older version of the brief. Re-run the model, or turn off reuse, to refresh those verdicts.</p> : null}
  </section>;
}

function LauncherSection({ base, icpId, overview, efforts, onStarted }: {
  base: string; icpId: string; overview: Overview; efforts: string[]; onStarted: (message: string) => void;
}) {
  const [models, setModels] = useState<string[]>(() => ICP_MODELS.map((model) => model.id));
  const [effort, setEffort] = useState("low");
  const [scope, setScope] = useState<StartScope>("all");
  const [sample, setSample] = useState("200");
  const [reuse, setReuse] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const companyCount = num(overview.profile.company_count);
  const sampleSize = Math.floor(Number(sample));
  const sampleValid = Number.isFinite(sampleSize) && sampleSize >= 1 && sampleSize <= 5000;
  const scopeCount = scope === "sample" ? (sampleValid ? sampleSize : 0)
    : companyCount;
  const estimate = models.reduce((sum, model) => sum + (estimateRunCost(model, scopeCount, { effort, briefLength: overview.profile.description_length }) ?? 0), 0);
  const effortOptions = efforts.length ? efforts : ["minimal", "low", "medium", "high"];
  const canStart = models.length > 0 && !busy && (scope !== "sample" || sampleValid);

  function toggleModel(id: string) {
    setModels((currentModels) => currentModels.includes(id) ? currentModels.filter((item) => item !== id) : [...currentModels, id]);
  }

  async function start() {
    setBusy(true); setError("");
    try {
      const response = await api<{ runs: unknown[]; error?: string }>(base, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "start", icpId, models, effort, scope,
          scopeDetail: "",
          sampleSize: scope === "sample" ? sampleSize : undefined, reuse,
        }),
      });
      const started = response.runs?.length ?? 0;
      if (response.error) setError(response.error);
      onStarted(`Started ${started} run${started === 1 ? "" : "s"}. Progress appears below.`);
    } catch (caught) { setError(failure(caught, "Unable to start the check.")); }
    finally { setBusy(false); }
  }

  return <section className="icpv-section" aria-labelledby="icpv-launch-title">
    <h4 id="icpv-launch-title">Run a check</h4>
    <div className="icpv-grid">
      <fieldset className="icpv-fieldset">
        <legend>Models (up to three, run on the same companies)</legend>
        {ICP_MODELS.map((model) => <label key={model.id} className="icpv-check">
          <input type="checkbox" checked={models.includes(model.id)} onChange={() => toggleModel(model.id)} />
          <span className="icpv-strong">{model.label} <small className="icpv-sub">{model.id}</small></span>
        </label>)}
      </fieldset>
      <div className="form-field">
        <label htmlFor="icpv-effort">Reasoning effort</label>
        <select id="icpv-effort" value={effort} onChange={(event) => setEffort(event.target.value)}>
          {effortOptions.map((value) => <option key={value} value={value}>{value}</option>)}
        </select>
        <small className="icpv-note">Higher effort reads more carefully but costs more and runs slower.</small>
      </div>
    </div>

    <fieldset className="icpv-fieldset">
      <legend>Which companies</legend>
      <label className="icpv-check"><input type="radio" name="icpv-scope" checked={scope === "all"} onChange={() => setScope("all")} /> <span>All {formatNumber(companyCount)} companies</span></label>
      <label className="icpv-check"><input type="radio" name="icpv-scope" checked={scope === "unchecked"} onChange={() => setScope("unchecked")} /> <span>Only companies without a current verdict from the chosen model(s)</span></label>
      <label className="icpv-check"><input type="radio" name="icpv-scope" checked={scope === "sample"} onChange={() => setScope("sample")} />
        <span>Random sample of</span>
        <input className="icpv-number" type="number" min={1} max={5000} aria-label="Sample size" value={sample} disabled={scope !== "sample"} onChange={(event) => setSample(event.target.value)} />
        <span>companies</span>
      </label>
      {scope === "sample" && models.length > 1 ? <small className="icpv-note">Every selected model gets the same sample.</small> : null}
      {scope === "sample" && !sampleValid ? <small className="form-error" role="alert">A sample is between 1 and 5,000 companies.</small> : null}
    </fieldset>

    <label className="icpv-check"><input type="checkbox" checked={reuse} onChange={(event) => setReuse(event.target.checked)} /> Reuse earlier verdicts from the same model for this exact brief</label>

    <div className="icpv-actions">
      <button type="button" className="primary" disabled={!canStart} onClick={() => void start()}>{busy ? "Starting…" : models.length > 1 ? `Start ${models.length} checks` : "Start check"}</button>
      <span className="icpv-estimate" role="status">{models.length && scopeCount ? `≈ ${money(estimate)} (estimate)` : "Choose a model and companies for an estimate."}</span>
    </div>
    {error ? <p className="form-error" role="alert">{error}</p> : null}
  </section>;
}

function RunsSection({ base, runs, onChanged, onNotice }: { base: string; runs: Run[]; onChanged: () => void; onNotice: (message: string) => void }) {
  const [busyRun, setBusyRun] = useState("");
  const [error, setError] = useState("");

  async function act(run: Run, action: "pause" | "resume" | "cancel" | "retry_failed") {
    setBusyRun(run.id); setError("");
    try {
      await api(base, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, runId: run.id }) });
      onNotice(action === "retry_failed" ? `Retrying failed companies for ${modelLabel(run.model)}.` : `${modelLabel(run.model)} run ${action === "pause" ? "paused" : action === "resume" ? "resumed" : "cancelled"}.`);
      onChanged();
    } catch (caught) { setError(failure(caught, "Unable to change that run.")); }
    finally { setBusyRun(""); }
  }

  return <section className="icpv-section" aria-labelledby="icpv-runs-title">
    <h4 id="icpv-runs-title">Runs</h4>
    {error ? <div className="inline-error" role="alert">{error}</div> : null}
    {runs.length ? <div className="table-wrap"><table>
      <thead><tr><th>Model</th><th>Companies</th><th>Status</th><th>Progress</th><th>FIT / NON_FIT</th><th>Failed</th><th>Cost</th><th>Avg call</th><th>Started</th><th><span className="icpv-sr">Actions</span></th></tr></thead>
      <tbody>{runs.map((run) => {
        const total = num(run.total_items), done = num(run.done_items), failed = num(run.failed_items), calls = num(run.request_count);
        const active = run.status === "queued" || run.status === "running";
        return [
          <tr key={run.id} className={run.status_message ? "icpv-has-message" : undefined}>
            <td><strong>{modelLabel(run.model)}</strong><small className="icpv-sub">effort {run.reasoning_effort}</small></td>
            <td>{scopeText(run)}{!run.icp_current ? <small className="icpv-sub icpv-stale">stale brief - the ICP changed after this run</small> : null}</td>
            <td><span className={`data-pill ${statusClass(run.status)}`}>{run.status}</span></td>
            <td><progress className="icpv-progress" max={Math.max(total, 1)} value={Math.min(done, Math.max(total, 1))} aria-label={`${modelLabel(run.model)} progress`} />
              <small className="icpv-sub">{formatNumber(done)} / {formatNumber(total)}{num(run.cached_items) ? ` (${formatNumber(num(run.cached_items))} reused)` : ""}</small></td>
            <td>{formatNumber(num(run.fit_items))} / {formatNumber(num(run.non_fit_items))}</td>
            <td>{failed ? <span className="data-pill icpv-bad">{formatNumber(failed)}</span> : <span className="icpv-muted">0</span>}</td>
            <td>${num(run.cost_usd).toFixed(4)}</td>
            <td>{calls ? `${(num(run.request_ms) / calls / 1000).toFixed(1)}s` : "-"}</td>
            <td>{whenText(run.started_at ?? run.created_at)}<small className="icpv-sub">{run.created_by || ""}</small></td>
            <td><div className="icpv-row-actions">
              {active ? <button type="button" className="secondary" disabled={busyRun === run.id} onClick={() => void act(run, "pause")}>Pause</button> : null}
              {run.status === "paused" ? <button type="button" className="secondary" disabled={busyRun === run.id} onClick={() => void act(run, "resume")}>Resume</button> : null}
              {active || run.status === "paused" ? <button type="button" className="row-danger" disabled={busyRun === run.id} onClick={() => void act(run, "cancel")}>Cancel</button> : null}
              {run.status === "completed" && failed > 0 ? <button type="button" className="secondary" disabled={busyRun === run.id} onClick={() => void act(run, "retry_failed")}>Retry failed</button> : null}
            </div></td>
          </tr>,
          run.status_message ? <tr key={`${run.id}-message`} className="icpv-message-row"><td colSpan={10}><span role="status">{run.status_message}</span></td></tr> : null,
        ];
      })}</tbody>
    </table></div> : <EmptyCompact text="No runs yet." />}
  </section>;
}

function ResultsSection({ base, icpId, sources, refresh }: { base: string; icpId: string; sources: Source[]; refresh: string }) {
  const available = useMemo(() => sources.map((source) => source.source), [sources]);
  const [chosen, setChosen] = useState<string[] | null>(null);
  const [filter, setFilter] = useState<(typeof filterOptions)[number]["value"]>("all");
  const [search, setSearch] = useState("");
  const [term, setTerm] = useState("");
  const [page, setPage] = useState(1);
  const [data, setData] = useState<{ key: string; total: number; rows: ResultRow[] } | null>(null);
  const [error, setError] = useState("");

  const selected = useMemo(() => chosen
    ? chosen.filter((source) => available.includes(source))
    : sources.filter((source) => source.kind === "model").map((source) => source.source).slice(0, maxSources),
  [chosen, available, sources]);
  const sourcesParam = selected.join(",");

  useEffect(() => {
    const timer = window.setTimeout(() => { setTerm(search.trim()); setPage(1); }, 300);
    return () => window.clearTimeout(timer);
  }, [search]);

  const query = useMemo(() => new URLSearchParams({ icp: icpId, sources: sourcesParam, filter, search: term }), [icpId, sourcesParam, filter, term]);
  const key = `${query}|${page}|${refresh}`;

  useEffect(() => {
    if (!sourcesParam) return;
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ total: number; rows: ResultRow[] }>(`${base}?${query}&view=rows&page=${page}`, { cache: "no-store" })
        .then((result) => { if (!cancelled) { setData({ key, total: num(result.total), rows: result.rows ?? [] }); setError(""); } })
        .catch((caught) => { if (!cancelled) setError(failure(caught, "Unable to load the results.")); });
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [base, query, page, key, sourcesParam]);

  function toggle(source: string) {
    setPage(1);
    setChosen(selected.includes(source) ? selected.filter((item) => item !== source) : selected.length >= maxSources ? selected : [...selected, source]);
  }

  const current = data && data.key === key ? data : null;
  const totalPages = Math.max(1, Math.ceil((current?.total ?? 0) / pageSize));
  const csvHref = sourcesParam ? `${base}?${query}&view=csv` : undefined;

  return <section className="icpv-section" aria-labelledby="icpv-results-title">
    <div className="icpv-section-head">
      <h4 id="icpv-results-title">Results</h4>
      {csvHref ? <a className="secondary icpv-download" href={csvHref} download>Download CSV</a> : null}
    </div>
    {sources.length ? <>
      <fieldset className="icpv-fieldset icpv-source-picker">
        <legend>Columns to show</legend>
        {sources.map((source) => <label key={source.source} className="icpv-check">
          <input type="checkbox" checked={selected.includes(source.source)} onChange={() => toggle(source.source)} /> <span>{modelLabel(source.source)}</span>
        </label>)}
      </fieldset>
      <div className="icpv-toolbar">
        <div className="form-field icpv-inline-field">
          <label htmlFor="icpv-filter">Show</label>
          <select id="icpv-filter" value={filter} onChange={(event) => { setFilter(event.target.value as typeof filter); setPage(1); }}>
            {filterOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
        </div>
        <label className="workspace-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search companies by name or domain" value={search} placeholder="Search name or domain…" onChange={(event) => setSearch(event.target.value)} /></label>
        {current ? <span className="icpv-note">{formatNumber(current.total)} companies</span> : null}
      </div>
      {error ? <div className="inline-error" role="alert">{error}</div> : null}
      {!selected.length ? <EmptyCompact text="Choose at least one column above." />
        : !current ? (error ? null : <div className="workspace-loading icpv-loading">Loading results…</div>)
          : current.rows.length ? <div className="table-wrap"><table className="icpv-results">
            <thead><tr><th>Company</th>{selected.map((source) => <th key={source}>{modelLabel(source)}</th>)}</tr></thead>
            <tbody>{current.rows.map((row) => <tr key={row.company_id}>
              <td>
                <strong>{row.name}</strong>
                <small className="icpv-sub">{[row.domain, row.industry].filter(Boolean).join(" · ") || "-"}</small>
                {row.short_description || row.keywords ? <details className="icpv-desc">
                  <summary>Description</summary>
                  {row.short_description ? <p>{row.short_description}</p> : null}
                  {row.keywords ? <p className="icpv-sub">Keywords: {row.keywords}</p> : null}
                </details> : null}
              </td>
              {selected.map((source) => {
                const verdict = row.verdicts[source];
                return <td key={source}>{verdict ? <>
                  <VerdictPill verdict={verdict.verdict} />{!verdict.current ? <span className="data-pill icpv-warn icpv-stale-pill" title="Judged against an older version of the brief">stale</span> : null}
                  {verdict.reason ? <small className="icpv-reason">{verdict.reason}</small> : null}
                </> : <span className="icpv-muted">-</span>}</td>;
              })}
            </tr>)}</tbody>
          </table></div> : <EmptyCompact text={term ? `No companies match “${term}”.` : "No companies match this filter."} />}
      {current && totalPages > 1 ? <div className="company-pagination"><span>Page {formatNumber(page)} of {formatNumber(totalPages)}</span><div>
        <button type="button" disabled={page <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}>Previous</button>
        <button type="button" disabled={page >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>Next</button>
      </div></div> : null}
    </> : <EmptyCompact text="Results appear here once a run has produced verdicts." />}
  </section>;
}
