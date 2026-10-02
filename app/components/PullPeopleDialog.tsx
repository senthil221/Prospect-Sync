"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { DepartmentFunctionFilter, IncludeExcludeFilter, ManagementLevelFilter } from "../ApolloFilterPanel";
import { api } from "../../lib/dashboard-api";
import { formatNumber } from "../../lib/dashboard-helpers";
import { emptyTaxonomy, type TitleTaxonomy } from "../../lib/title-taxonomy";
import type { ProspectFilter } from "../../lib/types";

type Preview = { companies: number; matching: number; alreadyInClient: number; blocked: number; toAdd: number };
type Pulled = Preview & { added?: number; queued?: number };

const titleFields = new Set(["__title"]);
const levelFields = new Set(["__title_seniority_tier"]);
const departmentFields = new Set(["__title_department", "__title_sub_department"]);

// Pull people from the Master People DB at companies this client already has,
// by job title, management level and department. New people the Master DB
// gained since (a later import) are added; people the client already has, and
// people on its blocklist, are not. The last criteria are remembered per client.
export default function PullPeopleDialog({ clientId, clientName, selectedCount, selection, onClose, onDone }: {
  clientId: string;
  clientName: string;
  selectedCount: number;
  selection: Record<string, unknown>;
  onClose: () => void;
  onDone: (message: string) => void;
}) {
  const [filters, setFilters] = useState<ProspectFilter[] | null>(null);
  const [taxonomy, setTaxonomy] = useState<TitleTaxonomy>(emptyTaxonomy);
  const [preview, setPreview] = useState<{ key: string; value: Preview } | null>(null);
  const [previewError, setPreviewError] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const requestId = useRef(`pull-${crypto.randomUUID()}`);

  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(() => {
      api<{ filters: ProspectFilter[] }>(`/api/clients/${encodeURIComponent(clientId)}/pull-people`, { cache: "no-store" })
        .then((result) => { if (!cancelled) setFilters(result.filters.map((filter, index) => ({ ...filter, id: `pull:${index}:${filter.field}` }))); })
        .catch(() => { if (!cancelled) setFilters([]); });
      // Master DB counts: the pull reads the Master DB, not this client.
      api<{ taxonomy?: TitleTaxonomy }>("/api/prospects/title-taxonomy")
        .then((result) => { if (!cancelled && result.taxonomy) setTaxonomy(result.taxonomy); })
        .catch(() => {});
    }, 0);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [clientId]);

  const payload = useMemo(() => filters ? {
    ...selection,
    peopleFilters: filters.map(({ field, operator, values }) => ({ field, operator, values })),
  } : null, [filters, selection]);
  const payloadKey = payload ? JSON.stringify(payload) : "";

  // Counts follow the criteria, a moment after the last change.
  useEffect(() => {
    if (!payload) return;
    let cancelled = false;
    const timer = window.setTimeout(() => {
      setPreviewError("");
      api<{ result: Preview }>(`/api/clients/${encodeURIComponent(clientId)}/pull-people`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "preview", ...payload }),
      }).then((result) => { if (!cancelled) setPreview({ key: payloadKey, value: result.result }); })
        .catch((caught) => { if (!cancelled) setPreviewError(caught instanceof Error ? caught.message : "Unable to count matching people."); });
    }, 400);
    return () => { cancelled = true; window.clearTimeout(timer); };
    // payloadKey carries the payload's content.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [clientId, payloadKey]);

  const current = preview?.key === payloadKey ? preview.value : null;

  function setGroup(fields: Set<string>, next: ProspectFilter[]) {
    setFilters((existing) => [...(existing ?? []).filter((filter) => !fields.has(filter.field)), ...next]);
  }

  async function pull() {
    if (!payload || !current?.toAdd) return;
    setBusy(true); setError("");
    try {
      const result = await api<{ result: Pulled }>(`/api/clients/${encodeURIComponent(clientId)}/pull-people`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "pull", requestId: requestId.current, ...payload }),
      });
      const added = Number(result.result.added ?? 0);
      const queued = Number(result.result.queued ?? 0);
      onDone(`Added ${formatNumber(added)} ${added === 1 ? "person" : "people"} from the Master DB at ${formatNumber(result.result.companies)} ${result.result.companies === 1 ? "company" : "companies"} to ${clientName}. They are on Recently Added.${queued ? ` ${formatNumber(queued)} are still being indexed and will appear shortly.` : ""}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Unable to pull people.");
      setBusy(false);
    }
  }

  const all = filters ?? [];
  const criteria = all.length;
  return <div className="modal-backdrop" role="presentation">
    <section className="confirm-modal pull-people-dialog" role="dialog" aria-modal="true" aria-labelledby="pull-people-title">
      <p className="eyebrow">MASTER PEOPLE DB</p>
      <h2 id="pull-people-title">Pull people for {formatNumber(selectedCount)} {selectedCount === 1 ? "company" : "companies"}</h2>
      <p>Adds the Master DB&apos;s people at these companies who match the job filters below and are not in {clientName} yet. Run it again later to pick up people added since.</p>
      {filters === null ? <div className="workspace-loading">Loading…</div> : <div className="pull-people-criteria">
        <div className="pull-people-field"><span className="include-exclude-label-heading">Job title</span>
          <IncludeExcludeFilter field="__title" filters={all.filter((filter) => titleFields.has(filter.field))} onChange={(next) => setGroup(titleFields, next)}/>
        </div>
        <div className="pull-people-field"><span className="include-exclude-label-heading">Management level</span>
          <ManagementLevelFilter filters={all.filter((filter) => levelFields.has(filter.field))} taxonomy={taxonomy} onChange={(next) => setGroup(levelFields, next)}/>
        </div>
        <div className="pull-people-field"><span className="include-exclude-label-heading">Department &amp; job function</span>
          <DepartmentFunctionFilter filters={all.filter((filter) => departmentFields.has(filter.field))} taxonomy={taxonomy} onChange={(next) => setGroup(departmentFields, next)}/>
        </div>
      </div>}
      <div className="pull-people-summary" role="status">
        {previewError ? <span className="form-error">{previewError}</span>
          : !current ? <span>Counting…</span>
          : <>
            <strong>{formatNumber(current.toAdd)} new {current.toAdd === 1 ? "person" : "people"}</strong>
            <span>{formatNumber(current.matching)} match{criteria ? "" : " (no job filter - everyone)"} at {formatNumber(current.companies)} {current.companies === 1 ? "company" : "companies"}{current.alreadyInClient ? ` · ${formatNumber(current.alreadyInClient)} already in ${clientName}` : ""}{current.blocked ? ` · ${formatNumber(current.blocked)} on the blocklist` : ""}</span>
          </>}
      </div>
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="modal-actions">
        <button className="secondary" data-autofocus disabled={busy} onClick={onClose}>Cancel</button>
        <button className="primary" disabled={busy || !current?.toAdd} onClick={() => void pull()}>{busy ? "Adding…" : current?.toAdd ? `Add ${formatNumber(current.toAdd)} to ${clientName}` : "Nothing new to add"}</button>
      </div>
    </section>
  </div>;
}
