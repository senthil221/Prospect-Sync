"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { IcpModelOption } from "../../lib/openrouter-models";
import type { ClientIcpProfile, ClientRecord } from "../../lib/types";
import { ICP_MODELS, REASONING_EFFORTS } from "../../worker/icp-validator-core.mjs";
import { AppIcon, ConfirmDialog } from "./DashboardUi";
import { ModelPicker, estimateModels, modelName, useIcpModelCatalog } from "./IcpCheck";
import {
  KpiStrip, ModelScoreboard, ResultsTable, RunTimeline, Segmented, Switch, WorkerBadge, money,
  type ResultRow, type RunStatus, type ValidatorRun, type ValidatorSource, type WorkerState,
} from "./IcpValidatorViews";

// The ICP validator: an LLM (run by the ICP worker, never in the browser)
// labels each of a client's companies FIT or NON_FIT against one ICP brief.
// Labels only - nothing is hidden or deleted.
//
// Layout, top to bottom: which ICP and whether the worker is live; the
// numbers; how strict each model is (the scoreboard); start a check beside
// the runs it produced; and the companies with every model's verdict side by
// side. The panel owns data and polling; IcpValidatorViews draws.

type Overview = {
  profile: { id: string; name: string; icp_hash: string; description_length: number; company_count: number };
  sources: ValidatorSource[];
  runs: ValidatorRun[];
  worker: WorkerState;
};
type OverviewResponse = { overview: Overview; efforts: string[] };
type StartScope = "all" | "unchecked" | "sample";
type Filter = "all" | "fit" | "all_non_fit" | "disagree";

const pageSize = 100;
const maxColumns = 8;
const activeStatuses: RunStatus[] = ["queued", "running"];
const num = (value: unknown) => { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; };
const failure = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback;

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
  const [pendingDelete, setPendingDelete] = useState<ValidatorSource | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState("");
  const [busyRun, setBusyRun] = useState("");
  const [runError, setRunError] = useState("");

  const catalog = useIcpModelCatalog(client.id);
  const labelFor = useCallback((source: string) => modelName(catalog, source), [catalog]);
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

  // Changes whenever a run stops moving, so results refresh once a run
  // finishes without refetching on every progress tick.
  const settledSignature = (overview?.runs ?? []).filter((run) => !activeStatuses.includes(run.status)).map((run) => `${run.id}:${run.status}:${run.done_items}`).join("|");

  function changed(message?: string) {
    if (message) setNotice(message);
    setVersion((value) => value + 1);
  }

  async function runAction(run: ValidatorRun, action: "pause" | "resume" | "cancel" | "retry_failed") {
    setBusyRun(run.id); setRunError("");
    try {
      await api(base, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action, runId: run.id }) });
      changed(action === "retry_failed" ? `Retrying failed companies for ${labelFor(run.model)}.`
        : `${labelFor(run.model)} ${action === "pause" ? "paused" : action === "resume" ? "resumed" : "cancelled"}.`);
    } catch (caught) { setRunError(failure(caught, "Unable to change that run.")); }
    finally { setBusyRun(""); }
  }

  async function confirmDelete() {
    if (!pendingDelete || !icpId) return;
    setDeleting(true); setDeleteError("");
    try {
      const result = await api<{ deleted: number }>(base, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "delete_source", icpId, source: pendingDelete.source }),
      });
      setPendingDelete(null);
      changed(`Deleted ${formatNumber(num(result.deleted))} verdicts from ${labelFor(pendingDelete.source)}.`);
    } catch (caught) { setDeleteError(failure(caught, "Unable to delete those verdicts.")); }
    finally { setDeleting(false); }
  }

  return <article className="icpx">
    <header className="icpx-hero">
      <div className="icpx-hero-copy">
        <p className="icpx-eyebrow"><AppIcon name="target" size={14}/> ICP Validator</p>
        <h3>Which of {client.name}&apos;s companies actually fit?</h3>
        <p>AI models read each company&apos;s description and keywords against your brief and label it <b className="is-fit">FIT</b> or <b className="is-non-fit">NON_FIT</b>. Labels only - nothing is hidden or removed.</p>
      </div>
      <div className="icpx-hero-side">
        {overview ? <WorkerBadge worker={overview.worker}/> : null}
        {usable.length ? <label className="icpx-icp-select">
          <span>Checking against</span>
          <select value={icpId} onChange={(event) => { setChosenIcp(event.target.value); setNotice(""); }}>
            {profiles.map((item) => {
              const empty = !item.description.trim();
              return <option key={item.id} value={item.id} disabled={empty}>{(item.name.trim() || "Untitled ICP") + (empty ? " - no brief yet" : "")}</option>;
            })}
          </select>
        </label> : null}
      </div>
    </header>

    {profilesError ? <div className="inline-error" role="alert">{profilesError}</div> : null}
    {overviewError ? <div className="inline-error" role="alert">{overviewError}</div> : null}
    {notice ? <div className="icpx-notice" role="status"><AppIcon name="check" size={15}/><span>{notice}</span><button type="button" aria-label="Dismiss" onClick={() => setNotice("")}><AppIcon name="close" size={14}/></button></div> : null}

    {profilesLoading ? <div className="icpx-skeleton" aria-busy="true"><span/><span/><span/></div>
      : !usable.length ? <div className="icpx-empty is-large"><AppIcon name="target" size={26}/><div>
          <strong>{profiles.length ? "Add a brief to an ICP first" : `No ICPs for ${client.name} yet`}</strong>
          <p>The models judge companies against the brief on the ICPs tab: who you sell to, and who to exclude.</p></div></div>
        : !overview || !profile ? (overviewError ? null : <div className="icpx-skeleton" aria-busy="true"><span/><span/><span/></div>)
          : <>
            {!overview.worker.configured
              ? <div className="icpx-banner"><AppIcon name="warning" size={16}/><span>The ICP worker has no OpenRouter key. Checks will queue and start once <code>OPENROUTER_API_KEY</code> is set on the server.</span></div>
              : !overview.worker.alive ? <div className="icpx-banner"><AppIcon name="warning" size={16}/><span>The ICP worker has not reported in the last 2 minutes.</span></div> : null}

            <KpiStrip companyCount={num(overview.profile.company_count)} sources={overview.sources} runs={overview.runs}/>

            <section className="icpx-section" aria-labelledby="icpx-models">
              <div className="icpx-section-head"><div><h4 id="icpx-models">Model scoreboard</h4><p>How strict each model is with this brief. Very different rejection rates on the same companies are worth a look.</p></div></div>
              <ModelScoreboard sources={overview.sources} labelFor={labelFor} onDelete={(source) => { setDeleteError(""); setPendingDelete(source); }}/>
            </section>

            <div className="icpx-split">
              <Composer base={base} icpId={icpId} overview={overview} catalog={catalog} efforts={current?.efforts ?? REASONING_EFFORTS} onStarted={(message) => changed(message)}/>
              <section className="icpx-card icpx-activity" aria-labelledby="icpx-runs">
                <div className="icpx-section-head"><div><h4 id="icpx-runs">Runs</h4><p>{hasActive ? "Live - updating every few seconds." : "Latest first."}</p></div>
                  {hasActive ? <span className="icpx-live" aria-hidden="true"><span className="icpx-pulse"/>Live</span> : null}</div>
                {runError ? <div className="inline-error" role="alert">{runError}</div> : null}
                <RunTimeline runs={overview.runs} labelFor={labelFor} busyRun={busyRun} onAction={(run, action) => void runAction(run, action)}/>
              </section>
            </div>

            <Results base={base} icpId={icpId} sources={overview.sources} labelFor={labelFor} refresh={`${version}|${settledSignature}`}/>
          </>}

    {pendingDelete ? <ConfirmDialog
      title={`Delete ${labelFor(pendingDelete.source)} verdicts?`}
      body={`This removes all ${formatNumber(num(pendingDelete.total))} verdicts from ${labelFor(pendingDelete.source)} for this ICP. Companies themselves are not touched, and the check can be run again.`}
      error={deleteError} confirmLabel="Delete verdicts" busy={deleting}
      onCancel={() => { setPendingDelete(null); setDeleteError(""); }} onConfirm={() => void confirmDelete()}/> : null}
  </article>;
}

export function Composer({ base, icpId, overview, catalog, efforts, onStarted }: {
  base: string; icpId: string; overview: Overview; catalog: IcpModelOption[]; efforts: string[]; onStarted: (message: string) => void;
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
  const scopeCount = scope === "sample" ? (sampleValid ? sampleSize : 0) : companyCount;
  const estimate = estimateModels(catalog, models, scopeCount, effort, overview.profile.description_length);
  const canStart = models.length > 0 && !busy && scopeCount > 0;

  async function start() {
    setBusy(true); setError("");
    try {
      const response = await api<{ runs: unknown[]; error?: string }>(base, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "start", icpId, models, effort, scope, sampleSize: scope === "sample" ? sampleSize : undefined, reuse }),
      });
      const started = response.runs?.length ?? 0;
      if (response.error) setError(response.error);
      onStarted(`Started ${started} check${started === 1 ? "" : "s"} on ${formatNumber(scopeCount)} companies.`);
    } catch (caught) { setError(failure(caught, "Unable to start the check.")); }
    finally { setBusy(false); }
  }

  return <section className="icpx-card icpx-composer" aria-labelledby="icpx-new">
    <div className="icpx-section-head"><div><h4 id="icpx-new">New check</h4><p>Pick up to three models. They all judge the same companies.</p></div></div>

    <ModelPicker catalog={catalog} selected={models} onChange={setModels} idPrefix="icpx"/>

    <div className="icpx-field">
      <span className="icpx-label">Companies</span>
      <Segmented<StartScope> label="Which companies" value={scope} onChange={setScope} options={[
        { value: "all", label: <>All <b>{formatNumber(companyCount)}</b></>, hint: "Every company with a description or keywords" },
        { value: "unchecked", label: "Unchecked", hint: "Only companies without a current verdict from the chosen models" },
        { value: "sample", label: "Sample", hint: "A random sample - every model gets the same one" },
      ]}/>
      {scope === "sample" ? <label className="icpx-inline-number">
        <input type="number" min={1} max={5000} value={sample} aria-label="Sample size" onChange={(event) => setSample(event.target.value)}/>
        <span>random companies{sampleValid ? "" : " - between 1 and 5,000"}</span>
      </label> : null}
      <small className="icpx-help">Incomplete Info companies (no description or keywords) are always skipped.</small>
    </div>

    <div className="icpx-field">
      <span className="icpx-label">Reasoning</span>
      <Segmented label="Reasoning effort" value={effort} onChange={setEffort}
        options={efforts.map((value) => ({ value, label: value[0].toUpperCase() + value.slice(1) }))}/>
      <small className="icpx-help">More effort reads more carefully, costs more and runs slower.</small>
    </div>

    <Switch checked={reuse} onChange={setReuse} label="Reuse earlier verdicts" hint="Skip companies a model already judged against this exact brief."/>

    <footer className="icpx-composer-foot">
      <div className="icpx-estimate"><span>Estimated cost</span><strong>{models.length && scopeCount ? `≈ ${money(estimate)}` : "-"}</strong></div>
      <button type="button" className="icpx-primary" disabled={!canStart} onClick={() => void start()}>
        {busy ? "Starting…" : models.length > 1 ? `Run ${models.length} models` : "Run check"} <AppIcon name="arrow" size={15}/>
      </button>
    </footer>
    {error ? <p className="form-error" role="alert">{error}</p> : null}
  </section>;
}

function Results({ base, icpId, sources, labelFor, refresh }: {
  base: string; icpId: string; sources: ValidatorSource[]; labelFor: (source: string) => string; refresh: string;
}) {
  const available = useMemo(() => sources.map((source) => source.source), [sources]);
  const [chosen, setChosen] = useState<string[] | null>(null);
  const [filter, setFilter] = useState<Filter>("all");
  const [search, setSearch] = useState("");
  const [term, setTerm] = useState("");
  const [page, setPage] = useState(1);
  const [data, setData] = useState<{ key: string; total: number; rows: ResultRow[] } | null>(null);
  const [error, setError] = useState("");

  const selected = useMemo(() => chosen
    ? chosen.filter((source) => available.includes(source))
    : sources.filter((source) => source.kind === "model").map((source) => source.source).slice(0, maxColumns),
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
    setChosen(selected.includes(source) ? selected.filter((item) => item !== source) : selected.length >= maxColumns ? selected : [...selected, source]);
  }

  const current = data && data.key === key ? data : null;
  const totalPages = Math.max(1, Math.ceil((current?.total ?? 0) / pageSize));

  return <section className="icpx-card icpx-results" aria-labelledby="icpx-results-title">
    <div className="icpx-section-head">
      <div><h4 id="icpx-results-title">Companies</h4><p>{current ? `${formatNumber(current.total)} ${current.total === 1 ? "company" : "companies"}${filter === "disagree" ? " where the models disagree" : filter === "fit" ? " every model calls FIT" : filter === "all_non_fit" ? " every model calls NON_FIT" : ""}` : "Every model's verdict, side by side."}</p></div>
      {sourcesParam ? <a className="icpx-ghost" href={`${base}?${query}&view=csv`} download><AppIcon name="download" size={15}/> Export CSV</a> : null}
    </div>
    {!sources.length ? <div className="icpx-empty is-quiet"><AppIcon name="rows" size={20}/><div><strong>Nothing to show yet</strong><p>Verdicts appear here as soon as a run produces them.</p></div></div> : <>
      <div className="icpx-toolbar">
        <Segmented<Filter> label="Show" value={filter} onChange={(value) => { setFilter(value); setPage(1); }} options={[
          { value: "all", label: "All" },
          { value: "fit", label: "All FIT", hint: "Every chosen model says FIT" },
          { value: "all_non_fit", label: "All NON_FIT", hint: "Every chosen model says NON_FIT" },
          { value: "disagree", label: "Disagreements", hint: "The chosen models do not agree" },
        ]}/>
        <label className="icpx-search"><AppIcon name="search" size={15}/><input aria-label="Search companies by name or domain" value={search} placeholder="Search name or domain" onChange={(event) => setSearch(event.target.value)}/></label>
      </div>
      <div className="icpx-columns" role="group" aria-label="Models to compare">
        {sources.map((source) => <button key={source.source} type="button" aria-pressed={selected.includes(source.source)}
          className={selected.includes(source.source) ? "is-on" : undefined} onClick={() => toggle(source.source)}>
          <span className="icpx-dot" aria-hidden="true"/>{labelFor(source.source)}
        </button>)}
      </div>
      {error ? <div className="inline-error" role="alert">{error}</div> : null}
      {!selected.length ? <div className="icpx-empty is-quiet"><div><strong>Choose a model above</strong><p>Pick at least one to see its verdicts.</p></div></div>
        : !current ? (error ? null : <div className="icpx-skeleton is-rows" aria-busy="true"><span/><span/><span/><span/></div>)
          : current.rows.length ? <ResultsTable rows={current.rows} columns={selected} labelFor={labelFor}/>
            : <div className="icpx-empty is-quiet"><div><strong>{term ? `No companies match “${term}”` : "Nothing matches this filter"}</strong><p>Try another filter or clear the search.</p></div></div>}
      {current && totalPages > 1 ? <nav className="icpx-pager" aria-label="Pages">
        <button type="button" disabled={page <= 1} onClick={() => setPage((value) => Math.max(1, value - 1))}><AppIcon name="back" size={14}/> Previous</button>
        <span>Page <b>{formatNumber(page)}</b> of {formatNumber(totalPages)}</span>
        <button type="button" disabled={page >= totalPages} onClick={() => setPage((value) => Math.min(totalPages, value + 1))}>Next <AppIcon name="arrow" size={14}/></button>
      </nav> : null}
    </>}
  </section>;
}
