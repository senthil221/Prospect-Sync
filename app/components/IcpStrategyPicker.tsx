"use client";

import { ICP_STRATEGIES, estimateRunCost, sourceLabel } from "../../worker/icp-validator-core.mjs";

// Strict / Balanced / Lenient, as three cards: what the rule is, which model
// runs make the votes, and roughly what it costs for these companies. Shared
// by the ICP checks tab and the Company DB "Validate ICP" dialog.

export type StrategyId = "strict" | "balanced" | "lenient";
type Pass = { model: string; effort: string };
type Strategy = { id: StrategyId; label: string; rule: string; summary: string; passes: Pass[] };

export const strategies = ICP_STRATEGIES as Strategy[];

// Observed cost per company, keyed "model|effort" (the ICP checks route
// reads it from recent finished runs).
export type CostPerCompany = Record<string, number>;

// From what these model runs actually cost recently when there is history for
// every pass, else at OpenRouter list prices (which overstate high-effort
// DeepSeek several times over).
export function estimateStrategy(id: StrategyId, companies: number, briefLength = 800, observed?: CostPerCompany | null) {
  const strategy = strategies.find((item) => item.id === id);
  if (!strategy || !companies) return 0;
  const known = observed && strategy.passes.every((pass) => observed[`${pass.model}|${pass.effort}`] > 0);
  return strategy.passes.reduce((sum, pass) => sum + (known
    ? observed[`${pass.model}|${pass.effort}`] * companies
    : estimateRunCost(pass.model, companies, { effort: pass.effort, briefLength }) ?? 0), 0);
}

export function hasObservedCost(id: StrategyId, observed?: CostPerCompany | null) {
  const strategy = strategies.find((item) => item.id === id);
  return Boolean(strategy && observed && strategy.passes.every((pass) => observed[`${pass.model}|${pass.effort}`] > 0));
}

export function strategyLabel(id: string) {
  return strategies.find((item) => item.id === id)?.label ?? id;
}

// "DeepSeek V4.1 Flash · high ×2", "GPT-6 Luna · low"
export function passSummary(passes: Pass[]) {
  const groups: Array<{ key: string; text: string; count: number }> = [];
  for (const pass of passes) {
    const key = `${pass.model}|${pass.effort}`;
    const existing = groups.find((group) => group.key === key);
    if (existing) existing.count += 1;
    else groups.push({ key, text: `${sourceLabel(pass.model)} · ${pass.effort}`, count: 1 });
  }
  return groups.map((group) => group.count > 1 ? `${group.text} ×${group.count}` : group.text);
}

const cost = (value: number) => value <= 0 ? "" : value < 0.01 ? "< $0.01" : `≈ $${value.toFixed(value < 1 ? 3 : 2)}`;

export function StrategyPicker({ value, onChange, companies, briefLength, name, observed }: {
  value: StrategyId; onChange: (next: StrategyId) => void; companies: number; briefLength?: number; name: string; observed?: CostPerCompany | null;
}) {
  return <div className="icc-strategies" role="radiogroup" aria-label="Method">
    {strategies.map((strategy) => {
      const on = strategy.id === value;
      const estimate = cost(estimateStrategy(strategy.id, companies, briefLength, observed));
      return <label key={strategy.id} className={`icc-strategy is-${strategy.id}${on ? " is-on" : ""}`}>
        <input type="radio" name={name} value={strategy.id} checked={on} onChange={() => onChange(strategy.id)}/>
        <span className="icc-strategy-head">
          <span className="icc-radio" aria-hidden="true"/>
          <strong>{strategy.label}</strong>
          <small>{strategy.passes.length} runs</small>
          {estimate ? <em>{estimate}</em> : null}
        </span>
        <span className="icc-strategy-rule">{strategy.rule}</span>
        <span className="icc-strategy-passes">{passSummary(strategy.passes).map((text) => <span key={text} className="icpx-chip">{text}</span>)}</span>
        <span className="icc-strategy-summary">{strategy.summary}</span>
      </label>;
    })}
  </div>;
}
