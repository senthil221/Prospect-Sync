"use client";

import { useEffect, useState } from "react";

export type ClientListOption = { id: string; name: string };

/**
 * The client's uploaded lists, as filter options.
 *
 * Fetched per client rather than threaded down as a prop, the same reasoning
 * use-client-icps.ts already gives for ICPs: one small indexed read
 * (list_summaries by client_id), against a prop threaded through ClientsPanel
 * and both filter panels.
 */
export function useClientLists(clientId?: string) {
  const [lists, setLists] = useState<ClientListOption[]>([]);

  useEffect(() => {
    if (!clientId) return;
    let current = true;
    const controller = new AbortController();
    void (async () => {
      try {
        const response = await fetch(`/api/lists?clientId=${encodeURIComponent(clientId)}`, { signal: controller.signal });
        const data = await response.json() as { lists?: Array<{ id: string; name: string }> };
        if (!current || !response.ok) return;
        setLists((data.lists ?? [])
          .filter((list) => list.id && list.name?.trim())
          .map((list) => ({ id: list.id, name: list.name.trim() })));
      } catch {
        // A workspace must still work with no lists loaded, and a database
        // without the migration answers 503 - both mean "offer nothing".
      }
    })();
    return () => { current = false; controller.abort(); };
  }, [clientId]);

  return clientId ? lists : [];
}
