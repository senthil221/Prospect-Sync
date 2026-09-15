"use client";

import { useEffect, useState } from "react";

export type ClientIcpOption = { id: string; name: string };

/**
 * The client's named ICPs, as tag options.
 *
 * An ICP owns its tag, so "the client's ICP tags" and "the client's ICPs" are
 * the same list — which is why nothing here fetches tags. Only profiles that
 * have been named have a tag, so the unnamed ones are dropped: there is nothing
 * to apply or filter by until somebody names it.
 *
 * Fetched per client rather than plumbed down through four components, the same
 * way ApolloFilterPanel already loads the title taxonomy. It is one small
 * indexed read of client_icp_profiles, and the alternative is a prop threaded
 * through ClientsPanel, the two workspaces and both filter panels.
 *
 * Returns the ids of TAGS, not of profiles: the filters and the write paths
 * both take tag ids.
 */
export function useClientIcps(clientId?: string) {
  const [icps, setIcps] = useState<ClientIcpOption[]>([]);

  useEffect(() => {
    if (!clientId) return;
    let current = true;
    const controller = new AbortController();
    void (async () => {
      try {
        const response = await fetch(`/api/clients/${encodeURIComponent(clientId)}/icp`, { signal: controller.signal });
        const data = await response.json() as { profiles?: Array<{ name: string; tag_id: string | null }> };
        if (!current || !response.ok) return;
        setIcps((data.profiles ?? [])
          .filter((profile) => profile.tag_id && profile.name.trim())
          .map((profile) => ({ id: profile.tag_id as string, name: profile.name.trim() })));
      } catch {
        // A workspace must still work with no ICPs defined, and a database
        // without the migration answers 503 - both mean "offer nothing".
      }
    })();
    return () => { current = false; controller.abort(); };
  }, [clientId]);

  // Derived rather than cleared in the effect: clearing there is a setState in
  // an effect body, which is a cascading render. With no client there are no
  // client ICPs, so the answer is simply the empty list.
  return clientId ? icps : [];
}
