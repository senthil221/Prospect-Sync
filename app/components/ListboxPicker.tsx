"use client";

import { Children, Fragment, isValidElement, useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type MouseEvent as ReactMouseEvent, type ReactElement, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { AppIcon, type IconName } from "./DashboardUi";

export type ListboxOption = { value: string; label: string; hint?: string; divider?: boolean; disabled?: boolean };

/**
 * A button + role="listbox" popup in place of a native <select>: the open list
 * of a <select> is drawn by the browser, and no CSS reaches its padding,
 * radius, hover colour or font. Styled with the .ds-menu primitives the View
 * and Actions menus use.
 *
 * The list is drawn in a portal with position: fixed, so a table cell, a
 * scrolling panel or a dialog never clips it. Inside a dialog it is portalled
 * into the dialog, so the dialog's focus trap and inert background still hold.
 *
 * `value === ""` is "nothing chosen": the trigger shows `placeholder`, and
 * when `clearable` an × beside it puts the value back to "".
 */
export default function ListboxPicker({
  label, placeholder, prefix, icon, options, value, onChange, clearable = false, align = "start", className = "",
  quiet = false, disabled = false, id, title, onTriggerClick,
}: {
  /** Accessible name of the control, e.g. "Filter blocklist reason". */
  label: string;
  /** Trigger text when nothing is chosen. */
  placeholder: string;
  /** Shown before the chosen label, e.g. "ICP" - so a chosen value still says what it filters. */
  prefix?: string;
  icon?: IconName;
  options: ListboxOption[];
  value: string;
  onChange: (next: string) => void;
  clearable?: boolean;
  align?: "start" | "end";
  className?: string;
  /** A form field rather than a filter: no accent colour when a value is chosen. */
  quiet?: boolean;
  disabled?: boolean;
  id?: string;
  title?: string;
  onTriggerClick?: (event: ReactMouseEvent<HTMLButtonElement>) => void;
}) {
  const [open, setOpen] = useState(false);
  const [place, setPlace] = useState<CSSProperties | null>(null);
  const [host, setHost] = useState<HTMLElement | null>(null);
  const wrapper = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const typed = useRef({ text: "", at: 0 });
  const listId = useId();
  const selected = options.find((option) => option.value === value && value !== "");
  const triggerText = selected ? selected.label : placeholder;

  const close = useCallback((returnFocus = true) => {
    setOpen((wasOpen) => {
      if (wasOpen && returnFocus) trigger.current?.focus();
      return false;
    });
  }, []);

  // Where the list goes: under the trigger, or above it when there is no room
  // below; right-aligned to it for `align="end"`.
  const position = useCallback(() => {
    const rect = trigger.current?.getBoundingClientRect();
    if (!rect) return;
    const below = window.innerHeight - rect.bottom;
    const above = rect.top;
    const flip = below < 240 && above > below;
    const maxHeight = Math.max(160, Math.min(360, (flip ? above : below) - 16));
    const style: CSSProperties = { position: "fixed", zIndex: 1000, maxHeight, minWidth: Math.max(220, rect.width) };
    if (flip) { style.top = "auto"; style.bottom = window.innerHeight - rect.top + 4; } else style.top = rect.bottom + 4;
    if (align === "end") style.right = Math.max(8, window.innerWidth - rect.right);
    else style.left = Math.max(8, Math.min(rect.left, window.innerWidth - 240));
    setPlace(style);
  }, [align]);

  useLayoutEffect(() => {
    if (!open) return;
    setHost(trigger.current?.closest<HTMLElement>('[role="dialog"]') ?? document.body);
    position();
  }, [open, position]);

  useEffect(() => {
    if (!open) return;
    function onPointer(event: PointerEvent) {
      const target = event.target as Node;
      if (wrapper.current?.contains(target) || panel.current?.contains(target)) return;
      close(false);
    }
    function onKey(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      // Close the list, not the dialog or menu it sits in.
      event.stopPropagation();
      close();
    }
    function onScroll(event: Event) {
      if (panel.current?.contains(event.target as Node)) return;
      position();
    }
    document.addEventListener("pointerdown", onPointer, true);
    document.addEventListener("keydown", onKey, true);
    window.addEventListener("scroll", onScroll, true);
    window.addEventListener("resize", position);
    return () => {
      document.removeEventListener("pointerdown", onPointer, true);
      document.removeEventListener("keydown", onKey, true);
      window.removeEventListener("scroll", onScroll, true);
      window.removeEventListener("resize", position);
    };
  }, [open, close, position]);

  const focusFirst = useRef(false);
  useEffect(() => {
    if (!open || !place || !focusFirst.current) return;
    focusFirst.current = false;
    const current = panel.current?.querySelector<HTMLElement>('[role="option"][aria-selected="true"]');
    (current ?? panel.current?.querySelector<HTMLElement>('[role="option"]:not(:disabled)'))?.focus();
  }, [open, place]);

  function onTriggerKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    focusFirst.current = true;
    setOpen(true);
  }

  function onPanelKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    const stops = [...(panel.current?.querySelectorAll<HTMLElement>('[role="option"]:not(:disabled)') ?? [])];
    const at = stops.findIndex((node) => node === document.activeElement);
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = event.key === "ArrowDown" ? (at + 1) % stops.length : (at - 1 + stops.length) % stops.length;
      stops[next]?.focus();
      return;
    }
    if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      stops[event.key === "Home" ? 0 : stops.length - 1]?.focus();
      return;
    }
    if (event.key === "Tab") { close(false); return; }
    // Type-ahead, like a native select: letters typed within a second build a
    // prefix and focus the first option that starts with it.
    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      const now = Date.now();
      typed.current = { text: (now - typed.current.at < 1000 ? typed.current.text : "") + event.key.toLowerCase(), at: now };
      const match = stops.find((node) => (node.textContent ?? "").trim().toLowerCase().startsWith(typed.current.text));
      match?.focus();
    }
  }

  return <div className={`listbox-picker${selected && !quiet ? " is-active" : ""}${quiet ? " is-quiet" : ""}${className ? ` ${className}` : ""}`} ref={wrapper}>
    <button
      type="button"
      ref={trigger}
      id={id}
      title={title}
      disabled={disabled}
      className="listbox-picker-trigger"
      aria-haspopup="listbox"
      aria-expanded={open}
      aria-controls={open ? listId : undefined}
      aria-label={`${label}, currently ${selected ? selected.label : placeholder}`}
      onClick={(event) => { onTriggerClick?.(event); setOpen((current) => !current); }}
      onKeyDown={onTriggerKeyDown}
    >
      {icon ? <AppIcon name={icon} size={14}/> : null}
      <span className="listbox-picker-text">{selected && prefix ? <small>{prefix}</small> : null}{triggerText}</span>
      <AppIcon name="chevron" size={12}/>
    </button>
    {clearable && selected && !disabled ? <button type="button" className="listbox-picker-clear" aria-label={`Clear ${label.toLowerCase()}`} title="Clear" onClick={() => onChange("")}><AppIcon name="close" size={12}/></button> : null}
    {open && host && place ? createPortal(<div
      id={listId}
      ref={panel}
      role="listbox"
      tabIndex={-1}
      aria-label={label}
      className="ds-menu-panel listbox-picker-panel"
      style={place}
      onKeyDown={onPanelKeyDown}
    >
      {options.map((option) => <div key={option.value} role="none" className={option.divider ? "listbox-picker-divided" : undefined}>
        <button
          type="button"
          role="option"
          aria-selected={option.value === value}
          disabled={option.disabled}
          className="ds-menu-item"
          onClick={() => { onChange(option.value); close(); }}
        ><span>{option.label}</span>{option.hint ? <small>{option.hint}</small> : null}{option.value === value ? <AppIcon name="check" size={13}/> : null}</button>
      </div>)}
    </div>, host) : null}
  </div>;
}

function optionText(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(optionText).join("");
  if (isValidElement<{ children?: ReactNode }>(node)) return optionText(node.props.children);
  return "";
}

function collectOptions(children: ReactNode, into: ListboxOption[] = []) {
  Children.forEach(children, (child) => {
    if (!isValidElement(child)) return;
    const element = child as ReactElement<{ value?: string | number; children?: ReactNode; disabled?: boolean }>;
    if (element.type === Fragment) { collectOptions(element.props.children, into); return; }
    if (element.type === "option") {
      const text = optionText(element.props.children);
      into.push({ value: String(element.props.value ?? text), label: text, disabled: element.props.disabled });
    }
  });
  return into;
}

/**
 * A drop-in for a native <select>: the same <option> children and the same
 * `onChange={(event) => ... event.target.value}` handler, drawn as a
 * ListboxPicker. The "" option, when there is one, is the placeholder.
 */
export function Select({
  value: rawValue, defaultValue, onChange, children, disabled, id, title, className = "", onClick, filter = false, ...aria
}: {
  value?: string | number;
  /** Accepted for parity with <select>; every caller also disables its submit until a value is chosen. */
  required?: boolean;
  defaultValue?: string;
  onChange?: (event: { target: { value: string } }) => void;
  children: ReactNode;
  disabled?: boolean;
  id?: string;
  title?: string;
  className?: string;
  onClick?: (event: ReactMouseEvent<HTMLButtonElement>) => void;
  /** A filter rather than a form field: accent colour once something is chosen. */
  filter?: boolean;
  "aria-label"?: string;
}) {
  const value = rawValue === undefined ? undefined : String(rawValue);
  const [own, setOwn] = useState(defaultValue ?? "");
  const current = value ?? own;
  const options = collectOptions(children);
  const empty = options.find((option) => option.value === "");
  const placeholder = empty?.label ?? options[0]?.label ?? "";
  return <ListboxPicker
    className={`ui-select${className ? ` ${className}` : ""}`}
    label={aria["aria-label"] ?? title ?? placeholder}
    placeholder={placeholder}
    options={options}
    value={current}
    quiet={!filter}
    disabled={disabled}
    id={id}
    title={title}
    onTriggerClick={onClick}
    onChange={(next) => { if (value === undefined) setOwn(next); onChange?.({ target: { value: next } }); }}
  />;
}
