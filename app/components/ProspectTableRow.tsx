import { memo } from "react";
import { initials, prospectFieldValue, prospectMembershipItems } from "../../lib/dashboard-helpers";
import { clientIdleAge } from "../../lib/client-idle-age";
import type { Prospect } from "../../lib/types";
import { Tooltip } from "./DashboardUi";

type ColumnDefinition = { id: string; label: string };

function formatClientDate(value: unknown) {
  const date = String(value ?? "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return "-";
  const [year, month, day] = date.split("-").map(Number);
  return new Intl.DateTimeFormat("en-IN", { day: "2-digit", month: "short", year: "numeric" })
    .format(new Date(year, month - 1, day));
}

function ListMembershipCell({ prospect, includeClient, onShowAll }: { prospect: Prospect; includeClient: boolean; onShowAll: () => void }) {
  const memberships = prospectMembershipItems(prospect, includeClient);
  if (!memberships.length) return <span className="missing-value">No linked list</span>;
  const hiddenCount = Math.max(0, memberships.length - 2);
  return <Tooltip content={`${memberships.length} linked ${memberships.length === 1 ? "list" : "lists"}`}>
    {/* Not a control - just made focusable so the full membership count (TOOLTIP-01)
        reaches a keyboard user the same way it already reaches a mouse one. */}
    {/* eslint-disable-next-line jsx-a11y/no-noninteractive-tabindex */}
    <div className="membership-chips" tabIndex={0}>
      {memberships.slice(0, 2).map((membership) => <span key={membership.key}>{membership.label}</span>)}
      {hiddenCount ? <button type="button" aria-label={`Show all ${memberships.length} list memberships for ${prospect.full_name || "this prospect"}`} onClick={(event) => { event.stopPropagation(); onShowAll(); }}>+{hiddenCount} more</button> : null}
    </div>
  </Tooltip>;
}

function ProspectTableRow({ prospect, visibleDefinitions, selected, includeClient, canDeleteMaster, clientId, clientCooldownDays = 90, onSelect, onToggleSelected, onRemoveFromClient, onDelete }: { prospect: Prospect; visibleDefinitions: ColumnDefinition[]; selected: boolean; includeClient: boolean; canDeleteMaster: boolean; clientId?: string; clientCooldownDays?: number; onSelect: (prospect: Prospect) => void; onToggleSelected: (id: string) => void; onRemoveFromClient?: (prospect: Prospect) => Promise<void>; onDelete: (id: string) => void }) {
  // Per-client state: ICP verification and blocklist status are true for this
  // client only, so they are read from the arrays the index carries per row.
  const verified = Boolean(clientId && prospect.icp_verified_client_ids?.includes(clientId));
  const blocked = Boolean(clientId && prospect.blocked_client_ids?.includes(clientId));
  const idleAge = clientId ? clientIdleAge(prospect.client_date_contacted, clientCooldownDays) : null;
  const dateAddedTooltip = prospect.client_date_contacted
    ? `Contacted for this client on ${formatClientDate(prospect.client_date_contacted)}; next eligible ${idleAge?.nextEligibleDate ?? "unknown"}`
    : "No contact date for this client; eligible now";
  return <tr className={`${selected ? "selected" : ""} ${blocked ? "row-blocked" : ""}`.trim()} onClick={() => onSelect(prospect)}>
    <td className="select-column" onClick={(event) => event.stopPropagation()}><input aria-label={`Select ${prospect.full_name || "prospect"}`} type="checkbox" checked={selected} onChange={() => onToggleSelected(prospect.id)}/></td>
    {visibleDefinitions.map((field) => {
      const value = prospectFieldValue(prospect, field.id);
      // Cells below are plain text, not controls - tabIndex only exists so the
      // Tooltip they sit in (TOOLTIP-01) is reachable by keyboard, not mouse only.
      // eslint-disable-next-line jsx-a11y/no-noninteractive-tabindex
      return <td key={field.id} className={field.id === "__employee_count" ? "numeric-cell" : undefined}>{field.id === "__name" ? <div className="compact-person"><span aria-hidden="true">{initials(value)}</span><Tooltip content={value || "Unnamed prospect"}><button type="button" className="row-open" onClick={(event) => { event.stopPropagation(); onSelect(prospect); }}>{value || "Unnamed prospect"}</button></Tooltip></div> : field.id === "__email" ? <Tooltip content={value || undefined}><span className="email-cell" tabIndex={value ? 0 : undefined}>{value || "-"}</span></Tooltip> : field.id === "__esp" ? <Tooltip content={Array.isArray(prospect.mx_records) && prospect.mx_records.length ? prospect.mx_records.join("\n") : "Run Detect ESPs to check this domain"}><span className={`esp-cell ${prospect.email_provider_type === "SEG" ? "seg" : ""}`} tabIndex={0}><strong>{value || "Not checked"}</strong><small>{prospect.email_provider_type || "Unknown"}</small></span></Tooltip> : field.id === "__lists" ? <ListMembershipCell prospect={prospect} includeClient={includeClient} onShowAll={() => onSelect(prospect)}/> : <Tooltip content={value || undefined}><span tabIndex={value ? 0 : undefined}>{value || "-"}</span></Tooltip>}</td>;
    })}
    {/* eslint-disable-next-line jsx-a11y/no-noninteractive-tabindex */}
    {clientId ? <><td className="date-added-column"><Tooltip content={dateAddedTooltip}><span className={`client-idle-age ${idleAge?.tone ?? "unknown"}`} tabIndex={0}><strong>{formatClientDate(prospect.client_date_contacted)}</strong><small>{idleAge?.label ?? "Eligible now · no contact date"}</small></span></Tooltip></td><td className="icp-column">{blocked ? <Tooltip content={String(prospect.blocked_reason ?? "Blocked for this client")}><span className="blocked-badge" tabIndex={0}>Blocked</span></Tooltip> : <Tooltip content="Inherited from this client's company verification"><span className={`company-icp-status ${verified ? "validated" : "pending"}`} tabIndex={0}>{verified ? "Verified" : "Not verified"}</span></Tooltip>}</td></> : null}<td className="row-detail-column" onClick={(event) => event.stopPropagation()}>{onRemoveFromClient ? <button className="row-danger client-remove-prospect" onClick={() => void onRemoveFromClient(prospect)}>Remove</button> : canDeleteMaster ? <Tooltip content={`Delete ${prospect.full_name || "this prospect"} from the People database`}><button className="row-danger" onClick={() => onDelete(prospect.id)}>Delete</button></Tooltip> : "›"}</td>
  </tr>;
}

export default memo(ProspectTableRow);
