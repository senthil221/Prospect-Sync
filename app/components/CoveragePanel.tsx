"use client";

import { ChangeEvent, useState } from "react";
import { api } from "../../lib/dashboard-api";
import { formatNumber, readImportTable } from "../../lib/dashboard-helpers";
import {
  checkCoverageFile, checkCoverageTable, coverageMappingProblem, coverageReadProblem,
  coverageRowNotice, coverageServerProblem, formatFileSize, maxCoverageRows, problemText,
  type CoverageProblem,
} from "../../lib/coverage-file";
import type { CoverageRow } from "../../lib/types";
import { AppIcon, ProgressBar, StatusMessage } from "./DashboardUi";

type CoverageSummary = { total: number; known: number; new: number; covered: number; existingProspects: number };
type ParsedTable = { headers: string[]; rows: string[][] };

const normalized = (value: string) => value.toLowerCase().replace(/[^a-z0-9]/g, "");
const domainHeaders = ["companywebsite", "website", "domain", "companydomain", "url", "companyurl"];
const nameHeaders = ["company", "companyname", "casualcompanyname", "organization", "organisation", "account", "accountname"];

/**
 * COVERAGE-01/02: one task at a time.
 *
 * The panel used to frame the whole job at once - a small upload card on the
 * left and a 470px empty bordered canvas on the right, present from the first
 * paint. Two thirds of the screen were a promise about a step you could not
 * reach yet, and the mapping selects sat in the same card as the upload whether
 * or not there were any headers to map. Now each stage renders only itself:
 * upload, then map, then results. The stage is derived from what actually
 * exists rather than tracked separately, so it can never disagree with the data.
 */
export default function CoveragePanel() {
  const [file, setFile] = useState<File | null>(null);
  const [table, setTable] = useState<ParsedTable | null>(null);
  const [nameField, setNameField] = useState("");
  const [domainField, setDomainField] = useState("");
  const [rows, setRows] = useState<CoverageRow[]>([]);
  const [summary, setSummary] = useState<CoverageSummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [problem, setProblem] = useState<CoverageProblem | null>(null);
  const [notice, setNotice] = useState("");

  const stage = summary ? "results" : table && file ? "mapping" : "upload";
  const mappingHint = table ? coverageMappingProblem({ headers: table.headers, nameField, domainField }) : null;
  const checking = table ? Math.min(table.rows.length, maxCoverageRows) : 0;

  function forget(next: CoverageProblem | null) {
    setFile(null); setTable(null); setRows([]); setSummary(null); setNotice(""); setProblem(next);
  }

  async function selectCoverageFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    if (!next) return;                                        // cancelled picker: keep what was already loaded
    const rejected = checkCoverageFile(next);
    if (rejected) { forget(rejected); return; }
    try {
      const parsed = await readImportTable(next);
      const unusable = checkCoverageTable(next.name, parsed);
      if (unusable) { forget(unusable); return; }
      forget(null);
      setFile(next); setTable(parsed); setNotice(coverageRowNotice(parsed.rows.length));
      setDomainField(parsed.headers.find((header) => domainHeaders.includes(normalized(header))) ?? "");
      setNameField(parsed.headers.find((header) => nameHeaders.includes(normalized(header))) ?? "");
    } catch (caught) { forget(coverageReadProblem(next.name, caught)); }
  }

  async function checkCoverage() {
    if (!file || !table) return;
    const unmapped = coverageMappingProblem({ headers: table.headers, nameField, domainField });
    if (unmapped) { setProblem(unmapped); return; }
    setBusy(true); setProblem(null);
    try {
      const nameIndex = table.headers.indexOf(nameField);
      const domainIndex = table.headers.indexOf(domainField);
      const companies = table.rows.slice(0, maxCoverageRows).map((row, index) => ({
        row: index + 2,
        name: nameIndex >= 0 ? row[nameIndex] : "",
        domain: domainIndex >= 0 ? row[domainIndex] : "",
      }));
      const data = await api<{ rows: CoverageRow[]; summary: CoverageSummary }>("/api/coverage", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ companies }),
      });
      setRows(data.rows); setSummary(data.summary);
    } catch (caught) { setProblem(coverageServerProblem(caught)); }
    finally { setBusy(false); }
  }

  function exportNewCompanies() {
    const newRows = rows.filter((row) => row.status === "new");
    const quoted = (value: string) => `"${value.replace(/"/g, '""')}"`;
    const csv = ["Company,Domain,Source row", ...newRows.map((row) => `${quoted(row.name)},${quoted(row.domain)},${row.row}`)].join("\r\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv" }));
    const link = document.createElement("a"); link.href = url; link.download = "net-new-companies.csv"; link.click();
    URL.revokeObjectURL(url);
  }

  // Remounted per stage on purpose: a fresh input has an empty value, so
  // choosing the same file again still fires change. One input kept mounted is
  // how "Replace file" silently does nothing when you re-pick the same path.
  const fileInput = <input
    type="file"
    accept=".csv,.tsv,.xlsx,.xls,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    onChange={(event) => void selectCoverageFile(event)}
  />;

  const steps = <ol className="coverage-steps">
    <li aria-current={stage === "upload" ? "step" : undefined}>Upload list</li>
    <li aria-current={stage === "mapping" ? "step" : undefined}>Map columns</li>
    <li aria-current={stage === "results" ? "step" : undefined}>Check coverage</li>
  </ol>;

  const fileSummary = file && table ? <div className="coverage-file">
    <span className="coverage-file-mark"><AppIcon name="check" size={14}/></span>
    <div>
      <strong>{file.name}</strong>
      <small>{formatNumber(table.rows.length)} companies · {formatFileSize(file.size)}</small>
    </div>
    <label className="coverage-replace">Replace file{fileInput}</label>
  </div> : null;

  return <section className="operations-page coverage-page">
    <div className="section-intro compact-intro"><div>
      <p className="eyebrow">BEFORE YOU SCRAPE</p>
      <h2>Company coverage checker</h2>
      <p>Check a company list against your database before paying for employee emails.</p>
    </div></div>

    {stage === "upload" ? <article className="panel coverage-task">
      {steps}
      {/* COVERAGE-AC-01: the dropzone is the only control on screen. */}
      <label className="dropzone">
        {fileInput}
        <span className="upload-mark"><AppIcon name="upload" size={14}/></span>
        <strong>Upload a company CSV or Excel file</strong>
        <small>Up to {formatNumber(maxCoverageRows)} companies per check</small>
      </label>
      <p className="coverage-task-note">One column of company names or websites is enough. You choose which after it uploads.</p>
      {problem ? <StatusMessage tone="alert">{problemText(problem)}</StatusMessage> : null}
    </article> : null}

    {stage === "mapping" && table ? <article className="panel coverage-task">
      {steps}
      {fileSummary}
      {notice ? <StatusMessage>{notice}</StatusMessage> : null}
      <div className="mapping-grid">
        <label>Company name
          <select value={nameField} onChange={(event) => setNameField(event.target.value)}>
            <option value="">Not mapped</option>
            {table.headers.map((header) => <option key={header}>{header}</option>)}
          </select>
        </label>
        <label>Website or domain
          <select value={domainField} onChange={(event) => setDomainField(event.target.value)}>
            <option value="">Not mapped</option>
            {table.headers.map((header) => <option key={header}>{header}</option>)}
          </select>
        </label>
      </div>
      {mappingHint ? <StatusMessage>{problemText(mappingHint)}</StatusMessage> : null}
      {problem ? <StatusMessage tone="alert">{problemText(problem)}</StatusMessage> : null}
      {busy ? <ProgressBar label={`Checking ${formatNumber(checking)} companies against the database`}/> : null}
      <button className="primary coverage-check" disabled={busy || !!mappingHint} onClick={() => void checkCoverage()}>
        {busy ? "Checking database…" : `Check ${formatNumber(checking)} companies`}
      </button>
    </article> : null}

    {stage === "results" && summary ? <div className="coverage-report">
      <article className="panel coverage-task wide">
        {steps}
        {fileSummary}
        <button className="secondary" onClick={() => { setSummary(null); setRows([]); setProblem(null); }}>Change mapping</button>
      </article>
      {/* COVERAGE-04: the totals are said out loud, not only drawn. */}
      <StatusMessage>
        {formatNumber(summary.total)} companies checked — {formatNumber(summary.known)} already known, {formatNumber(summary.new)} net new.
      </StatusMessage>
      <div className="quality-metrics four">
        <div><span>Total companies</span><strong>{formatNumber(summary.total)}</strong></div>
        <div><span>Already known</span><strong>{formatNumber(summary.known)}</strong></div>
        <div><span>Net new</span><strong>{formatNumber(summary.new)}</strong></div>
        <div><span>Existing prospects</span><strong>{formatNumber(summary.existingProspects)}</strong></div>
      </div>
      <article className="panel">
        <div className="panel-head">
          <div>
            <h3>Coverage results</h3>
            {/* COVERAGE-AC-03: the button says what leaves in the file. */}
            <p>{formatNumber(summary.covered)} of the known companies already contain prospects. The export holds the {formatNumber(summary.new)} net-new companies only — nothing already in the database is included.</p>
          </div>
          <button onClick={exportNewCompanies} disabled={!summary.new}>
            <AppIcon name="download" size={14}/>{summary.new ? `Export ${formatNumber(summary.new)} net-new companies` : "No net-new companies to export"}
          </button>
        </div>
        <div className="table-wrap coverage-table"><table>
          <thead><tr><th>Company</th><th>Domain</th><th>Status</th><th>Matched by</th><th>Prospects</th><th>Clients</th></tr></thead>
          <tbody>{rows.map((row) => <tr key={`${row.row}-${row.domain}-${row.name}`}>
            <td><strong>{row.name || row.matchedCompany || "Unnamed"}</strong></td>
            <td>{row.domain || "-"}</td>
            <td><span className={`coverage-status ${row.status}`}>{row.status === "known" ? "Known" : "Net new"}</span></td>
            <td>{row.matchedBy || "-"}</td>
            <td>{formatNumber(row.prospectCount)}</td>
            <td>{formatNumber(row.clientCount)}</td>
          </tr>)}</tbody>
        </table></div>
      </article>
    </div> : null}
  </section>;
}
