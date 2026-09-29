"use client";

import { useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { summarizeIcpLabels, type IcpLabel } from "../../lib/icp-labels";
import type { ClientIcpProfile, Company } from "../../lib/types";
import { ICP_MODELS, REASONING_EFFORTS, estimateRunCost, sourceLabel } from "../../worker/icp-validator-core.mjs";
import { Tooltip } from "./DashboardUi";

// The ICP validator inside the client Company DB: the verdicts on each row,
// and "Validate ICP" for the current selection. The runs themselves are
// followed and browsed on the client's ICP Validator tab.

// Verdicts for the companies on the page. Re-read whenever the page's rows
// are re-read, so a finished run shows up with the next refresh.
export function useIcpLabels(clientId: string, companies: Company[]) {
  const [labels, setLabels] = useState<{ key: string; byCompany: Map<string, IcpLabel[]> }>({ key: "", byCompany: new Map() });
  const ids = useMemo(() => companies.map((company) => company.id).slice(0, 200).join(","), [companies]);

  useEffect(() => {
    if (!clientId || !ids) return;
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ labels: IcpLabel[] }>(`/api/clients/${encodeURIComponent(clientId)}/icp-validator?view=labels&ids=${encodeURIComponent(ids)}`, { cache: "no-store" })
        .then((result) => {
          if (cancelled) return;
          const byCompany = new Map<string, IcpLabel[]>();
          for (const label of result.labels ?? []) {
            const list = byCompany.get(label.company_id) ?? [];
            list.push(label);
            byCompany.set(label.company_id, list);
          }
          setLabels({ key: ids, byCompany });
        })
        // Decoration: a table without verdicts is better than no table.
        .catch(() => {});
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [clientId, ids, companies]);

  return labels.key === ids ? labels.byCompany : new Map<string, IcpLabel[]>();
}

const verdictText = { FIT: "FIT", NON_FIT: "NON_FIT", MIXED: "Mixed", STALE: "Stale" } as const;

export function IcpCheckCell({ labels }: { labels: IcpLabel[] | undefined }) {
  if (!labels?.length) return <span className="icpv-muted">-</span>;
  const summaries = summarizeIcpLabels(labels);
  return <div className="icpv-cell">{summaries.map((summary) => {
    const detail = summary.labels
      .map((label) => `${sourceLabel(label.source)}: ${label.verdict}${label.current ? "" : " (stale)"}${label.reason ? ` - ${label.reason}` : ""}`)
      .join("\n");
    const counts = summary.verdict === "MIXED" ? ` ${summary.nonFit}/${summary.fit + summary.nonFit}` : "";
    return <Tooltip key={summary.icpId} content={`${summary.icpName}\n${detail}`}>
      <span className={`data-pill icpv-verdict icpv-verdict-${summary.verdict.toLowerCase()}`}>
        {summaries.length > 1 ? <small>{summary.icpName}: </small> : null}{verdictText[summary.verdict]}{counts}
      </span>
    </Tooltip>;
  })}</div>;
}

export function IcpValidateDialog({ clientId, clientName, selectedCount, selection, onClose, onStarted }: {
  clientId: string;
  clientName: string;
  selectedCount: number;
  selection: Record<string, unknown>;
  onClose: () => void;
  onStarted: (message: string) => void;
}) {
  const [profiles, setProfiles] = useState<ClientIcpProfile[] | null>(null);
  const [icpId, setIcpId] = useState("");
  const [models, setModels] = useState<string[]>(() => ICP_MODELS.map((model) => model.id));
  const [effort, setEffort] = useState("low");
  const [reuse, setReuse] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ profiles: ClientIcpProfile[] }>(`/api/clients/${encodeURIComponent(clientId)}/icp`, { cache: "no-store" })
        .then((result) => { if (!cancelled) setProfiles(result.profiles); })
        .catch((caught) => { if (!cancelled) { setProfiles([]); setError(caught instanceof Error ? caught.message : "Unable to load ICPs."); } });
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [clientId]);

  const usable = (profiles ?? []).filter((profile) => profile.description.trim());
  const chosen = usable.find((profile) => profile.id === icpId) ?? usable[0] ?? null;
  const estimate = models.reduce((sum, model) => sum + (estimateRunCost(model, selectedCount, { effort, briefLength: chosen?.description.length ?? 800 }) ?? 0), 0);

  async function start() {
    if (!chosen || !models.length) return;
    setBusy(true); setError("");
    try {
      const result = await api<{ selected: number; runs: Array<{ cached_items: number; total_items: number }> }>(
        `/api/clients/${encodeURIComponent(clientId)}/icp-validator`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "start_selection", icpId: chosen.id, models, effort, reuse, ...selection }),
        });
      const reused = result.runs.reduce((sum, run) => sum + Number(run.cached_items ?? 0), 0);
      onStarted(`Checking ${formatNumber(result.selected)} ${result.selected === 1 ? "company" : "companies"} against ${chosen.name || "the ICP"} with ${result.runs.length} model${result.runs.length === 1 ? "" : "s"}${reused ? ` (${formatNumber(reused)} earlier verdicts reused)` : ""}. Verdicts fill the ICP check column as they arrive; follow progress on the ICP Validator tab.`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to start the check.");
      setBusy(false);
    }
  }

  return <div className="modal-backdrop" role="presentation">
    <section className="confirm-modal icpv-dialog" role="dialog" aria-modal="true" aria-labelledby="icpv-dialog-title">
      <p className="eyebrow">ICP VALIDATOR</p>
      <h2 id="icpv-dialog-title">Validate {formatNumber(selectedCount)} {selectedCount === 1 ? "company" : "companies"}</h2>
      <p>Each model reads the company&apos;s description and keywords and labels it FIT or NON_FIT for {clientName}&apos;s ICP. Labels only - nothing is hidden or removed.</p>
      {profiles === null ? <div className="workspace-loading">Loading ICPs…</div> : !usable.length
        ? <p className="form-error" role="alert">None of {clientName}&apos;s ICPs has a brief yet. Add one on the ICPs tab first.</p>
        : <>
          <div className="form-field">
            <label htmlFor="icpv-dialog-icp">ICP</label>
            <select id="icpv-dialog-icp" value={chosen?.id ?? ""} onChange={(event) => setIcpId(event.target.value)}>
              {usable.map((profile) => <option key={profile.id} value={profile.id}>{profile.name.trim() || "Untitled ICP"}</option>)}
            </select>
          </div>
          <fieldset className="icpv-fieldset">
            <legend>Models (each judges the same companies)</legend>
            {ICP_MODELS.map((model) => <label key={model.id} className="icpv-check">
              <input type="checkbox" checked={models.includes(model.id)}
                onChange={() => setModels((current) => current.includes(model.id) ? current.filter((item) => item !== model.id) : [...current, model.id])}/>
              <span>{model.label} <small className="icpv-sub">{model.id}</small></span>
            </label>)}
          </fieldset>
          <div className="form-field">
            <label htmlFor="icpv-dialog-effort">Reasoning effort</label>
            <select id="icpv-dialog-effort" value={effort} onChange={(event) => setEffort(event.target.value)}>
              {REASONING_EFFORTS.map((value: string) => <option key={value} value={value}>{value}</option>)}
            </select>
          </div>
          <label className="icpv-check"><input type="checkbox" checked={reuse} onChange={(event) => setReuse(event.target.checked)}/> Reuse earlier verdicts from the same model for this exact brief</label>
          <p className="icpv-estimate" role="status">{models.length ? `≈ $${estimate.toFixed(estimate < 1 ? 3 : 2)} (estimate)` : "Choose at least one model."}</p>
        </>}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="modal-actions">
        <button className="secondary" data-autofocus disabled={busy} onClick={onClose}>Cancel</button>
        <button className="primary" disabled={busy || !chosen || !models.length} onClick={() => void start()}>{busy ? "Starting…" : "Start validation"}</button>
      </div>
    </section>
  </div>;
}
