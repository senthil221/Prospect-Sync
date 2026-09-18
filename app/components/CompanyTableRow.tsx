import { memo } from "react";
import { colorTone, formatNumber, initials } from "../../lib/dashboard-helpers";
import type { Company } from "../../lib/types";
import { Tooltip } from "./DashboardUi";

function CompanyTableRow({ company, selected, showSelection, canDelete, clientScoped, onOpen, onToggleSelected, onDelete }: { company: Company; selected: boolean; showSelection: boolean; canDelete: boolean; clientScoped: boolean; onOpen: (company: Company) => void; onToggleSelected: (id: string) => void; onDelete: (id: string) => void }) {
  const tone = colorTone(company.id);
  const name = company.name || company.domain || "Unnamed company";
  return <tr className={`company-row tone-${tone} ${selected ? "selected" : ""}`} onClick={() => onOpen(company)}>
    {showSelection ? <td className="select-column" onClick={(event) => event.stopPropagation()}><input aria-label={`Select ${company.name || company.domain || "company"}`} type="checkbox" checked={selected} onChange={() => onToggleSelected(company.id)}/></td> : null}
    {/* Row-open parity with People (ROW-01): the company name is the focusable
        control, not a small trailing icon with the name left as inert text. */}
    <td><div className="company-identity"><span className={`company-logo tone-${tone}`}>{initials(company.name)}</span><div><Tooltip content={name}><button type="button" className="row-open" onClick={(event) => { event.stopPropagation(); onOpen(company); }}>{name}</button></Tooltip><small>{company.prospect_count ? `${formatNumber(company.prospect_count)} people available` : "No prospects linked"}</small></div></div></td>
    <td onClick={(event) => event.stopPropagation()}>{company.domain ? <a href={`https://${company.domain}`} target="_blank" rel="noreferrer">{company.domain}</a> : <span className="missing-value">No domain</span>}</td>
    <td className="numeric-cell"><span className="prospect-count-badge">{formatNumber(company.prospect_count)}</span></td><td className="numeric-cell">{formatNumber(company.client_count)} {company.client_count === 1 ? "client" : "clients"}</td><td className="date-added-column">{new Date(company.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</td><td><span className={`coverage-status ${company.prospect_count ? "known" : "new"}`}>{company.prospect_count ? "Covered" : "Needs prospects"}</span></td>{clientScoped ? <td className="company-icp-column"><span className={`company-icp-status ${company.icp_validated ? "validated" : "pending"}`}>{company.icp_validated ? "Verified" : "Not verified"}</span></td> : null}
    {canDelete ? <td className="row-detail-column" onClick={(event) => event.stopPropagation()}><Tooltip content={`Delete ${company.name || company.domain || "this company"} from the Company database`}><button className="row-danger" onClick={() => onDelete(company.id)}>Delete</button></Tooltip></td> : null}
  </tr>;
}

export default memo(CompanyTableRow);
