"use client";

import { useRef, useState } from "react";
import { initials } from "../../lib/dashboard-helpers";
import { AppIcon, type IconName } from "./DashboardUi";
import ThemeToggle from "./ThemeToggle";
import { useDialogFocus } from "./use-dialog";

export type MobileNavItem = { id: string; label: string; mark: IconName };

/** The three that earn a permanent slot. Everything else lives behind More. */
const pinned = ["overview", "prospects", "companies"];

/**
 * MOBILE-01: the bottom bar, and the way back to everything it cannot hold.
 *
 * The previous mobile shell took the desktop sidebar and turned it sideways:
 * seven destinations at a 76px minimum in a horizontally scrolling 72px strip.
 * At 390px that is 532px of navigation in a 390px viewport, so three of the
 * seven were off-screen with nothing indicating they existed. The same rule hid
 * `.profile`, which is the only sign-out in the product, and `.search`, with no
 * replacement - on the two screens whose entire purpose is searching.
 *
 * Four fixed destinations fit at 390px with room for a 44px target. The rest
 * move into a sheet that can be as long as it needs to be, which is also where
 * the account and the theme control belong: they are settings, not destinations.
 */
export default function MobileNav({ section, items, onNavigate, currentUserEmail }: {
  section: string;
  items: MobileNavItem[];
  onNavigate: (id: string) => void;
  currentUserEmail: string;
}) {
  const [open, setOpen] = useState(false);
  const sheet = useRef<HTMLElement>(null);
  useDialogFocus(sheet, { onClose: () => setOpen(false) });

  const primary = items.filter((item) => pinned.includes(item.id));
  const secondary = items.filter((item) => !pinned.includes(item.id));
  // More is "current" when the screen you are on lives inside it - otherwise
  // the bar would show no active destination at all on four of seven screens.
  const inSheet = secondary.some((item) => item.id === section);

  // Navigating closes the sheet: the screen the user just asked for would
  // otherwise open underneath it. Done on the click rather than in an effect
  // watching `section`, which would set state during render for every
  // navigation, including the ones that never opened the sheet.
  const go = (id: string) => { setOpen(false); onNavigate(id); };

  return <>
    <nav className="mobile-nav" aria-label="Primary">
      {primary.map((item) => <button
        key={item.id}
        type="button"
        aria-current={section === item.id ? "page" : undefined}
        className={section === item.id ? "active" : ""}
        onClick={() => go(item.id)}
      >
        <span aria-hidden="true"><AppIcon name={item.mark} size={20}/></span>
        {item.label === "People database" ? "People" : item.label}
      </button>)}
      <button
        type="button"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-current={inSheet ? "page" : undefined}
        className={inSheet ? "active" : ""}
        onClick={() => setOpen(true)}
      >
        <span aria-hidden="true"><AppIcon name="grid" size={20}/></span>
        More
      </button>
    </nav>

    {open ? <div className="mobile-sheet-backdrop" role="presentation">
      <section
        ref={sheet}
        className="mobile-sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby="mobile-sheet-title"
      >
        <div className="mobile-sheet-head">
          <h2 id="mobile-sheet-title">More</h2>
          <button type="button" className="mobile-sheet-close" data-autofocus onClick={() => setOpen(false)} aria-label="Close">
            <AppIcon name="close" size={18}/>
          </button>
        </div>
        <div className="mobile-sheet-body">
          {secondary.map((item) => <button
            key={item.id}
            type="button"
            aria-current={section === item.id ? "page" : undefined}
            className={`mobile-sheet-item ${section === item.id ? "active" : ""}`}
            onClick={() => go(item.id)}
          >
            <span aria-hidden="true"><AppIcon name={item.mark} size={18}/></span>
            {item.label}
          </button>)}

          <div className="mobile-sheet-group">
            <span className="mobile-sheet-label">Appearance</span>
            <ThemeToggle/>
          </div>

          {/* The only sign-out in the product. The old shell hid it entirely
              below 760px, so a phone could sign in and never sign out. */}
          <a className="mobile-sheet-account" href="/auth/signout">
            <span className="profile-avatar">{initials(currentUserEmail)}</span>
            <div><strong>{currentUserEmail}</strong><small>Sign out</small></div>
            <AppIcon name="arrow" size={16}/>
          </a>
        </div>
      </section>
    </div> : null}
  </>;
}
