"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { filterPayload } from "../../lib/dashboard-api";
import type { ProspectFilter } from "../../lib/types";
import { MAX_MANUAL_VERIFICATION_EMAILS, parseManualVerificationEmailLimit } from "../../lib/verification-limits";
import type { CompanyScope } from "../../lib/workspace-scopes";
import { AppIcon, DialogBackdrop } from "./DashboardUi";
import { useDialogFocus } from "./use-dialog";

type VerificationRun = {
  id: string; scope: "all" | "filtered" | "import"; source: "manual" | "import";
  status: string; total_count: number; processed_count: number; reused_count: number;
  skipped_count: number; error_count: number; force_reverify: boolean; created_at: string;
  max_emails?: number | null; eligible_email_count?: number | null; selected_email_count?: number | null;
  completed_at?: string | null; last_error?: string | null;
};
type ProviderState = {
  enabled?: boolean; manually_paused?: boolean; pause_reason?: string | null;
  cooldown_until?: string | null; quota_wait_until?: string | null;
  daily_attempts?: number; daily_limit?: number; worker_configured?: boolean; worker_seen_at?: string | null;
};
type StatusPayload = { runs?: VerificationRun[]; provider?: ProviderState | null };
type ManualScope = "all" | "filtered";
type LimitMode = "100" | "1000" | "10000" | "custom" | "all";

const terminal = new Set(["completed", "completed_with_errors", "cancelled", "failed"]);
const label = (value: string) => value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
const count = (value: unknown) => new Intl.NumberFormat("en-IN").format(Number(value ?? 0));

async function jsonRequest<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({})) as T & { error?: string };
  if (!response.ok) throw new Error(body.error || "Email verification request failed.");
  return body;
}

export default function EmailVerificationPanel({ open, search, filters, companyScope, onClose }: {
  open: boolean; search: string; filters: ProspectFilter[]; companyScope: CompanyScope | null; onClose: () => void;
}) {
  const hasMatchingScope = Boolean(search.trim() || filters.length || companyScope);
  const [data, setData] = useState<StatusPayload>({});
  const [loading, setLoading] = useState(false);
  const [statusLoaded, setStatusLoaded] = useState(false);
  const [clock, setClock] = useState(0);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [runScope, setRunScope] = useState<ManualScope>(hasMatchingScope ? "filtered" : "all");
  const [confirmScope, setConfirmScope] = useState<ManualScope | null>(null);
  const [forceReverify, setForceReverify] = useState(false);
  const [limitMode, setLimitMode] = useState<LimitMode>("10000");
  const [customEmails, setCustomEmails] = useState("10000");
  const [confirmationRequestId, setConfirmationRequestId] = useState("");
  const panel = useRef<HTMLElement>(null);
  const reviewLauncher = useRef<HTMLButtonElement | null>(null);
  const confirmationBack = useRef<HTMLButtonElement | null>(null);
  const closeConfirmation = useCallback(() => {
    setConfirmScope(null); setConfirmationRequestId("");
    window.setTimeout(() => reviewLauncher.current?.focus(), 0);
  }, []);
  useDialogFocus(panel, { onClose: confirmScope ? closeConfirmation : onClose, busy: Boolean(busy) });
  const effectiveScope = runScope === "filtered" && !hasMatchingScope ? "all" : runScope;

  function selectedMaxEmails(): number | undefined {
    if (limitMode === "all") return undefined;
    if (limitMode !== "custom") return Number(limitMode);
    if (!/^\d+$/.test(customEmails.trim())) throw new Error("Enter a whole number of emails to verify.");
    return parseManualVerificationEmailLimit(Number(customEmails));
  }
  let limitError = "";
  try { selectedMaxEmails(); }
  catch (caught) { limitError = caught instanceof Error ? caught.message : "Enter a valid email limit."; }
  const displayedLimit = limitMode === "all" ? "All eligible work emails"
    : limitError ? "Choose a valid email limit" : `Up to ${count(limitMode === "custom" ? customEmails : limitMode)} unique work emails`;

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const status = await jsonRequest<StatusPayload>("/api/verifications", { cache: "no-store" });
      setData(status); setClock(Date.now()); setStatusLoaded(true);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load verification status."); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => {
    if (!open) return;
    const initial = window.setTimeout(() => void refresh(), 0);
    const timer = window.setInterval(() => void refresh(), 5000);
    return () => { window.clearTimeout(initial); window.clearInterval(timer); };
  }, [open, refresh]);

  useEffect(() => { if (confirmScope) confirmationBack.current?.focus(); }, [confirmScope]);

  const active = useMemo(() => (data.runs ?? []).filter((run) => !terminal.has(run.status)), [data.runs]);

  async function createRun() {
    if (!confirmScope) return;
    setBusy("create"); setError(""); setNotice("");
    try {
      const parsedMaxEmails = selectedMaxEmails();
      const requestId = confirmationRequestId || crypto.randomUUID();
      setConfirmationRequestId(requestId);
      let created = false;
      for (let attempt = 0; attempt < 30 && !created; attempt += 1) {
        const result = await jsonRequest<{ run?: unknown; preparation?: { message?: string } }>("/api/verifications", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            requestId, scope: confirmScope, forceReverify,
            ...(parsedMaxEmails === undefined ? {} : { maxEmails: parsedMaxEmails }),
            ...(confirmScope === "filtered" ? { search: search.trim(), filters: filterPayload(filters), companyScope } : {}),
          }),
        });
        if (result.run) { created = true; break; }
        if (!result.preparation) throw new Error("The verification run was not created.");
        setNotice(result.preparation.message || "Preparing the matching companies…");
        await new Promise((resolve) => window.setTimeout(resolve, 2000));
      }
      if (!created) throw new Error("The matching company scope is still preparing. Try again in a moment; the same request will be reused.");
      setConfirmScope(null); setConfirmationRequestId(""); setNotice(""); await refresh();
    } catch (caught) { setNotice(""); setError(caught instanceof Error ? caught.message : "Unable to start verification."); }
    finally { setBusy(""); }
  }

  async function controlRun(run: VerificationRun, action: "pause" | "continue" | "cancel") {
    setBusy(`${run.id}:${action}`); setError("");
    try {
      await jsonRequest(`/api/verifications/${encodeURIComponent(run.id)}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action }) });
      await refresh();
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to update verification run."); }
    finally { setBusy(""); }
  }

  async function controlProvider(action: "start" | "pause" | "continue" | "stop") {
    setBusy(`provider:${action}`); setError("");
    try {
      await jsonRequest("/api/verifications/provider", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action }) });
      await refresh();
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to update provider dispatch."); }
    finally { setBusy(""); }
  }

  if (!open) return null;
  const provider = data.provider ?? {};
  const heartbeatFresh = Boolean(provider.worker_seen_at && clock - Date.parse(provider.worker_seen_at) < 90_000);
  const providerConfigured = provider.worker_configured === true;
  const providerReady = providerConfigured && heartbeatFresh;
  const quotaWaiting = Boolean(provider.quota_wait_until && Date.parse(provider.quota_wait_until) > clock);
  const coolingDown = Boolean(provider.cooldown_until && Date.parse(provider.cooldown_until) > clock);
  const providerRunning = providerReady && provider.enabled === true && provider.manually_paused !== true && !quotaWaiting && !coolingDown;
  const providerTitle = !statusLoaded ? "Checking verification worker"
    : !providerConfigured ? "Worker needs its dedicated key"
    : !heartbeatFresh ? "Verification worker is offline"
    : provider.manually_paused ? "Verification paused"
    : quotaWaiting ? "Waiting for daily allowance"
    : coolingDown ? "Temporarily paused"
    : providerRunning ? "Verification running" : "Verification stopped";
  const providerDetail = !statusLoaded ? "Loading provider status…"
    : provider.pause_reason || (providerConfigured
      ? `${count(provider.daily_attempts)} of ${count(provider.daily_limit)} checks used in the rolling day`
      : "Add the dedicated MailTesterNinja key on the server to enable dispatch.");
  const openConfirmation = () => {
    if (limitError) return;
    setConfirmationRequestId(crypto.randomUUID());
    setConfirmScope(effectiveScope);
    setError("");
    setNotice("");
  };
  return <DialogBackdrop className="verification-backdrop">
    <section ref={panel} className="verification-modal" role="dialog" aria-modal="true" aria-labelledby={confirmScope ? "verify-confirm-title" : "verification-title"}>
    {confirmScope ? <div className="verification-confirm-view">
      <div><p className="eyebrow">REVIEW RUN</p><h2 id="verify-confirm-title">Review verification run</h2><p>Confirm the scope and limit before creating a background run.</p></div>
      <div className="verification-review-summary">
        <div><span>Database scope</span><strong>{confirmScope === "all" ? "Master People" : "Current search & filters"}</strong><small>{confirmScope === "all" ? "Across the entire Master database, not just this page." : "Your current search, filters and company scope are frozen across all pages."}</small></div>
        <div><span>Email selection</span><strong>{displayedLimit}</strong><small>People sharing a selected work email stay together.</small></div>
        <div><span>Existing results</span><strong>{forceReverify ? "Recheck unchanged emails" : "Reuse unchanged results"}</strong><small>{forceReverify ? "This can use additional provider checks." : "Reused results do not use a new provider check."}</small></div>
      </div>
      <p className="verification-review-note">{providerRunning ? "The provider is already running. Checks can begin when preparation finishes." : "This run will wait until you select Start provider. Creating it does not start provider dispatch."}</p>
      {notice ? <p className="verification-notice" role="status">{notice}</p> : null}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="modal-actions verification-review-actions"><button ref={confirmationBack} data-autofocus className="secondary" disabled={busy === "create"} onClick={closeConfirmation}>Back to setup</button><button className="primary" disabled={busy === "create"} onClick={() => void createRun()}>{busy === "create" ? "Preparing run…" : "Create run"}</button></div>
    </div> : <>
      <header><div><p className="eyebrow">MASTER PEOPLE · EMAIL QUALITY</p><h2 id="verification-title">Work email verification</h2><p>Run a controlled batch of MailTesterNinja checks. Results are saved as labels and never remove people from exports or client pushes.</p></div><button className="icon-button" data-autofocus aria-label="Close verification" onClick={onClose}><AppIcon name="close" size={16}/></button></header>
      <div className={"verification-provider" + (providerRunning ? " running" : " paused")}>
        <div><span className="verification-dot" aria-hidden="true"/><div><strong>{providerTitle}</strong><small>{providerDetail}</small></div></div>
        <div>{providerRunning ? <button className="secondary" disabled={Boolean(busy)} onClick={() => void controlProvider("pause")}>Pause provider</button> : <button className="secondary" disabled={Boolean(busy) || !providerReady} onClick={() => void controlProvider(provider.enabled ? "continue" : "start")}>Start provider</button>}</div>
      </div>
      <section className="verification-setup" aria-labelledby="verification-setup-title">
        <div className="verification-section-heading"><div><p className="eyebrow">NEW RUN</p><h3 id="verification-setup-title">Choose what to verify</h3></div><span className="verification-setup-tag">Background job</span></div>
        <div className="verification-setting">
          <span className="verification-setting-label">1. Database scope</span>
          <div className="verification-scope-options" role="group" aria-label="Verification scope">
            <button type="button" className={effectiveScope === "filtered" ? "selected" : ""} aria-pressed={effectiveScope === "filtered"} disabled={!hasMatchingScope} onClick={() => setRunScope("filtered")}><strong>Current search & filters</strong><small>{hasMatchingScope ? "Only people matching this view, across every page" : "Apply a search or filter to use this scope"}</small></button>
            <button type="button" className={effectiveScope === "all" ? "selected" : ""} aria-pressed={effectiveScope === "all"} onClick={() => setRunScope("all")}><strong>Master People</strong><small>All eligible work emails in the Master database</small></button>
          </div>
        </div>
        <div className="verification-setting">
          <span className="verification-setting-label">2. Maximum unique work emails</span>
          <div className="verification-limit-options" role="group" aria-label="Maximum unique work emails">
            <button type="button" className={limitMode === "100" ? "selected" : ""} aria-pressed={limitMode === "100"} onClick={() => setLimitMode("100")}>100</button>
            <button type="button" className={limitMode === "1000" ? "selected" : ""} aria-pressed={limitMode === "1000"} onClick={() => setLimitMode("1000")}>1,000</button>
            <button type="button" className={limitMode === "10000" ? "selected" : ""} aria-pressed={limitMode === "10000"} onClick={() => setLimitMode("10000")}>10,000</button>
            <button type="button" className={limitMode === "custom" ? "selected" : ""} aria-pressed={limitMode === "custom"} onClick={() => setLimitMode("custom")}>Custom</button>
            <button type="button" className={limitMode === "all" ? "selected" : ""} aria-pressed={limitMode === "all"} onClick={() => setLimitMode("all")}>All eligible</button>
          </div>
          {limitMode === "custom" ? <div className="verification-custom-limit"><label htmlFor="verification-max-emails">Maximum unique work emails</label><input id="verification-max-emails" type="number" inputMode="numeric" min={1} max={MAX_MANUAL_VERIFICATION_EMAILS} step={1} aria-invalid={Boolean(limitError)} aria-describedby="verification-limit-help" value={customEmails} onChange={(event) => setCustomEmails(event.target.value)}/></div> : null}
          <small id="verification-limit-help" className={limitError ? "verification-limit-help invalid" : "verification-limit-help"}>{limitError || "A limit selects distinct work emails. People sharing an address stay together; existing completed results are reused by default."}</small>
        </div>
        <details className="verification-advanced"><summary>More options</summary><label className="inline-checkbox" htmlFor="verification-force-recheck"><input id="verification-force-recheck" aria-label="Reverify completed unchanged emails" type="checkbox" checked={forceReverify} onChange={(event) => setForceReverify(event.target.checked)}/> Reverify completed unchanged emails</label><small>Leave this off to preserve the original verified date and avoid a new provider check for unchanged emails.</small></details>
        <div className="verification-setup-footer"><div><strong>{displayedLimit}</strong><small>{providerRunning ? "The worker can start this run after preparation." : "The run will wait until you start provider dispatch."}</small></div><button ref={reviewLauncher} className="primary" disabled={Boolean(limitError)} onClick={openConfirmation}>Review verification <AppIcon name="arrow" size={15}/></button></div>
      </section>
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="verification-runs-head"><div><p className="eyebrow">ACTIVITY</p><h3>Verification runs</h3></div><button className="secondary" disabled={loading} onClick={() => void refresh()}>{loading ? "Refreshing…" : "Refresh"}</button></div>
      <div className="verification-run-list">
        {(data.runs ?? []).length ? (data.runs ?? []).map((run) => {
          const percent = run.total_count ? Math.min(100, Math.round((run.processed_count / run.total_count) * 100)) : 0;
          return <article className="verification-run" key={run.id}>
            <div className="verification-run-title"><div><strong>{run.scope === "all" ? "Master People" : run.scope === "import" ? "Import verification" : "Current filters"}{run.max_emails != null ? " · Up to " + count(run.max_emails) + " emails" : ""}</strong><span className={`verification-state state-${run.status}`}>{label(run.status)}</span></div><time>{new Date(run.created_at).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })}</time></div>
            <div className="verification-progress" role="progressbar" aria-label={`${percent}% complete`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}><i style={{ width: `${percent}%` }}/></div>
            <div className="verification-run-metrics"><span><strong>{count(run.processed_count)} / {count(run.total_count)}</strong> people processed</span>{run.selected_email_count != null ? <span><strong>{count(run.selected_email_count)}</strong> emails selected</span> : null}</div>
            <div className="verification-run-counts">{run.eligible_email_count != null ? <span>{count(run.eligible_email_count)} emails eligible</span> : null}{run.max_emails != null ? <span>{count(run.max_emails)} requested limit</span> : null}<span>{count(run.reused_count)} people reused</span>{run.error_count ? <span>{count(run.error_count)} errors</span> : null}</div>
            {run.last_error ? <p className="form-error">{run.last_error}</p> : null}
            {!terminal.has(run.status) ? <div className="verification-run-controls">{run.status === "paused" ? <button disabled={Boolean(busy)} onClick={() => void controlRun(run, "continue")}>Continue same run</button> : <button disabled={Boolean(busy)} onClick={() => void controlRun(run, "pause")}>Pause</button>}<button className="danger-button" disabled={Boolean(busy)} onClick={() => void controlRun(run, "cancel")}>Cancel</button></div> : null}
          </article>;
        }) : <div className="verification-empty">{loading || !statusLoaded ? "Loading runs…" : "No verification runs yet. Your first bounded run will appear here."}</div>}
      </div>
      <footer><span>{active.length ? `${active.length} active run${active.length === 1 ? "" : "s"}` : "No active runs"}</span><button className="secondary" onClick={onClose}>Close</button></footer>
    </>}
    </section>
  </DialogBackdrop>;
}
