"use client";

import { useMemo, useState } from "react";
import type { ClientRecord } from "../../lib/types";
import { AppIcon } from "./DashboardUi";
import IcpValidatorPanel from "./IcpValidatorPanel";

// The ICP Validator as a Data tool: the bench for comparing models on a
// client's ICP (any OpenRouter model, side by side). Everyday checks run from
// each client's ICP checks tab; this is where new models get tried first.
export default function IcpValidatorWorkspace({ clients }: { clients: ClientRecord[] }) {
  const usable = useMemo(() => clients.filter((client) => !client.archived_at), [clients]);
  const [clientId, setClientId] = useState("");
  const client = usable.find((item) => item.id === clientId) ?? usable[0] ?? null;

  if (!client) {
    return <div className="icpx-empty is-large"><AppIcon name="clients" size={26}/><div><strong>No clients yet</strong><p>Create a client and give it an ICP brief to compare models on it.</p></div></div>;
  }
  return <div className="icpv-workspace">
    <label className="icpv-client-picker">
      <span>Client</span>
      <select value={client.id} onChange={(event) => setClientId(event.target.value)}>
        {usable.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}
      </select>
    </label>
    <IcpValidatorPanel key={client.id} client={client}/>
  </div>;
}
