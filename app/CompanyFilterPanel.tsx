"use client";

import { ChangeEvent, useRef, useState } from "react";
import { filterId, IncludeExcludeFilter, TextBooleanFilter, type ProspectFilter } from "./ApolloFilterPanel";
import { useDismiss } from "./use-dismiss";

const COMPANY_VALUES_ENDPOINT = "/api/companies/filter-values";

type CompanyFieldKind = "text" | "token" | "employee" | "year";
type CompanyFilterDefinition = {
  id: string;
  label: string;
  kind: CompanyFieldKind;
  autocomplete?: boolean;
  description?: string;
};

// Every one of these maps to a real companies column populated on import.
const companyFilters: CompanyFilterDefinition[] = [
  { id: "__company", label: "Company name", kind: "text", autocomplete: true, description: "Simple include/exclude, or Boolean with AND/OR/NOT." },
  { id: "__website", label: "Website", kind: "token", autocomplete: true, description: "Matches the company domain." },
  { id: "__industry", label: "Industry", kind: "token", autocomplete: true },
  { id: "__employee_count", label: "# Employees", kind: "employee" },
  { id: "__company_city", label: "Company city", kind: "token", autocomplete: true },
  { id: "__company_state", label: "Company state", kind: "token", autocomplete: true },
  { id: "__company_country", label: "Company country", kind: "token", autocomplete: true },
  { id: "__keywords", label: "Keywords", kind: "text", autocomplete: true, description: "Simple include/exclude, or Boolean with AND/OR/NOT." },
  { id: "__short_description", label: "Short description", kind: "text", description: "Search the company description. Boolean supported." },
  { id: "__founded_year", label: "Founded year", kind: "year" },
  { id: "__technologies", label: "Technologies", kind: "token", autocomplete: true },
  { id: "__total_funding", label: "Total funding", kind: "token", autocomplete: true },
];

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
      const parsed = parseCsv(await file.text());
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
        <span className="apollo-filter-mark">{definition.kind === "employee" || definition.kind === "year" ? "#" : "⌾"}</span>
        <strong>{definition.label}</strong>
        {count ? <span className="filter-count">{count}</span> : null}
        <span className="apollo-chevron">⌄</span>
      </button>
      {isExpanded ? <div className="apollo-filter-content">
        {definition.description ? <p className="apollo-filter-description">{definition.description}</p> : null}
        {definition.kind === "employee"
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
      <div><span className="filter-icon">⌁</span><div><strong>Filters</strong><small>Apollo-style company filters</small></div></div>
      {total ? <button onClick={() => onChange([])}>Clear all</button> : null}
    </div>
    <label className="company-filter-import"><input type="file" accept=".csv,text/csv" onChange={(event) => void importNamesWebsites(event)}/>Import names &amp; websites</label>
    {importError ? <p className="form-error" role="alert">{importError}</p> : null}
    <label className="filter-panel-search"><span>⌕</span><input aria-label="Search company filters" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search all filters…"/></label>
    <div className="apollo-filter-scroll">
      {visible.length ? <div className="apollo-filter-group"><small>COMPANY FILTERS</small>{visible.map(renderDefinition)}</div> : <p className="filter-search-empty">No filters match “{search}”.</p>}
    </div>
  </aside>;
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
