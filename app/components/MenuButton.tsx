"use client";

import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { useDismiss } from "../use-dismiss";
import { AppIcon, type IconName } from "./DashboardUi";

/**
 * A button that opens a panel of related controls.
 *
 * COMMANDS-01 needs this because the People and Companies command bars put
 * eight and seven controls side by side at equal weight, so nothing read as the
 * primary action and neither bar fit at 1024px. Grouping them under View and
 * Actions is the fix, and grouping needs somewhere to group into.
 *
 * NOT role="menu". A menu's children are commands, and half of what goes in
 * here is not: Columns is a list of checkboxes, Density is a cycling control,
 * Saved views is a select. Declaring role="menu" and then filling it with form
 * controls tells a screen reader something false about how to operate it. This
 * is a disclosure - a labelled button that expands a group - which is what the
 * content actually is, and it costs nothing that a menu would have given.
 *
 * What it does provide, and what useDismiss alone does not:
 *   - focus returns to the trigger when the panel closes, instead of being
 *     dropped on <body> when the panel it was inside disappears;
 *   - Arrow Down from the trigger opens and lands on the first control;
 *   - Arrow keys move between controls once inside;
 *   - Tab out closes it, because a panel you have tabbed past is not open.
 */
export default function MenuButton({
  label, icon, count, panelLabel, children, disabled = false, align = "start",
}: {
  label: string;
  icon?: IconName;
  /** Shown as a badge - the number of columns chosen, filters applied, and so on. */
  count?: number | string;
  /** Accessible name for the expanded group. Defaults to the button's label. */
  panelLabel?: string;
  children: ReactNode;
  disabled?: boolean;
  align?: "start" | "end";
}) {
  const [open, setOpen] = useState(false);
  const wrapper = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const panelId = useId();

  const close = useCallback((returnFocus = true) => {
    setOpen((wasOpen) => {
      // Only reclaim focus if it is still inside the panel. Closing because the
      // user clicked something else must not yank them back to this button.
      if (wasOpen && returnFocus && panel.current?.contains(document.activeElement)) trigger.current?.focus();
      return false;
    });
  }, []);

  useDismiss(wrapper, () => close(), open);

  const items = useCallback(
    () => [...(panel.current?.querySelectorAll<HTMLElement>(
      "button:not([disabled]), input:not([disabled]), select:not([disabled]), a[href], [tabindex]:not([tabindex='-1'])",
    ) ?? [])],
    [],
  );

  // Opening with the keyboard should land somewhere useful; opening with the
  // mouse should not steal the pointer's place.
  const focusFirst = useRef(false);
  useEffect(() => {
    if (!open || !focusFirst.current) return;
    focusFirst.current = false;
    items()[0]?.focus();
  }, [open, items]);

  function onTriggerKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    focusFirst.current = true;
    setOpen(true);
  }

  function onPanelKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Escape") { event.stopPropagation(); close(); return; }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const stops = items();
    if (stops.length < 2) return;
    // Arrow keys are a convenience inside a group of controls, so they must not
    // fight a control that owns them: a select uses Up/Down to change value.
    const active = document.activeElement;
    if (active instanceof HTMLSelectElement) return;
    event.preventDefault();
    const at = stops.findIndex((node) => node === active);
    const next = event.key === "ArrowDown" ? (at + 1) % stops.length : (at - 1 + stops.length) % stops.length;
    stops[next]?.focus();
  }

  return (
    <div className={`ds-menu ds-menu-${align}`} ref={wrapper}>
      <button
        type="button"
        ref={trigger}
        className={`outline-button ${open ? "active" : ""}`}
        aria-haspopup="true"
        aria-expanded={open}
        aria-controls={open ? panelId : undefined}
        disabled={disabled}
        onClick={() => (open ? close() : setOpen(true))}
        onKeyDown={onTriggerKeyDown}
      >
        {icon ? <AppIcon name={icon} size={14}/> : null}
        {label}
        {count !== undefined && count !== "" ? <span>{count}</span> : null}
        <AppIcon name="chevron" size={13}/>
      </button>
      {open ? (
        // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- the keys belong to the focusable controls inside; this container is never a tab stop
        <div
          id={panelId}
          ref={panel}
          className="ds-menu-panel"
          role="group"
          aria-label={panelLabel ?? label}
          onKeyDown={onPanelKeyDown}
          // Tabbing past the last control means the user has left; keeping the
          // panel open behind them leaves a floating surface nobody is using.
          onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node)) close(false); }}
        >
          {children}
        </div>
      ) : null}
    </div>
  );
}
