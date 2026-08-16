"use client";

import { useState } from "react";
import { formatNumber, initials, parseAllData } from "../../lib/dashboard-helpers";
import type { DuplicateCandidate, Prospect } from "../../lib/types";

export default function DuplicatesPanel({ candidate }: { candidate: DuplicateCandidate }) {
  return <><ProspectCompareCard prospect={candidate.left}/><div className="compare-divider">vs</div><ProspectCompareCard prospect={candidate.right}/></>;
}
function ProspectCompareCard({ prospect }: { prospect: Prospect }) {
  const [expanded, setExpanded] = useState(false);
  const fields = Object.entries({ "Full name": prospect.full_name, "Title": prospect.title, "Company": prospect.company_name, "Work email": prospect.work_email, "Personal email": prospect.personal_email, "LinkedIn": prospect.linkedin_url, "Mobile": prospect.mobile_number, "Seniority": prospect.seniority, "Department": prospect.department, "City": prospect.city, "State": prospect.state, "Country": prospect.country, ...parseAllData(prospect.all_data) }).filter(([, value]) => String(value ?? "").trim());
  return <div className={`compare-card ${expanded ? "expanded" : ""}`}><div className="compact-person"><span>{initials(prospect.full_name)}</span><strong>{prospect.full_name || "Unnamed"}</strong></div><p>{prospect.title || "No title"}</p><p>{prospect.company_name || "No company"}</p><p>{prospect.work_email || "No work email"}</p>{prospect.client_names?.length ? <div className="compare-client-list">{prospect.client_names.map((name) => <span key={name}>{name}</span>)}</div> : null}<div className="compare-card-footer"><small>{formatNumber(prospect.list_count)} lists · {formatNumber(fields.length)} populated fields</small><button aria-expanded={expanded} onClick={() => setExpanded((open) => !open)}>{expanded ? "Hide fields" : "View all fields"}</button></div>{expanded ? <div className="compare-fields">{fields.map(([field, value]) => <div key={field}><span>{field}</span><strong>{String(value)}</strong></div>)}</div> : null}</div>;
}
