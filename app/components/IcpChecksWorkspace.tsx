"use client";

import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import type { ClientIcpProfile, ClientRecord } from "../../lib/types";
import { sourceLabel } from "../../worker/icp-validator-core.mjs";
import { AppIcon, ConfirmDialog } from "./DashboardUi";
import { StrategyPicker, estimateStrategy, hasObservedCost, strategies, strategyLabel, type CostPerCompany, type StrategyId } from "./IcpStrategyPicker";
import { ProgressRing, Segmented, WorkerBadge, durationText, money, relativeTime, type RunStatus, type WorkerState } from "./IcpValidatorViews";
import { Select } from "./ListboxPicker";

// ICP checks: label a client's companies FIT / NON_FIT with one of three
// voting setups (Strict, Balanced, Lenient). Each check is two or three model
// runs by the ICP worker; the database decides each company from the votes.
// Lives in each client's workspace (client given); without one it offers a
// client picker. The ICP Validator (Data tools) is the bench for comparing models.

type Pass = {
  run_id: string; pass_no: number; model: string; reasoning_effort: string; status: RunStatus; status_message: string;
  total_items: number; done_items: number; failed_items: number; fit_items: number; non_fit_items: number; cost_usd: number;
  providers: Record<string, number>;
};
export type Check = {
  id: string; client_id: string; client_name: string; icp_profile_id: string; icp_name: string; icp_current: boolean;
  strategy: StrategyId; scope: string; provider_mode: "cheapest" | "default"; total_items: number; created_by: string; created_at: string;
  forced?: boolean; skipped_items?: number;
  verified_at?: string | null; verified_by?: string; verified_items?: number; auto_apply?: boolean;
  status: RunStatus; status_message: string; started_at: string | null; finished_at: string | null; cost_usd: number; failed_items: number;
  passes: Pass[]; outcome: { fit: number; non_fit: number; pending: number; split: number; reviewed?: number; split_unreviewed?: number;
    applied_verified?: number; applied_blocked?: number; kept_not_blocked?: number; apply_pending?: number };
};
type Vote = { pass_no: number; model: string; reasoning_effort: string; state: string; verdict: "FIT" | "NON_FIT" | null; reason: string };
export type ResultRow = {
  company_id: string; name: string; domain: string; industry: string; short_description: string;
  verdict: "FIT" | "NON_FIT" | null; reason: string; fit_votes: number; non_fit_votes: number; votes: Vote[];
  // What the method's rule decides from the votes alone, and who (if anyone) set the result by hand.
  rule_verdict?: "FIT" | "NON_FIT" | null; reviewed_by?: string; reviewed_at?: string | null;
  // What an auto-applying check has done to the client for this company.
  applied?: "FIT" | "NON_FIT" | null; applied_blocked?: boolean; applied_verified?: boolean; apply_pending?: boolean;
};
type Scope = "unverified" | "all" | "paste";
type Filter = "all" | "fit" | "non_fit" | "pending" | "split" | "reviewed";
type ScopeCounts = { all: number; all_unchecked: number; unverified: number; unverified_unchecked: number };

const base = "/api/icp-checks";
const pageSize = 100;
const num = (value: unknown) => { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0; };
const failure = (caught: unknown, fallback: string) => caught instanceof Error ? caught.message : fallback;
const isActive = (check: Check) => check.status === "queued" || check.status === "running";
const post = <T,>(body: Record<string, unknown>) => api<T>(base, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

export default function IcpChecksWorkspace({ clients, client }: { clients: ClientRecord[]; client?: ClientRecord }) {
  const scopedTo = client?.id ?? "";
  const [checks, setChecks] = useState<Check[] | null>(null);
  const [worker, setWorker] = useState<WorkerState | null>(null);
  const [listError, setListError] = useState("");
  const [version, setVersion] = useState(0);
  const [notice, setNotice] = useState("");
  const [selectedId, setSelectedId] = useState("");

  const load = useCallback(async () => {
    try {
      const result = await api<{ checks: Check[]; worker: WorkerState }>(`${base}?view=checks${scopedTo ? `&client=${encodeURIComponent(scopedTo)}` : ""}`, { cache: "no-store" });
      setChecks(result.checks); setWorker(result.worker); setListError("");
    } catch (caught) { setListError(failure(caught, "Unable to load ICP checks.")); setChecks((current) => current ?? []); }
  }, [scopedTo]);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load, version]);

  const anyActive = (checks ?? []).some(isActive);
  useEffect(() => {
    if (!anyActive) return;
    const timer = window.setInterval(() => void load(), 5000);
    return () => window.clearInterval(timer);
  }, [anyActive, load]);

  const selected = (checks ?? []).find((check) => check.id === selectedId) ?? (checks ?? [])[0] ?? null;

  function started(message: string, checkId: string) {
    setNotice(message); setSelectedId(checkId); setVersion((value) => value + 1);
  }

  return <article className="icpx icc">
    <header className="icpx-hero">
      <div className="icpx-hero-copy">
        <p className="icpx-eyebrow"><AppIcon name="target" size={14}/> ICP checks</p>
        <h3>{client ? `Check ${client.name}'s companies against its ICP` : "Label companies FIT or NON_FIT with a voting setup"}</h3>
        <p>Pick the companies and a method. Two or three model runs read each company&apos;s description and keywords, and the method&apos;s rule turns their votes into one label. Labels only - nothing is hidden or removed.</p>
      </div>
      <div className="icpx-hero-side">{worker ? <WorkerBadge worker={worker}/> : null}</div>
    </header>

    {worker && !worker.configured
      ? <div className="icpx-banner"><AppIcon name="warning" size={16}/><span>The ICP worker has no OpenRouter key. Checks will queue and start once <code>OPENROUTER_API_KEY</code> is set on the server.</span></div>
      : worker && !worker.alive ? <div className="icpx-banner"><AppIcon name="warning" size={16}/><span>The ICP worker has not reported in the last 2 minutes.</span></div> : null}
    {notice ? <div className="icpx-notice" role="status"><AppIcon name="check" size={15}/><span>{notice}</span><button type="button" aria-label="Dismiss" onClick={() => setNotice("")}><AppIcon name="close" size={14}/></button></div> : null}

    <div className="icpx-split">
      <NewCheck clients={clients} fixedClient={client} onStarted={started}/>
      <section className="icpx-card icpx-activity" aria-labelledby="icc-checks">
        <div className="icpx-section-head"><div><h4 id="icc-checks">Checks</h4><p>{anyActive ? "Live - updating every few seconds." : client ? "Latest first." : "Latest first, every client."}</p></div>
          {anyActive ? <span className="icpx-live" aria-hidden="true"><span className="icpx-pulse"/>Live</span> : null}</div>
        {listError ? <p className="form-error" role="alert">{listError}</p> : null}
        {checks === null ? <div className="icpx-skeleton is-rows" aria-busy="true"><span/><span/><span/></div>
          : !checks.length ? <div className="icpx-empty is-quiet"><AppIcon name="target" size={18}/><div><strong>No checks yet</strong><p>Start one on the left. It shows up here with its progress and outcome.</p></div></div>
          : <ul className="icpx-runs icc-checks">{checks.map((check) => <CheckItem key={check.id} check={check} showClient={!client} selected={selected?.id === check.id}
              onSelect={() => setSelectedId(check.id)} onChanged={(message) => { setNotice(message); setVersion((value) => value + 1); }}/>)}</ul>}
      </section>
    </div>

    {selected ? <Results check={selected} onChanged={(message) => { setNotice(message); setVersion((value) => value + 1); }}
      onRefresh={() => setVersion((value) => value + 1)}/> : null}
  </article>;
}

function NewCheck({ clients, fixedClient, onStarted }: { clients: ClientRecord[]; fixedClient?: ClientRecord; onStarted: (message: string, checkId: string) => void }) {
  const usableClients = useMemo(() => fixedClient ? [fixedClient] : clients.filter((client) => !client.archived_at), [clients, fixedClient]);
  const [clientId, setClientId] = useState("");
  const client = usableClients.find((item) => item.id === clientId) ?? usableClients[0] ?? null;
  const [profiles, setProfiles] = useState<{ clientId: string; list: ClientIcpProfile[] } | null>(null);
  const [icpId, setIcpId] = useState("");
  const [strategy, setStrategy] = useState<StrategyId>("balanced");
  // Newly pushed companies are ICP unverified, so that is where a check starts.
  const [scope, setScope] = useState<Scope>("unverified");
  const [pasted, setPasted] = useState("");
  const [counts, setCounts] = useState<{ key: string; value: ScopeCounts; cost: CostPerCompany } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!client) return;
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ profiles: ClientIcpProfile[] }>(`/api/clients/${encodeURIComponent(client.id)}/icp`, { cache: "no-store" })
        .then((result) => { if (!cancelled) setProfiles({ clientId: client.id, list: result.profiles }); })
        .catch((caught) => { if (!cancelled) { setProfiles({ clientId: client.id, list: [] }); setError(failure(caught, "Unable to load ICPs.")); } });
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [client]);

  const loadedProfiles = profiles && client && profiles.clientId === client.id ? profiles.list : null;
  const usable = (loadedProfiles ?? []).filter((profile) => profile.description.trim());
  const icp = usable.find((profile) => profile.id === icpId) ?? usable[0] ?? null;
  const countsKey = client && icp ? `${client.id}|${icp.id}` : "";

  useEffect(() => {
    if (!countsKey || !client || !icp) return;
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ counts: ScopeCounts; costPerCompany?: CostPerCompany }>(`${base}?view=scope&client=${encodeURIComponent(client.id)}&icp=${encodeURIComponent(icp.id)}`, { cache: "no-store" })
        .then((result) => { if (!cancelled) setCounts({ key: countsKey, value: result.counts, cost: result.costPerCompany ?? {} }); })
        .catch(() => {});
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [countsKey, client, icp]);

  const scopeCounts = counts?.key === countsKey ? counts.value : null;
  // Keeps the last answer while another ICP's counts load: cost history is not per ICP.
  const observed = counts?.cost ?? null;
  const pastedLines = pasted.split(/[\n,;\t]+/).map((value) => value.trim()).filter(Boolean).length;
  const companies = scope === "paste" ? pastedLines
    : scope === "unverified" ? num(scopeCounts?.unverified_unchecked)
    : num(scopeCounts?.all_unchecked);
  const estimate = estimateStrategy(strategy, companies, icp?.description.length ?? 800, observed);

  async function start() {
    if (!client || !icp || !companies) return;
    setBusy(true); setError("");
    try {
      let selection: Record<string, unknown> = { scope };
      if (scope === "paste") {
        const resolved = await api<{ companyIds: string[]; matched: number; submitted: number }>(`/api/clients/${encodeURIComponent(client.id)}/companies`, {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "resolve_selection", values: pasted }),
        });
        if (!resolved.companyIds.length) throw new Error(`None of the ${formatNumber(resolved.submitted)} pasted values matched a company in ${client.name}.`);
        selection = { scope: "selection", companyIds: resolved.companyIds };
      }
      const result = await post<{ check: { id: string; total_items: number; skipped_items?: number } }>({
        // Production defaults: cheapest providers, results applied, companies
        // already checked for this ICP skipped.
        action: "start", clientId: client.id, icpId: icp.id, strategy, providerMode: "cheapest", force: false, autoApply: true, ...selection,
      });
      const skipped = num(result.check.skipped_items);
      onStarted(`${strategyLabel(strategy)} check started on ${formatNumber(result.check.total_items)} ${result.check.total_items === 1 ? "company" : "companies"} for ${client.name}${skipped ? ` - ${formatNumber(skipped)} already checked were skipped` : ""}. Companies with no description and no keywords are never checked.`, result.check.id);
      setPasted("");
    } catch (caught) {
      setError(failure(caught, "Unable to start the check."));
    } finally { setBusy(false); }
  }

  const count = (value: number | undefined) => scopeCounts ? <b>{formatNumber(num(value))}</b> : null;
  const scopeOptions: Array<{ value: Scope; label: ReactNode; hint?: string }> = [
    { value: "unverified", label: <>ICP unverified {count(scopeCounts?.unverified_unchecked)}</>, hint: "Companies not marked ICP verified for this client - newly pushed ones land here" },
    { value: "all", label: <>All companies {count(scopeCounts?.all_unchecked)}</>, hint: "Every company of this client that has a description or keywords" },
    { value: "paste", label: "Paste a list", hint: "Websites or company names, one per line" },
  ];
  const skippedHere = scope === "paste" || !scopeCounts ? 0
    : scope === "unverified" ? num(scopeCounts.unverified) - num(scopeCounts.unverified_unchecked)
    : num(scopeCounts.all) - num(scopeCounts.all_unchecked);

  return <section className="icpx-card icpx-composer" aria-labelledby="icc-new">
    <div className="icpx-section-head"><div><h4 id="icc-new">New check</h4><p>Choose the companies and how strict the labels should be.</p></div></div>

    {!usableClients.length ? <div className="icpx-empty is-quiet"><AppIcon name="clients" size={18}/><div><strong>No clients</strong><p>Create a client and give it an ICP brief first.</p></div></div> : <>
      <div className={`icc-row${fixedClient ? " is-single" : ""}`}>
        {fixedClient ? null : <label className="icpx-field"><span className="icpx-label">Client</span>
          <Select className="icc-select" value={client?.id ?? ""} onChange={(event) => { setClientId(event.target.value); setIcpId(""); setError(""); }}>
            {usableClients.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
          </Select>
        </label>}
        <label className="icpx-field"><span className="icpx-label">ICP</span>
          <Select className="icc-select" value={icp?.id ?? ""} disabled={!usable.length} onChange={(event) => setIcpId(event.target.value)}>
            {!loadedProfiles ? <option>Loading…</option> : !usable.length ? <option>No ICP with a brief</option>
              : usable.map((profile) => <option key={profile.id} value={profile.id}>{profile.name.trim() || "Untitled ICP"}</option>)}
          </Select>
        </label>
      </div>
      {loadedProfiles && !usable.length ? <p className="icpx-help">None of {client?.name}&apos;s ICPs has a brief yet. Add one on the client&apos;s ICPs tab.</p> : null}

      <div className="icpx-field"><span className="icpx-label">Method</span>
        <StrategyPicker name="icc-strategy" value={strategy} onChange={setStrategy} companies={companies} briefLength={icp?.description.length} observed={observed}/>
      </div>

      <div className="icpx-field"><span className="icpx-label">Companies</span>
        <Segmented label="Companies" value={scope} options={scopeOptions} onChange={setScope}/>
        {scope === "paste" ? <>
          <textarea className="icc-paste" rows={5} value={pasted} onChange={(event) => setPasted(event.target.value)}
            placeholder={"acme.com\nhttps://www.example.org\nContoso Fertilizers"} aria-label="Company websites or names"/>
          <p className="icpx-help">{pastedLines ? `${formatNumber(pastedLines)} value${pastedLines === 1 ? "" : "s"} - matched to ${client?.name}'s companies when you start.` : "Websites or names, one per line. Only this client's companies are matched."}</p>
        </> : <p className="icpx-help">{skippedHere ? <>{formatNumber(skippedHere)} already checked for this ICP {skippedHere === 1 ? "is" : "are"} skipped. </> : null}To check a filtered set, select companies in the Company DB and use <b>Validate ICP</b>.</p>}
      </div>
    </>}

    {error ? <p className="form-error" role="alert">{error}</p> : null}
    <div className="icpx-composer-foot">
      <div className="icpx-estimate"><span>{hasObservedCost(strategy, observed) ? "Estimate from your recent runs" : "Estimate at list price"}</span><strong>{companies ? money(estimate) : "-"}</strong></div>
      <button type="button" className="icpx-primary" disabled={busy || !client || !icp || !companies} onClick={() => void start()}>
        {busy ? "Starting…" : companies ? `Run ${strategyLabel(strategy)} on ${formatNumber(companies)}` : `Run ${strategyLabel(strategy)}`}
      </button>
    </div>
  </section>;
}

function providerText(pass: Pass) {
  const entries = Object.entries(pass.providers ?? {}).sort((a, b) => b[1] - a[1]);
  if (!entries.length) return "";
  return entries.slice(0, 2).map(([name]) => name).join(", ") + (entries.length > 2 ? ` +${entries.length - 2}` : "");
}

export function CheckItem({ check, selected, onSelect, onChanged, showClient = true }: { check: Check; selected: boolean; onSelect: () => void; onChanged: (message: string) => void; showClient?: boolean }) {
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const done = check.passes.reduce((sum, pass) => sum + num(pass.done_items), 0);
  const total = check.passes.reduce((sum, pass) => sum + num(pass.total_items), 0);
  const active = isActive(check);
  const finished = check.status === "completed" || check.status === "cancelled";
  const took = durationText(check.started_at, check.finished_at);

  async function act(action: "pause" | "resume" | "cancel" | "retry_failed") {
    setBusy(action); setError("");
    try {
      await post({ action, clientId: check.client_id, checkId: check.id });
      onChanged(action === "pause" ? "Check paused." : action === "resume" ? "Check resumed." : action === "cancel" ? "Check cancelled. Companies already decided keep their label." : "Failed companies are queued again.");
    } catch (caught) { setError(failure(caught, "Unable to change the check.")); }
    finally { setBusy(""); }
  }

  return <li className={`icpx-run icc-check is-${check.status}${selected ? " is-selected" : ""}`}>
    <ProgressRing done={done} total={total} status={check.status}/>
    <div className="icpx-run-main">
      <div className="icpx-run-title">
        <button type="button" className="icc-check-open" onClick={onSelect} aria-pressed={selected}>
          <span className={`icc-method is-${check.strategy}`}>{strategyLabel(check.strategy)}</span>
          {showClient ? <><strong>{check.client_name || "Client"}</strong><span className="icpx-muted">· {check.icp_name || "ICP"}</span></> : <strong>{check.icp_name || "ICP"}</strong>}
        </button>
        <span className={`icpx-status is-${check.status}`}>{check.status === "completed" ? "Done" : check.status.charAt(0).toUpperCase() + check.status.slice(1)}</span>
        {!check.icp_current ? <span className="icpx-chip is-warn" title="The ICP brief changed after this check started">Older brief</span> : null}
        {check.verified_at ? <span className="icpx-chip is-ok" title={`${formatNumber(num(check.verified_items))} FIT marked ICP verified ${relativeTime(check.verified_at)}${check.verified_by ? ` by ${check.verified_by}` : ""}`}>FIT verified</span> : null}
      </div>
      <div className="icpx-run-meta">
        <span>{formatNumber(num(check.total_items))} companies{num(check.skipped_items) ? <small className="icpx-muted"> · {formatNumber(num(check.skipped_items))} skipped</small> : null}{check.forced ? <small className="icpx-muted"> · forced</small> : null}</span>
        <span className="icpx-run-split"><b className="is-fit">{formatNumber(num(check.outcome.fit))}</b> FIT <b className="is-non-fit">{formatNumber(num(check.outcome.non_fit))}</b> NON_FIT</span>
        {num(check.outcome.pending) ? <span>{formatNumber(num(check.outcome.pending))} {finished ? "undecided" : "pending"}</span> : null}
        {check.auto_apply ? <span className="icc-applied" title="Applied to the client automatically">
          {formatNumber(num(check.outcome.applied_verified))} verified · {formatNumber(num(check.outcome.applied_blocked))} blocked
          {num(check.outcome.kept_not_blocked) ? ` · ${formatNumber(num(check.outcome.kept_not_blocked))} kept (already verified)` : ""}
          {num(check.outcome.apply_pending) ? ` · applying ${formatNumber(num(check.outcome.apply_pending))}…` : ""}</span> : null}
        <span>{money(num(check.cost_usd))}</span>
        {took ? <span className={`icpx-duration${active ? " is-live" : ""}`}>{active ? "Running " : "Took "}{took}</span> : null}
        <span>{relativeTime(check.created_at)}{check.created_by ? ` · ${check.created_by}` : ""}</span>
      </div>
      <div className="icc-passes">{check.passes.map((pass) => {
        const providers = providerText(pass);
        return <span key={pass.run_id} className={`icc-pass is-${pass.status}`} title={pass.status_message || undefined}>
          <b>#{pass.pass_no}</b> {sourceLabel(pass.model)} · {pass.reasoning_effort}
          <i>{formatNumber(num(pass.done_items))}/{formatNumber(num(pass.total_items))}</i>
          {providers ? <small>{providers}</small> : null}
          {num(pass.failed_items) ? <em>{formatNumber(num(pass.failed_items))} failed</em> : null}
        </span>;
      })}</div>
      {check.status === "paused" && check.status_message ? <p className="icpx-run-message"><AppIcon name="warning" size={13}/>{check.status_message}</p> : null}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
    </div>
    <div className="icpx-run-actions">
      {active ? <button type="button" disabled={Boolean(busy)} onClick={() => void act("pause")}>Pause</button> : null}
      {check.status === "paused" ? <button type="button" className="is-primary" disabled={Boolean(busy)} onClick={() => void act("resume")}>Resume</button> : null}
      {!finished ? <button type="button" disabled={Boolean(busy)} onClick={() => void act("cancel")}>Cancel</button> : null}
      {num(check.failed_items) > 0 ? <button type="button" disabled={Boolean(busy)} onClick={() => void act("retry_failed")}>Retry failed</button> : null}
    </div>
  </li>;
}

function Results({ check, onChanged, onRefresh }: { check: Check; onChanged: (message: string) => void; onRefresh: () => void }) {
  const [reviewing, setReviewing] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [confirmVerify, setConfirmVerify] = useState(false);
  const [verifying, setVerifying] = useState(false);
  const [verifyError, setVerifyError] = useState("");
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(1);
  const [data, setData] = useState<{ key: string; total: number; rows: ResultRow[] } | null>(null);
  const [error, setError] = useState("");
  const finished = check.status === "completed" || check.status === "cancelled";
  // Re-read as votes land: the outcome counts move whenever anything settles.
  const signature = `${check.outcome.fit}|${check.outcome.non_fit}|${check.passes.map((pass) => pass.done_items).join(",")}`;
  const key = `${check.id}|${filter}|${query}|${page}`;

  useEffect(() => {
    const timer = window.setTimeout(() => setQuery(search.trim()), 300);
    return () => window.clearTimeout(timer);
  }, [search]);

  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      const params = new URLSearchParams({ view: "results", client: check.client_id, check: check.id, filter, search: query, page: String(page) });
      api<{ total: number; rows: ResultRow[] }>(`${base}?${params}`, { cache: "no-store" })
        .then((result) => { if (!cancelled) { setData({ key, total: num(result.total), rows: result.rows ?? [] }); setError(""); } })
        .catch((caught) => { if (!cancelled) setError(failure(caught, "Unable to load results.")); });
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [check.client_id, check.id, filter, query, page, key, signature]);

  const current = data?.key === key ? data : null;
  const shown = current ?? data;
  const pages = Math.max(1, Math.ceil(num(shown?.total) / pageSize));
  const csv = `${base}?${new URLSearchParams({ view: "csv", client: check.client_id, check: check.id, filter, search: query })}`;
  const strategy = strategies.find((item) => item.id === check.strategy);
  const fit = num(check.outcome.fit);

  // Set one company's result by hand ("" puts back what the runs decided).
  async function review(companyId: string, verdict: "FIT" | "NON_FIT" | "") {
    setReviewing(companyId); setError("");
    try {
      const response = await post<{ result: Partial<ResultRow> & { company_id: string } }>({ action: "review", clientId: check.client_id, checkId: check.id, companyId, verdict });
      setData((current) => current ? { ...current, rows: current.rows.map((row) => row.company_id === companyId ? { ...row, ...response.result } : row) } : current);
      onRefresh();
    } catch (caught) { setError(failure(caught, "Unable to save the review.")); }
    finally { setReviewing(""); }
  }

  async function markFitVerified() {
    setVerifying(true); setVerifyError("");
    try {
      const response = await post<{ result: { fit?: number; updated?: number } }>({ action: "mark_fit_verified", clientId: check.client_id, checkId: check.id });
      const marked = num(response.result.fit);
      const newly = num(response.result.updated);
      setConfirmVerify(false);
      onChanged(`${formatNumber(marked)} FIT ${marked === 1 ? "company is" : "companies are"} ICP verified for ${check.client_name}${newly < marked ? ` (${formatNumber(marked - newly)} already were)` : ""}. They now show under ICP Verified in the Company DB.`);
    } catch (caught) { setVerifyError(failure(caught, "Unable to mark the FIT companies verified.")); }
    finally { setVerifying(false); }
  }

  const filterOptions: Array<{ value: Filter; label: ReactNode; hint?: string }> = [
    { value: "all", label: <>All <b>{formatNumber(num(check.total_items))}</b></> },
    { value: "fit", label: <>FIT <b>{formatNumber(num(check.outcome.fit))}</b></> },
    { value: "non_fit", label: <>NON_FIT <b>{formatNumber(num(check.outcome.non_fit))}</b></> },
    { value: "split", label: <>Split votes <b>{formatNumber(num(check.outcome.split))}</b></>,
      hint: `The runs disagreed - the borderline companies. ${formatNumber(num(check.outcome.split_unreviewed))} not reviewed yet.` },
    ...(num(check.outcome.reviewed) ? [{ value: "reviewed" as Filter, label: <>Reviewed <b>{formatNumber(num(check.outcome.reviewed))}</b></>, hint: "Results set by hand" }] : []),
    ...(num(check.outcome.pending) ? [{ value: "pending" as Filter, label: <>{finished ? "Undecided" : "Pending"} <b>{formatNumber(num(check.outcome.pending))}</b></> }] : []),
  ];

  return <section className="icpx-card" aria-labelledby="icc-results">
    <div className="icpx-section-head">
      <div><h4 id="icc-results">{strategyLabel(check.strategy)} · {check.client_name} · {check.icp_name || "ICP"}</h4>
        <p>{strategy?.rule}{check.provider_mode === "cheapest" ? " Cheapest providers." : ""}{check.auto_apply ? " Results applied: FIT → ICP verified, NON_FIT → blocklist." : ""}</p></div>
      <div className="icc-results-actions">
        {fit && !check.auto_apply ? <button type="button" className="icpx-ghost is-accent" onClick={() => { setVerifyError(""); setConfirmVerify(true); }}
          title={check.verified_at ? `Last marked ${relativeTime(check.verified_at)}${check.verified_by ? ` by ${check.verified_by}` : ""}` : undefined}>
          <AppIcon name="check" size={14}/> {check.verified_at ? "Marked verified · mark again" : `Mark ${formatNumber(fit)} FIT as ICP verified`}
        </button> : null}
        <a className="icpx-ghost" href={csv} download><AppIcon name="download" size={14}/> CSV</a>
      </div>
    </div>
    {confirmVerify ? <ConfirmDialog
      title={`Mark ${formatNumber(fit)} FIT ${fit === 1 ? "company" : "companies"} ICP verified?`}
      body={`They move to ICP Verified for ${check.client_name}, exactly like "Mark ICP verified" in the Company DB, and their people follow. NON_FIT and undecided companies are not touched.${isActive(check) ? " The check is still running: only the companies decided FIT so far are marked." : ""}`}
      confirmLabel={verifying ? "Marking…" : "Mark ICP verified"}
      busy={verifying}
      error={verifyError}
      onCancel={() => setConfirmVerify(false)}
      onConfirm={() => void markFitVerified()}/> : null}
    <div className="icpx-toolbar">
      <Segmented label="Show" value={filter} options={filterOptions} onChange={(value) => { setFilter(value); setPage(1); }}/>
      <label className="icpx-search">
        <AppIcon name="search" size={14}/>
        <span className="sr-only">Search companies</span>
        <input type="search" value={search} placeholder="Search name or domain" onChange={(event) => { setSearch(event.target.value); setPage(1); }}/>
      </label>
    </div>
    {error ? <p className="form-error" role="alert">{error}</p> : null}
    {!shown ? <div className="icpx-skeleton is-rows" aria-busy="true"><span/><span/><span/><span/></div>
      : !shown.rows.length ? <div className="icpx-empty is-quiet"><AppIcon name="search" size={18}/><div><strong>Nothing here</strong><p>{filter === "all" && !query ? "The first votes land within a minute or two." : "No company matches this view."}</p></div></div>
      : <StrategyResultsTable rows={shown.rows} finished={finished} busyId={reviewing} onReview={(companyId, verdict) => void review(companyId, verdict)}/>}
    {shown && pages > 1 ? <div className="icpx-pager">
      <span>Page {page} of {formatNumber(pages)} · {formatNumber(shown.total)} companies</span>
      <span><button type="button" disabled={page <= 1} onClick={() => setPage((value) => value - 1)}>Previous</button>{" "}
        <button type="button" disabled={page >= pages} onClick={() => setPage((value) => value + 1)}>Next</button></span>
    </div> : null}
  </section>;
}

export function StrategyResultsTable({ rows, finished, onReview, busyId = "" }: {
  rows: ResultRow[]; finished: boolean; onReview?: (companyId: string, verdict: "FIT" | "NON_FIT" | "") => void; busyId?: string;
}) {
  return <div className="icpx-table-wrap"><table className="icpx-table icc-table">
    <thead><tr><th>Company</th><th>Result</th><th>Votes</th><th>Why</th></tr></thead>
    <tbody>{rows.map((row) => <tr key={row.company_id} className={row.fit_votes > 0 && row.non_fit_votes > 0 ? "is-split" : undefined}>
      <td><div className="icpx-company">
        <span className="icpx-avatar" aria-hidden="true">{(row.name || "?").slice(0, 2).toUpperCase()}</span>
        <div><strong>{row.name || "Unnamed company"}</strong><small>{[row.domain, row.industry].filter(Boolean).join(" · ")}</small>
          {row.short_description ? <details><summary>Description</summary><p>{row.short_description}</p></details> : null}</div>
      </div></td>
      <td>{row.verdict
        ? <span className={`icpx-verdict ${row.verdict === "FIT" ? "is-fit" : "is-non-fit"}`}>{row.verdict}</span>
        : <span className="icpx-chip">{finished ? "Undecided" : "Pending"}</span>}
        {row.apply_pending ? <span className="icpx-chip icc-applied-chip">Applying…</span>
          : row.applied === "FIT" ? <span className="icpx-chip is-ok icc-applied-chip" title={row.applied_verified ? "Marked ICP verified by this check" : "Was already ICP verified"}>ICP verified</span>
          : row.applied === "NON_FIT" ? <span className={`icpx-chip icc-applied-chip${row.applied_blocked ? " is-bad" : ""}`} title={row.applied_blocked ? "Domain added to the client's blocklist by this check" : "Not blocked: already ICP verified, a free-mail domain, or already on the blocklist"}>{row.applied_blocked ? "Blocked" : "Not blocked"}</span>
          : null}
        {row.reviewed_at ? <span className="icpx-chip is-ok icc-reviewed" title={`Set by ${row.reviewed_by || "a teammate"} ${relativeTime(row.reviewed_at)}`}>Reviewed</span> : null}
        <small className="icc-tally">{row.fit_votes} FIT · {row.non_fit_votes} NON_FIT
          {row.reviewed_at && row.rule_verdict && row.rule_verdict !== row.verdict ? <> · runs said {row.rule_verdict}</> : null}</small>
        {onReview ? <div className="icc-review" role="group" aria-label={`Set the result for ${row.name}`}>
          {(["FIT", "NON_FIT"] as const).map((value) => <button key={value} type="button" disabled={busyId === row.company_id}
            className={row.reviewed_at && row.verdict === value ? `is-on is-${value === "FIT" ? "fit" : "non-fit"}` : undefined}
            aria-pressed={Boolean(row.reviewed_at) && row.verdict === value}
            onClick={() => onReview(row.company_id, value)}>{value}</button>)}
          {row.reviewed_at ? <button type="button" className="is-undo" disabled={busyId === row.company_id} onClick={() => onReview(row.company_id, "")}>Undo</button> : null}
        </div> : null}</td>
      <td><div className="icc-votes">{row.votes.map((vote) => <span key={vote.pass_no} title={vote.reason || undefined}
        className={`icc-vote ${vote.verdict === "FIT" ? "is-fit" : vote.verdict === "NON_FIT" ? "is-non-fit" : "is-waiting"}`}>
        <b>#{vote.pass_no}</b> {sourceLabel(vote.model).split(" ")[0]} {vote.verdict ?? (vote.state === "failed" ? "failed" : vote.state === "skipped" ? "skipped" : "waiting")}
      </span>)}</div></td>
      <td className="icpx-verdict-cell"><p>{row.reason || (row.verdict ? "" : "Waiting for the remaining runs.")}</p></td>
    </tr>)}</tbody>
  </table></div>;
}
