"use client";

import { ChangeEvent, useEffect, useState } from "react";
import { mapProspect } from "../../db/normalize";
import { companyMergeModeLabels, companyMergeModes, defaultCompanyMergeMode, type CompanyMergeMode } from "../../lib/company-merge-mode";
import { commonDataSources } from "../../lib/data-source";
import { api } from "../../lib/dashboard-api";
import { deriveListName, formatNumber, readCsvPreview, readImportTable } from "../../lib/dashboard-helpers";
import { companyImportFields, missingCompanyImportFields, missingRequiredFields, requiredPersonImportFields, resolvedImportFields, skipImportField, suggestedCompanyImportField, suggestedPersonImportField, unmappedCompanyDetailFields } from "../../lib/import-schema";
import { parsePastedCompanyTable } from "../../lib/paste-table";
import { importHeadersMatch } from "../../lib/import-resume";
import { unassignedClientId } from "../../lib/import-owner";
import { canonicalImportFields } from "../../lib/prospect-field-definitions";
import { prospectUploadFingerprint, uploadProspectCsv } from "../../lib/resumable-upload.ts";
import type { BackgroundImport, ClientRecord, FileAudit, ImportResumeDetail, InterruptedImport } from "../../lib/types";
import { AppIcon } from "./DashboardUi";

function localIsoDate() {
  const now = new Date();
  return new Date(now.getTime() - now.getTimezoneOffset() * 60_000).toISOString().slice(0, 10);
}

function ImportMappingPanel({ audit, fieldMap, onChange }: { audit: FileAudit; fieldMap: Record<string, string>; onChange: (header: string, value: string) => void }) {
  return <div className="import-mapping"><div className="mapping-head"><div><strong>Field mapping</strong><small>Review how CSV columns map to master fields</small></div><span>{audit.invalidRows ? `${audit.invalidRows} rows need identity data` : "All rows identifiable"}</span></div><div className="mapping-list">{audit.headers.map((header) => <label key={header}><span title={header}>{header}</span><b><AppIcon name="arrow" size={14}/></b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Auto detect"} onChange={(event) => onChange(header, event.target.value)}>{canonicalImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div><p>Original headers and values are preserved when mapped or auto-detected. Set a column to “{skipImportField}” to drop it entirely - it won’t be stored or added to the field catalog.</p></div>;
}
export default function ImportsPanel({ clients, onComplete, onChanged }: { clients: ClientRecord[]; onComplete: () => Promise<void>; onChanged: () => Promise<void> }) {
  const [kind, setKind] = useState<"prospects" | "companies">("prospects");
  const [sourceChoice, setSourceChoice] = useState("");
  const [customSource, setCustomSource] = useState("");
  const [interruptedImports, setInterruptedImports] = useState<InterruptedImport[]>([]);
  const [backgroundImports, setBackgroundImports] = useState<BackgroundImport[]>([]);
  const [resumeImport, setResumeImport] = useState<InterruptedImport | null>(null);
  const [cancelImport, setCancelImport] = useState<InterruptedImport | null>(null);
  const [cancelBusy, setCancelBusy] = useState(false);
  const [cancelError, setCancelError] = useState("");
  const [activeImportId, setActiveImportId] = useState("");
  const dataSource = sourceChoice === "Other" ? customSource.trim() : sourceChoice;
  const activeDataSource = resumeImport?.dataSource ?? dataSource;
  const visibleInterruptedImports = interruptedImports.filter((item) => item.id !== activeImportId);
  useEffect(() => {
    let active = true;
    const load = () => void api<{ imports: InterruptedImport[]; backgroundImports?: BackgroundImport[] }>("/api/imports", { cache: "no-store" })
      .then((result) => { if (active) { setInterruptedImports(result.imports); setBackgroundImports(result.backgroundImports ?? []); } })
      .catch(() => { if (active) { setInterruptedImports([]); setBackgroundImports([]); } });
    load();
    const timer = window.setInterval(load, 5000);
    return () => { active = false; window.clearInterval(timer); };
  }, []);
  const chooseResume = (item: InterruptedImport) => { setKind(item.kind); setResumeImport(item); };
  const finishResume = (id: string) => {
    setInterruptedImports((current) => current.filter((item) => item.id !== id));
    setResumeImport(null);
  };
  async function retryBackgroundImport(id: string) {
    try {
      await api(`/api/imports/${encodeURIComponent(id)}`, { method: "PATCH" });
      setBackgroundImports((current) => current.map((item) => item.id === id ? { ...item, status: "queued", lastError: "" } : item));
    } catch (caught) {
      setBackgroundImports((current) => current.map((item) => item.id === id ? { ...item, lastError: caught instanceof Error ? caught.message : "Unable to retry." } : item));
    }
  }
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
    {backgroundImports.length ? <div className="interrupted-imports panel"><div><p className="eyebrow">BACKGROUND IMPORTS</p><h3>Server-side processing</h3><p>These jobs continue even when this browser is closed.</p></div>{backgroundImports.map((item) => <div className="interrupted-import" key={item.id}><div><strong>{item.fileName}</strong><small>{item.status === "failed" ? `Failed after automatic retries - ${item.lastError}` : item.totalRows ? `${formatNumber(item.committedRowOffset)} of ${formatNumber(item.totalRows)} rows committed` : "Queued or validating the CSV"}</small></div><span className="interrupted-import-actions"><span>{item.status}</span>{item.status === "failed" ? <button className="secondary" onClick={() => void retryBackgroundImport(item.id)}>Retry</button> : null}</span></div>)}</div> : null}
    {visibleInterruptedImports.length ? <div className="interrupted-imports panel"><div><p className="eyebrow">INTERRUPTED IMPORTS</p><h3>Continue an unfinished import</h3><p>Re-select the original file; committed rows will not be imported twice.</p></div>{visibleInterruptedImports.map((item) => <div className="interrupted-import" key={item.id}><div><strong>{item.fileName}</strong><small>Interrupted - resume from row {formatNumber(item.resumeFromRow)} of {formatNumber(item.totalRows)}</small></div><span className="interrupted-import-actions"><button className="secondary" onClick={() => chooseResume(item)}>Resume</button><button className="interrupted-cancel" onClick={() => { setCancelError(""); setCancelImport(item); }}>Cancel import</button></span></div>)}</div> : null}
    <div className="import-setup panel">
      <div><p className="eyebrow">IMPORT SETUP</p><h2>What are you importing?</h2><p>Every import must have a data source so its lineage remains auditable.</p></div>
      <div className="import-kind-switch" role="tablist" aria-label="Import type"><button role="tab" aria-selected={kind === "prospects"} className={kind === "prospects" ? "active" : ""} onClick={() => { setKind("prospects"); setResumeImport(null); }}>People / prospects</button><button role="tab" aria-selected={kind === "companies"} className={kind === "companies" ? "active" : ""} onClick={() => { setKind("companies"); setResumeImport(null); }}>Companies</button></div>
      <div className="import-source-fields"><label><span>Data source <b>*</b></span><select aria-label="Data source" value={sourceChoice} onChange={(event) => setSourceChoice(event.target.value)}><option value="">Choose source</option>{commonDataSources.map((source) => <option key={source}>{source}</option>)}<option>Other</option></select></label>{sourceChoice === "Other" ? <label><span>Custom source <b>*</b></span><input value={customSource} maxLength={80} onChange={(event) => setCustomSource(event.target.value)} placeholder="Enter the source name"/></label> : null}</div>
      {!activeDataSource ? <p className="source-required-note">A data source is required before the import can start.</p> : <p className="source-selected-note">Source: <strong>{activeDataSource}</strong></p>}
    </div>
    {kind === "prospects"
      ? <ProspectImportView key="prospects" clients={clients} dataSource={activeDataSource} resumeImport={resumeImport?.kind === "prospects" ? resumeImport : null} onCancelResume={() => setResumeImport(null)} onResumed={finishResume} onComplete={onComplete}/>
      : <CompanyImportView key="companies" dataSource={activeDataSource} resumeImport={resumeImport?.kind === "companies" ? resumeImport : null} onCancelResume={() => setResumeImport(null)} onResumed={finishResume} onActiveImportChange={setActiveImportId} onComplete={onComplete}/>}
    {cancelImport ? <div className="modal-backdrop" role="presentation"><section className="confirm-modal" role="dialog" aria-modal="true" aria-labelledby="cancel-import-title"><span className="warning-mark">!</span><p className="eyebrow">PERMANENT ACTION</p><h2 id="cancel-import-title">Cancel unfinished import?</h2><p>The unfinished session and any client-list links it created will be removed. Records already added to the People or Company database stay in place.</p><div className="delete-target"><strong>{cancelImport.fileName}</strong><span>{formatNumber(cancelImport.committedRowOffset)} of {formatNumber(cancelImport.totalRows)} rows committed</span></div>{cancelError ? <p className="form-error" role="alert">{cancelError}</p> : null}<div className="modal-actions"><button className="secondary" disabled={cancelBusy} onClick={() => setCancelImport(null)}>Keep import</button><button className="danger-button solid" disabled={cancelBusy} onClick={() => void confirmCancelImport()}>{cancelBusy ? "Cancelling…" : "Cancel import"}</button></div></section></div> : null}
  </section>;
}

// A company row that matches one already in the database can be handled three ways.
// This is the single most consequential choice in a company upload -- "let this file
// win" rewrites stored values -- so it is a visible set of radios with the
// consequence spelled out, not a dropdown default nobody reads.
function MergeModeChooser({ mode, disabled, onChange }: { mode: CompanyMergeMode; disabled: boolean; onChange: (mode: CompanyMergeMode) => void }) {
  return <fieldset className="merge-mode-chooser">
    <legend>When a company is already in the database</legend>
    <p className="merge-mode-hint">Matched by website first, then by company name when either side has no website.</p>
    {companyMergeModes.map((option) => <label key={option} htmlFor={`company-merge-mode-${option}`} className={mode === option ? "active" : ""}>
      <input id={`company-merge-mode-${option}`} type="radio" name="company-merge-mode" value={option} checked={mode === option} disabled={disabled} onChange={() => onChange(option)}/>
      <strong>{companyMergeModeLabels[option].label}</strong>
      <small>{companyMergeModeLabels[option].description}</small>
    </label>)}
  </fieldset>;
}

function RequiredFieldList({ title, fields }: { title: string; fields: readonly string[] }) {
  return <div className="required-field-list"><strong>{title}</strong><div>{fields.map((field) => <span key={field}><AppIcon name="check" size={14}/> {field}</span>)}</div></div>;
}

function CompanyImportView({ dataSource, onComplete, resumeImport, onCancelResume, onResumed, onActiveImportChange }: { dataSource: string; onComplete: () => Promise<void>; resumeImport: InterruptedImport | null; onCancelResume: () => void; onResumed: (id: string) => void; onActiveImportChange: (id: string) => void }) {
  const [file, setFile] = useState<File | null>(null);
  // A paste has no File behind it, so the import needs a name of its own for the
  // audit trail. Everything downstream -- mapping, merge mode, chunked upload,
  // resume -- works off `parsed` and does not care which of the two produced it.
  const [inputMode, setInputMode] = useState<"file" | "paste">("file");
  const [pastedText, setPastedText] = useState("");
  const [pasteNotice, setPasteNotice] = useState("");
  const [parsed, setParsed] = useState<{ headers: string[]; rows: string[][] } | null>(null);
  const [fieldMap, setFieldMap] = useState<Record<string, string>>({});
  const [phase, setPhase] = useState<"idle" | "uploading" | "done">("idle");
  const [progress, setProgress] = useState(0);
  const [message, setMessage] = useState("");
  const [summary, setSummary] = useState<{ processed_rows: number; added_count: number; updated_count: number; skipped_count: number } | null>(null);
  // What to do when an uploaded row matches a company already in the Company DB.
  // A resumed import keeps whatever mode it started under -- see the note in the route.
  const [mergeMode, setMergeMode] = useState<CompanyMergeMode>(defaultCompanyMergeMode);
  const mappedFields = parsed ? resolvedImportFields(parsed.headers, fieldMap, suggestedCompanyImportField) : [];
  const missingFields = missingCompanyImportFields(mappedFields);
  const unmappedDetails = parsed ? unmappedCompanyDetailFields(mappedFields) : [];
  const sourceName = inputMode === "paste" ? `Pasted companies ${new Date().toISOString().slice(0, 10)}` : file?.name ?? "";
  const hasSource = inputMode === "paste" ? Boolean(pastedText.trim()) : Boolean(file);
  const canSubmit = Boolean(hasSource && parsed?.rows.length && dataSource && !missingFields.length && phase === "idle");

  function applyParsedTable(table: { headers: string[]; rows: string[][] }) {
    setFieldMap(Object.fromEntries(table.headers.map((header) => [header, suggestedCompanyImportField(header)])));
    setParsed(table);
  }

  async function pickCompanyFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setParsed(null); setFieldMap({}); setMessage(""); setSummary(null); setProgress(0);
    if (!next) return;
    try {
      applyParsedTable(await readImportTable(next));
    } catch (caught) { setMessage(caught instanceof Error ? caught.message : "Unable to read this company CSV."); }
  }

  function readPastedCompanies(text: string) {
    setPastedText(text); setMessage(""); setSummary(null); setProgress(0);
    if (!text.trim()) { setParsed(null); setFieldMap({}); setPasteNotice(""); return; }
    try {
      const table = parsePastedCompanyTable(text);
      applyParsedTable(table);
      setPasteNotice(table.inferredHeaders
        ? `No header row found - ${formatNumber(table.rows.length)} rows read and the columns named from their contents. Correct any of them below.`
        : `Header row detected - ${formatNumber(table.rows.length)} company rows read.`);
    } catch (caught) {
      setParsed(null); setFieldMap({}); setPasteNotice("");
      setMessage(caught instanceof Error ? caught.message : "Unable to read this paste.");
    }
  }

  function switchInputMode(next: "file" | "paste") {
    setInputMode(next);
    setParsed(null); setFieldMap({}); setMessage(""); setSummary(null); setProgress(0); setPasteNotice("");
    if (next === "paste") setFile(null); else setPastedText("");
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
        location: valueFor(row, "Company Location"),
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
    setSummary(completed.summary); setPhase("done");
    setMessage(`Company import complete. Companies already in the database were handled with “${companyMergeModeLabels[mergeMode].label}”.`);
  }

  async function startCompanyImport() {
    if (!parsed || !canSubmit) return;
    try {
      const started = await api<{ importId: string }>("/api/company-imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fileName: sourceName, totalRows: parsed.rows.length, dataSource, headers: parsed.headers, fieldMap, mergeMode }) });
      onActiveImportChange(started.importId);
      await uploadCompanyRows(started.importId, parsed, fieldMap, 0);
    } catch (caught) { onActiveImportChange(""); setMessage(caught instanceof Error ? caught.message : "Company import failed."); setPhase("idle"); }
  }

  // A paste is resumed by pasting the same block again, exactly as a file import is
  // resumed by re-selecting the same file: the header signature and the row count
  // have to match either way before a single further row is sent.
  async function resumeCompanyTable(label: string, read: () => Promise<{ headers: string[]; rows: string[][] }>) {
    if (!resumeImport) return;
    onActiveImportChange(resumeImport.id);
    try {
      setPhase("uploading"); setMessage(`Validating ${label} before resuming…`);
      const [detail, table] = await Promise.all([api<ImportResumeDetail>(`/api/imports/${encodeURIComponent(resumeImport.id)}`), read()]);
      if (!detail.headerSignature || !importHeadersMatch(table.headers, detail.headerSignature)) throw new Error("The headers do not match the interrupted import. Supply the original rows, or start a new import instead.");
      if (detail.totalRows !== table.rows.length) throw new Error(`This has ${formatNumber(table.rows.length)} rows; the interrupted import expected ${formatNumber(detail.totalRows)}. Supply the original rows, or start a new import instead.`);
      setParsed(table); setFieldMap(detail.fieldMap);
      if (detail.mergeMode) setMergeMode(detail.mergeMode);
      await uploadCompanyRows(detail.id, table, detail.fieldMap, detail.committedRowOffset);
      onResumed(detail.id);
    } catch (caught) { onActiveImportChange(""); setMessage(caught instanceof Error ? caught.message : "Unable to resume the company import."); setPhase("idle"); }
  }

  async function resumeCompanyFile(event: ChangeEvent<HTMLInputElement>) {
    const selected = event.target.files?.[0];
    if (!selected) return;
    setFile(selected);
    await resumeCompanyTable(selected.name, () => readImportTable(selected));
  }

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark"><AppIcon name="check" size={14}/></span><p className="eyebrow">COMPANY IMPORT COMPLETE</p><h2>Your Company DB is updated.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(summary.added_count)}</strong><span>Companies added</span></div><div><strong>{formatNumber(summary.updated_count)}</strong><span>Companies matched</span></div><div><strong>{formatNumber(summary.skipped_count)}</strong><span>Rows skipped</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  if (resumeImport) return <div className="resume-import-card panel"><p className="eyebrow">RESUME COMPANY IMPORT</p><h3>{resumeImport.fileName}</h3><p>Interrupted - resume from row {formatNumber(resumeImport.resumeFromRow)} of {formatNumber(resumeImport.totalRows)}.</p><label className="dropzone"><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" disabled={phase !== "idle"} onChange={(event) => void resumeCompanyFile(event)}/><span className="upload-mark"><AppIcon name="upload" size={14}/></span><strong>Re-select the same file</strong><small>Its headers and row count will be verified before upload resumes.</small></label><div className="resume-paste"><label><span>…or paste the same rows again</span><textarea aria-label="Paste the same company rows to resume" rows={4} disabled={phase !== "idle"} value={pastedText} onChange={(event) => setPastedText(event.target.value)} placeholder="Paste the original block to resume a pasted import"/></label><button className="secondary" disabled={phase !== "idle" || !pastedText.trim()} onClick={() => void resumeCompanyTable("the pasted rows", async () => parsePastedCompanyTable(pastedText))}>Resume from paste</button></div>{phase === "uploading" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}{message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}<button className="secondary" disabled={phase !== "idle"} onClick={onCancelResume}>Start a new import instead</button></div>;

  return <div className="import-layout company-import-layout">
    <div className="import-copy">
      <p className="eyebrow">COMPANY IMPORT</p>
      <h2>Import companies from a file or a paste.</h2>
      <p>A company name or a website is all that is required - either one identifies a company. Companies are matched by normalized website first and company name second, so a list of domains lands on the companies you already have rather than duplicating them.</p>
      <RequiredFieldList title="Company columns" fields={companyImportFields}/>
    </div>
    <div className="import-card">
      <div className="import-kind-switch import-input-switch" role="tablist" aria-label="How to supply the companies">
        <button role="tab" aria-selected={inputMode === "file"} className={inputMode === "file" ? "active" : ""} disabled={phase !== "idle"} onClick={() => switchInputMode("file")}>Upload a file</button>
        <button role="tab" aria-selected={inputMode === "paste"} className={inputMode === "paste" ? "active" : ""} disabled={phase !== "idle"} onClick={() => switchInputMode("paste")}>Paste rows</button>
      </div>
      {inputMode === "file"
        ? <label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={(event) => void pickCompanyFile(event)}/><span className="upload-mark"><AppIcon name="upload" size={14}/></span>{file ? <><strong>{file.name}</strong><small>{formatNumber(parsed?.rows.length)} company rows ready</small></> : <><strong>Choose a company CSV or Excel file</strong><small>A company name or website is required</small></>}</label>
        : <div className="paste-zone"><label><span>Paste companies</span><textarea aria-label="Paste company rows" rows={9} disabled={phase !== "idle"} value={pastedText} onChange={(event) => readPastedCompanies(event.target.value)} placeholder={"Acme Corp\tacme.com\nGlobex\tglobex.com\n\nOne company per line. Names only, websites only, or both - tabs, commas or semicolons between columns. A header row is used if there is one."}/></label>{pasteNotice ? <p className="source-selected-note" role="status">{pasteNotice}</p> : null}</div>}
      {parsed ? <>
        <div className="mapping-list company-required-mapping">{parsed.headers.map((header) => <label key={header}><span title={header}>{header}</span><b><AppIcon name="arrow" size={14}/></b><select aria-label={`Map ${header}`} value={fieldMap[header] || "Not mapped"} onChange={(event) => setFieldMap((current) => ({ ...current, [header]: event.target.value }))}><option>Not mapped</option><option>{skipImportField}</option>{companyImportFields.map((field) => <option key={field}>{field}</option>)}</select></label>)}</div>
        <p className={missingFields.length ? "form-error" : "source-selected-note"}>{missingFields.length ? `Map a ${missingFields.join(", ")} column - one of the two identifies the company.` : `${formatNumber(parsed.rows.length)} rows ready to import.`}</p>
        {!missingFields.length && unmappedDetails.length ? <p className="import-partial-note">Detail columns this import does not carry: {unmappedDetails.join(", ")}. They are left exactly as stored - no merge mode can blank out a value this import has nothing to say about.</p> : null}
        <MergeModeChooser mode={mergeMode} disabled={phase !== "idle"} onChange={setMergeMode}/>
      </> : null}
      {phase === "uploading" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}
      {message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}
      <button className="primary import-button" disabled={!canSubmit} onClick={() => void startCompanyImport()}>{phase === "uploading" ? "Processing…" : "Import companies"}</button>
    </div>
  </div>;
}

function ProspectImportView({ clients, onComplete, dataSource, resumeImport, onCancelResume, onResumed }: { clients: ClientRecord[]; onComplete: () => Promise<void>; dataSource: string; resumeImport: InterruptedImport | null; onCancelResume: () => void; onResumed: (id: string) => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [clientId, setClientId] = useState("");
  const [newClient, setNewClient] = useState("");
  const [listName, setListName] = useState("");
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState<"idle" | "reading" | "uploading" | "queued" | "done">("idle");
  const [message, setMessage] = useState("");
  const [summary, setSummary] = useState<{ processed_rows: number; unique_added: number; duplicates_linked: number } | null>(null);
  const [fileAudit, setFileAudit] = useState<FileAudit | null>(null);
  const [fieldMap, setFieldMap] = useState<Record<string, string>>({});
  const [allowMissing, setAllowMissing] = useState(false);
  const [activeBackgroundId, setActiveBackgroundId] = useState("");
  const [dateContacted, setDateContacted] = useState(localIsoDate);
  const [noDateContacted, setNoDateContacted] = useState(false);
  const mappedFields = fileAudit ? resolvedImportFields(fileAudit.headers, fieldMap, suggestedPersonImportField) : [];
  const missingFields = missingRequiredFields(requiredPersonImportFields, mappedFields);
  const canSubmit = file && fileAudit && dataSource && (noDateContacted || dateContacted) && listName.trim() && (clientId || newClient.trim()) && (!missingFields.length || allowMissing) && phase === "idle";

  useEffect(() => {
    if (!activeBackgroundId) return;
    let active = true;
    const poll = async () => {
      try {
        const detail = await api<ImportResumeDetail>(`/api/imports/${encodeURIComponent(activeBackgroundId)}`, { cache: "no-store" });
        if (!active) return;
        if (detail.status === "failed") {
          setActiveBackgroundId(""); setPhase("idle"); setMessage(detail.lastError || "Background import failed after automatic retries.");
          return;
        }
        if (detail.status === "completed") {
          setActiveBackgroundId("");
          setSummary({ processed_rows: detail.processedRows ?? 0, unique_added: detail.uniqueAdded ?? 0, duplicates_linked: detail.duplicatesLinked ?? 0 });
          setProgress(100); setPhase("done"); setMessage("Import complete. Your list is ready and the people database is up to date.");
          return;
        }
        const completedRows = detail.processedRows ?? detail.committedRowOffset;
        setMessage(detail.totalRows
          ? `Processing ${formatNumber(completedRows)} of ${formatNumber(detail.totalRows)} rows in the background. You can close this tab safely.`
          : "Inspecting the uploaded CSV before processing. You can close this tab safely.");
        if (detail.totalRows) setProgress(Math.round(completedRows / detail.totalRows * 100));
      } catch { /* The background panel remains the durable source of truth. */ }
    };
    void poll();
    const timer = window.setInterval(() => void poll(), 2000);
    return () => { active = false; window.clearInterval(timer); };
  }, [activeBackgroundId]);

  async function pickFile(event: ChangeEvent<HTMLInputElement>) {
    const next = event.target.files?.[0] ?? null;
    setFile(next); setFileAudit(null); setFieldMap({}); setMessage(""); setAllowMissing(false);
    if (next) setListName(deriveListName(next.name));
    if (!next) return;
    if (!/\.csv$/i.test(next.name)) {
      setFile(null); setMessage("Prospect imports require CSV so large files can be streamed safely. Export this spreadsheet as CSV and try again."); return;
    }
    try {
      const parsed = await readCsvPreview(next);
      const populatedCells = parsed.rows.reduce((count, row) => count + row.filter((value) => value.trim()).length, 0);
      const nextFieldMap = Object.fromEntries(parsed.headers.map((header) => [header, suggestedPersonImportField(header)]));
      const mappedHeaders = parsed.headers.map((header) => nextFieldMap[header] === "Auto detect" ? header : nextFieldMap[header]);
      const invalidRows = parsed.rows.filter((row) => mapProspect(mappedHeaders, row).identifiers.length === 0).length;
      setFieldMap(nextFieldMap);
      setFileAudit({ headers: parsed.headers, rows: parsed.rows.length, populatedCells, invalidRows, sampled: parsed.sampled });
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
      if (/\.csv$/i.test(file.name)) {
        setPhase("uploading"); setProgress(0); setMessage("Uploading the CSV safely - this can resume after a network interruption…");
        const fingerprint = await prospectUploadFingerprint(file);
        const upload = await api<{ objectPath: string; token?: string; alreadyUploaded?: boolean }>("/api/imports/upload-token", {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ fileName: file.name, fileSize: file.size, fingerprint }),
        });
        if (!upload.alreadyUploaded) {
          if (!upload.token) throw new Error("The server did not issue an upload token.");
          await uploadProspectCsv(file, upload.objectPath, upload.token, setProgress);
        } else setProgress(100);
        const sourceHeaders = fileAudit?.headers ?? [];
        const keptHeaders = sourceHeaders.filter((header) => fieldMap[header] !== skipImportField);
        const withoutClient = clientId === unassignedClientId;
        const started = await api<{ importId: string; listId: string }>("/api/imports/start", {
          method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({
            clientId: withoutClient ? undefined : clientId || undefined,
            clientName: newClient || undefined, withoutClient, listName, dataSource,
            fileName: file.name, headers: keptHeaders, sourceHeaders, fieldMap, dateContacted: noDateContacted ? null : dateContacted,
            allowMissingFields: allowMissing, background: true,
            storageObjectPath: upload.objectPath, fileSizeBytes: file.size,
          }),
        });
        setActiveBackgroundId(started.importId);
        setPhase("queued"); setProgress(0); setMessage("Upload complete. The server is processing this list in the background; you can close this tab safely.");
        return;
      }
      setPhase("reading"); setMessage("Reading CSV and checking the columns…");
      const parsed = await readImportTable(file);
      if (!parsed.headers.length || !parsed.rows.length) throw new Error("The CSV needs a header row and at least one data row.");
      // Columns set to "Skip column" are dropped here so they never reach the DB -
      // not stored in raw all_data, not registered in the field catalog.
      const keptColumns = parsed.headers.map((header, column) => ({ header, column })).filter(({ header }) => fieldMap[header] !== skipImportField);
      const keptHeaders = keptColumns.map(({ header }) => header);
      const resolvedFieldMap = Object.fromEntries(Object.entries(fieldMap).filter(([header, value]) => value && value !== "Auto detect" && value !== skipImportField && keptHeaders.includes(header)));
      const withoutClient = clientId === unassignedClientId;
      const started = await api<{ importId: string; listId: string }>("/api/imports/start", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ clientId: withoutClient ? undefined : clientId || undefined, clientName: newClient || undefined, withoutClient, listName, dataSource, dateContacted: noDateContacted ? null : dateContacted, fileName: file.name, totalRows: parsed.rows.length, headers: keptHeaders, sourceHeaders: parsed.headers, fieldMap, allowMissingFields: allowMissing }) });
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

  if (phase === "done" && summary) return <div className="import-success"><span className="success-mark"><AppIcon name="check" size={14}/></span><p className="eyebrow">IMPORT COMPLETE</p><h2>Your list is ready.</h2><p>{message}</p><div className="result-grid four"><div><strong>{formatNumber(summary.processed_rows)}</strong><span>Rows processed</span></div><div><strong>{formatNumber(fileAudit?.headers.length)}</strong><span>Fields preserved</span></div><div><strong>{formatNumber(summary.unique_added)}</strong><span>Added to master</span></div><div><strong>{formatNumber(summary.duplicates_linked)}</strong><span>Existing prospects linked</span></div></div><button className="primary" onClick={onComplete}>Go to dashboard</button></div>;

  if (resumeImport) return <div className="resume-import-card panel"><p className="eyebrow">RESUME PROSPECT IMPORT</p><h3>{resumeImport.fileName}</h3><p>Interrupted - resume from row {formatNumber(resumeImport.resumeFromRow)} of {formatNumber(resumeImport.totalRows)}.</p><label className="dropzone"><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" disabled={phase !== "idle"} onChange={(event) => void resumeProspectFile(event)}/><span className="upload-mark"><AppIcon name="upload" size={14}/></span><strong>Re-select the same file</strong><small>Its headers and row count will be verified before upload resumes.</small></label>{phase !== "idle" ? <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div> : null}{message && phase === "idle" ? <p className="form-error" role="alert">{message}</p> : null}<button className="secondary" disabled={phase !== "idle"} onClick={onCancelResume}>Start a new import instead</button></div>;

  return <div className="import-layout">
    <div className="import-copy"><p className="eyebrow">CSV IMPORT</p><h2>Bring every list into one clean database.</h2><p>Preview the file, confirm field mapping, choose the client, and synchronize it safely with your people database.</p><RequiredFieldList title="Required person columns" fields={requiredPersonImportFields}/><ol><li><span>1</span><div><strong>Validate before import</strong><p>Review fields, row counts and records without usable identity data.</p></div></li><li><span>2</span><div><strong>Control field mapping</strong><p>Map unusual CSV headers without losing the original source fields.</p></div></li><li><span>3</span><div><strong>Sync with rollback</strong><p>Existing prospects are linked, new records are added once, and imports can be undone.</p></div></li></ol></div>
    <div className="import-card">
      <div className="form-field"><label htmlFor="import-client">Client</label><select id="import-client" value={clientId} onChange={(event) => { setClientId(event.target.value); if (event.target.value) setNewClient(""); }}><option value="">Create a new client</option><option value={unassignedClientId}>Unassigned (list only)</option>{clients.filter((client) => client.id !== unassignedClientId).map((client) => <option key={client.id} value={client.id}>{client.name}</option>)}</select><small>Choose “Unassigned” to import the list without entering a client name.</small></div>
      {!clientId && <div className="form-field"><label htmlFor="new-client-name">New client name</label><input id="new-client-name" value={newClient} onChange={(event) => setNewClient(event.target.value)} placeholder="e.g. Acme Recruitment" /></div>}
      <div className="form-field"><label htmlFor="prospect-date-contacted">Date Contacted</label><input id="prospect-date-contacted" type="date" disabled={noDateContacted} required={!noDateContacted} value={dateContacted} max={localIsoDate()} onChange={(event) => setDateContacted(event.target.value)}/><label className="inline-checkbox" htmlFor="prospect-no-date-contacted"><input id="prospect-no-date-contacted" type="checkbox" checked={noDateContacted} onChange={(event) => setNoDateContacted(event.target.checked)}/> No contact date</label><small>Applied to these prospects for this client only. Choose “No contact date” to leave it blank.</small></div>
      <label className={`dropzone ${file ? "has-file" : ""}`}><input type="file" accept=".csv,text/csv" onChange={(event) => void pickFile(event)}/><span className="upload-mark"><AppIcon name="upload" size={14}/></span>{file ? <><strong>{file.name}</strong><small>{(file.size / 1024 / 1024).toFixed(2)} MB · Ready to review</small></> : <><strong>Choose a prospect CSV</strong><small>CSV streams safely for lists up to 500,000+ rows</small></>}</label>
      <div className="form-field"><label htmlFor="list-name">List name</label><input id="list-name" value={listName} onChange={(event) => setListName(event.target.value)} placeholder="Auto-filled from the CSV filename" /></div>
      {fileAudit && <><div className="file-audit"><div><span className="audit-check"><AppIcon name="check" size={14}/></span><p><strong>{formatNumber(fileAudit.headers.length)} fields detected</strong><small>{fileAudit.sampled ? `${formatNumber(fileAudit.rows)} sample rows checked · full CSV will be processed by the server` : `${formatNumber(fileAudit.rows)} rows · ${formatNumber(fileAudit.populatedCells)} populated cells`}</small></p></div><div className="audit-fields">{fileAudit.headers.slice(0, 8).map((header) => <span key={header}>{header}</span>)}{fileAudit.headers.length > 8 && <span>+{fileAudit.headers.length - 8} more</span>}</div><p>{fileAudit.invalidRows ? `${fileAudit.invalidRows} sampled rows have no email, LinkedIn, or name plus company and will be preserved without a People DB link.` : "The checked rows have enough identity data to match the People DB."}</p></div><ImportMappingPanel audit={fileAudit} fieldMap={fieldMap} onChange={(header, value) => setFieldMap((current) => ({ ...current, [header]: value }))}/><p className={missingFields.length ? "form-error" : "source-selected-note"}>{missingFields.length ? `Missing mandatory columns: ${missingFields.join(", ")}.` : "All required person columns are mapped."}</p>{missingFields.length ? <div className="cleanup-choice import-override"><input id="import-allow-missing" type="checkbox" checked={allowMissing} onChange={(event) => setAllowMissing(event.target.checked)} /><label htmlFor="import-allow-missing"><strong>Import anyway without all mandatory fields</strong><small>Rows import with whatever identity they have; those missing name/company and email/LinkedIn are preserved without a People DB link.</small></label></div> : null}</>}
      {phase !== "idle" && <div className="progress"><div><span>{message}</span><strong>{progress}%</strong></div><i><b style={{ width: `${progress}%` }}/></i></div>}
      {message && phase === "idle" && <p className="form-error" role="alert">{message}</p>}
      <button className="primary import-button" disabled={!canSubmit} onClick={startImport}>{phase === "idle" ? "Start import & sync" : "Processing…"}</button><p className="privacy-note">Original rows and fields remain stored in your private database.</p>
    </div>
  </div>;
}
