"use client";

import { useEffect, useMemo, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { summarizeIcpLabels, type IcpLabel } from "../../lib/icp-labels";
import type { IcpModelOption } from "../../lib/openrouter-models";
import type { ClientIcpProfile, Company } from "../../lib/types";
import { ICP_MODELS, MAX_MODELS_PER_CHECK, REASONING_EFFORTS, estimateRunCost, sourceLabel } from "../../worker/icp-validator-core.mjs";
import { Tooltip } from "./DashboardUi";
import { StrategyPicker, strategyLabel, type StrategyId } from "./IcpStrategyPicker";
import { Segmented } from "./IcpValidatorViews";
import { Select } from "./ListboxPicker";

// The ICP validator inside the client Company DB: the verdicts on each row,
// "Validate ICP" for the current selection, and the model picker the ICP
// Validator tab shares. Runs are followed and browsed on that tab.

const defaultCatalog: IcpModelOption[] = ICP_MODELS.map((model) => ({
  id: model.id, label: model.label, inputPerM: model.inputPerM, outputPerM: model.outputPerM, contextLength: null, recommended: true,
}));

// Every OpenRouter model that can run a check (the server filters to JSON
// output + reasoning). The three defaults until it loads, or if it can't.
// ...and the team's default models (pre-ticked, listed first), which anyone
// can change with saveDefaults. Until the server answers, the built-in three.
export type IcpModelCatalog = {
  catalog: IcpModelOption[];
  defaults: string[];
  loaded: boolean;
  saveDefaults: (models: string[]) => Promise<void>;
};

export function useIcpModelCatalog(clientId: string): IcpModelCatalog {
  const [state, setState] = useState<{ catalog: IcpModelOption[]; defaults: string[]; loaded: boolean }>(
    { catalog: defaultCatalog, defaults: defaultCatalog.map((model) => model.id), loaded: false });
  const base = `/api/clients/${encodeURIComponent(clientId)}/icp-validator`;
  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ models: IcpModelOption[]; defaults?: string[] }>(`${base}?view=models`, { cache: "no-store" })
        .then((result) => {
          if (cancelled || !result.models?.length) return;
          setState({ catalog: result.models, defaults: result.defaults?.length ? result.defaults : defaultCatalog.map((model) => model.id), loaded: true });
        })
        .catch(() => {});
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [base]);

  const saveDefaults = async (models: string[]) => {
    const result = await api<{ defaults: string[] }>(base, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "set_default_models", models }),
    });
    setState((current) => {
      const saved = result.defaults;
      const byId = new Map(current.catalog.map((model) => [model.id, model]));
      const first = saved.map((id) => ({ ...(byId.get(id) ?? { id, label: sourceLabel(id), inputPerM: 0, outputPerM: 0, contextLength: null }), recommended: true }));
      const rest = current.catalog.filter((model) => !saved.includes(model.id)).map((model) => ({ ...model, recommended: false }));
      return { catalog: [...first, ...rest], defaults: saved, loaded: true };
    });
  };

  return { ...state, saveDefaults };
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
export function ModelPicker({ catalog, selected, onChange, idPrefix, defaults, onSaveDefaults }: {
  catalog: IcpModelOption[]; selected: string[]; onChange: (next: string[]) => void; idPrefix: string;
  defaults?: string[]; onSaveDefaults?: (models: string[]) => Promise<void>;
}) {
  const [added, setAdded] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveState, setSaveState] = useState<{ tone: "ok" | "error"; text: string } | null>(null);
  // Offered only when the ticks differ from what the team saved.
  const differs = Boolean(defaults && selected.length
    && (selected.length !== defaults.length || selected.some((id) => !defaults.includes(id))));

  async function saveAsDefaults() {
    if (!onSaveDefaults) return;
    setSaving(true); setSaveState(null);
    try {
      await onSaveDefaults(selected);
      setSaveState({ tone: "ok", text: "Saved. New checks start with these models for everyone." });
    } catch (caught) {
      setSaveState({ tone: "error", text: caught instanceof Error ? caught.message : "Unable to save the default models." });
    } finally { setSaving(false); }
  }
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

  return <fieldset className="icpx-models">
    <legend><span>Models</span><small>{selected.length} of {MAX_MODELS_PER_CHECK} chosen</small></legend>
    <div className="icpx-model-grid">{shown.map((model) => {
      const checked = selected.includes(model.id);
      return <label key={model.id} className={`icpx-model-option${checked ? " is-on" : ""}${!checked && full ? " is-disabled" : ""}`}>
        <input type="checkbox" checked={checked} disabled={!checked && full} onChange={() => toggle(model.id)}/>
        <span className="icpx-check" aria-hidden="true"/>
        <span className="icpx-model-option-copy">
          <strong>{model.label}{model.recommended ? <em>default</em> : null}</strong>
          <code>{model.id}</code>
          {model.inputPerM || model.outputPerM ? <small>${model.inputPerM} in · ${model.outputPerM} out / 1M</small> : null}
        </span>
      </label>;
    })}</div>
    <div className="icpx-model-search">
      <label className="icpx-search">
        <span className="sr-only">Add another OpenRouter model</span>
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
        <input id={`${idPrefix}-model-search`} type="search" value={query} placeholder="Add any OpenRouter model - claude, gemini, qwen…"
          onChange={(event) => setQuery(event.target.value)}/>
      </label>
      {matches.length ? <ul className="icpx-model-results" role="listbox" aria-label="Matching models">
        {matches.map((model) => <li key={model.id}>
          <button type="button" onClick={() => add(model)} title={price(model)}>
            <span><strong>{model.label}</strong><code>{model.id}</code></span><small>${model.inputPerM} / ${model.outputPerM}</small>
          </button>
        </li>)}
      </ul> : query.trim() ? <p className="icpx-help">No OpenRouter model matching &ldquo;{query.trim()}&rdquo; supports JSON output and reasoning.</p> : null}
      {full ? <p className="icpx-help">Untick a model to swap in a different one.</p> : null}
    </div>
    {onSaveDefaults && (differs || saveState) ? <div className="icpx-defaults">
      {differs ? <button type="button" className="icpx-link-button" disabled={saving} onClick={() => void saveAsDefaults()}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" aria-hidden="true"><path d="m12 3 2.6 5.6 6.1.7-4.5 4.2 1.2 6L12 16.6 6.6 19.5l1.2-6L3.3 9.3l6.1-.7z"/></svg>
        {saving ? "Saving…" : `Make ${selected.length === 1 ? "this the default model" : "these the default models"}`}
      </button> : null}
      {saveState ? <span className={`icpx-defaults-note is-${saveState.tone}`} role={saveState.tone === "error" ? "alert" : "status"}>{saveState.text}</span> : null}
    </div> : null}
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
    const counts = summary.verdict === "MIXED" ? ` ${summary.nonFit}/${summary.fit + summary.nonFit}` : summary.method ? ` · ${summary.method}` : "";
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
  const modelCatalog = useIcpModelCatalog(clientId);
  const catalog = modelCatalog.catalog;
  const [profiles, setProfiles] = useState<ClientIcpProfile[] | null>(null);
  const [icpId, setIcpId] = useState("");
  // The team defaults until the user changes the ticks.
  const [picked, setModels] = useState<string[] | null>(null);
  const models = picked ?? modelCatalog.defaults;
  const [effort, setEffort] = useState("low");
  const [reuse, setReuse] = useState(true);
  // Production: one of the three voting methods. "Compare models" is the
  // ICP Validator's testing path, kept for trying other models.
  const [method, setMethod] = useState<"strategy" | "models">("strategy");
  const [strategy, setStrategy] = useState<StrategyId>("balanced");
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
    if (!chosen) return;
    if (method === "strategy") {
      setBusy(true); setError("");
      try {
        const result = await api<{ check: { total_items: number; skipped_items?: number } }>("/api/icp-checks", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "start", clientId, icpId: chosen.id, strategy, providerMode: "cheapest", force: false, autoApply: true, scope: "selection", ...selection }),
        });
        const skipped = Number(result.check.skipped_items ?? 0);
        onStarted(`${strategyLabel(strategy)} check started on ${formatNumber(result.check.total_items)} ${result.check.total_items === 1 ? "company" : "companies"} against ${chosen.name || "the ICP"}${skipped ? ` (${formatNumber(skipped)} already checked were skipped)` : ""}. Results fill the ICP check column as the votes decide them; follow progress on the client's ICP checks tab.`);
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : "Unable to start the check.");
        setBusy(false);
      }
      return;
    }
    if (!models.length) return;
    setBusy(true); setError("");
    try {
      const result = await api<{ selected: number; runs: Array<{ cached_items: number; total_items: number }> }>(
        `/api/clients/${encodeURIComponent(clientId)}/icp-validator`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "start_selection", icpId: chosen.id, models, effort, reuse, ...selection }),
        });
      const reused = result.runs.reduce((sum, run) => sum + Number(run.cached_items ?? 0), 0);
      onStarted(`Checking ${formatNumber(result.selected)} ${result.selected === 1 ? "company" : "companies"} against ${chosen.name || "the ICP"} with ${models.map((id) => modelName(catalog, id)).join(", ")}${reused ? ` (${formatNumber(reused)} earlier verdicts reused)` : ""}. Verdicts fill the ICP check column as they arrive; follow progress on the ICP validator page (Data tools).`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to start the check.");
      setBusy(false);
    }
  }

  return <div className="modal-backdrop" role="presentation">
    <section className="confirm-modal icpv-dialog" role="dialog" aria-modal="true" aria-labelledby="icpv-dialog-title">
      <p className="eyebrow">ICP VALIDATOR</p>
      <h2 id="icpv-dialog-title">Validate {formatNumber(selectedCount)} {selectedCount === 1 ? "company" : "companies"}</h2>
      <p>Models read each company&apos;s description and keywords and label it FIT or NON_FIT for {clientName}&apos;s ICP. {method === "strategy" ? <>FIT companies are marked ICP verified and NON_FIT domains go to the client&apos;s blocklist. Companies already checked for this ICP are skipped.</> : "Labels only - nothing is hidden or removed."} Companies with no description and no keywords are skipped.</p>
      {profiles === null ? <div className="workspace-loading">Loading ICPs…</div> : !usable.length
        ? <p className="form-error" role="alert">None of {clientName}&apos;s ICPs has a brief yet. Add one on the ICPs tab first.</p>
        : <>
          <div className="form-field">
            <label htmlFor="icpv-dialog-icp">ICP</label>
            <Select id="icpv-dialog-icp" value={chosen?.id ?? ""} onChange={(event) => setIcpId(event.target.value)}>
              {usable.map((profile) => <option key={profile.id} value={profile.id}>{profile.name.trim() || "Untitled ICP"}</option>)}
            </Select>
          </div>
          <Segmented label="How to check" value={method} onChange={setMethod} options={[
            { value: "strategy", label: "Method", hint: "Strict, Balanced or Lenient - the production setups" },
            { value: "models", label: "Compare models", hint: "Pick models yourself, for testing" },
          ]}/>
          {method === "strategy" ? <>
            <StrategyPicker name="icpv-dialog-strategy" value={strategy} onChange={setStrategy} companies={selectedCount} briefLength={chosen?.description.length}/>
          </> : <>
            <ModelPicker catalog={catalog} selected={models} onChange={setModels} idPrefix="icpv-dialog" defaults={modelCatalog.defaults} onSaveDefaults={modelCatalog.saveDefaults}/>
            <div className="form-field">
              <label htmlFor="icpv-dialog-effort">Reasoning effort</label>
              <Select id="icpv-dialog-effort" value={effort} onChange={(event) => setEffort(event.target.value)}>
                {REASONING_EFFORTS.map((value: string) => <option key={value} value={value}>{value}</option>)}
              </Select>
            </div>
            <label className="icpv-check"><input type="checkbox" checked={reuse} onChange={(event) => setReuse(event.target.checked)}/> Reuse earlier verdicts from the same model for this exact brief</label>
            <p className="icpv-estimate" role="status">{models.length ? `≈ ${estimate.toFixed(estimate < 1 ? 3 : 2)} (estimate)` : "Choose at least one model."}</p>
          </>}
        </>}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="modal-actions">
        <button className="secondary" data-autofocus disabled={busy} onClick={onClose}>Cancel</button>
        <button className="primary" disabled={busy || !chosen || (method === "models" && !models.length)} onClick={() => void start()}>{busy ? "Starting…" : method === "strategy" ? `Run ${strategyLabel(strategy)}` : "Start validation"}</button>
      </div>
    </section>
  </div>;
}
