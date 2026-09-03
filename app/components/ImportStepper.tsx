"use client";

import { importStepLabels, importStepOrder, stepStatus, type ImportStepId, type StepProblem } from "../../lib/import-steps";
import { AppIcon, StatusMessage } from "./DashboardUi";

/**
 * IMPORT-01: where you are in the import, and how far back you can go.
 *
 * A step you have not earned is not clickable, so the strip cannot be used to
 * skip validation; a step you have completed always is, because Back must never
 * be the only way to fix something you already entered.
 */
export function ImportStepper({ current, furthest, onSelect }: {
  current: ImportStepId;
  furthest: ImportStepId;
  onSelect: (step: ImportStepId) => void;
}) {
  return <ol className="import-stepper">
    {importStepOrder.map((step, index) => {
      const status = stepStatus(step, current, furthest);
      return <li key={step} className={`import-step ${status}`}>
        <button
          type="button"
          disabled={status === "upcoming"}
          aria-current={status === "current" ? "step" : undefined}
          onClick={() => onSelect(step)}
        >
          <span className="import-step-mark">{status === "complete" ? <AppIcon name="check" size={12}/> : index + 1}</span>
          <span className="import-step-label">{importStepLabels[step]}</span>
        </button>
      </li>;
    })}
  </ol>;
}

/**
 * IMPORT-02: the readiness summary sits beside the button that refused.
 *
 * Errors are not shown until a Continue or Submit has actually been pressed -
 * an untouched field is not yet wrong - and when they are, focus moves to the
 * first control at fault rather than leaving the user to find it.
 */
export function StepFooter({ backLabel, onBack, continueLabel, onContinue, problems, attempted, busy = false }: {
  backLabel?: string;
  onBack?: () => void;
  continueLabel: string;
  onContinue: () => void;
  problems: StepProblem[];
  attempted: boolean;
  busy?: boolean;
}) {
  return <div className="import-step-footer">
    {attempted && problems.length ? <StatusMessage tone="alert">
      {problems.length === 1 ? problems[0].message : <>Before continuing: <ul>{problems.map((problem) => <li key={problem.field}>{problem.message}</li>)}</ul></>}
    </StatusMessage> : null}
    <div className="import-step-actions">
      {onBack ? <button type="button" className="secondary" disabled={busy} onClick={onBack}>{backLabel ?? "Back"}</button> : <span/>}
      <button type="button" className="primary" disabled={busy} onClick={onContinue}>{continueLabel}</button>
    </div>
  </div>;
}

/** Moves focus to the control a refusal names, if it is on screen. */
export function focusProblem(problems: StepProblem[]) {
  if (!problems.length) return;
  const target = document.getElementById(problems[0].field);
  if (target) { target.focus(); target.scrollIntoView({ block: "center", behavior: "smooth" }); }
}
