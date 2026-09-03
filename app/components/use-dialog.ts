"use client";

import { useEffect, useRef } from "react";

// The focus lifecycle every dialog and drawer in the product shares.
//
// A11Y-01. Both surfaces already carried role="dialog" and aria-modal="true",
// which tells a screen reader that the rest of the page is inert without any of
// it being true: Tab walked straight out into the table behind, Escape worked on
// the drawer and not on the delete confirmation, focus started wherever the
// browser left it, and closing dropped focus onto <body> so the next Tab
// restarted from the top of the document. aria-modal is a promise; this is the
// implementation of it.
//
// The contract, from section G of the redesign plan:
//   1. store the launcher; focus the safest meaningful control
//   2. keep Tab/Shift+Tab inside, and make the background inert
//   3. Escape closes, unless a committed operation is running
//   4. close restores focus to the launcher
//
// WHY "SAFEST". Initial focus goes to the element marked data-autofocus, and
// callers put that on the cancelling control rather than the confirming one. A
// delete dialog that opens with Delete focused turns a stray Enter - from the
// keypress that opened it - into a confirmed deletion.

const focusableSelector = [
  "a[href]", "button:not([disabled])", "input:not([disabled])", "select:not([disabled])",
  "textarea:not([disabled])", "[tabindex]:not([tabindex='-1'])",
].join(",");

function focusable(container: HTMLElement) {
  return [...container.querySelectorAll<HTMLElement>(focusableSelector)]
    // offsetParent is null for display:none and for anything inside it, which is
    // what keeps a collapsed accordion's controls out of the tab order.
    .filter((node) => node.offsetParent !== null || node === document.activeElement);
}

export function useDialogFocus(
  container: React.RefObject<HTMLElement | null>,
  options: { onClose: () => void; busy?: boolean },
) {
  const { onClose, busy = false } = options;
  // Held in a ref so a re-render caused by typing inside the dialog cannot
  // replace the launcher with something focused after it opened.
  const launcher = useRef<HTMLElement | null>(null);
  // The key handler below is bound once, on mount, so it would otherwise close
  // over the first render's onClose and busy forever - and `busy` in particular
  // changes exactly when it matters, at the moment the operation commits. These
  // keep it reading the current values. Written in an effect rather than during
  // render, because a ref is not render state.
  const closeRef = useRef(onClose);
  const busyRef = useRef(busy);
  useEffect(() => {
    closeRef.current = onClose;
    busyRef.current = busy;
  });

  useEffect(() => {
    const node = container.current;
    if (!node) return;
    launcher.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;

    const preferred = node.querySelector<HTMLElement>("[data-autofocus]");
    (preferred ?? focusable(node)[0] ?? node).focus();

    // Everything that is not an ancestor of this dialog stops being reachable -
    // by Tab, by screen reader, and by pointer. aria-modal alone does none of
    // that. Only siblings are marked, so the dialog's own subtree is untouched
    // whether it renders inline or through a portal.
    const inerted: HTMLElement[] = [];
    for (const sibling of [...document.body.children]) {
      if (!(sibling instanceof HTMLElement) || sibling.contains(node)) continue;
      if (sibling.inert) continue;
      sibling.inert = true;
      inerted.push(sibling);
    }

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        // A committed import or delete is not interruptible by a stray Escape;
        // the dialog stays up and keeps reporting until it finishes.
        if (busyRef.current) return;
        event.stopPropagation();
        closeRef.current();
        return;
      }
      if (event.key !== "Tab") return;
      const stops = focusable(node);
      if (!stops.length) { event.preventDefault(); return; }
      const first = stops[0];
      const last = stops[stops.length - 1];
      const active = document.activeElement;
      // Wrap at both ends, and pull focus back in if it has escaped the dialog
      // some other way - a click on an inert region, say.
      if (!node.contains(active)) { event.preventDefault(); first.focus(); return; }
      if (!event.shiftKey && active === last) { event.preventDefault(); first.focus(); }
      else if (event.shiftKey && active === first) { event.preventDefault(); last.focus(); }
    };

    document.addEventListener("keydown", onKeyDown, true);
    return () => {
      document.removeEventListener("keydown", onKeyDown, true);
      for (const sibling of inerted) sibling.inert = false;
      // Back to the control that opened it. If that control has gone - the row
      // it lived in was just deleted - the browser would drop focus on <body>,
      // so anything still focusable stands in rather than nothing.
      const target = launcher.current;
      if (target?.isConnected) target.focus();
      else document.querySelector<HTMLElement>("main, [role='main']")?.focus?.();
    };
    // Deliberately runs once per mounted dialog: re-running would re-steal focus
    // from wherever the user has moved it inside the dialog.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}
