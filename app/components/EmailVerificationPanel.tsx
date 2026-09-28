"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { filterPayload } from "../../lib/dashboard-api";
import type { ProspectFilter } from "../../lib/types";
import type { CompanyScope } from "../../lib/workspace-scopes";
import { AppIcon, DialogBackdrop } from "./DashboardUi";
import { useDialogFocus } from "./use-dialog";

type VerificationRun = {
  id: string; scope: "all" | "filtered" | "import"; source: "manual" | "import";
  status: string; total_count: number; processed_count: number; reused_count: number;
  skipped_count: number; error_count: number; force_reverify: boolean; created_at: string;
  completed_at?: string | null; last_error?: string | null;
};
type ProviderState = {
  enabled?: boolean; manually_paused?: boolean; pause_reason?: string | null;
  cooldown_until?: string | null; quota_wait_until?: string | null;
  daily_attempts?: number; daily_limit?: number; worker_configured?: boolean; worker_seen_at?: string | null;
};
type StatusPayload = { runs?: VerificationRun[]; provider?: ProviderState | null };

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
  const [data, setData] = useState<StatusPayload>({});
  const [loading, setLoading] = useState(false);
  const [clock, setClock] = useState(0);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [confirmScope, setConfirmScope] = useState<"all" | "filtered" | null>(null);
  const [forceReverify, setForceReverify] = useState(false);
  const [confirmationRequestId, setConfirmationRequestId] = useState("");
  const panel = useRef<HTMLElement>(null);
  useDialogFocus(panel, { onClose, busy: Boolean(busy) });
  const hasMatchingScope = Boolean(search.trim() || filters.length || companyScope);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const status = await jsonRequest<StatusPayload>("/api/verifications", { cache: "no-store" });
      setData(status); setClock(Date.now());
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to load verification status."); }
    finally { setLoading(false); }
  }, []);

  useEffect(() => {
    if (!open) return;
    const initial = window.setTimeout(() => void refresh(), 0);
    const timer = window.setInterval(() => void refresh(), 5000);
    return () => { window.clearTimeout(initial); window.clearInterval(timer); };
  }, [open, refresh]);

  const active = useMemo(() => (data.runs ?? []).filter((run) => !terminal.has(run.status)), [data.runs]);

  async function createRun() {
    if (!confirmScope) return;
    setBusy("create"); setError("");
    try {
      const requestId = confirmationRequestId || crypto.randomUUID();
      setConfirmationRequestId(requestId);
      let created = false;
      for (let attempt = 0; attempt < 30 && !created; attempt += 1) {
        const result = await jsonRequest<{ run?: unknown; preparation?: { message?: string } }>("/api/verifications", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            requestId, scope: confirmScope, forceReverify,
            ...(confirmScope === "filtered" ? { search: search.trim(), filters: filterPayload(filters), companyScope } : {}),
          }),
        });
        if (result.run) { created = true; break; }
        if (!result.preparation) throw new Error("The verification run was not created.");
        setError(result.preparation.message || "Preparing the matching companies…");
        await new Promise((resolve) => window.setTimeout(resolve, 2000));
      }
      if (!created) throw new Error("The matching company scope is still preparing. Try again in a moment; the same request will be reused.");
      setConfirmScope(null); setForceReverify(false); await refresh();
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to start verification."); }
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
  const providerTitle = !providerConfigured ? "Worker needs its dedicated key"
    : !heartbeatFresh ? "Verification worker is offline"
    : provider.manually_paused ? "Provider dispatch is paused"
    : quotaWaiting ? "Provider quota wait"
    : coolingDown ? "Provider circuit is cooling down"
    : providerRunning ? "Provider dispatch is running" : "Provider dispatch is stopped";
  const openConfirmation = (scope: "all" | "filtered") => { setConfirmationRequestId(crypto.randomUUID()); setForceReverify(false); setConfirmScope(scope); setError(""); };
  return <DialogBackdrop className="verification-backdrop">
    <section ref={panel} className="verification-modal" role="dialog" aria-modal="true" aria-labelledby="verification-title">
      <header><div><p className="eyebrow">MASTER EMAIL VERIFICATION</p><h2 id="verification-title">Work email verification</h2><p>MailTester Ninja checks work emails in the background. Results are labels only and never remove people from exports, pushes or outreach.</p></div><button className="icon-button" data-autofocus aria-label="Close verification" onClick={onClose}><AppIcon name="close" size={16}/></button></header>
      <div className={`verification-provider ${providerRunning ? "running" : "paused"}`}>
        <div><span className="verification-dot"/><div><strong>{providerTitle}</strong><small>{provider.pause_reason || (providerConfigured ? `${count(provider.daily_attempts)} of ${count(provider.daily_limit)} checks used in the rolling day` : "Add MTN_API_KEY to the verification worker, then start dispatch here.")}</small></div></div>
        <div>{providerRunning ? <button disabled={Boolean(busy)} onClick={() => void controlProvider("pause")}>Pause provider</button> : <button disabled={Boolean(busy) || !providerReady} onClick={() => void controlProvider(provider.enabled ? "continue" : "start")}>Start provider</button>}</div>
      </div>
      <div className="verification-actions">
        <button className="primary" onClick={() => openConfirmation("all")}><AppIcon name="target" size={15}/> Verify all work emails</button>
        <button className="secondary" disabled={!hasMatchingScope} title={hasMatchingScope ? "Verify every record matching the current search and filters, across all pages" : "Apply a search, filter or company scope first"} onClick={() => openConfirmation("filtered")}><AppIcon name="filter" size={15}/> Verify matching people</button>
      </div>
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="verification-runs-head"><strong>Runs</strong><button disabled={loading} onClick={() => void refresh()}>{loading ? "Refreshing…" : "Refresh"}</button></div>
      <div className="verification-run-list">
        {(data.runs ?? []).length ? (data.runs ?? []).map((run) => {
          const percent = run.total_count ? Math.min(100, Math.round((run.processed_count / run.total_count) * 100)) : 0;
          return <article className="verification-run" key={run.id}>
            <div className="verification-run-title"><div><strong>{run.scope === "all" ? "Entire Master People" : run.scope === "import" ? "Import verification" : "Matching people"}</strong><span className={`verification-state state-${run.status}`}>{label(run.status)}</span></div><time>{new Date(run.created_at).toLocaleString("en-IN", { timeZone: "Asia/Kolkata" })}</time></div>
            <div className="verification-progress" aria-label={`${percent}% complete`}><i style={{ width: `${percent}%` }}/></div>
            <div className="verification-run-counts"><span><strong>{count(run.processed_count)}</strong> processed</span><span><strong>{count(run.total_count)}</strong> total</span><span><strong>{count(run.reused_count)}</strong> reused</span>{run.error_count ? <span><strong>{count(run.error_count)}</strong> errors</span> : null}</div>
            {run.last_error ? <p className="form-error">{run.last_error}</p> : null}
            {!terminal.has(run.status) ? <div className="verification-run-controls">{run.status === "paused" ? <button disabled={Boolean(busy)} onClick={() => void controlRun(run, "continue")}>Continue same run</button> : <button disabled={Boolean(busy)} onClick={() => void controlRun(run, "pause")}>Pause</button>}<button className="danger-button" disabled={Boolean(busy)} onClick={() => void controlRun(run, "cancel")}>Cancel</button></div> : null}
          </article>;
        }) : <div className="verification-empty">{loading ? "Loading runs…" : "No verification runs yet."}</div>}
      </div>
      <footer><span>{active.length ? `${active.length} active run${active.length === 1 ? "" : "s"}` : "No active runs"}</span><button className="secondary" onClick={onClose}>Close</button></footer>
    {confirmScope ? <div className="verification-confirm-layer" role="presentation"><section className="confirm-modal" role="alertdialog" aria-modal="true" aria-labelledby="verify-confirm-title">
      <p className="eyebrow">CONFIRM VERIFICATION</p><h2 id="verify-confirm-title">{confirmScope === "all" ? "Verify the entire Master People database?" : "Verify every matching person?"}</h2>
      <p>{confirmScope === "all" ? "This ignores the current page, search, filters and company pivot. Every Master record with a work email is included." : "The current search, filters, people-per-company limit and company scope are frozen across every result page."}</p>
      <label className="inline-checkbox" htmlFor="verification-force-recheck">Reverify completed unchanged emails<input id="verification-force-recheck" aria-label="Reverify completed unchanged emails" type="checkbox" disabled={busy === "create"} checked={forceReverify} onChange={(event) => { setForceReverify(event.target.checked); setConfirmationRequestId(crypto.randomUUID()); }}/><span><small>Leave off to reuse existing results and preserve their original verified date.</small></span></label>
      <div className="modal-actions"><button className="secondary" disabled={busy === "create"} onClick={() => { setConfirmScope(null); setForceReverify(false); setConfirmationRequestId(""); }}>Back</button><button className="primary" disabled={busy === "create"} onClick={() => void createRun()}>{busy === "create" ? "Preparing and starting…" : "Start verification"}</button></div>
    </section></div> : null}
    </section>
  </DialogBackdrop>;
}
