"use client";

import { ChangeEvent, useEffect, useState } from "react";
import { mapProspect } from "../../db/normalize";
import { commonDataSources } from "../../lib/data-source";
import { api } from "../../lib/dashboard-api";
import { deriveListName, formatNumber, readImportTable } from "../../lib/dashboard-helpers";
import { companyImportFields, missingCompanyImportFields, missingRequiredFields, requiredPersonImportFields, resolvedImportFields, skipImportField, suggestedCompanyImportField, suggestedPersonImportField } from "../../lib/import-schema";
import { importHeadersMatch } from "../../lib/import-resume";
import { canonicalImportFields } from "../../lib/prospect-field-definitions";
import type { ClientRecord, FileAudit, ImportResumeDetail, InterruptedImport } from "../../lib/types";

function ImportMappingPanel({ audit, fieldMap, onChange }: { audit: FileAudit; fieldMap: Record<string, string>; onChange: (header: string, value: string) => void }) {
  return <div className="import-mapping"><div className="mapping-head"><div><strong>Field mapping</strong><small>Review how CSV columns map to master fields</small></div><span>{audit.invalidRows ? `${audit.invalidRows} rows need identity data` : "All rows identifiable"}</span></div><div className="mapping-list">{audit.headers.map((header) => <label key={header}><span title={header}>{header}</span><b>→</b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Auto detect"} onChange={(event) => onChange(header, event.target.value)}>{canonicalImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div><p>Original headers and values are preserved when mapped or auto-detected. Set a column to “{skipImportField}” to drop it entirely — it won’t be stored or added to the field catalog.</p></div>;
}
export default function ImportsPanel({ clients, onComplete, onChanged }: { clients: ClientRecord[]; onComplete: () => Promise<void>; onChanged: () => Promise<void> }) {
  const [kind, setKind] = useState<"prospects" | "companies">("prospects");
  const [sourceChoice, setSourceChoice] = useState("");
  const [customSource, setCustomSource] = useState("");
  const [interruptedImports, setInterruptedImports] = useState<InterruptedImport[]>([]);
  const [resumeImport, setResumeImport] = useState<InterruptedImport | null>(null);
  const [cancelImport, setCancelImport] = useState<InterruptedImport | null>(null);
  const [cancelBusy, setCancelBusy] = useState(false);
  const [cancelError, setCancelError] = useState("");
  const dataSource = sourceChoice === "Other" ? customSource.trim() : sourceChoice;
  const activeDataSource = resumeImport?.dataSource ?? dataSource;
  useEffect(() => {
    let active = true;
    void api<{ imports: InterruptedImport[] }>("/api/imports")
      .then((result) => { if (active) setInterruptedImports(result.imports); })
      .catch(() => { if (active) setInterruptedImports([]); });
    return () => { active = false; };
  }, []);
  const chooseResume = (item: InterruptedImport) => { setKind(item.kind); setResumeImport(item); };
  const finishResume = (id: string) => {
    setInterruptedImports((current) => current.filter((item) => item.id !== id));
    setResumeImport(null);
  };
  async function confirmCancelImport() {
    if (!cancelImport) return;
    setCancelBusy(true); setCancelError("");
    try {
      await api(`/api/imports/${encodeURIComponent(cancelImport.id)}`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ cancel: true, kind: cancelImport.kind }) });
      setInterruptedImports((current) => current.filter((item) => item.id !== cancelImport.id));
      if (resumeImport?.id === cancelImport.id) setResumeImport(null);
      setCancelImport(null);
      void onChanged().catch(() => undefined);
    } catch (caught) { setCancelError(caught instanceof Error ? caught.message : "Unable to cancel this import."); }
    finally { setCancelBusy(false); }
  }
  return <section className="import-workspace">
    {interruptedImports.length ? <div className="interrupted-imports panel"><div><p className="eyebrow">INTERRUPTED IMPORTS</p><h3>Continue an unfinished import</h3><p>Re-select the original file; committed rows will not be imported twice.</p></div>{interruptedImports.map((item) => <div className="interrupted-import" key={item.id}><div><strong>{item.fileName}</strong><small>Interrupted — resume from row {formatNumber(item.resumeFromRow)} of {formatNumber(item.totalRows)}</small></div><span className="interrupted-import-actions"><button className="secondary" onClick={() => chooseResume(item)}>Resume</button><button className="interrupted-cancel" onClick={() => { setCancelError(""); setCancelImport(item); }}>Cancel import</button></span></div>)}</div> : null}
    <div className="import-setup panel">
      <div><p className="eyebrow">IMPORT SETUP</p><h2>What are you importing?</h2><p>Every import must have a data source so its lineage remains auditable.</p></div>
      <div className="import-kind-switch" role="tablist" aria-label="Import type"><button role="tab" aria-selected={kind === "prospects"} className={kind === "prospects" ? "active" : ""} onClick={() => { setKind("prospects"); setResumeImport(null); }}>People / prospects</button><button role="tab" aria-selected={kind === "companies"} className={kind === "companies" ? "active" : ""} onClick={() => { setKind("companies"); setResumeImport(null); }}>Companies</button></div>
      <div className="import-source-fields"><label><span>Data source <b>*</b></span><select aria-label="Data source" value={sourceChoice} onChange={(event) => setSourceChoice(event.target.value)}><option value="">Choose source</option>{commonDataSources.map((source) => <option key={source}>{source}</option>)}<option>Other</option></select></label>{sourceChoice === "Other" ? <label><span>Custom source <b>*</b></span><input value={customSource} maxLength={80} onChange={(event) => setCustomSource(event.target.value)} placeholder="Enter the source name"/></label> : null}</div>
      {!activeDataSource ? <p className="source-required-note">A data source is required before the import can start.</p> : <p className="source-selected-note">Source: <strong>{activeDataSource}</strong></p>}
    </div>
    {kind === "prospects"
      ? <ProspectImportView key="prospects" clients={clients} dataSource={activeDataSource} resumeImport={resumeImport?.kind === "prospects" ? resumeImport : null} onCancelResume={() => setResumeImport(null)} onResumed={finishResume} onComplete={onComplete}/>
      : <CompanyImportView key="companies" dataSource={activeDataSource} resumeImport={resumeImport?.kind === "companies" ? resumeImport : null} onCancelResume={() => setResumeImport(null)} onResumed={finishResume} onComplete={onComplete}/>}
    {cancelImport ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="cancel-import-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="cancel-import-title">Cancel unfinished import?</h2><p>The unfinished session and any client-list links it created will be removed. Records already added to the People or Company database stay in place.</p><div className="delete-target"><strong>{cancelImport.fileName}</strong><span>{formatNumber(cancelImport.committedRowOffset)} of {formatNumber(cancelImport.totalRows)} rows committed</span></div>{cancelError ? <p className="form-error" role="alert">{cancelError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={cancelBusy} onClick={() => setCancelImport(null)}>Keep import</button><button className="danger-button solid" disabled={cancelBusy} onClick={() => void confirmCancelImport()}>{cancelBusy ? "Cancelling…" : "Cancel import"}</button></div></section></div> : null}
  </section>;
}

function RequiredFieldList({ title, fields }: { title: string; fields: readonly string[] }) {
  return <div className="required-field-list"><strong>{title}</strong><div>{fields.map((field) => <span key={field}>✓ {field}</span>)}</div></div>;
}

function CompanyImportView({ dataSource, onComplete, resumeImport, onCancelResume, onResumed }: { dataSource: string; onComplete: () => Promise<void>; resumeImport: InterruptedImport | null; onCancelResume: () => void; onResumed: (id: string) => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [parsed, setParsed] = useState<{ headers: string[]; rows: string[][] } | null>(null);
  const [fieldMap, setFieldMap] = useState<Record<string, string>>({});
  const [phase, setPhase] = useState<"idle" | "uploading" | "done">("idle");
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState("");
  const [summary, setSummary] = useState<{ processed_rows: number; added_count: number; updated_count: number; skipped_count: number } | null>(null);
  const mappedFields = parsed ? resolvedImportFields(parsed.headers, fieldMap, suggestedCompanyImportField) : [];
  const missingFields = missingCompanyImportFields(mappedFields);
  const canSubmit = Boolean(file && parsed?.rows.length && dataSource && !missingFields.length && phase === "idle");

  async function pickCompanyFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setParsed(null); setFieldMap({}); setMessage(""); setSummary(null); setProgress(0);
    if (!next) return;
    try {
      const nextParsed = await readImportTable(next);
      setFieldMap(Object.fromEntries(nextParsed.headers.map((header) => [header, suggestedCompanyImportField(header)])));
      setParsed(nextParsed);
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Unable to read this company CSV."); }
  }

  async function uploadCompanyRows(importId: string, table: { headers: string[]; rows: string[][] }, savedFieldMap: Record<string, string>, rowOffset: number) {
    const columnFor = (field: string) => table.headers.findIndex((header) => savedFieldMap[header] === field);
    const valueFor = (row: string[], field: string) => { const column = columnFor(field); return column >= 0 ? String(row[column] ?? "").trim() : ""; };
    const chunkSize = 100;
    setPhase("uploading");
    setProgress(Math.round((rowOffset / table.rows.length) * 100));
    setMessage(rowOffset ? `Resuming company import from row ${formatNumber(rowOffset + 1)}…` : "Importing companies into the master Company DB…");
    for (let index = rowOffset; index < table.rows.length; index += chunkSize) {
      const rows = table.rows.slice(index, index + chunkSize).map((row, chunkIndex) => ({
        name: valueFor(row, "Company Name"),
        website: valueFor(row, "Website"),
        employeeCount: valueFor(row, "#employees"),
        industry: valueFor(row, "Industry"),
        city: valueFor(row, "Company City"),
        state: valueFor(row, "Company State"),
        country: valueFor(row, "Company Country"),
        keywords: valueFor(row, "Keywords"),
        shortDescription: valueFor(row, "Short Description"),
        foundedYear: valueFor(row, "Founded Year"),
        technologies: valueFor(row, "Technologies"),
        totalFunding: valueFor(row, "Total Funding"),
        raw: Object.fromEntries(table.headers.map((header, column) => [header, String(row[column] ?? "").trim()]).filter(([header]) => savedFieldMap[header] !== skipImportField)),
        sourceRowNumber: index + chunkIndex + 2,
      }));
      await api("/api/company-imports/chunk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId, rows, rowOffset: index }) });
      setProgress(Math.round(((index + rows.length) / table.rows.length) * 100));
    }
    const completed = await api<{ summary: { processed_rows: number; added_count: number; updated_count: number; skipped_count: number } }>("/api/company-imports/complete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId }) });
    setSummary(completed.summary); setPhase("done"); setMessage("Company import complete. Names and websites are now available in the Company DB.");
  }

  async function startCompanyImport() {
    if (!file || !parsed || !canSubmit) return;
    try {
      const started = await api<{ importId: string }>("/api/company-imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fileName: file.name, totalRows: parsed.rows.length, dataSource, headers: parsed.headers, fieldMap }) });
      await uploadCompanyRows(started.importId, parsed, fieldMap, 0);
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Company import failed."); setPhase("idle"); }
  }

  async function resumeCompanyFile(event: ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0];
    if (!selected || !resumeImport) return;
    try {
      setPhase("uploading"); setMessage(`Validating ${selected.name} before resuming…`);
      const [detail, table] = await Promise.all([
        api<ImportResumeDetail>(`/api/imports/${encodeURIComponent(resumeImport.id)}`),
        readImportTable(selected),
      ]);
      if (!detail.headerSignature || !importHeadersMatch(table.headers, detail.headerSignature)) throw new Error("The selected file headers do not match the interrupted import. Re-select the original file or start a new import instead.");
      if (detail.totalRows !== table.rows.length) throw new Error(`The selected file has ${formatNumber(table.rows.length)} rows; the interrupted import expected ${formatNumber(detail.totalRows)}. Re-select the same file or start a new import instead.`);
      setFile(selected); setParsed(table); setFieldMap(detail.fieldMap);
      await uploadCompanyRows(detail.id, table, detail.fieldMap, detail.committedRowOffset);
      onResumed(detail.id);
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Unable to resume the company import."); setPhase("idle"); }
  }

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark">✓</span><p className="eyebrow">COMPANY IMPORT COMPLETE</p><h2>Your Company DB is updated.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(summary.added_count)}</strong><span>Companies added</span></div><div><strong>{formatNumber(summary.updated_count)}</strong><span>Companies matched</span></div><div><strong>{formatNumber(summary.skipped_count)}</strong><span>Rows skipped</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  if (resumeImport) return <div className="resume-import-card panel"><p className="eyebrow">RESUME COMPANY IMPORT</p><h3>{resumeImport.fileName}</h3><p>Interrupted — resume from row {formatNumber(resumeImport.resumeFromRow)} of {formatNumber(resumeImport.totalRows)}.</p><label className="dropzone"><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" disabled={phase !== "idle"} onChange={(event) => void resumeCompanyFile(event)}/><span className="upload-mark">↑</span><strong>Re-select the same file</strong><small>Its headers and row count will be verified before upload resumes.</small></label>{phase === "uploading" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}{message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}<button className="secondary" disabled={phase !== "idle"} onClick={onCancelResume}>Start a new import instead</button></div>;

  return <div className="import-layout company-import-layout"><div className="import-copy"><p className="eyebrow">COMPANY CSV IMPORT</p><h2>Import a complete company dataset.</h2><p>Map a company name or a website (either works), plus the company detail columns. Companies are matched by normalized website first and company name second.</p><RequiredFieldList title="Company columns" fields={companyImportFields}/></div><div className="import-card"><label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={(event) => void pickCompanyFile(event)}/><span className="upload-mark">↑</span>{file ? <><strong>{file.name}</strong><small>{formatNumber(parsed?.rows.length)} company rows ready</small></> : <><strong>Choose a company CSV or Excel file</strong><small>A company name or website is required</small></>}</label>{parsed ? <><div className="mapping-list company-required-mapping">{parsed.headers.map((header) => <label key={header}><span title={header}>{header}</span><b>→</b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Not mapped"} onChange={(event) => setFieldMap((current) => ({ ...current, [header]: event.target.value }))}><option>Not mapped</option><option>{skipImportField}</option>{companyImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div><p className={missingFields.length ? "form-error" : "source-selected-note"}>{missingFields.length ? `Map required columns: ${missingFields.join(", ")}.` : "All required company columns are mapped."}</p></> : null}{phase === "uploading" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}{message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}<button className="primary import-button" disabled={!canSubmit} onClick={() => void startCompanyImport()}>{phase === "uploading" ? "Processing…" : "Import companies"}</button></div></div>;
}

function ProspectImportView({ clients, onComplete, dataSource, resumeImport, onCancelResume, onResumed }: { clients: ClientRecord[]; onComplete: () => Promise<void>; dataSource: string; resumeImport: InterruptedImport | null; onCancelResume: () => void; onResumed: (id: string) => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [clientId, setClientId] = useState("");
  const [newClient, setNewClient] = useState("");
  const [listName, setListName] = useState("");
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState<"idle" | "reading" | "uploading" | "done">("idle");
  const [message, setMessage] = useState("");
  const [summary, setSummary] = useState<{ processed_rows: number; unique_added: number; duplicates_linked: number } | null>(null);
  const [fileAudit, setFileAudit] = useState<FileAudit | null>(null);
  const [fieldMap, setFieldMap] = useState<Record<string, string>>({});
  const [allowMissing, setAllowMissing] = useState(false);
  const mappedFields = fileAudit ? resolvedImportFields(fileAudit.headers, fieldMap, suggestedPersonImportField) : [];
  const missingFields = missingRequiredFields(requiredPersonImportFields, mappedFields);
  const canSubmit = file && fileAudit && dataSource && listName.trim() && (clientId || newClient.trim()) && (!missingFields.length || allowMissing) && phase === "idle";

  async function pickFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setFileAudit(null); setFieldMap({}); setMessage(""); setAllowMissing(false);
    if (next) setListName(deriveListName(next.name));
    if (!next) return;
    try {
      const parsed = await readImportTable(next);
      const populatedCells = parsed.rows.reduce((count, row) => count + row.filter((value) => value.trim()).length, 0);
      const nextFieldMap = Object.fromEntries(parsed.headers.map((header) => [header, suggestedPersonImportField(header)]));
      const mappedHeaders = parsed.headers.map((header) => nextFieldMap[header] === "Auto detect" ? header : nextFieldMap[header]);
      const invalidRows = parsed.rows.filter((row) => mapProspect(mappedHeaders, row).identifiers.length === 0).length;
      setFieldMap(nextFieldMap);
      setFileAudit({ headers: parsed.headers, rows: parsed.rows.length, populatedCells, invalidRows });
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : "Unable to read this CSV.");
    }
  }

  async function uploadProspectRows(table: { headers: string[]; rows: string[][] }, session: { importId: string; listId: string }, keptColumns: Array<{ header: string; column: number }>, keptHeaders: string[], resolvedFieldMap: Record<string, string>, rowOffset: number) {
    setPhase("uploading");
    setProgress(Math.round((rowOffset / table.rows.length) * 100));
    setMessage(rowOffset ? `Resuming from row ${formatNumber(rowOffset + 1)}…` : `Synchronizing ${formatNumber(table.rows.length)} rows with the people database…`);
    const chunkSize = 100;
    for (let index = rowOffset; index < table.rows.length; index += chunkSize) {
      const chunk = table.rows.slice(index, index + chunkSize).map((row) => keptColumns.map(({ column }) => row[column] ?? ""));
      await api("/api/imports/chunk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ importId: session.importId, listId: session.listId, headers: keptHeaders, rows: chunk, rowOffset: index, fieldMap: resolvedFieldMap }) });
      setProgress(Math.round(((index + chunk.length) / table.rows.length) * 100));
    }
    const completed = await api<{ summary: { processed_rows: number; unique_added: number; duplicates_linked: number } }>("/api/imports/complete", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(session) });
    setSummary(completed.summary); setPhase("done"); setMessage("Import complete. Your list is ready and the people database is up to date.");
  }

  async function startImport() {
    if (!file || !canSubmit) return;
    try {
      setPhase("reading"); setMessage("Reading CSV and checking the columns…");
      const parsed = await readImportTable(file);
      if (!parsed.headers.length || !parsed.rows.length) throw new Error("The CSV needs a header row and at least one data row.");
      // Columns set to "Skip column" are dropped here so they never reach the DB —
      // not stored in raw all_data, not registered in the field catalog.
      const keptColumns = parsed.headers.map((header, column) => ({ header, column })).filter(({ header }) => fieldMap[header] !== skipImportField);
      const keptHeaders = keptColumns.map(({ header }) => header);
      const resolvedFieldMap = Object.fromEntries(Object.entries(fieldMap).filter(([header, value]) => value && value !== "Auto detect" && value !== skipImportField && keptHeaders.includes(header)));
      const started = await api<{ importId: string; listId: string }>("/api/imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ clientId: clientId || undefined, clientName: newClient || undefined, listName, dataSource, fileName: file.name, totalRows: parsed.rows.length, headers: keptHeaders, sourceHeaders: parsed.headers, fieldMap, allowMissingFields: allowMissing }) });
      await uploadProspectRows(parsed, started, keptColumns, keptHeaders, resolvedFieldMap, 0);
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Import failed."); setPhase("idle"); }
  }

  async function resumeProspectFile(event: ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0];
    if (!selected || !resumeImport) return;
    try {
      setPhase("reading"); setMessage(`Validating ${selected.name} before resuming…`);
      const [detail, table] = await Promise.all([
        api<ImportResumeDetail>(`/api/imports/${encodeURIComponent(resumeImport.id)}`),
        readImportTable(selected),
      ]);
      if (!detail.headerSignature || !importHeadersMatch(table.headers, detail.headerSignature)) throw new Error("The selected file headers do not match the interrupted import. Re-select the original file or start a new import instead.");
      if (detail.totalRows !== table.rows.length) throw new Error(`The selected file has ${formatNumber(table.rows.length)} rows; the interrupted import expected ${formatNumber(detail.totalRows)}. Re-select the same file or start a new import instead.`);
      if (!detail.listId) throw new Error("The interrupted import no longer has a destination list.");
      const keptColumns = table.headers.map((header, column) => ({ header, column })).filter(({ header }) => detail.fieldMap[header] !== skipImportField);
      const keptHeaders = keptColumns.map(({ header }) => header);
      if (JSON.stringify(keptHeaders) !== JSON.stringify(detail.headers)) throw new Error("The selected file headers do not match the interrupted import. Re-select the original file or start a new import instead.");
      const resolvedFieldMap = Object.fromEntries(Object.entries(detail.fieldMap).filter(([header, value]) => value && value !== "Auto detect" && value !== skipImportField && keptHeaders.includes(header)));
      const populatedCells = table.rows.reduce((count, row) => count + row.filter((value) => value.trim()).length, 0);
      setFile(selected); setFieldMap(detail.fieldMap); setFileAudit({ headers: table.headers, rows: table.rows.length, populatedCells, invalidRows: 0 });
      await uploadProspectRows(table, { importId: detail.id, listId: detail.listId }, keptColumns, keptHeaders, resolvedFieldMap, detail.committedRowOffset);
      onResumed(detail.id);
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Unable to resume the import."); setPhase("idle"); }
  }

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark">✓</span><p className="eyebrow">IMPORT COMPLETE</p><h2>Your list is ready.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(fileAudit?.headers.length)}</strong><span>Fields preserved</span></div><div><strong>{formatNumber(summary.unique_added)}</strong><span>Added to master</span></div><div><strong>{formatNumber(summary.duplicates_linked)}</strong><span>Existing prospects linked</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  if (resumeImport) return <div className="resume-import-card panel"><p className="eyebrow">RESUME PROSPECT IMPORT</p><h3>{resumeImport.fileName}</h3><p>Interrupted — resume from row {formatNumber(resumeImport.resumeFromRow)} of {formatNumber(resumeImport.totalRows)}.</p><label className="dropzone"><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" disabled={phase !== "idle"} onChange={(event) => void resumeProspectFile(event)}/><span className="upload-mark">↑</span><strong>Re-select the same file</strong><small>Its headers and row count will be verified before upload resumes.</small></label>{phase !== "idle" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}{message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}<button className="secondary" disabled={phase !== "idle"} onClick={onCancelResume}>Start a new import instead</button></div>;

  return <div className="import-layout">
    <div className="import-copy"><p className="eyebrow">CSV IMPORT</p><h2>Bring every list into one clean database.</h2><p>Preview the file, confirm field mapping, choose the client, and synchronize it safely with your people database.</p><RequiredFieldList title="Required person columns" fields={requiredPersonImportFields}/><ol><li><span>1</span><div><strong>Validate before import</strong><p>Review fields, row counts and records without usable identity data.</p></div></li><li><span>2</span><div><strong>Control field mapping</strong><p>Map unusual CSV headers without losing the original source fields.</p></div></li><li><span>3</span><div><strong>Sync with rollback</strong><p>Existing prospects are linked, new records are added once, and imports can be undone.</p></div></li></ol></div>
    <div className="import-card">
      <div className="form-field"><label htmlFor="import-client">Client</label><select id="import-client" value={clientId} onChange={(event) => { setClientId(event.target.value); if (event.target.value) setNewClient(""); }}><option value="">Create a new client</option>{clients.map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select></div>
      {!clientId && <div className="form-field"><label htmlFor="new-client-name">New client name</label><input id="new-client-name" value={newClient} onChange={(event) => setNewClient(event.target.value)} placeholder="e.g. Acme Recruitment" /></div>}
      <label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={(event) => void pickFile(event)}/><span className="upload-mark">↑</span>{file ? <><strong>{file.name}</strong><small>{(file.size / 1024 / 1024).toFixed(2)} MB · Ready to review</small></> : <><strong>Choose a CSV or Excel file</strong><small>CSV or .xlsx from Excel / Google Sheets</small></>}</label>
      <div className="form-field"><label htmlFor="list-name">List name</label><input id="list-name" value={listName} onChange={(event) => setListName(event.target.value)} placeholder="Auto-filled from the CSV filename" /></div>
      {fileAudit && <><div className="file-audit"><div><span className="audit-check">✓</span><p><strong>{formatNumber(fileAudit.headers.length)} fields detected</strong><small>{formatNumber(fileAudit.rows)} rows · {formatNumber(fileAudit.populatedCells)} populated cells</small></p></div><div className="audit-fields">{fileAudit.headers.slice(0, 8).map((header) => <span key={header}>{header}</span>)}{fileAudit.headers.length > 8 && <span>+{fileAudit.headers.length - 8} more</span>}</div><p>{fileAudit.invalidRows ? `${fileAudit.invalidRows} rows have no email, LinkedIn, or name plus company and will be preserved without a People DB link.` : "Every row has enough identity data (email, LinkedIn, or name plus company) to match the People DB."}</p></div><ImportMappingPanel audit={fileAudit} fieldMap={fieldMap} onChange={(header, value) => setFieldMap((current) => ({ ...current, [header]: value }))}/><p className={missingFields.length ? "form-error" : "source-selected-note"}>{missingFields.length ? `Missing mandatory columns: ${missingFields.join(", ")}.` : "All required person columns are mapped."}</p>{missingFields.length ? <div className="cleanup-choice import-override"><input id="import-allow-missing" type="checkbox" checked={allowMissing} onChange={(event) => setAllowMissing(event.target.checked)} /><label htmlFor="import-allow-missing"><strong>Import anyway without all mandatory fields</strong><small>Rows import with whatever identity they have; those missing name/company and email/LinkedIn are preserved without a People DB link.</small></label></div> : null}</>}
      {phase !== "idle" && <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div>}
      {message && phase === "idle" && <p className="form-error" role="alert">{message}</p>}
      <button className="primary import-button" disabled={!canSubmit} onClick={startImport}>{phase === "idle" ? "Start import & sync" : "Processing…"}</button><p className="privacy-note">Original rows and fields remain stored in your private database.</p>
    </div>
  </div>;
}
