"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { formatNumber } from "../../lib/dashboard-helpers";

/**
 * A number that arrives rather than appears.
 *
 * Every figure on these screens is the answer to a question the database took
 * real work to answer - 681,085 people counted in 276 ms, 358,001 inside a
 * company pivot. A number that snaps into place reads as a label printed on the
 * page. One that counts up reads as a measurement being taken, which is what it
 * is, and it gives the eye somewhere to land on a first paint that is otherwise
 * a wall of table.
 *
 * Deliberately NOT a live region, and deliberately not announced. These are
 * ordinary spans, so assistive technology reads whatever is in the DOM when it
 * reaches them - the settled number - and never the intermediate frames.
 * Announcing a count ticking from 0 to 681,085 would be hostile.
 */

// The server has no requestAnimationFrame and no motion preference to read, so
// the rewind below is browser-only. On the server this collapses to "render the
// final number", which is also exactly what a no-JS render should show.
const useBrowserLayoutEffect = typeof window === "undefined" ? useEffect : useLayoutEffect;

// Fast out of the gate, then settling. Linear interpolation reads as a slider
// being dragged; this reads as counting. Clamped so it lands exactly on target
// rather than asymptotically near it.
function easeOutExpo(progress: number) {
  return progress >= 1 ? 1 : 1 - Math.pow(2, -10 * progress);
}

// Scaled by magnitude, because a fixed duration makes 4 feel sluggish and
// 681,085 feel skipped: ~320 ms for a two-digit number, ~1.1 s for six digits.
function durationFor(distance: number) {
  return Math.min(1100, 320 + Math.log10(Math.max(10, Math.abs(distance))) * 170);
}

function prefersReducedMotion() {
  return typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export function useCountUp(value: number, enabled = true) {
  const target = Number.isFinite(value) ? Math.round(value) : 0;
  // Starts settled so the first render - and the server's HTML - is the real
  // number. The layout effect below rewinds it to the start before the browser
  // paints, so the final value is never visible for a frame first.
  const [shown, setShown] = useState(target);
  const shownRef = useRef(target);
  const mountedRef = useRef(false);
  const frameRef = useRef(0);

  useBrowserLayoutEffect(() => {
    // From zero on the way in; from wherever it currently reads when the answer
    // itself changes, so a total that gets refined climbs from the old figure
    // instead of restarting.
    const from = mountedRef.current ? shownRef.current : 0;
    mountedRef.current = true;
    if (from === target || !enabled || prefersReducedMotion()) {
      shownRef.current = target;
      setShown(target);
      return;
    }
    // Committed before the first frame so a double-invoked effect (React strict
    // mode) restarts from the same place rather than deciding there is nothing
    // left to animate.
    shownRef.current = from;
    setShown(from);

    const distance = target - from;
    const duration = durationFor(distance);
    const started = performance.now();
    const step = (now: number) => {
      const progress = Math.min(1, (now - started) / duration);
      const next = progress >= 1 ? target : Math.round(from + distance * easeOutExpo(progress));
      shownRef.current = next;
      setShown(next);
      if (progress < 1) frameRef.current = requestAnimationFrame(step);
    };
    frameRef.current = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frameRef.current);
  }, [target, enabled]);

  return shown;
}

/**
 * The animated figure itself, formatted the way every other number in the
 * product is. `suffix` carries the "+" of a bounded count, and `enabled` turns
 * the motion off where a number changes too often for counting to read as
 * anything but flicker.
 */
export default function CountUp({ value, suffix = "", enabled = true, className }: {
  value: number;
  suffix?: string;
  enabled?: boolean;
  className?: string;
}) {
  const shown = useCountUp(value, enabled);
  return <span className={className ? `count-up ${className}` : "count-up"}>{formatNumber(shown)}{suffix}</span>;
}
