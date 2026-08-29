import { memo } from "react";
import { initials, prospectFieldValue, prospectMembershipItems } from "../../lib/dashboard-helpers";
import { clientIdleAge } from "../../lib/client-idle-age";
import type { Prospect } from "../../lib/types";

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
  return <div className="membership-chips" title={`${memberships.length} linked ${memberships.length === 1 ? "list" : "lists"}`}>
    {memberships.slice(0, 2).map((membership) => <span key={membership.key}>{membership.label}</span>)}
    {hiddenCount ? <button type="button" aria-label={`Show all ${memberships.length} list memberships for ${prospect.full_name || "this prospect"}`} onClick={(event) => { event.stopPropagation(); onShowAll(); }}>+{hiddenCount} more</button> : null}
  </div>;
}

function ProspectTableRow({ prospect, visibleDefinitions, selected, includeClient, canDeleteMaster, clientId, onSelect, onToggleSelected, onRemoveFromClient, onDelete }: { prospect: Prospect; visibleDefinitions: ColumnDefinition[]; selected: boolean; includeClient: boolean; canDeleteMaster: boolean; clientId?: string; onSelect: (prospect: Prospect) => void; onToggleSelected: (id: string) => void; onRemoveFromClient?: (prospect: Prospect) => Promise<void>; onDelete: (id: string) => void }) {
  // Per-client state: ICP verification and blocklist status are true for this
  // client only, so they are read from the arrays the index carries per row.
  const verified = Boolean(clientId && prospect.icp_verified_client_ids?.includes(clientId));
  const blocked = Boolean(clientId && prospect.blocked_client_ids?.includes(clientId));
  const idleAge = clientId ? clientIdleAge(prospect.client_date_contacted) : null;
  return <tr className={`${selected ? "selected" : ""} ${blocked ? "row-blocked" : ""}`.trim()} onClick={() => onSelect(prospect)}>
    <td className="select-column" onClick={(event) => event.stopPropagation()}><input aria-label={`Select ${prospect.full_name || "prospect"}`} type="checkbox" checked={selected} onChange={() => onToggleSelected(prospect.id)}/></td>
    {visibleDefinitions.map((field) => {
      const value = prospectFieldValue(prospect, field.id);
      return <td key={field.id}>{field.id === "__name" ? <div className="compact-person"><span>{initials(value)}</span><strong>{value || "Unnamed prospect"}</strong></div> : field.id === "__email" ? <span className="email-cell">{value || "-"}</span> : field.id === "__esp" ? <span className={`esp-cell ${prospect.email_provider_type === "SEG" ? "seg" : ""}`} title={Array.isArray(prospect.mx_records) && prospect.mx_records.length ? prospect.mx_records.join("\n") : "Run Detect ESPs to check this domain"}><strong>{value || "Not checked"}</strong><small>{prospect.email_provider_type || "Unknown"}</small></span> : field.id === "__lists" ? <ListMembershipCell prospect={prospect} includeClient={includeClient} onShowAll={() => onSelect(prospect)}/> : <span title={value}>{value || "-"}</span>}</td>;
    })}
    {clientId ? <><td className="date-added-column" title={prospect.client_date_contacted ? `Contacted for this client on ${formatClientDate(prospect.client_date_contacted)}` : "No contact date for this client"}><span className={`client-idle-age ${idleAge?.tone ?? "unknown"}`}><strong>{formatClientDate(prospect.client_date_contacted)}</strong><small>{idleAge?.label ?? "No contact date"}</small></span></td><td className="icp-column">{blocked ? <span className="blocked-badge" title={String(prospect.blocked_reason ?? "Blocked for this client")}>Blocked</span> : <span className={`company-icp-status ${verified ? "validated" : "pending"}`} title="Inherited from this client's company verification">{verified ? "Verified" : "Not verified"}</span>}</td></> : null}<td className="row-detail-column" onClick={(event) => event.stopPropagation()}>{onRemoveFromClient ? <button className="row-danger client-remove-prospect" onClick={() => void onRemoveFromClient(prospect)}>Remove</button> : canDeleteMaster ? <button className="row-danger" title={`Delete ${prospect.full_name || "this prospect"} from the People database`} onClick={() => onDelete(prospect.id)}>Delete</button> : "›"}</td>
  </tr>;
}

export default memo(ProspectTableRow);
