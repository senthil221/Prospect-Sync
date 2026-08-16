import { memo } from "react";
import { colorTone, formatNumber, initials } from "../../lib/dashboard-helpers";
import type { Company } from "../../lib/types";
import { AppIcon } from "./DashboardUi";

function CompanyTableRow({ company, selected, canDelete, onOpen, onToggleSelected, onDelete }: { company: Company; selected: boolean; canDelete: boolean; onOpen: (company: Company) => void; onToggleSelected: (id: string) => void; onDelete: (id: string) => void }) {
  const tone = colorTone(company.id);
  return <tr className={`company-row tone-${tone} ${selected ? "selected" : ""}`} onClick={() => onOpen(company)}>
    {canDelete ? <td className="select-column" onClick={(event) => event.stopPropagation()}><input aria-label={`Select ${company.name || company.domain || "company"}`} type="checkbox" checked={selected} onChange={() => onToggleSelected(company.id)}/></td> : null}
    <td><div className="company-identity"><button className="company-open" aria-label={`Open ${company.name || company.domain || "company"} details`} onClick={(event) => { event.stopPropagation(); onOpen(company); }}><AppIcon name="arrow" size={15}/></button><span className={`company-logo tone-${tone}`}>{initials(company.name)}</span><div><strong>{company.name || company.domain || "Unnamed company"}</strong><small>{company.prospect_count ? `${formatNumber(company.prospect_count)} people available` : "No prospects linked"}</small></div></div></td>
    <td onClick={(event) => event.stopPropagation()}>{company.domain ? <a href={`https://${company.domain}`} target="_blank" rel="noreferrer">{company.domain}</a> : <span className="missing-value">No domain</span>}</td>
    <td><span className="prospect-count-badge">{formatNumber(company.prospect_count)}</span></td><td>{formatNumber(company.client_count)} {company.client_count === 1 ? "client" : "clients"}</td><td>{new Date(company.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><span className={`coverage-status ${company.prospect_count ? "known" : "new"}`}>{company.prospect_count ? "Covered" : "Needs prospects"}</span></td>
    {canDelete ? <td className="row-detail-column" onClick={(event) => event.stopPropagation()}><button className="row-danger" title={`Delete ${company.name || company.domain || "this company"} from the Company database`} onClick={() => onDelete(company.id)}>Delete</button></td> : null}
  </tr>;
}

export default memo(CompanyTableRow);
