"use client";

import { useEffect, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { StrategyPicker, estimateStrategy, hasObservedCost, type CostPerCompany, type StrategyId } from "./IcpStrategyPicker";
import { money } from "./IcpValidatorViews";

type Profile = { id: string; name: string; description: string };

// Re-check the client's ICP Invalid blocklist against one or more ICPs
// (scope 'blocklisted', 20261010120000). One ICP check per ICP; the ICP worker
// takes every FIT off the blocklist, brings the company and its people back,
// and tags it with that ICP. NON_FITs stay blocked.
export default function IcpInvalidRecheckDialog({ clientId, clientName, onClose, onStarted }: {
  clientId: string;
  clientName: string;
  onClose: () => void;
  onStarted: (message: string) => void;
}) {
  const [profiles, setProfiles] = useState<Profile[] | null>(null);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [strategy, setStrategy] = useState<StrategyId>("balanced");
  const [companies, setCompanies] = useState<number | null>(null);
  const [observed, setObserved] = useState<CostPerCompany | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let current = true;
    void (async () => {
      try {
        const [icp, scope] = await Promise.all([
          api<{ profiles?: Array<{ id: string; name: string; description?: string }> }>(`/api/clients/${encodeURIComponent(clientId)}/icp`, { cache: "no-store" }),
          api<{ companies: number; costPerCompany?: CostPerCompany }>(`/api/icp-checks?view=blocklisted&client=${encodeURIComponent(clientId)}`, { cache: "no-store" }),
        ]);
        if (!current) return;
        const usable = (icp.profiles ?? []).filter((profile) => (profile.description ?? "").trim())
          .map((profile) => ({ id: profile.id, name: profile.name.trim() || "Unnamed ICP", description: profile.description ?? "" }));
        setProfiles(usable);
        setChosen(new Set(usable.slice(0, 1).map((profile) => profile.id)));
        setCompanies(scope.companies);
        setObserved(scope.costPerCompany ?? null);
      } catch (caught) {
        if (current) { setProfiles([]); setError(caught instanceof Error ? caught.message : "Unable to load the ICPs."); }
      }
    })();
    return () => { current = false; };
  }, [clientId]);

  const briefLength = Math.max(800, ...[...chosen].map((id) => profiles?.find((profile) => profile.id === id)?.description.length ?? 0));
  const total = companies ? estimateStrategy(strategy, companies, briefLength, observed) * chosen.size : 0;

  async function start() {
    setBusy(true); setError("");
    let started = 0;
    try {
      for (const icpId of chosen) {
        await api("/api/icp-checks", { method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "start", clientId, icpId, strategy, scope: "blocklisted", autoApply: true }) });
        started += 1;
      }
      onStarted(`Started ${started} ICP ${started === 1 ? "check" : "checks"} on ${formatNumber(companies ?? 0)} ICP Invalid companies. FITs come off the blocklist and get the ICP tag as results arrive.`);
    } catch (caught) {
      setError(`${started ? `${started} started, then: ` : ""}${caught instanceof Error ? caught.message : "Unable to start the check."}`);
    } finally { setBusy(false); }
  }

  return <div className="modal-backdrop" role="presentation">
    <section className="confirm-modal icp-recheck-dialog" role="dialog" aria-modal="true" aria-labelledby="icp-recheck-title">
      <p className="eyebrow">ICP INVALID BLOCKLIST</p>
      <h2 id="icp-recheck-title">Re-check ICP Invalid companies</h2>
      <p>Runs an ICP check on {clientName}&apos;s companies blocked as <strong>ICP Invalid</strong>. A company that now fits comes off the blocklist with its people, is marked ICP verified and gets the ICP&apos;s tag. The rest stay blocked. This uses model tokens.</p>
      {profiles === null ? <div className="workspace-loading">Loading…</div> : <>
        <fieldset className="icp-recheck-icps"><legend>Check against</legend>
          {profiles.length ? profiles.map((profile) => <label key={profile.id} className="inline-checkbox"><input type="checkbox" checked={chosen.has(profile.id)}
            onChange={() => setChosen((current) => { const next = new Set(current); if (next.has(profile.id)) next.delete(profile.id); else next.add(profile.id); return next; })}/> {profile.name}</label>)
            : <p className="form-error">This client has no ICP with a brief. Add one on the ICPs tab.</p>}
        </fieldset>
        <StrategyPicker name="icp-recheck-strategy" value={strategy} onChange={setStrategy} companies={companies ?? 0} briefLength={briefLength} observed={observed}/>
        <p className="source-selected-note" role="status">{companies === null ? "Counting…" : `${formatNumber(companies)} ICP Invalid ${companies === 1 ? "company" : "companies"} to check${chosen.size > 1 ? ` against each of ${chosen.size} ICPs` : ""} · ${hasObservedCost(strategy, observed) ? "about" : "list price about"} ${money(total)}`}</p>
      </>}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="modal-actions">
        <button className="secondary" data-autofocus disabled={busy} onClick={onClose}>Cancel</button>
        <button className="primary" disabled={busy || !chosen.size || !companies} onClick={() => void start()}>{busy ? "Starting…" : `Re-check ${formatNumber(companies ?? 0)} companies`}</button>
      </div>
    </section>
  </div>;
}
