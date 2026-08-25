"use client";

import { ChangeEvent, useRef, useState } from "react";
import { describeBulkMerge, mergeBulkValues, splitPastedValues } from "../lib/bulk-values";
import { isXlsxFile, readXlsxRows } from "../lib/spreadsheet";
import { filterId, IncludeExcludeFilter, TextBooleanFilter, type ProspectFilter } from "./ApolloFilterPanel";
import type { CompanyKeywordScope } from "../lib/types";
import { useDismiss } from "./use-dismiss";
import { AppIcon } from "./components/DashboardUi";

const COMPANY_VALUES_ENDPOINT = "/api/companies/filter-values";

type CompanyFieldKind = "company_keywords" | "text" | "token" | "employee" | "year";
type CompanyFilterDefinition = {
  id: string;
  label: string;
  kind: CompanyFieldKind;
  autocomplete?: boolean;
  description?: string;
};

// Every one of these maps to a real companies column populated on import.
const companyFilters: CompanyFilterDefinition[] = [
  { id: "__company_keywords", label: "Company keywords", kind: "company_keywords", description: "Search company names and keywords together. Add description when you want broader coverage." },
  { id: "__company", label: "Company name only", kind: "text", autocomplete: true, description: "Use for known accounts or imported company-name lists. Simple include/exclude and Boolean search are supported." },
  { id: "__website", label: "Website", kind: "token", autocomplete: true, description: "Matches the company domain. Use the Bulk domains tab to paste a list." },
  { id: "__industry", label: "Industry", kind: "token", autocomplete: true },
  { id: "__employee_count", label: "# Employees", kind: "employee" },
  { id: "__company_location", label: "Company location", kind: "token", autocomplete: true, description: "One field for city, state and country — e.g. “London”, “California”, “India”." },
  { id: "__founded_year", label: "Founded year", kind: "year" },
  { id: "__technologies", label: "Technologies", kind: "token", autocomplete: true },
  { id: "__total_funding", label: "Total funding", kind: "token", autocomplete: true },
];

// Company city / state / country are deliberately NOT filters. "Company
// location" matches all three at once, which is the whole point of having it.
// The columns still exist and are still exported and read by the
// fill-from-company enrichment — they just are not three things to filter on.
const companyDetailFilters: CompanyFilterDefinition[] = [];

const employeeRanges = [
  ["1:10", "1–10"], ["11:20", "11–20"], ["21:50", "21–50"], ["51:100", "51–100"],
  ["101:200", "101–200"], ["201:500", "201–500"], ["501:1000", "501–1,000"],
  ["1001:2000", "1,001–2,000"], ["2001:5000", "2,001–5,000"],
  ["5001:10000", "5,001–10,000"], ["10001:", "10,001+"],
] as const;

const foundedYearRanges = [
  ["2020:", "2020 or later"], ["2010:2019", "2010–2019"], ["2000:2009", "2000–2009"],
  ["1990:1999", "1990–1999"], ["1980:1989", "1980–1989"], ["0:1979", "Before 1980"],
] as const;

function activeCount(filters: ProspectFilter[]) {
  return filters.reduce((count, filter) => count + (filter.operator === "empty" || filter.operator === "not_empty" ? 1 : filter.values.length), 0);
}

function parseCsv(text: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') { value += '"'; index += 1; }
      else quoted = !quoted;
    } else if (char === "," && !quoted) {
      row.push(value); value = "";
    } else if ((char === "\n" || char === "\r") && !quoted) {
      if (char === "\r" && text[index + 1] === "\n") index += 1;
      row.push(value); value = "";
      if (row.some((cell) => cell.trim())) rows.push(row);
      row = [];
    } else value += char;
  }
  row.push(value);
  if (row.some((cell) => cell.trim())) rows.push(row);
  if (!rows.length) throw new Error("The CSV is empty.");
  return { headers: rows[0], rows: rows.slice(1) };
}

// Accept a CSV or .xlsx for the name/website import.
async function readImportTable(file: File) {
  if (!isXlsxFile(file)) return parseCsv(await file.text());
  const rows = (await readXlsxRows(file)).filter((row) => row.some((cell) => cell.trim()));
  if (!rows.length) throw new Error("The spreadsheet is empty.");
  return { headers: rows[0], rows: rows.slice(1) };
}

export default function CompanyFilterPanel({ filters, onChange }: {
  filters: ProspectFilter[];
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const [search, setSearch] = useState("");
  const [expanded, setExpanded] = useState("");
  const [importError, setImportError] = useState("");
  const panelRef = useRef<HTMLElement>(null);
  useDismiss(panelRef, () => setExpanded(""), Boolean(expanded));
  const normalizedSearch = search.trim().toLocaleLowerCase();
  const visible = companyFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const visibleDetail = companyDetailFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const total = activeCount(filters);

  function replaceField(field: string, replacements: ProspectFilter[]) {
    onChange([...filters.filter((filter) => filter.field !== field), ...replacements]);
  }

  function addIncludeValues(field: string, additions: string[]) {
    if (!additions.length) return;
    const fieldFilters = filters.filter((filter) => filter.field === field);
    const include = fieldFilters.find((filter) => filter.operator === "contains" || filter.operator === "equals");
    const others = fieldFilters.filter((filter) => filter !== include);
    const seen = new Set((include?.values ?? []).map((value) => value.toLocaleLowerCase()));
    const merged = [...(include?.values ?? [])];
    for (const value of additions) {
      const key = value.toLocaleLowerCase();
      if (!key || seen.has(key)) continue;
      seen.add(key);
      merged.push(value);
    }
    replaceField(field, [...others, { id: include?.id ?? filterId(field, "contains"), field, operator: "contains", values: merged }]);
  }

  async function importNamesWebsites(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    try {
      const parsed = await readImportTable(file);
      const normalized = parsed.headers.map((header) => header.toLocaleLowerCase().replace(/[^a-z0-9]/g, ""));
      const nameIndex = normalized.findIndex((header) => ["company", "companyname", "name", "organization", "accountname"].includes(header));
      const domainIndex = normalized.findIndex((header) => ["website", "domain", "companywebsite", "companydomain", "url"].includes(header));
      if (nameIndex < 0 && domainIndex < 0) throw new Error("CSV needs a Company Name and/or Website column.");
      if (nameIndex >= 0) addIncludeValues("__company", parsed.rows.map((row) => row[nameIndex]?.trim()).filter(Boolean));
      if (domainIndex >= 0) addIncludeValues("__website", parsed.rows.map((row) => row[domainIndex]?.trim()).filter(Boolean));
      setImportError("");
    } catch (caught) { setImportError(caught instanceof Error ? caught.message : "Unable to import company filters."); }
  }

  function renderDefinition(definition: CompanyFilterDefinition) {
    const fieldFilters = filters.filter((filter) => filter.field === definition.id);
    const count = activeCount(fieldFilters);
    const isExpanded = expanded === definition.id;
    const autocompleteField = definition.autocomplete ? definition.id : undefined;
    return <section className={`apollo-filter-section ${isExpanded ? "expanded" : ""}`} key={definition.id}>
      <button type="button" className="apollo-filter-summary" aria-expanded={isExpanded} onClick={() => setExpanded(isExpanded ? "" : definition.id)}>
        <span className="apollo-filter-mark"><AppIcon name={definition.kind === "employee" || definition.kind === "year" ? "hash" : "target"} size={14}/></span>
        <strong>{definition.label}</strong>
        {count ? <span className="filter-count">{count}</span> : null}
        <span className="apollo-chevron"><AppIcon name="chevron" size={14}/></span>
      </button>
      {isExpanded ? <div className="apollo-filter-content">
        {definition.description ? <p className="apollo-filter-description">{definition.description}</p> : null}
        {definition.kind === "company_keywords"
          ? <CompanyKeywordFilter key={fieldFilters.map((filter) => filter.scopes?.join("|") ?? "default").join(";") || "default"} filters={fieldFilters} onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "employee"
          ? <RangeFilter field={definition.id} filters={fieldFilters} presets={employeeRanges} unknownLabel="# of employees is unknown" onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "year"
            ? <RangeFilter field={definition.id} filters={fieldFilters} presets={foundedYearRanges} unknownLabel="Founded year is unknown" minPlaceholder="e.g. 2005" maxPlaceholder="e.g. 2015" onChange={(next) => replaceField(definition.id, next)} />
            : definition.kind === "text"
              ? <TextBooleanFilter key={fieldFilters.map((filter) => `${filter.id}:${filter.values.join("|")}`).join(";")} definition={definition} filters={fieldFilters} valuesEndpoint={autocompleteField ? COMPANY_VALUES_ENDPOINT : undefined} onChange={(next) => replaceField(definition.id, next)} />
              : <IncludeExcludeFilter field={definition.id} filters={fieldFilters} valuesEndpoint={autocompleteField ? COMPANY_VALUES_ENDPOINT : undefined} onChange={(next) => replaceField(definition.id, next)} />}
        {count ? <button type="button" className="clear-section-filter" onClick={() => replaceField(definition.id, [])}>Clear {definition.label}</button> : null}
      </div> : null}
    </section>;
  }

  return <aside ref={panelRef} className="panel filter-panel apollo-filter-panel company-filter-panel">
    <div className="filter-panel-head">
      <div><span className="filter-icon"><AppIcon name="filter" size={16}/></span><div><strong>Filters</strong><small>Narrow the directory</small></div></div>
      {total ? <button onClick={() => onChange([])}>Clear all</button> : null}
    </div>
    <label className="company-filter-import"><input type="file" accept=".csv,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={(event) => void importNamesWebsites(event)}/>Import names &amp; websites</label>
    {importError ? <p className="form-error" role="alert">{importError}</p> : null}
    <label className="filter-panel-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search company filters" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search all filters…"/></label>
    <div className="apollo-filter-scroll">
      {visible.length ? <div className="apollo-filter-group"><small>Company filters</small>{visible.map(renderDefinition)}</div> : null}
      {visibleDetail.length ? <div className="apollo-filter-group optional"><small>More filters</small>{visibleDetail.map(renderDefinition)}</div> : null}
      {!visible.length && !visibleDetail.length ? <p className="filter-search-empty">No filters match “{search}”.</p> : null}
    </div>
    {/* Same applied-state footer as the People panel, so both rails read alike. */}
    <div className="filter-panel-footer" role="status">
      {total
        ? <><span><strong>{total}</strong> value{total === 1 ? "" : "s"} applied</span><button type="button" className="clear-section-filter" onClick={() => onChange([])}>Reset</button></>
        : <span>No filters applied</span>}
    </div>
  </aside>;
}

const companyKeywordScopeOptions: Array<{ id: CompanyKeywordScope; label: string; note?: string }> = [
  { id: "name", label: "Name" },
  { id: "keywords", label: "Keywords" },
  { id: "description", label: "Company description", note: "Broader coverage" },
];

function CompanyKeywordFilter({ filters, onChange }: { filters: ProspectFilter[]; onChange: (filters: ProspectFilter[]) => void }) {
  const initialScopes = filters.find((filter) => filter.scopes?.length)?.scopes ?? ["name", "keywords"];
  const [scopes, setScopes] = useState<CompanyKeywordScope[]>(initialScopes);

  function updateScopes(scope: CompanyKeywordScope) {
    const selected = scopes.includes(scope);
    if (selected && scopes.length === 1) return;
    const next = selected ? scopes.filter((item) => item !== scope) : [...scopes, scope];
    setScopes(next);
    if (filters.length) onChange(filters.map((filter) => ({ ...filter, scopes: next })));
  }

  return <div className="company-keyword-filter">
    <fieldset className="company-keyword-scopes">
      <legend>Search in</legend>
      {companyKeywordScopeOptions.map((option) => <label key={option.id}>
        <input type="checkbox" checked={scopes.includes(option.id)} disabled={scopes.includes(option.id) && scopes.length === 1} onChange={() => updateScopes(option.id)} />
        <span>{option.label}{option.note ? <small>{option.note}</small> : null}</span>
      </label>)}
    </fieldset>
    <p className="company-keyword-scope-note">Selected fields are searched together. Description increases recall and may return more companies.</p>
    <TextBooleanFilter
      definition={{ id: "__company_keywords", label: "Company keywords" }}
      filters={filters}
      onChange={(next) => onChange(next.map((filter) => ({ ...filter, scopes })))}
    />
  </div>;
}

// Merge a list of (already-normalized) domains into the __website include filter,
// deduping case-insensitively against whatever is already there. Pure so the
// Company DB "Bulk domains" tab can call it without the panel being mounted.
export function addDomainsToWebsiteFilter(filters: ProspectFilter[], domains: string[]): ProspectFilter[] {
  const field = "__website";
  const additions = domains.map((domain) => domain.trim()).filter(Boolean);
  if (!additions.length) return filters;
  const fieldFilters = filters.filter((filter) => filter.field === field);
  const include = fieldFilters.find((filter) => filter.operator === "contains" || filter.operator === "equals");
  const others = fieldFilters.filter((filter) => filter !== include);
  const seen = new Set((include?.values ?? []).map((value) => value.toLocaleLowerCase()));
  const merged = [...(include?.values ?? [])];
  for (const value of additions) {
    const key = value.toLocaleLowerCase();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    merged.push(value);
  }
  return [...filters.filter((filter) => filter.field !== field), ...others, { id: include?.id ?? filterId(field, "contains"), field, operator: "contains", values: merged }];
}

export function BulkDomainPaste({ onAdd }: { onAdd: (domains: string[]) => void }) {
  const [text, setText] = useState("");
  const [note, setNote] = useState("");
  const pending = splitPastedValues(text).length;

  function apply() {
    // Shares the parser the filter pickers and the client blocklist use, so a
    // pasted URL is trimmed to the stored domain identically everywhere.
    const result = mergeBulkValues([], text, "domain");
    if (!result.added) { setNote(describeBulkMerge(result, "domain")); return; }
    onAdd(result.values);
    setNote(describeBulkMerge(result, "domain"));
    setText("");
  }

  return <div className="bulk-domain-paste">
    <textarea
      value={text}
      onChange={(event) => { setText(event.target.value); if (note) setNote(""); }}
      aria-label="Bulk paste domains"
      spellCheck={false}
      placeholder={"acme.com\nhttps://www.stripe.com/pricing\ncontoso.co.uk\n\nOne per line, or comma-separated. URLs are trimmed to the domain."}
    />
    <div className="bulk-domain-actions">
      <button type="button" onClick={apply} disabled={!pending}>Add {pending ? pending.toLocaleString("en-IN") : ""} domains</button>
      {note ? <span className="bulk-domain-note">{note}</span> : null}
    </div>
  </div>;
}

function RangeFilter({ field, filters, presets, unknownLabel, minPlaceholder = "e.g. 50", maxPlaceholder = "No maximum", onChange }: {
  field: string;
  filters: ProspectFilter[];
  presets: ReadonlyArray<readonly [string, string]>;
  unknownLabel: string;
  minPlaceholder?: string;
  maxPlaceholder?: string;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const existing = filters.find((filter) => filter.operator === "number_ranges");
  const values = existing?.values ?? [];
  const [rangeMode, setRangeMode] = useState<"predefined" | "custom">("predefined");
  const [minimum, setMinimum] = useState("");
  const [maximum, setMaximum] = useState("");

  function setValues(nextValues: string[]) {
    onChange(nextValues.length ? [{ id: existing?.id ?? filterId(field, "number_ranges"), field, operator: "number_ranges", values: nextValues }] : []);
  }

  function toggle(value: string) {
    setValues(values.includes(value) ? values.filter((item) => item !== value) : [...values, value]);
  }

  function applyCustom() {
    const min = Math.max(0, Number(minimum));
    const max = maximum.trim() ? Math.max(0, Number(maximum)) : null;
    if (!minimum.trim() || !Number.isFinite(min) || (max !== null && (!Number.isFinite(max) || max < min))) return;
    const custom = `${Math.trunc(min)}:${max === null ? "" : Math.trunc(max)}`;
    setValues(values.includes(custom) ? values : [...values, custom]);
    setMinimum(""); setMaximum("");
  }

  return <div className="employee-filter">
    <div className="employee-mode"><button type="button" className={rangeMode === "predefined" ? "active" : ""} onClick={() => setRangeMode("predefined")}><i/>Predefined range</button><button type="button" className={rangeMode === "custom" ? "active" : ""} onClick={() => setRangeMode("custom")}><i/>Custom range</button></div>
    {rangeMode === "predefined"
      ? <div className="employee-range-list">{presets.map(([value, label]) => <label key={value}><input type="checkbox" checked={values.includes(value)} onChange={() => toggle(value)}/><span>{label}</span></label>)}</div>
      : <div className="employee-custom-range"><label>Minimum<input type="number" min="0" value={minimum} onChange={(event) => setMinimum(event.target.value)} placeholder={minPlaceholder}/></label><label>Maximum<input type="number" min="0" value={maximum} onChange={(event) => setMaximum(event.target.value)} placeholder={maxPlaceholder}/></label><button type="button" onClick={applyCustom}>Apply range</button></div>}
    <label className="employee-unknown"><input type="checkbox" checked={values.includes("unknown")} onChange={() => toggle("unknown")}/><span>{unknownLabel}</span></label>
  </div>;
}
