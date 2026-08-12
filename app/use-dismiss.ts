"use client";

import { RefObject, useEffect, useRef } from "react";

/**
 * Dismisses a floating element (menu, popover, expanded panel) when the user
 * points down anywhere outside it or presses Escape. Uses the capture phase so
 * it runs before inner click handlers, and only listens while `active` is true.
 */
export function useDismiss<T extends HTMLElement>(ref: RefObject<T | null>, onDismiss: () => void, active = true) {
  const onDismissRef = useRef(onDismiss);

  useEffect(() => {
    onDismissRef.current = onDismiss;
  }, [onDismiss]);

  useEffect(() => {
    if (!active) return;
    function handlePointer(event: PointerEvent) {
      const node = ref.current;
      if (node && !node.contains(event.target as Node)) onDismissRef.current();
    }
    function handleKey(event: KeyboardEvent) {
      if (event.key === "Escape") onDismissRef.current();
    }
    document.addEventListener("pointerdown", handlePointer, true);
    document.addEventListener("keydown", handleKey);
    return () => {
      document.removeEventListener("pointerdown", handlePointer, true);
      document.removeEventListener("keydown", handleKey);
    };
  }, [ref, active]);
}
