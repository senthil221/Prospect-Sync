"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";

export type TabItem<T extends string> = {
  id: T;
  label: string;
  /** Optional trailing count. Rendered as a badge, muted until the tab is active. */
  count?: number | string;
  /** Optional leading icon — pass an <AppIcon/>, not a unicode glyph. */
  icon?: ReactNode;
};

type TabsProps<T extends string> = {
  items: Array<TabItem<T>>;
  value: T;
  onChange: (next: T) => void;
  /** "line" is the workspace default; "segmented" is for enclosed switchers. */
  variant?: "line" | "segmented";
  /** Accessible name for the tablist — required, it is what a screen reader announces. */
  label: string;
};

/**
 * The product's single tab control.
 *
 * Replaces the two hand-rolled tab strips that previously diverged in height,
 * radius, padding and shadow. Implements the WAI-ARIA tabs pattern properly:
 * roving tabindex, Left/Right/Home/End, and an indicator that animates between
 * positions rather than snapping. The indicator is driven by CSS custom
 * properties written from a ResizeObserver, so it stays correct when labels,
 * counts or the container width change.
 */
export default function Tabs<T extends string>({ items, value, onChange, variant = "line", label }: TabsProps<T>) {
  const listRef = useRef<HTMLDivElement>(null);
  const tabRefs = useRef(new Map<T, HTMLButtonElement>());
  const [ready, setReady] = useState(false);

  const positionIndicator = useCallback(() => {
    const list = listRef.current;
    const active = tabRefs.current.get(value);
    if (!list || !active) return;
    list.style.setProperty("--indicator-x", `${active.offsetLeft}px`);
    list.style.setProperty("--indicator-w", `${active.offsetWidth}px`);
  }, [value]);

  // Layout effect so the indicator is in place on the first paint, not one frame late.
  useLayoutEffect(() => {
    positionIndicator();
    // Suppress the slide transition until the first position is committed,
    // otherwise the indicator animates in from the left edge on mount.
    const frame = requestAnimationFrame(() => setReady(true));
    return () => cancelAnimationFrame(frame);
  }, [positionIndicator]);

  useEffect(() => {
    const list = listRef.current;
    if (!list || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(positionIndicator);
    observer.observe(list);
    for (const node of tabRefs.current.values()) observer.observe(node);
    return () => observer.disconnect();
  }, [positionIndicator, items.length]);

  // Handled on the tabs rather than the tablist: the tabs are what hold focus
  // under a roving tabindex, and a non-focusable container with a key handler
  // is unreachable for keyboard users.
  function onKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    const order = items.map((item) => item.id);
    const current = order.indexOf(value);
    let next = -1;
    if (event.key === "ArrowRight") next = (current + 1) % order.length;
    else if (event.key === "ArrowLeft") next = (current - 1 + order.length) % order.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = order.length - 1;
    if (next < 0) return;
    event.preventDefault();
    onChange(order[next]);
    tabRefs.current.get(order[next])?.focus();
  }

  return (
    <div
      ref={listRef}
      role="tablist"
      aria-label={label}
      className={`ds-tabs ds-tabs-${variant}${ready ? " is-ready" : ""}`}
    >
      <span className="ds-tabs-indicator" aria-hidden="true" />
      {items.map((item) => {
        const selected = item.id === value;
        return (
          <button
            key={item.id}
            type="button"
            role="tab"
            id={`tab-${item.id}`}
            aria-selected={selected}
            aria-controls={`tabpanel-${item.id}`}
            tabIndex={selected ? 0 : -1}
            className={selected ? "active" : ""}
            ref={(node) => {
              if (node) tabRefs.current.set(item.id, node);
              else tabRefs.current.delete(item.id);
            }}
            onClick={() => onChange(item.id)}
            onKeyDown={onKeyDown}
          >
            {item.icon ? <span className="ds-tab-icon" aria-hidden="true">{item.icon}</span> : null}
            <span className="ds-tab-label">{item.label}</span>
            {item.count !== undefined ? <span className="ds-tab-count">{item.count}</span> : null}
          </button>
        );
      })}
    </div>
  );
}
