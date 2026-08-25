"use client";

import { useEffect, useState } from "react";
import { AppIcon, type IconName } from "./DashboardUi";

/**
 * Colour theme control.
 *
 * Dark mode is opt-in, not automatic: the default is Light, so nobody has the
 * theme changed under them by an OS setting they made for something else.
 * "System" is offered for people who do want it to follow the OS.
 *
 * The choice is stamped on <html> as data-theme, which is what
 * app/design-system.css keys its palettes off:
 *   - data-theme="light"  -> the :root palette, and the dark media query is
 *                            suppressed by its :not([data-theme="light"]) guard
 *   - data-theme="dark"   -> the explicit dark palette
 *   - no attribute        -> follows prefers-color-scheme ("System")
 *
 * The initial stamp is applied by the inline boot script in app/layout.tsx,
 * before first paint. This component only reflects and changes it.
 */

export const THEME_STORAGE_KEY = "prospecthub-theme";

const CHOICES = [
  { id: "light", label: "Light", icon: "sun" },
  { id: "dark", label: "Dark", icon: "moon" },
  { id: "system", label: "System", icon: "monitor" },
] as const satisfies ReadonlyArray<{ id: string; label: string; icon: IconName }>;

export type ThemeChoice = (typeof CHOICES)[number]["id"];

const isThemeChoice = (value: string | null): value is ThemeChoice =>
  value === "light" || value === "dark" || value === "system";

function stamp(choice: ThemeChoice) {
  const root = document.documentElement;
  if (choice === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", choice);
}

export default function ThemeToggle() {
  const [choice, setChoice] = useState<ThemeChoice>("light");

  useEffect(() => {
    // Deferred: localStorage is not readable during the server render, and the
    // boot script has already applied the visual stamp by this point. This only
    // syncs the control's own highlight to what is already on screen.
    const timer = window.setTimeout(() => {
      const stored = localStorage.getItem(THEME_STORAGE_KEY);
      if (isThemeChoice(stored)) setChoice(stored);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  function select(next: ThemeChoice) {
    setChoice(next);
    stamp(next);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, next);
    } catch {
      /* Private browsing: the theme still applies for this session. */
    }
  }

  return (
    <div className="theme-toggle" role="group" aria-label="Colour theme">
      {CHOICES.map((option) => (
        <button
          key={option.id}
          type="button"
          aria-pressed={choice === option.id}
          title={`${option.label} theme`}
          className={choice === option.id ? "active" : ""}
          onClick={() => select(option.id)}
        >
          <AppIcon name={option.icon} size={14} />
          <span className="sr-only">{option.label} theme</span>
        </button>
      ))}
    </div>
  );
}
