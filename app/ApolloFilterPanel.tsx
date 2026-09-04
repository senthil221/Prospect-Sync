"use client";

import { ClipboardEvent, KeyboardEvent, useEffect, useRef, useId, useState } from "react";
import { bulkFieldKind, describeBulkMerge, describeMatchMode, mergeBulkValues, splitPastedValues, switchesToExactMatch } from "../lib/bulk-values";
import type { ProspectFieldDefinition } from "../lib/prospect-fields";
import type { ProspectFilter, ProspectFilterOperator } from "../lib/types";
import { useDismiss } from "./use-dismiss";
import { AppIcon } from "./components/DashboardUi";

export type { ProspectFilter, ProspectFilterOperator } from "../lib/types";

type FilterDefinition = ProspectFieldDefinition & {
  kind?: "text" | "employee";
  advanced?: boolean;
  description?: string;
};

// Only the mandatory person fields are offered as filters. Industry (and any other
// kept field) arrives through the whitelisted custom fields in "MORE FILTERS".
const mainFilters: FilterDefinition[] = [
  { id: "__name", label: "Name" },
  { id: "__company", label: "Company Name" },
  { id: "__email", label: "Email" },
  { id: "__linkedin", label: "Personal LinkedIn URL" },
  { id: "__title_seniority", label: "Job Title & Seniority", description: "Matches either the job title or the seniority." },
  { id: "__department", label: "Departments" },
  { id: "__person_location", label: "Location", description: "One field for city, state and country - e.g. “London”, “California”, “United Kingdom”." },
  { id: "__esp_type", label: "ESP", description: "Matches the ESP or the email provider type (e.g. SEG)." },
];

// Derived from the job title by the deterministic classifier, not from the uploaded
// Seniority/Departments columns -- so they are consistent across data sources even
// when the file's own columns are blank or use a different vocabulary.
const classifierFilters: FilterDefinition[] = [
  { id: "__title_department", label: "Department (from title)", description: "One of 18 departments worked out from the job title itself." },
  { id: "__title_sub_department", label: "Sub-department (from title)", description: "The finer slice, where the title is specific enough to tell. Titles that only identify the department have no sub-department, so pair this with the department filter rather than using it alone." },
  { id: "__title_seniority_tier", label: "Seniority tier (from title)", description: "owner · c_suite · vp · director · manager · senior_ic · entry" },
];

// City / state / country are deliberately NOT filters. "Location" matches all
// three at once, which is the whole point of having it. The columns still exist
// and are still exported - they just are not three things to filter on.
//
// Tags are the one thing that belongs here: applied inside the workspace rather
// than imported, so they sit with the kept custom fields rather than the mandatory
// person fields. The value picker lists the tags that actually exist, which is the
// whole point of having tagged a selection.
const optionalFilters: FilterDefinition[] = [
  { id: "__tags", label: "Tags", description: "Tags added from the bulk actions bar after selecting rows." },
];

const employeeRanges = [
  ["1:10", "1–10"], ["11:20", "11–20"], ["21:50", "21–50"], ["51:100", "51–100"],
  ["101:200", "101–200"], ["201:500", "201–500"], ["501:1000", "501–1,000"],
  ["1001:2000", "1,001–2,000"], ["2001:5000", "2,001–5,000"],
  ["5001:10000", "5,001–10,000"], ["10001:", "10,001+"],
] as const;

// Separators a pasted list can arrive with: commas, semicolons, pipes, newlines, and
// tabs (a column copied out of a spreadsheet).
const splitPattern = /[,;\n\t|]/;

export function filterId(field: string, operator: ProspectFilterOperator) {
  return `${field}:${operator}:${Date.now()}:${Math.random().toString(36).slice(2, 7)}`;
}

function activeCount(filters: ProspectFilter[]) {
  return filters.reduce((count, filter) => count + (filter.operator === "empty" || filter.operator === "not_empty" ? 1 : filter.values.length), 0);
}

export function filterLabel(field: string, customFields: ProspectFieldDefinition[] = []) {
  return [...mainFilters, ...classifierFilters, ...optionalFilters, ...customFields].find((definition) => definition.id === field)?.label ?? field;
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
  const visibleClassifier = classifierFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const visibleOptional = [...optionalFilters, ...customFields].filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));

  function replaceField(field: string, replacements: ProspectFilter[]) {
    onChange([...filters.filter((filter) => filter.field !== field), ...replacements]);
  }

  function renderDefinition(definition: FilterDefinition) {
    const fieldFilters = filters.filter((filter) => filter.field === definition.id);
    const count = activeCount(fieldFilters);
    const isExpanded = expanded === definition.id;
    return <section className={`apollo-filter-section ${isExpanded ? "expanded" : ""}`} key={definition.id}>
      <button type="button" id={`filter-trigger-${definition.id}`} className="apollo-filter-summary" aria-expanded={isExpanded} aria-controls={`filter-panel-${definition.id}`} onClick={() => setExpanded(isExpanded ? "" : definition.id)}>
        <span className="apollo-filter-mark"><AppIcon name={definition.kind === "employee" ? "hash" : "target"} size={14}/></span>
        <strong>{definition.label}</strong>
        {count ? <span className="filter-count">{count}</span> : null}
        <span className="apollo-chevron"><AppIcon name="chevron" size={14}/></span>
      </button>
      {isExpanded ? <div id={`filter-panel-${definition.id}`} role="region" aria-labelledby={`filter-trigger-${definition.id}`} className="apollo-filter-content">
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

  const totalActive = activeCount(filters);
  const fieldsInUse = new Set(filters.map((filter) => filter.field)).size;

  return <aside ref={panelRef} className="panel filter-panel apollo-filter-panel">
    <div className="filter-panel-head"><div><span className="filter-icon"><AppIcon name="filter" size={16}/></span><div><strong>Filters</strong><small>Narrow the database</small></div></div>{filters.length ? <button onClick={() => onChange([])}>Clear all</button> : null}</div>
    <label className="filter-panel-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search filters" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search all filters…"/></label>
    <div className="apollo-filter-scroll">
      {visibleMain.length ? <div className="apollo-filter-group"><small>Main filters</small>{visibleMain.map(renderDefinition)}</div> : null}
      {visibleClassifier.length ? <div className="apollo-filter-group"><small>From job title</small>{visibleClassifier.map(renderDefinition)}</div> : null}
      {visibleOptional.length ? <div className="apollo-filter-group optional"><small>More filters</small>{visibleOptional.map(renderDefinition)}</div> : null}
      {!visibleMain.length && !visibleClassifier.length && !visibleOptional.length ? <p className="filter-search-empty">No filters match “{search}”.</p> : null}
    </div>
    {/* Applied state stays visible without scrolling the list back to the top. */}
    <div className="filter-panel-footer" role="status">
      {totalActive
        ? <><span><strong>{totalActive}</strong> value{totalActive === 1 ? "" : "s"} across <strong>{fieldsInUse}</strong> field{fieldsInUse === 1 ? "" : "s"}</span><button type="button" className="clear-section-filter" onClick={() => onChange([])}>Reset</button></>
        : <span>No filters applied</span>}
    </div>
  </aside>;
}

export function TextBooleanFilter({ definition, filters, clientId, valuesEndpoint, onChange }: {
  definition: { id: string; label: string };
  filters: ProspectFilter[];
  clientId?: string;
  valuesEndpoint?: string;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const existingBoolean = filters.find((filter) => filter.operator === "boolean");
  const [mode, setMode] = useState<"simple" | "advanced">(existingBoolean ? "advanced" : "simple");
  const [booleanQuery, setBooleanQuery] = useState(existingBoolean?.values[0] ?? "");
  const [message, setMessage] = useState("");

  if (mode === "simple") return <>
    <div className="apollo-mode-tabs"><button className="active" type="button">Simple</button><button type="button" onClick={() => setMode("advanced")}>Advanced</button></div>
    <IncludeExcludeFilter field={definition.id} filters={filters.filter((filter) => filter.operator !== "boolean")} clientId={clientId} valuesEndpoint={valuesEndpoint} onChange={onChange} />
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

export function IncludeExcludeFilter({ field, filters, clientId, valuesEndpoint, onChange }: {
  field: string;
  filters: ProspectFilter[];
  clientId?: string;
  valuesEndpoint?: string;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const includeRule = filters.find((filter) => filter.operator === "contains" || filter.operator === "equals");
  const excludeRule = filters.find((filter) => filter.operator === "not_contains" || filter.operator === "not_equals");
  const otherRules = filters.filter((filter) => !["contains", "equals", "not_contains", "not_equals"].includes(filter.operator));

  function setValues(side: "include" | "exclude", values: string[]) {
    const current = side === "include" ? includeRule : excludeRule;
    // A pasted column of hundreds of values means "these exact values", not "anything
    // containing one of them". Substring matching also widens the result set: 781
    // pasted domains matched 5,904 companies, because acme.com is a substring of
    // notacme.com.au. And equality is a single indexable array test where a chain of
    // ILIKE '%…%' is not -- above 40 values the prefilter falls back to a correlated
    // EXISTS that no index can serve, which measured 83s on 418k companies.
    //
    // Both sides switch on their own length, so include and exclude stay symmetric.
    // Field-aware: a keyword search never switches, because its values are
    // phrases to find inside a name or description, not values to equal.
    const exact = switchesToExactMatch(field, values.length);
    const operator: ProspectFilterOperator = side === "include"
      ? (exact ? "equals" : "contains")
      : (exact ? "not_equals" : "not_contains");
    const opposite = side === "include" ? excludeRule : includeRule;
    const next = [...otherRules];
    if (opposite?.values.length) next.push(opposite);
    if (values.length) next.push({ id: current?.id ?? filterId(field, operator), field, operator, values });
    onChange(next);
  }

  return <div className="include-exclude-grid">
    <div><span className="include-exclude-label">Include</span><TokenValuePicker field={field} values={includeRule?.values ?? []} clientId={clientId} valuesEndpoint={valuesEndpoint} placeholder="Type or paste comma-separated values" onChange={(values) => setValues("include", values)} /></div>
    <div><span className="include-exclude-label">Exclude</span><TokenValuePicker field={field} values={excludeRule?.values ?? []} clientId={clientId} valuesEndpoint={valuesEndpoint} placeholder="Values to leave out" onChange={(values) => setValues("exclude", values)} /></div>
  </div>;
}

// Past this many chips the box stops being readable, so it collapses to a count
// and a Review button that opens the same list in the editable bulk textarea.
const chipCollapseThreshold = 20;

export function TokenValuePicker({ field, values, clientId, placeholder, valuesEndpoint = "/api/prospects/filter-values", onChange }: {
  field?: string;
  values: string[];
  clientId?: string;
  placeholder: string;
  valuesEndpoint?: string;
  onChange: (values: string[]) => void;
}) {
  const [query, setQuery] = useState("");
  const [options, setOptions] = useState<Array<{ value: string; count: number }>>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [mode, setMode] = useState<"search" | "bulk">("search");
  const [bulkText, setBulkText] = useState("");
  const [bulkNote, setBulkNote] = useState("");
  // The option the keyboard is on. -1 means "none", which is the state where
  // Enter adds what was typed rather than picking a suggestion.
  const [activeIndex, setActiveIndex] = useState(-1);
  const listId = useId();
  const pickerRef = useRef<HTMLDivElement>(null);
  useDismiss(pickerRef, () => setOpen(false), open);
  const kind = bulkFieldKind(field);

  function openBulk(prefill: boolean) {
    setBulkText(prefill ? values.join("\n") : "");
    setBulkNote("");
    setOpen(false);
    setMode("bulk");
  }

  function applyBulk(replace: boolean) {
    const result = mergeBulkValues(replace ? [] : values, bulkText, kind);
    onChange(result.values);
    // Crossing the threshold switches the operator, which changes how many rows
    // come back. Say so, so the count moving does not read as a bug -- and pass
    // the field, so a keyword search (which never switches) is not told it did.
    setBulkNote(`${describeBulkMerge(result)} ${describeMatchMode(result.values.length, "value", field)}`.trim());
    if (!replace) setBulkText("");
  }

  useEffect(() => {
    if (!open || !field) return;
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      setLoading(true);
      const params = new URLSearchParams({ field, search: query.trim(), limit: "30" });
      if (clientId) params.set("clientId", clientId);
      try {
        const response = await fetch(`${valuesEndpoint}?${params}`, { signal: controller.signal });
        const data = await response.json() as { values?: Array<{ value: string; count: number }> };
        setOptions(response.ok ? data.values ?? [] : []);
      } catch { if (!controller.signal.aborted) setOptions([]); }
      finally { if (!controller.signal.aborted) setLoading(false); }
    }, 180);
    return () => { window.clearTimeout(timer); controller.abort(); };
  }, [clientId, field, open, query, valuesEndpoint]);

  function addMany(raw: string) {
    const result = mergeBulkValues(values, raw, kind);
    if (result.added) onChange(result.values);
    setQuery("");
  }

  function onKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    // PEOPLE-03. The list was visible and completely unreachable: no arrows, no
    // Enter-to-take-the-suggestion, no Escape. A sighted mouse user could pick
    // an option; nobody else could.
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (!visibleOptions.length) return;
      event.preventDefault();
      setOpen(true);
      setActiveIndex((current) => {
        const next = event.key === "ArrowDown" ? current + 1 : current - 1;
        // Past either end returns to "none", so the typed text is reachable
        // again rather than trapping the caret inside the suggestions.
        if (next < 0 || next >= visibleOptions.length) return -1;
        return next;
      });
      return;
    }
    if (event.key === "Escape" && open) { event.preventDefault(); setOpen(false); setActiveIndex(-1); return; }
    if (["Enter", ",", ";"].includes(event.key)) {
      event.preventDefault();
      const chosen = activeIndex >= 0 ? visibleOptions[activeIndex] : null;
      if (chosen) { onChange([...values, chosen.value]); setQuery(""); setActiveIndex(-1); return; }
      addMany(query);
      return;
    }
    if (event.key === "Backspace" && !query && values.length) onChange(values.slice(0, -1));
  }

  function onPaste(event: ClipboardEvent<HTMLInputElement>) {
    const pasted = event.clipboardData.getData("text");
    // Tabs matter: a column copied out of Excel or Google Sheets arrives tab- and
    // newline-separated, which used to paste in as one giant single value.
    if (splitPattern.test(pasted)) { event.preventDefault(); addMany(pasted); }
  }

  const selected = new Set(values.map((value) => value.toLocaleLowerCase()));
  const visibleOptions = options.filter((option) => !selected.has(option.value.toLocaleLowerCase()));
  const collapsed = values.length > chipCollapseThreshold;
  const pendingCount = mode === "bulk" ? splitPastedValues(bulkText).length : 0;
  const bulkPlaceholder = kind === "domain"
    ? "acme.com\nhttps://www.stripe.com\ncontoso.co.uk\n\nOne per line, or comma-separated. URLs are trimmed to the domain."
    : kind === "linkedin"
      ? "https://linkedin.com/in/ada-byron\nlinkedin.com/in/grace-hopper\n\nOne per line, or comma-separated."
      : kind === "email"
        ? "ada@example.com\ngrace@example.com\n\nOne per line, or comma-separated."
        : "One value per line, or comma-separated.\nPaste a whole spreadsheet column here.";

  return <div className="token-value-picker" ref={pickerRef}>
    <div className="token-mode-tabs">
      <button type="button" className={mode === "search" ? "active" : ""} onClick={() => setMode("search")}>Search</button>
      <button type="button" className={mode === "bulk" ? "active" : ""} onClick={() => openBulk(false)}>Paste list</button>
    </div>

    {mode === "bulk" ? <div className="token-bulk">
      <textarea
        aria-label={`Paste ${kind === "text" ? "values" : `${kind}s`} in bulk`}
        value={bulkText}
        onChange={(event) => { setBulkText(event.target.value); if (bulkNote) setBulkNote(""); }}
        placeholder={bulkPlaceholder}
        spellCheck={false}
      />
      <div className="token-bulk-actions">
        <button type="button" disabled={!pendingCount} onClick={() => applyBulk(false)}>
          Add {pendingCount ? pendingCount.toLocaleString("en-IN") : ""}
        </button>
        <button type="button" className="ghost" disabled={!pendingCount} onClick={() => applyBulk(true)}>Replace all</button>
        {values.length ? <button type="button" className="ghost" onClick={() => openBulk(true)}>Load current {values.length.toLocaleString("en-IN")}</button> : null}
      </div>
      <p className="token-bulk-note" role="status">{bulkNote || (pendingCount ? `${pendingCount.toLocaleString("en-IN")} value${pendingCount === 1 ? "" : "s"} ready` : `${values.length.toLocaleString("en-IN")} currently applied`)}</p>
    </div> : <>
      <div className="token-input">
        {collapsed
          ? <button type="button" className="token-summary" onClick={() => openBulk(true)}>{values.length.toLocaleString("en-IN")} values · Review</button>
          : values.map((value) => <button type="button" key={value} onClick={(event) => { event.stopPropagation(); onChange(values.filter((item) => item !== value)); }}>{value}<span><AppIcon name="close" size={14}/></span></button>)}
        <input value={query} role="combobox" aria-expanded={open} aria-controls={listId} aria-autocomplete="list" aria-activedescendant={activeIndex >= 0 ? `${listId}-option-${activeIndex}` : undefined} aria-label={placeholder} onFocus={() => setOpen(true)} onChange={(event) => { setQuery(event.target.value); setActiveIndex(-1); }} onKeyDown={onKeyDown} onPaste={onPaste} onBlur={() => { if (query.trim()) addMany(query); window.setTimeout(() => { setOpen(false); setActiveIndex(-1); }, 150); }} placeholder={values.length ? "Add another…" : placeholder}/>
      </div>
      {open ? <div className="token-options" id={listId} role="listbox" aria-multiselectable="true" aria-label={placeholder} aria-busy={loading}>
        {loading ? <p role="status">Searching all prospects…</p> : null}
        {!loading && visibleOptions.map((option, index) => (
          // The combobox keeps focus and names the active option through
          // aria-activedescendant, which is the WAI-ARIA pattern for a listbox
          // popup. These two rules assume the other pattern, where each option
          // is its own tab stop - doing that here would fight the input for
          // focus and break the arrow keys the same rules are protecting.
          // eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/interactive-supports-focus
          <div
          key={option.value}
          id={`${listId}-option-${index}`}
          role="option"
          aria-selected={index === activeIndex}
          className={index === activeIndex ? "active" : ""}
          onMouseDown={(event) => event.preventDefault()}
          onMouseEnter={() => setActiveIndex(index)}
          onClick={() => { onChange([...values, option.value]); setQuery(""); setActiveIndex(-1); }}
        ><span>{option.value}</span><small>{option.count.toLocaleString("en-IN")}</small></div>
        ))}
        {!loading && !visibleOptions.length ? <p role="status">{query.trim() ? "Press Enter to add this value." : "Type a value, or use Paste list for a whole column."}</p> : null}
      </div> : null}
    </>}
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
