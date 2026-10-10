"use client";

import { useCallback, useEffect, useId, useRef, useState } from "react";
import { useDismiss } from "../use-dismiss";
import { AppIcon, type IconName } from "./DashboardUi";

export type ListboxOption = { value: string; label: string; hint?: string; divider?: boolean };

/**
 * A button + role="listbox" popup in place of a native <select>: the open list
 * of a <select> is drawn by the browser, and no CSS reaches its padding,
 * radius, hover colour or font. Styled with the .ds-menu primitives the View
 * and Actions menus use. First used by the client's ICP picker; shared so the
 * blocklist filters look the same.
 *
 * `value === ""` is "nothing chosen": the trigger shows `placeholder`, and
 * when `clearable` an × beside it puts the value back to "".
 */
export default function ListboxPicker({
  label, placeholder, prefix, icon, options, value, onChange, clearable = false, align = "start", className = "",
}: {
  /** Accessible name of the control, e.g. "Filter blocklist reason". */
  label: string;
  /** Trigger text when nothing is chosen. */
  placeholder: string;
  /** Shown before the chosen label, e.g. "ICP:" - so a chosen value still says what it filters. */
  prefix?: string;
  icon?: IconName;
  options: ListboxOption[];
  value: string;
  onChange: (next: string) => void;
  clearable?: boolean;
  align?: "start" | "end";
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const wrapper = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const listId = useId();
  const selected = options.find((option) => option.value === value && value !== "");
  const triggerText = selected ? selected.label : placeholder;

  const close = useCallback((returnFocus = true) => {
    setOpen((wasOpen) => {
      if (wasOpen && returnFocus) trigger.current?.focus();
      return false;
    });
  }, []);
  useDismiss(wrapper, () => close(), open);

  const focusFirst = useRef(false);
  useEffect(() => {
    if (!open || !focusFirst.current) return;
    focusFirst.current = false;
    const current = panel.current?.querySelector<HTMLElement>('[role="option"][aria-selected="true"]');
    (current ?? panel.current?.querySelector<HTMLElement>('[role="option"]'))?.focus();
  }, [open]);

  function onTriggerKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    focusFirst.current = true;
    setOpen(true);
  }

  function onPanelKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const stops = [...(panel.current?.querySelectorAll<HTMLElement>('[role="option"]') ?? [])];
    const at = stops.findIndex((node) => node === document.activeElement);
    const next = event.key === "ArrowDown" ? (at + 1) % stops.length : (at - 1 + stops.length) % stops.length;
    stops[next]?.focus();
  }

  return <div className={`listbox-picker ds-menu${align === "end" ? " ds-menu-end" : ""}${selected ? " is-active" : ""}${className ? ` ${className}` : ""}`} ref={wrapper}>
    <button
      type="button"
      ref={trigger}
      className="listbox-picker-trigger"
      aria-haspopup="listbox"
      aria-expanded={open}
      aria-controls={open ? listId : undefined}
      aria-label={`${label}, currently ${selected ? selected.label : placeholder}`}
      onClick={() => setOpen((current) => !current)}
      onKeyDown={onTriggerKeyDown}
    >
      {icon ? <AppIcon name={icon} size={14}/> : null}
      <span className="listbox-picker-text">{selected && prefix ? <small>{prefix}</small> : null}{triggerText}</span>
      <AppIcon name="chevron" size={12}/>
    </button>
    {clearable && selected ? <button type="button" className="listbox-picker-clear" aria-label={`Clear ${label.toLowerCase()}`} title="Clear" onClick={() => onChange("")}><AppIcon name="close" size={12}/></button> : null}
    {open ? <div
      id={listId}
      ref={panel}
      role="listbox"
      tabIndex={-1}
      aria-label={label}
      className="ds-menu-panel listbox-picker-panel"
      onKeyDown={onPanelKeyDown}
    >
      {options.map((option) => <div key={option.value} role="none" className={option.divider ? "listbox-picker-divided" : undefined}>
        <button
          type="button"
          role="option"
          aria-selected={option.value === value}
          className="ds-menu-item"
          onClick={() => { onChange(option.value); close(); }}
        ><span>{option.label}</span>{option.hint ? <small>{option.hint}</small> : null}{option.value === value ? <AppIcon name="check" size={13}/> : null}</button>
      </div>)}
    </div> : null}
  </div>;
}
