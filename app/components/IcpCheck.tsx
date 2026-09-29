"use client";

import { useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { summarizeIcpLabels, type IcpLabel } from "../../lib/icp-labels";
import type { IcpModelOption } from "../../lib/openrouter-models";
import type { ClientIcpProfile, Company } from "../../lib/types";
import { ICP_MODELS, MAX_MODELS_PER_CHECK, REASONING_EFFORTS, estimateRunCost, sourceLabel } from "../../worker/icp-validator-core.mjs";
import { Tooltip } from "./DashboardUi";

// The ICP validator inside the client Company DB: the verdicts on each row,
// "Validate ICP" for the current selection, and the model picker the ICP
// Validator tab shares. Runs are followed and browsed on that tab.

const defaultCatalog: IcpModelOption[] = ICP_MODELS.map((model) => ({
  id: model.id, label: model.label, inputPerM: model.inputPerM, outputPerM: model.outputPerM, contextLength: null, recommended: true,
}));

// Every OpenRouter model that can run a check (the server filters to JSON
// output + reasoning). The three defaults until it loads, or if it can't.
export function useIcpModelCatalog(clientId: string) {
  const [catalog, setCatalog] = useState<IcpModelOption[]>(defaultCatalog);
  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ models: IcpModelOption[] }>(`/api/clients/${encodeURIComponent(clientId)}/icp-validator?view=models`)
        .then((result) => { if (!cancelled && result.models?.length) setCatalog(result.models); })
        .catch(() => {});
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [clientId]);
  return catalog;
}

export function modelName(catalog: IcpModelOption[], id: string) {
  return catalog.find((model) => model.id === id)?.label ?? sourceLabel(id);
}

export function estimateModels(catalog: IcpModelOption[], models: string[], companies: number, effort: string, briefLength: number) {
  return models.reduce((sum, id) => {
    const model = catalog.find((item) => item.id === id) ?? id;
    return sum + (estimateRunCost(model, companies, { effort, briefLength }) ?? 0);
  }, 0);
}

const price = (model: IcpModelOption) => `$${model.inputPerM} in / $${model.outputPerM} out per 1M tokens`;

// The three defaults, plus any other OpenRouter model added from the search
// box. At most MAX_MODELS_PER_CHECK are ticked; they all judge the same
// companies.
export function ModelPicker({ catalog, selected, onChange, idPrefix }: {
  catalog: IcpModelOption[]; selected: string[]; onChange: (next: string[]) => void; idPrefix: string;
}) {
  const [added, setAdded] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const shown = useMemo(() => {
    const ids = [...catalog.filter((model) => model.recommended).map((model) => model.id), ...added, ...selected];
    return [...new Set(ids)].map((id) => catalog.find((model) => model.id === id)
      ?? { id, label: sourceLabel(id), inputPerM: 0, outputPerM: 0, contextLength: null, recommended: false });
  }, [catalog, added, selected]);
  const full = selected.length >= MAX_MODELS_PER_CHECK;
  const matches = useMemo(() => {
    const term = query.trim().toLowerCase();
    if (!term) return [];
    return catalog.filter((model) => !shown.some((item) => item.id === model.id)
      && (model.id.toLowerCase().includes(term) || model.label.toLowerCase().includes(term))).slice(0, 8);
  }, [catalog, query, shown]);

  function toggle(id: string) {
    onChange(selected.includes(id) ? selected.filter((item) => item !== id) : full ? selected : [...selected, id]);
  }
  function add(model: IcpModelOption) {
    setAdded((current) => current.includes(model.id) ? current : [...current, model.id]);
    if (!full && !selected.includes(model.id)) onChange([...selected, model.id]);
    setQuery("");
  }

  return <fieldset className="icpv-fieldset icpv-model-picker">
    <legend>Models - up to {MAX_MODELS_PER_CHECK}, each judges the same companies ({selected.length} chosen)</legend>
    {shown.map((model) => {
      const checked = selected.includes(model.id);
      return <label key={model.id} className="icpv-check">
        <input type="checkbox" checked={checked} disabled={!checked && full} onChange={() => toggle(model.id)}/>
        <span>{model.label}{model.recommended ? <small className="icpv-tag">default</small> : null}
          <small className="icpv-sub">{model.id}{model.inputPerM || model.outputPerM ? ` · ${price(model)}` : ""}</small></span>
      </label>;
    })}
    <div className="icpv-model-search">
      <label htmlFor={`${idPrefix}-model-search`}>Add another OpenRouter model</label>
      <input id={`${idPrefix}-model-search`} type="search" value={query} placeholder="Search e.g. claude, gemini, qwen, llama…"
        onChange={(event) => setQuery(event.target.value)}/>
      {matches.length ? <ul className="icpv-model-results" role="listbox" aria-label="Matching models">
        {matches.map((model) => <li key={model.id}>
          <button type="button" onClick={() => add(model)}>
            <strong>{model.label}</strong><small className="icpv-sub">{model.id} · {price(model)}</small>
          </button>
        </li>)}
      </ul> : query.trim() ? <small className="icpv-sub">No OpenRouter model matching &ldquo;{query.trim()}&rdquo; supports JSON output and reasoning.</small> : null}
      {full ? <small className="icpv-sub">Untick a model to choose a different one.</small> : null}
    </div>
  </fieldset>;
}

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
  const catalog = useIcpModelCatalog(clientId);
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
  const estimate = estimateModels(catalog, models, selectedCount, effort, chosen?.description.length ?? 800);

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
      onStarted(`Checking ${formatNumber(result.selected)} ${result.selected === 1 ? "company" : "companies"} against ${chosen.name || "the ICP"} with ${models.map((id) => modelName(catalog, id)).join(", ")}${reused ? ` (${formatNumber(reused)} earlier verdicts reused)` : ""}. Verdicts fill the ICP check column as they arrive; follow progress on the ICP Validator tab.`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to start the check.");
      setBusy(false);
    }
  }

  return <div className="modal-backdrop" role="presentation">
    <section className="confirm-modal icpv-dialog" role="dialog" aria-modal="true" aria-labelledby="icpv-dialog-title">
      <p className="eyebrow">ICP VALIDATOR</p>
      <h2 id="icpv-dialog-title">Validate {formatNumber(selectedCount)} {selectedCount === 1 ? "company" : "companies"}</h2>
      <p>Each model reads the company&apos;s description and keywords and labels it FIT or NON_FIT for {clientName}&apos;s ICP. Labels only - nothing is hidden or removed. Companies with no description and no keywords are skipped.</p>
      {profiles === null ? <div className="workspace-loading">Loading ICPs…</div> : !usable.length
        ? <p className="form-error" role="alert">None of {clientName}&apos;s ICPs has a brief yet. Add one on the ICPs tab first.</p>
        : <>
          <div className="form-field">
            <label htmlFor="icpv-dialog-icp">ICP</label>
            <select id="icpv-dialog-icp" value={chosen?.id ?? ""} onChange={(event) => setIcpId(event.target.value)}>
              {usable.map((profile) => <option key={profile.id} value={profile.id}>{profile.name.trim() || "Untitled ICP"}</option>)}
            </select>
          </div>
          <ModelPicker catalog={catalog} selected={models} onChange={setModels} idPrefix="icpv-dialog"/>
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
