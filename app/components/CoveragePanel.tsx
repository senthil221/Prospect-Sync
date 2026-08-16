"use client";

import { ChangeEvent, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber, readImportTable } from "../../lib/dashboard-helpers";
import type { CoverageRow } from "../../lib/types";

export default function CoveragePanel() {
  const [file, setFile] = useState<File | null>(null);
  const [headers, setHeaders] = useState<string[]>([]);
  const [nameField, setNameField] = useState("");
  const [domainField, setDomainField] = useState("");
  const [rows, setRows] = useState<CoverageRow[]>([]);
  const [summary, setSummary] = useState<{ total: number; known: number; new: number; covered: number; existingProspects: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function selectCoverageFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null; setFile(next); setRows([]); setSummary(null); setError("");
    if (!next) { setHeaders([]); return; }
    try {
      const parsed = await readImportTable(next); setHeaders(parsed.headers);
      const normalized = (value: string) => value.toLowerCase().replace(/[^a-z0-9]/g, "");
      setDomainField(parsed.headers.find((header) => ["companywebsite", "website", "domain", "companydomain"].includes(normalized(header))) ?? "");
      setNameField(parsed.headers.find((header) => ["company", "companyname", "casualcompanyname", "organization"].includes(normalized(header))) ?? "");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Unable to read this CSV."); }
  }

  async function checkCoverage() {
    if (!file || (!nameField && !domainField)) return;
    setBusy(true); setError("");
    try {
      const parsed = await readImportTable(file);
      const nameIndex = parsed.headers.indexOf(nameField); const domainIndex = parsed.headers.indexOf(domainField);
      const companies = parsed.rows.map((row, index) => ({ row: index + 2, name: nameIndex >= 0 ? row[nameIndex] : "", domain: domainIndex >= 0 ? row[domainIndex] : "" }));
      const data = await api<{ rows: CoverageRow[]; summary: NonNullable<typeof summary> }>("/api/coverage", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ companies }) });
      setRows(data.rows); setSummary(data.summary);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Coverage check failed."); }
    finally { setBusy(false); }
  }

  function exportNewCompanies() {
    const newRows = rows.filter((row) => row.status === "new");
    const csv = ["Company,Domain,Source row", ...newRows.map((row) => `"${row.name.replace(/"/g, '""')}","${row.domain.replace(/"/g, '""')}",${row.row}`)].join("\r\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" })); const link = document.createElement("a"); link.href = url; link.download = "net-new-companies.csv"; link.click(); URL.revokeObjectURL(url);
  }

  return <section className="operations-page"><div className="section-intro compact-intro"><div><p className="eyebrow">BEFORE YOU SCRAPE</p><h2>Company coverage checker</h2><p>Check a company list against your database before paying for employee emails.</p></div></div>
    <div className="coverage-workspace"><article className="panel coverage-upload"><label className={`dropzone small ${file ? "has-file" : ""}`}><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={(event) => void selectCoverageFile(event)}/><span className="upload-mark">↑</span><strong>{file ? file.name : "Upload a company CSV or Excel file"}</strong><small>Up to 5,000 companies per check</small></label>{headers.length ? <div className="mapping-grid"><label>Company name<select value={nameField} onChange={(event) => setNameField(event.target.value)}><option value="">Not mapped</option>{headers.map((header) => <option key={header}>{header}</option>)}</select></label><label>Website or domain<select value={domainField} onChange={(event) => setDomainField(event.target.value)}><option value="">Not mapped</option>{headers.map((header) => <option key={header}>{header}</option>)}</select></label></div> : null}{error ? <p className="form-error" role="alert">{error}</p> : null}<button className="primary" disabled={!file || (!nameField && !domainField) || busy} onClick={() => void checkCoverage()}>{busy ? "Checking database…" : "Check company coverage"}</button></article>
      <article className="panel coverage-results">{summary ? <><div className="quality-metrics four"><div><span>Total companies</span><strong>{formatNumber(summary.total)}</strong></div><div><span>Already known</span><strong>{formatNumber(summary.known)}</strong></div><div><span>Net new</span><strong>{formatNumber(summary.new)}</strong></div><div><span>Existing prospects</span><strong>{formatNumber(summary.existingProspects)}</strong></div></div><div className="panel-head"><div><h3>Coverage results</h3><p>{summary.covered} companies already contain prospects</p></div><button onClick={exportNewCompanies}>Export net-new CSV</button></div><div className="table-wrap coverage-table"><table><thead><tr><th>Company</th><th>Domain</th><th>Status</th><th>Matched by</th><th>Prospects</th><th>Clients</th></tr></thead><tbody>{rows.map((row) => <tr key={`${row.row}-${row.domain}-${row.name}`}><td><strong>{row.name || row.matchedCompany || "Unnamed"}</strong></td><td>{row.domain || "-"}</td><td><span className={`coverage-status ${row.status}`}>{row.status === "known" ? "Known" : "Net new"}</span></td><td>{row.matchedBy || "-"}</td><td>{formatNumber(row.prospectCount)}</td><td>{formatNumber(row.clientCount)}</td></tr>)}</tbody></table></div></> : <div className="coverage-placeholder"><span>◫</span><h3>Know what already exists</h3><p>Upload company names or domains to see database coverage and export only net-new companies.</p></div>}</article></div>
  </section>;
}
