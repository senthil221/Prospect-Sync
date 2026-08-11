"use client";

import { ClipboardEvent, KeyboardEvent, useEffect, useRef, useState } from "react";
import type { ProspectFieldDefinition } from "../lib/prospect-fields";
import { useDismiss } from "./use-dismiss";

export type ProspectFilterOperator = "contains" | "equals" | "not_contains" | "not_equals" | "empty" | "not_empty" | "boolean" | "number_ranges";
export type ProspectFilter = { id: string; field: string; operator: ProspectFilterOperator; values: string[] };

type FilterDefinition = ProspectFieldDefinition & {
  kind?: "text" | "employee";
  advanced?: boolean;
  description?: string;
};

const mainFilters: FilterDefinition[] = [
  { id: "__keywords", label: "Keywords", kind: "text", advanced: true, description: "Search the prospect Keywords column." },
  { id: "__title", label: "Job titles", kind: "text", advanced: true, description: "Job Title is kept separate from Keywords." },
  { id: "__seniority", label: "Seniority" },
  { id: "__department", label: "Department" },
  { id: "__person_location", label: "Person location", description: "Matches the person's city, state, or country." },
  { id: "__company_location", label: "Company location", description: "Matches company headquarters, city, state, or country." },
  { id: "__employee_count", label: "# Employees", kind: "employee" },
  { id: "__first_name", label: "First name" },
  { id: "__last_name", label: "Last name" },
  { id: "__company", label: "Company" },
  { id: "__email", label: "Email" },
  { id: "__clients", label: "Client" },
  { id: "__esp", label: "ESP" },
  { id: "__email_provider_type", label: "Email provider type" },
  { id: "__lists", label: "List names" },
];

const optionalFilters: FilterDefinition[] = [
  { id: "__name", label: "Full name" },
  { id: "__work_email", label: "Work email" },
  { id: "__personal_email", label: "Personal email" },
  { id: "__linkedin", label: "LinkedIn" },
  { id: "__tags", label: "Tags" },
  { id: "__last_contacted", label: "Last contacted" },
];

const employeeRanges = [
  ["1:10", "1–10"], ["11:20", "11–20"], ["21:50", "21–50"], ["51:100", "51–100"],
  ["101:200", "101–200"], ["201:500", "201–500"], ["501:1000", "501–1,000"],
  ["1001:2000", "1,001–2,000"], ["2001:5000", "2,001–5,000"],
  ["5001:10000", "5,001–10,000"], ["10001:", "10,001+"],
] as const;

function filterId(field: string, operator: ProspectFilterOperator) {
  return `${field}:${operator}:${Date.now()}:${Math.random().toString(36).slice(2, 7)}`;
}

function activeCount(filters: ProspectFilter[]) {
  return filters.reduce((count, filter) => count + (filter.operator === "empty" || filter.operator === "not_empty" ? 1 : filter.values.length), 0);
}

export function filterLabel(field: string, customFields: ProspectFieldDefinition[] = []) {
  return [...mainFilters, ...optionalFilters, ...customFields].find((definition) => definition.id === field)?.label ?? field;
}

export default function ApolloFilterPanel({ filters, customFields, clientId, onChange }: {
  filters: ProspectFilter[];
  customFields: ProspectFieldDefinition[];
  clientId?: string;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const [search, setSearch] = useState("");
  const [expanded, setExpanded] = useState("");
  const panelRef = useRef<HTMLElement>(null);
  useDismiss(panelRef, () => setExpanded(""), Boolean(expanded));
  const normalizedSearch = search.trim().toLocaleLowerCase();
  const visibleMain = mainFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const visibleOptional = [...optionalFilters, ...customFields].filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));

  function replaceField(field: string, replacements: ProspectFilter[]) {
    onChange([...filters.filter((filter) => filter.field !== field), ...replacements]);
  }

  function renderDefinition(definition: FilterDefinition) {
    const fieldFilters = filters.filter((filter) => filter.field === definition.id);
    const count = activeCount(fieldFilters);
    const isExpanded = expanded === definition.id;
    return <section className={`apollo-filter-section ${isExpanded ? "expanded" : ""}`} key={definition.id}>
      <button type="button" className="apollo-filter-summary" aria-expanded={isExpanded} onClick={() => setExpanded(isExpanded ? "" : definition.id)}>
        <span className="apollo-filter-mark">{definition.kind === "employee" ? "#" : "⌾"}</span>
        <strong>{definition.label}</strong>
        {count ? <span className="filter-count">{count}</span> : null}
        <span className="apollo-chevron">⌄</span>
      </button>
      {isExpanded ? <div className="apollo-filter-content">
        {definition.description ? <p className="apollo-filter-description">{definition.description}</p> : null}
        {definition.kind === "employee"
          ? <EmployeeFilter filters={fieldFilters} onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "text" && definition.advanced
            ? <TextBooleanFilter key={fieldFilters.map((filter) => `${filter.id}:${filter.values.join("|")}`).join(";")} definition={definition} filters={fieldFilters} clientId={clientId} onChange={(next) => replaceField(definition.id, next)} />
            : <IncludeExcludeFilter field={definition.id} filters={fieldFilters} clientId={clientId} onChange={(next) => replaceField(definition.id, next)} />}
        {count ? <button type="button" className="clear-section-filter" onClick={() => replaceField(definition.id, [])}>Clear {definition.label}</button> : null}
      </div> : null}
    </section>;
  }

  return <aside ref={panelRef} className="panel filter-panel apollo-filter-panel">
    <div className="filter-panel-head"><div><span className="filter-icon">⌁</span><div><strong>Filters</strong><small>Apollo-style prospect filters</small></div></div>{filters.length ? <button onClick={() => onChange([])}>Clear all</button> : null}</div>
    <label className="filter-panel-search"><span>⌕</span><input aria-label="Search filters" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search all filters…"/></label>
    <div className="apollo-filter-scroll">
      {visibleMain.length ? <div className="apollo-filter-group"><small>MAIN FILTERS</small>{visibleMain.map(renderDefinition)}</div> : null}
      {visibleOptional.length ? <div className="apollo-filter-group optional"><small>MORE FILTERS</small>{visibleOptional.map(renderDefinition)}</div> : null}
      {!visibleMain.length && !visibleOptional.length ? <p className="filter-search-empty">No filters match “{search}”.</p> : null}
    </div>
  </aside>;
}

function TextBooleanFilter({ definition, filters, clientId, onChange }: {
  definition: FilterDefinition;
  filters: ProspectFilter[];
  clientId?: string;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const existingBoolean = filters.find((filter) => filter.operator === "boolean");
  const [mode, setMode] = useState<"simple" | "advanced">(existingBoolean ? "advanced" : "simple");
  const [booleanQuery, setBooleanQuery] = useState(existingBoolean?.values[0] ?? "");
  const [message, setMessage] = useState("");

  if (mode === "simple") return <>
    <div className="apollo-mode-tabs"><button className="active" type="button">Simple</button><button type="button" onClick={() => setMode("advanced")}>Advanced</button></div>
    <IncludeExcludeFilter field={definition.id} filters={filters.filter((filter) => filter.operator !== "boolean")} clientId={clientId} onChange={onChange} />
  </>;

  function applyBoolean() {
    const query = booleanQuery.trim();
    if (!query) { setMessage("Enter a Boolean search first."); return; }
    const words = query.match(/\b(?:AND|OR|NOT)\b/gi) ?? [];
    if (!words.length && !query.includes('"')) setMessage("Tip: combine terms with AND, OR, or NOT.");
    else setMessage("");
    onChange([{ id: existingBoolean?.id ?? filterId(definition.id, "boolean"), field: definition.id, operator: "boolean", values: [query] }]);
  }

  return <>
    <div className="apollo-mode-tabs"><button type="button" onClick={() => setMode("simple")}>Simple</button><button className="active" type="button">Advanced</button></div>
    <div className="boolean-search-box">
      <div className="boolean-search-title"><span className="boolean-radio"/> Boolean Search</div>
      <small>Search with Boolean operators</small>
      <textarea aria-label={`Boolean search for ${definition.label}`} value={booleanQuery} onChange={(event) => setBooleanQuery(event.target.value)} placeholder={`Enter ${definition.label.toLocaleLowerCase()} separated by AND/OR/NOT and parentheses`}/>
      <p>Examples: Sales AND “Product Design”; Sales OR Design; Sales AND NOT Design.</p>
      {message ? <span className="boolean-message">{message}</span> : null}
      <button type="button" onClick={applyBoolean}>Apply</button>
    </div>
  </>;
}

function IncludeExcludeFilter({ field, filters, clientId, onChange }: {
  field: string;
  filters: ProspectFilter[];
  clientId?: string;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const includeRule = filters.find((filter) => filter.operator === "contains" || filter.operator === "equals");
  const excludeRule = filters.find((filter) => filter.operator === "not_contains" || filter.operator === "not_equals");
  const otherRules = filters.filter((filter) => !["contains", "equals", "not_contains", "not_equals"].includes(filter.operator));

  function setValues(side: "include" | "exclude", values: string[]) {
    const current = side === "include" ? includeRule : excludeRule;
    const operator: ProspectFilterOperator = side === "include" ? "contains" : "not_contains";
    const opposite = side === "include" ? excludeRule : includeRule;
    const next = [...otherRules];
    if (opposite?.values.length) next.push(opposite);
    if (values.length) next.push({ id: current?.id ?? filterId(field, operator), field, operator, values });
    onChange(next);
  }

  return <div className="include-exclude-grid">
    <div><span className="include-exclude-label">Include</span><TokenValuePicker field={field} values={includeRule?.values ?? []} clientId={clientId} placeholder="Type or paste comma-separated values" onChange={(values) => setValues("include", values)} /></div>
    <div><span className="include-exclude-label">Exclude</span><TokenValuePicker field={field} values={excludeRule?.values ?? []} clientId={clientId} placeholder="Values to leave out" onChange={(values) => setValues("exclude", values)} /></div>
  </div>;
}

export function TokenValuePicker({ field, values, clientId, placeholder, onChange }: {
  field?: string;
  values: string[];
  clientId?: string;
  placeholder: string;
  onChange: (values: string[]) => void;
}) {
  const [query, setQuery] = useState("");
  const [options, setOptions] = useState<Array<{ value: string; count: number }>>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const pickerRef = useRef<HTMLDivElement>(null);
  useDismiss(pickerRef, () => setOpen(false), open);

  useEffect(() => {
    if (!open || !field) return;
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      setLoading(true);
      const params = new URLSearchParams({ field, search: query.trim(), limit: "30" });
      if (clientId) params.set("clientId", clientId);
      try {
        const response = await fetch(`/api/prospects/filter-values?${params}`, { signal: controller.signal });
        const data = await response.json() as { values?: Array<{ value: string; count: number }> };
        setOptions(response.ok ? data.values ?? [] : []);
      } catch { if (!controller.signal.aborted) setOptions([]); }
      finally { if (!controller.signal.aborted) setLoading(false); }
    }, 180);
    return () => { window.clearTimeout(timer); controller.abort(); };
  }, [clientId, field, open, query]);

  function addMany(raw: string) {
    const seen = new Set(values.map((value) => value.toLocaleLowerCase()));
    const additions = raw.split(/[,;\n|]/).map((value) => value.trim()).filter((value) => {
      const normalized = value.toLocaleLowerCase();
      if (!normalized || seen.has(normalized)) return false;
      seen.add(normalized);
      return true;
    });
    if (additions.length) onChange([...values, ...additions]);
    setQuery("");
  }

  function onKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (["Enter", ",", ";"].includes(event.key)) { event.preventDefault(); addMany(query); }
    if (event.key === "Backspace" && !query && values.length) onChange(values.slice(0, -1));
  }

  function onPaste(event: ClipboardEvent<HTMLInputElement>) {
    const pasted = event.clipboardData.getData("text");
    if (/[,;\n|]/.test(pasted)) { event.preventDefault(); addMany(pasted); }
  }

  const selected = new Set(values.map((value) => value.toLocaleLowerCase()));
  const visibleOptions = options.filter((option) => !selected.has(option.value.toLocaleLowerCase()));
  return <div className="token-value-picker" ref={pickerRef}>
    <div className="token-input">
      {values.map((value) => <button type="button" key={value} onClick={(event) => { event.stopPropagation(); onChange(values.filter((item) => item !== value)); }}>{value}<span>×</span></button>)}
      <input value={query} onFocus={() => setOpen(true)} onChange={(event) => setQuery(event.target.value)} onKeyDown={onKeyDown} onPaste={onPaste} onBlur={() => { if (query.trim()) addMany(query); window.setTimeout(() => setOpen(false), 150); }} placeholder={values.length ? "Add another…" : placeholder}/>
    </div>
    {open ? <div className="token-options" role="listbox" aria-multiselectable="true">
      {loading ? <p>Searching all prospects…</p> : null}
      {!loading && visibleOptions.map((option) => <button type="button" role="option" aria-selected="false" key={option.value} onMouseDown={(event) => event.preventDefault()} onClick={() => { onChange([...values, option.value]); setQuery(""); }}><span>{option.value}</span><small>{option.count.toLocaleString("en-IN")}</small></button>)}
      {!loading && !visibleOptions.length ? <p>{query.trim() ? "Press Enter to add this value." : "Type a value or paste a comma-separated list."}</p> : null}
    </div> : null}
  </div>;
}

function EmployeeFilter({ filters, onChange }: { filters: ProspectFilter[]; onChange: (filters: ProspectFilter[]) => void }) {
  const existing = filters.find((filter) => filter.operator === "number_ranges");
  const values = existing?.values ?? [];
  const [rangeMode, setRangeMode] = useState<"predefined" | "custom">("predefined");
  const [minimum, setMinimum] = useState("");
  const [maximum, setMaximum] = useState("");

  function setValues(nextValues: string[]) {
    onChange(nextValues.length ? [{ id: existing?.id ?? filterId("__employee_count", "number_ranges"), field: "__employee_count", operator: "number_ranges", values: nextValues }] : []);
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
  }

  return <div className="employee-filter">
    <div className="employee-mode"><button type="button" className={rangeMode === "predefined" ? "active" : ""} onClick={() => setRangeMode("predefined")}><i/>Predefined range</button><button type="button" className={rangeMode === "custom" ? "active" : ""} onClick={() => setRangeMode("custom")}><i/>Custom range</button></div>
    {rangeMode === "predefined" ? <div className="employee-range-list">{employeeRanges.map(([value, label]) => <label key={value}><input type="checkbox" checked={values.includes(value)} onChange={() => toggle(value)}/><span>{label}</span></label>)}</div> : <div className="employee-custom-range"><label>Minimum<input type="number" min="0" value={minimum} onChange={(event) => setMinimum(event.target.value)} placeholder="e.g. 50"/></label><label>Maximum<input type="number" min="0" value={maximum} onChange={(event) => setMaximum(event.target.value)} placeholder="No maximum"/></label><button type="button" onClick={applyCustom}>Apply range</button></div>}
    <label className="employee-unknown"><input type="checkbox" checked={values.includes("unknown")} onChange={() => toggle("unknown")}/><span># of employees is unknown</span></label>
  </div>;
}
