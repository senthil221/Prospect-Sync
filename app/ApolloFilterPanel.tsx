"use client";

import { ClipboardEvent, KeyboardEvent, useEffect, useRef, useId, useState } from "react";
import { bulkFieldKind, describeBulkMerge, describeMatchMode, mergeBulkValues, splitPastedValues, switchesToExactMatch } from "../lib/bulk-values";
import type { ProspectFieldDefinition } from "../lib/prospect-fields";
import type { CompanyKeywordScope, ProspectFilter, ProspectFilterOperator } from "../lib/types";
import { useDismiss } from "./use-dismiss";
import { AppIcon } from "./components/DashboardUi";
import Tabs from "./components/Tabs";
import { emptyTaxonomy, orderedDepartments, orderedTiers, tierLabel, type TitleTaxonomy } from "../lib/title-taxonomy";
import { useClientIcps } from "./components/use-client-icps";
import { useClientLists } from "./components/use-client-lists";

export type { ProspectFilter, ProspectFilterOperator } from "../lib/types";

type FilterDefinition = ProspectFieldDefinition & {
  kind?: "text" | "employee" | "tiers" | "departments" | "year" | "funding" | "company_keywords";
  advanced?: boolean;
  description?: string;
  /** Which value endpoint autocompletes this field. Company fields ask the company one. */
  valuesEndpoint?: string;
};

// The company filters below are company data, so their suggestions come from
// public.companies, not from prospect_index. Leaving this off made the Companies
// panel scan 674k prospect rows per keystroke to return nothing, which is
// recorded at the CompanyKeywordFilter it broke; the same trap is here.
const COMPANY_VALUES_ENDPOINT = "/api/companies/filter-values";

// Only the mandatory person fields are offered as filters. Industry (and any other
// kept field) arrives through the whitelisted custom fields in "MORE FILTERS".
const mainFilters: FilterDefinition[] = [
  { id: "__name", label: "Name" },
  { id: "__company", label: "Company Name" },
  { id: "__email", label: "Email" },
  { id: "__linkedin", label: "Personal LinkedIn URL" },
  { id: "__title_seniority", label: "Job Title & Seniority", description: "Matches either the job title or the seniority." },
  { id: "__esp_type", label: "ESP", description: "Matches the ESP or the email provider type (e.g. SEG)." },
];

// Derived from the job title by the deterministic classifier, not from the uploaded
// Seniority/Departments columns -- so they are consistent across data sources even
// when the file's own columns are blank or use a different vocabulary.
// Pickers rather than value boxes. These three fields were filterable and
// unusable at the same time: the value endpoint returns nothing for them, so
// using one meant knowing to type "senior_ic" or "Demand Gen & Performance"
// exactly. The taxonomy is a closed list, which is precisely the case a list of
// checkboxes with counts serves better than free text.
//
// Sub-department has no section of its own any more. It is not a thing anyone
// filters on alone - the spec is explicit that a blank sub means "department
// known, slice unknown", so a sub filter without its department silently drops
// every generic title - so it lives nested under its department, which is also
// the only place it makes sense to read.
const classifierFilters: FilterDefinition[] = [
  { id: "__title_seniority_tier", label: "Management Level", kind: "tiers", description: "The seniority the classifier read from the job title." },
  { id: "__title_department", label: "Departments & Job Function", kind: "departments", description: "The department the classifier read from the job title. Expand one to narrow it further." },
];

// Person geography and uploaded department values are retired. Department and
// seniority remain available through the generated title classification above.
//
// Tags are the one thing that belongs here: applied inside the workspace rather
// than imported, so they sit with the kept custom fields rather than the mandatory
// person fields. The value picker lists the tags that actually exist, which is the
// whole point of having tagged a selection.
//
// It matches on the tag NAME (pi.tag_text), which is why the picker had to be
// taught to offer the names that can match: until 20260916140000 it listed only
// agency-wide tags, so inside a client workspace it opened empty even though
// every ICP tag the client had applied was matchable. Filtering by ICP exactly
// - by id, rename-proof - is the Client ICP section further down, and the
// picker beside the client tabs.
const optionalFilters: FilterDefinition[] = [
  { id: "__tags", label: "Tags", description: "Matches an ICP tag by name. Use the Client ICP filter to pick one exactly." },
];

// The company profile, filterable from the People database.
//
// These are the SAME six keys the People export has offered since 20260910090000
// (lib/prospect-export.ts) plus the two that prospect_index already carried, so
// a column you can export is now a column you can filter on, under one name.
//
// None of them live on prospect_index. The compiler reads public.companies
// through company_id, which is why adding eight filters cost no storage and no
// backfill - see 20260916090000 for the measured plans and for the 1.7 GB of
// duplication the alternative would have added.
const companyFilters: FilterDefinition[] = [
  { id: "__company_industry", label: "Industry", valuesEndpoint: COMPANY_VALUES_ENDPOINT },
  // One control over name, keywords and description, with the tick boxes - the
  // same one the Companies rail has had since 20260825124148, rendered from the
  // same component so the two rails cannot answer the same question differently.
  //
  // __company_description is deliberately NOT offered any more: it was this
  // filter's third tick box all along, and having both meant "companies that do
  // X" was two filters that could not be OR-ed. It is not deleted - it still
  // compiles and still matches, so a saved view built on it keeps working. Same
  // treatment the retired export columns got.
  { id: "__company_keywords", label: "Company Keywords", kind: "company_keywords", valuesEndpoint: COMPANY_VALUES_ENDPOINT, description: "Searches company names, keywords and descriptions together. Untick description to narrow it." },
  { id: "__employee_count", label: "# Employees", kind: "employee" },
  // Suggestions for this one come from the PEOPLE endpoint on purpose: the
  // predicate reads the company location carried on prospect_index, so the list
  // offered is exactly the list that can match.
  { id: "__company_location", label: "Company Location", description: "One field for the company's city, state and country - e.g. “London”, “California”, “India”." },
  { id: "__company_founded_year", label: "Founded Year", kind: "year" },
  { id: "__company_technologies", label: "Technologies", valuesEndpoint: COMPANY_VALUES_ENDPOINT },
  { id: "__company_total_funding", label: "Total Funding", kind: "funding", description: "Ranges over the funding amount. Most companies carry no funding figure, so Not known is by far the largest group." },
];

// Shared with the Companies panel, which imports them from here. Both rails have
// to offer the same bands or "51-100 employees" would mean two different things
// depending on which database you asked.
export const employeeRanges = [
  ["1:10", "1–10"], ["11:20", "11–20"], ["21:50", "21–50"], ["51:100", "51–100"],
  ["101:200", "101–200"], ["201:500", "201–500"], ["501:1000", "501–1,000"],
  ["1001:2000", "1,001–2,000"], ["2001:5000", "2,001–5,000"],
  ["5001:10000", "5,001–10,000"], ["10001:", "10,001+"],
] as const;

export const foundedYearRanges = [
  ["2020:", "2020 or later"], ["2010:2019", "2010–2019"], ["2000:2009", "2000–2009"],
  ["1990:1999", "1990–1999"], ["1980:1989", "1980–1989"], ["0:1979", "Before 1980"],
] as const;

// Funding bands, in whole dollars because that is how the column stores it.
//
// Ranges are non-overlapping and the top one is open-ended: production's
// maximum is 178 billion, which no closed band should have to anticipate.
// Bounds above 2,147,483,647 are why the funding filter parses its own bigint
// bounds rather than sharing the integer ones - see 20260915090000.
export const fundingRanges = [
  ["0:1000000", "Up to $1M"], ["1000001:5000000", "$1M – $5M"],
  ["5000001:10000000", "$5M – $10M"], ["10000001:50000000", "$10M – $50M"],
  ["50000001:100000000", "$50M – $100M"], ["100000001:500000000", "$100M – $500M"],
  ["500000001:", "$500M+"],
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
  if (field === "__icp_verified" || field === "__company_icp_verified") return "ICP verification";
  if (field === "__client_ids" || field === "__company_client_ids") return "Client";
  // A set of company ids, applied by a button rather than typed. The values are
  // opaque, so the label has to carry the whole meaning.
  if (field === "__company_ids") return "Selected companies";
  if (field === "__client_tags" || field === "__company_tags") return "Client ICP";
  if (field === "__list_ids") return "Lists";
  if (field === "__lead") return "Lead";
  if (field === "__contactable") return "Contactable";
  return [...mainFilters, ...classifierFilters, ...companyFilters, ...optionalFilters, ...customFields].find((definition) => definition.id === field)?.label ?? field;
}

export default function ApolloFilterPanel({ filters, customFields, clientId, clients = [], onChange }: {
  filters: ProspectFilter[];
  customFields: ProspectFieldDefinition[];
  clientId?: string;
  /** For the Client section. Already loaded by the dashboard, so no round trip. */
  clients?: Array<{ id: string; name: string }>;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const [search, setSearch] = useState("");
  const [expanded, setExpanded] = useState("");
  const panelRef = useRef<HTMLElement>(null);
  useDismiss(panelRef, () => setExpanded(""), Boolean(expanded));
  const normalizedSearch = search.trim().toLocaleLowerCase();
  const visibleMain = mainFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const visibleClassifier = classifierFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const visibleCompany = companyFilters.filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));
  const visibleOptional = [...optionalFilters, ...customFields].filter((item) => item.label.toLocaleLowerCase().includes(normalizedSearch));

  function replaceField(field: string, replacements: ProspectFilter[]) {
    // Departments own the nested sub-department filter, so clearing the section
    // has to take both; leaving a sub behind would keep narrowing the grid with
    // nothing on screen to say so.
    const owned = field === "__title_department" ? ["__title_department", "__title_sub_department"] : [field];
    onChange([...filters.filter((filter) => !owned.includes(filter.field)), ...replacements]);
  }

  // Fetched once when the panel mounts, not per keystroke: it is one grouped
  // scan of prospect_index behind the endpoint. A database that has not had the
  // migration yet answers with an empty taxonomy and the pickers say so rather
  // than rendering nothing.
  const icps = useClientIcps(clientId);
  const lists = useClientLists(clientId);
  const [taxonomy, setTaxonomy] = useState<TitleTaxonomy>(emptyTaxonomy);
  useEffect(() => {
    let current = true;
    const controller = new AbortController();
    void (async () => {
      try {
        const response = await fetch(`/api/prospects/title-taxonomy${clientId ? `?clientId=${encodeURIComponent(clientId)}` : ""}`, { signal: controller.signal });
        const data = await response.json() as { taxonomy?: TitleTaxonomy };
        if (current && response.ok && data.taxonomy) setTaxonomy(data.taxonomy);
      } catch { /* the pickers fall back to their empty state */ }
    })();
    return () => { current = false; controller.abort(); };
  }, [clientId]);

  function renderDefinition(definition: FilterDefinition) {
    const fieldFilters = filters.filter((filter) => filter.field === definition.id);
    // The departments section owns the nested sub-department filter, so its
    // badge counts both: three sub-departments picked under Sales is three
    // filters applied, and a section reading "1" would understate what the grid
    // is doing.
    const countedFilters = definition.kind === "departments"
      ? filters.filter((filter) => filter.field === "__title_department" || filter.field === "__title_sub_department")
      : fieldFilters;
    const count = activeCount(countedFilters);
    const isExpanded = expanded === definition.id;
    return <section className={`apollo-filter-section ${isExpanded ? "expanded" : ""}`} key={definition.id}>
      {/* The clear control is a sibling of the disclosure button rather than a
          child of it: a button inside a button is invalid markup, and the
          browser resolves it by dropping one - which is how "clear this filter"
          would end up silently expanding the section instead. */}
      <div className="apollo-filter-head">
        <button type="button" id={`filter-trigger-${definition.id}`} className="apollo-filter-summary" aria-expanded={isExpanded} aria-controls={`filter-panel-${definition.id}`} onClick={() => setExpanded(isExpanded ? "" : definition.id)}>
          <span className="apollo-filter-mark"><AppIcon name={definition.kind === "employee" || definition.kind === "year" || definition.kind === "funding" ? "hash" : "target"} size={14}/></span>
          <strong>{definition.label}</strong>
          {count ? <span className="filter-count">{count}</span> : null}
          <span className="apollo-chevron"><AppIcon name="chevron" size={14}/></span>
        </button>
        {/* Only where there is something to clear. The same action existed
            before, but only inside the expanded body - so dropping one filter
            out of six meant expanding it first, and there was no way to see
            what was applied and remove it in the same gesture. */}
        {count ? <button type="button" className="apollo-filter-clear" title={`Clear ${definition.label}`} aria-label={`Clear the ${definition.label} filter`} onClick={() => replaceField(definition.id, [])}><AppIcon name="close" size={12}/></button> : null}
      </div>
      {isExpanded ? <div id={`filter-panel-${definition.id}`} role="region" aria-labelledby={`filter-trigger-${definition.id}`} className="apollo-filter-content">
        {definition.description ? <p className="apollo-filter-description">{definition.description}</p> : null}
        {definition.kind === "tiers"
          ? <ManagementLevelFilter filters={fieldFilters} taxonomy={taxonomy} onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "departments"
          ? <DepartmentFunctionFilter filters={filters} taxonomy={taxonomy} onChange={onChange} />
          : definition.kind === "employee"
          ? <RangeFilter field={definition.id} filters={fieldFilters} presets={employeeRanges} unknownLabel="# of employees is unknown" onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "year"
          ? <RangeFilter field={definition.id} filters={fieldFilters} presets={foundedYearRanges} unknownLabel="Founded year is unknown" minPlaceholder="e.g. 2005" maxPlaceholder="e.g. 2015" onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "funding"
          ? <RangeFilter field={definition.id} filters={fieldFilters} presets={fundingRanges} unknownLabel="Funding is not known" minPlaceholder="e.g. 1000000" maxPlaceholder="No maximum" onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "company_keywords"
          ? <CompanyKeywordFilter key={fieldFilters.map((filter) => filter.scopes?.join("|") ?? "default").join(";") || "default"} filters={fieldFilters} defaultScopes={["keywords"]} onChange={(next) => replaceField(definition.id, next)} />
          : definition.kind === "text" && definition.advanced
            ? <TextBooleanFilter key={fieldFilters.map((filter) => `${filter.id}:${filter.values.join("|")}`).join(";")} definition={definition} filters={fieldFilters} clientId={clientId} valuesEndpoint={definition.valuesEndpoint} onChange={(next) => replaceField(definition.id, next)} />
            : <IncludeExcludeFilter field={definition.id} filters={fieldFilters} clientId={clientId} valuesEndpoint={definition.valuesEndpoint} onChange={(next) => replaceField(definition.id, next)} />}
        {count ? <button type="button" className="clear-section-filter" onClick={() => replaceField(definition.id, [])}>Clear {definition.label}</button> : null}
      </div> : null}
    </section>;
  }

  const totalActive = activeCount(filters);
  const fieldsInUse = new Set(filters.map((filter) => filter.field)).size;

  return <aside ref={panelRef} className="panel filter-panel apollo-filter-panel">
    <div className="filter-panel-head"><div><span className="filter-icon"><AppIcon name="filter" size={16}/></span><div><strong>Filters</strong><small>{fieldsInUse ? `${fieldsInUse} filter${fieldsInUse === 1 ? "" : "s"} applied` : "Narrow the database"}</small></div></div>{fieldsInUse ? <button title="Remove every applied filter" onClick={() => onChange([])}>Clear all {fieldsInUse}</button> : null}</div>
    <label className="filter-panel-search"><span><AppIcon name="search" size={14}/></span><input aria-label="Search filters" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search all filters…"/></label>
    <div className="apollo-filter-scroll">
      {visibleMain.length ? <div className="apollo-filter-group"><small>Main filters</small>{visibleMain.map(renderDefinition)}</div> : null}
      {visibleClassifier.length ? <div className="apollo-filter-group"><small>From job title</small>{visibleClassifier.map(renderDefinition)}</div> : null}
      {/* The person's company, filtered from the People database. Its own group
          rather than folded into "More filters": every field in it is a fact
          about the company, and reading them together is how anyone builds an
          ICP. Shown in both databases - a client workspace narrows to that
          client's people first, and then still needs to narrow by company. */}
      {visibleCompany.length ? <div className="apollo-filter-group"><small>Company</small>{visibleCompany.map(renderDefinition)}</div> : null}
      {visibleOptional.length ? <div className="apollo-filter-group optional"><small>More filters</small>{visibleOptional.map(renderDefinition)}</div> : null}
      {/* Client filter only in the Master DB: inside a client workspace every
          row is already that client's, so it could only be a no-op or a
          contradiction. The ICP filter is the exact mirror — it needs a client
          to have ICPs, so it appears only inside one. */}
      {!clientId && clients.length && "client".includes(normalizedSearch) ? <div className="apollo-filter-group">
        <small>Client</small>
        <ClientMembershipFilter field="__client_ids" title="Client" noun="prospects" options={clients} filters={filters}
          expanded={expanded === "__client_ids"} onToggle={() => setExpanded(expanded === "__client_ids" ? "" : "__client_ids")}
          onChange={onChange}/>
      </div> : null}
      {clientId && icps.length && "client icp".includes(normalizedSearch) ? <div className="apollo-filter-group">
        <small>Client ICP</small>
        <ClientMembershipFilter field="__client_tags" title="Client ICP" noun="prospects" options={icps} filters={filters}
          expanded={expanded === "__client_tags"} onToggle={() => setExpanded(expanded === "__client_tags" ? "" : "__client_tags")}
          onChange={onChange}/>
      </div> : null}
      {/* Lists only inside a client workspace, for the same reason Client ICP
          is: it needs a client to have lists at all. pi.list_ids is the
          identity array (20260921100000), same shape as __client_ids. */}
      {clientId && lists.length && "lists".includes(normalizedSearch) ? <div className="apollo-filter-group">
        <small>Lists</small>
        <ClientMembershipFilter field="__list_ids" title="Lists" noun="prospects" options={lists} filters={filters}
          expanded={expanded === "__list_ids"} onToggle={() => setExpanded(expanded === "__list_ids" ? "" : "__list_ids")}
          onChange={onChange}/>
      </div> : null}
      {!visibleMain.length && !visibleClassifier.length && !visibleCompany.length && !visibleOptional.length ? <p className="filter-search-empty">No filters match “{search}”.</p> : null}
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

  function applyBoolean() {
    const query = booleanQuery.trim();
    if (!query) { setMessage("Enter a Boolean search first."); return; }
    const words = query.match(/\b(?:AND|OR|NOT)\b/gi) ?? [];
    if (!words.length && !query.includes('"')) setMessage("Tip: combine terms with AND, OR, or NOT.");
    else setMessage("");
    onChange([{ id: existingBoolean?.id ?? filterId(definition.id, "boolean"), field: definition.id, operator: "boolean", values: [query] }]);
  }

  return <>
    <Tabs variant="segmented" label={`${definition.label} search mode`} value={mode} onChange={setMode} items={[{ id: "simple", label: "Simple" }, { id: "advanced", label: "Advanced" }]}/>
    {mode === "simple"
      ? <IncludeExcludeFilter field={definition.id} filters={filters.filter((filter) => filter.operator !== "boolean")} clientId={clientId} valuesEndpoint={valuesEndpoint} onChange={onChange} />
      : <div className="boolean-search-box">
        <div className="boolean-search-title"><span className="boolean-radio"/> Boolean Search</div>
        <small>Search with Boolean operators</small>
        <textarea aria-label={`Boolean search for ${definition.label}`} value={booleanQuery} onChange={(event) => setBooleanQuery(event.target.value)} placeholder={`Enter ${definition.label.toLocaleLowerCase()} separated by AND/OR/NOT and parentheses`}/>
        <p>Examples: Sales AND “Product Design”; Sales OR Design; Sales AND NOT Design.</p>
        {message ? <span className="boolean-message">{message}</span> : null}
        <button type="button" onClick={applyBoolean}>Apply</button>
      </div>}
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
    <Tabs
      variant="segmented"
      label="Value entry method"
      value={mode}
      onChange={(next) => (next === "bulk" ? openBulk(false) : setMode("search"))}
      items={[{ id: "search", label: "Search" }, { id: "bulk", label: "Paste list" }]}
    />

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

// One range control for every banded number in the product: employees, founded
// year, funding. It used to exist twice - EmployeeFilter here and RangeFilter in
// CompanyFilterPanel, the second a generalisation of the first - and the copies
// had already drifted (only one cleared the custom inputs after applying). Both
// panels now render this one.
export function RangeFilter({ field, filters, presets, unknownLabel, minPlaceholder = "e.g. 50", maxPlaceholder = "No maximum", onChange }: {
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

// A compact count, because the number beside a checkbox is a sense of scale
// rather than a figure anyone reads exactly. 208,829 as "208.8K" keeps the rows
// the same width and the list scannable.
function compactCount(value: number) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return String(value);
}

// Every tier the classifier can assign, highest first, with how many people are
// on each. Checking several is an OR: the compiler turns a multi-value `equals`
// into an IN, which was verified against production before this was built -
// owner plus c_suite returns exactly the sum of the two.
function ManagementLevelFilter({ filters, taxonomy, onChange }: {
  filters: ProspectFilter[];
  taxonomy: TitleTaxonomy;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const selected = new Set(filters.flatMap((filter) => filter.values));
  const tiers = orderedTiers(taxonomy.tiers);

  function toggle(value: string) {
    const next = new Set(selected);
    if (next.has(value)) next.delete(value); else next.add(value);
    onChange(next.size
      ? [{ id: filterId("__title_seniority_tier", "equals"), field: "__title_seniority_tier", operator: "equals", values: [...next] }]
      : []);
  }

  if (!tiers.length) return <p className="apollo-filter-description">Management levels load once the title classifier has run.</p>;

  return <div className="taxonomy-picker" role="group" aria-label="Management level">
    {tiers.map((tier) => <label key={tier.value} className="taxonomy-option">
      <input type="checkbox" checked={selected.has(tier.value)} onChange={() => toggle(tier.value)}/>
      <span className="taxonomy-name">{tierLabel(tier.value)}</span>
      <span className="taxonomy-count">{compactCount(tier.count)}</span>
    </label>)}
  </div>;
}

// Departments, each expandable to the sub-departments it actually has.
//
// The two levels are separate filter fields rather than one nested value,
// because that is what the compiler understands - and it also gives the right
// semantics for free: checking Sales and then Inside Sales narrows to people
// whose department is Sales AND whose sub-department is Inside Sales, which is
// what the plus sign implies.
function DepartmentFunctionFilter({ filters, taxonomy, onChange }: {
  filters: ProspectFilter[];
  taxonomy: TitleTaxonomy;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const [expanded, setExpanded] = useState<string[]>([]);
  const [search, setSearch] = useState("");
  const departmentValues = new Set(filters.filter((filter) => filter.field === "__title_department").flatMap((filter) => filter.values));
  const subValues = new Set(filters.filter((filter) => filter.field === "__title_sub_department").flatMap((filter) => filter.values));

  function replace(field: string, values: Set<string>) {
    const rest = filters.filter((filter) => filter.field !== field);
    onChange(values.size
      ? [...rest, { id: filterId(field, "equals"), field, operator: "equals", values: [...values] }]
      : rest);
  }

  function toggleDepartment(name: string) {
    const next = new Set(departmentValues);
    if (next.has(name)) next.delete(name); else next.add(name);
    replace("__title_department", next);
  }

  function toggleSub(name: string) {
    const next = new Set(subValues);
    if (next.has(name)) next.delete(name); else next.add(name);
    replace("__title_sub_department", next);
  }

  const term = search.trim().toLocaleLowerCase();
  const departments = orderedDepartments(taxonomy.departments).filter((department) => !term
    || department.name.toLocaleLowerCase().includes(term)
    || department.subs.some((sub) => sub.name.toLocaleLowerCase().includes(term)));

  if (!taxonomy.departments.length) return <p className="apollo-filter-description">Departments load once the title classifier has run.</p>;

  return <div className="taxonomy-picker">
    <input className="taxonomy-search" type="search" value={search} placeholder="Search departments" aria-label="Search departments" onChange={(event) => setSearch(event.target.value)}/>
    <div role="group" aria-label="Departments and job function">
      {departments.map((department) => {
        const isOpen = expanded.includes(department.name) || Boolean(term);
        return <div key={department.name} className="taxonomy-branch">
          <label className="taxonomy-option">
            <input type="checkbox" checked={departmentValues.has(department.name)} onChange={() => toggleDepartment(department.name)}/>
            <span className="taxonomy-name">{department.name}</span>
            <span className="taxonomy-count">{compactCount(department.count)}</span>
            {department.subs.length ? <button type="button" className="taxonomy-expand" aria-expanded={isOpen}
              aria-label={`${isOpen ? "Hide" : "Show"} ${department.name} job functions`}
              onClick={(event) => { event.preventDefault(); setExpanded((current) => current.includes(department.name) ? current.filter((name) => name !== department.name) : [...current, department.name]); }}>
              {isOpen ? "−" : "+"}
            </button> : null}
          </label>
          {isOpen && department.subs.length ? <div className="taxonomy-subs">
            {department.subs.map((sub) => <label key={sub.name} className="taxonomy-option">
              <input type="checkbox" checked={subValues.has(sub.name)} onChange={() => toggleSub(sub.name)}/>
              <span className="taxonomy-name">{sub.name}</span>
              <span className="taxonomy-count">{compactCount(sub.count)}</span>
            </label>)}
          </div> : null}
        </div>;
      })}
    </div>
  </div>;
}

/**
 * Include or exclude whole clients, in either Master database.
 *
 * Shared by both panels because the two differ only in which field they write
 * — __client_ids on prospect_index, __company_client_ids on client_companies.
 * Two copies of a control with this much state in it is how the two export
 * dialogs drifted.
 *
 * WHY IDS AND NOT NAMES. The value sent is the client id; the name is only
 * rendered. Names are editable, and a saved view must not change what it
 * returns because somebody corrected a spelling. It is also what makes the
 * filter correct at all: the pre-existing __clients field compares against the
 * joined name string, so excluding one of a prospect's two clients kept 3,570
 * rows it should have removed (measured 2026-09-15; see 20260915130000).
 *
 * At most two filters are produced — one include, one exclude — each carrying a
 * list of ids, rather than one filter per client. That keeps the compiled SQL
 * to a single predicate per direction however many clients are picked.
 */
export function ClientMembershipFilter({ field, title, noun, options, filters, expanded, onToggle, onChange }: {
  /** __client_ids, __company_client_ids, __client_tags, __company_tags or __list_ids. */
  field: string;
  title: string;
  noun: string;
  /** Clients, or a client's ICPs — anything identified by an id, shown by name. */
  options: Array<{ id: string; name: string }>;
  filters: ProspectFilter[];
  expanded: boolean;
  onToggle: () => void;
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const includes = filters.find((filter) => filter.field === field && (filter.operator === "contains" || filter.operator === "equals"));
  const excludes = filters.find((filter) => filter.field === field && (filter.operator === "not_contains" || filter.operator === "not_equals"));
  const count = (includes?.values.length ?? 0) + (excludes?.values.length ?? 0);

  function stateOf(id: string): "include" | "exclude" | "off" {
    if (includes?.values.includes(id)) return "include";
    if (excludes?.values.includes(id)) return "exclude";
    return "off";
  }

  function set(id: string, next: "include" | "exclude" | "off") {
    // A client lands in exactly one list, never both: "include Acme and exclude
    // Acme" is a filter that can only ever return nothing.
    const include = (includes?.values ?? []).filter((value) => value !== id);
    const exclude = (excludes?.values ?? []).filter((value) => value !== id);
    if (next === "include") include.push(id);
    if (next === "exclude") exclude.push(id);
    onChange([
      ...filters.filter((filter) => filter.field !== field),
      ...(include.length ? [{ id: `${field}:include`, field, operator: "contains" as const, values: include }] : []),
      ...(exclude.length ? [{ id: `${field}:exclude`, field, operator: "not_contains" as const, values: exclude }] : []),
    ]);
  }

  return <section className={`apollo-filter-section ${expanded ? "expanded" : ""}`}>
    <button type="button" className="apollo-filter-summary" aria-expanded={expanded} onClick={onToggle}>
      <span className="apollo-filter-mark"><AppIcon name={field.endsWith("_tags") ? "tag" : "company"} size={14}/></span>
      <strong>{title}</strong>
      {count ? <span className="filter-count">{count}</span> : null}
      <span className="apollo-chevron"><AppIcon name="chevron" size={14}/></span>
    </button>
    {expanded ? <div role="region" className="apollo-filter-content">
      <p className="apollo-filter-description">
        Show only the matching {noun}, or exclude them. Excluding cannot use the index, so pair it with another filter on very large searches.
      </p>
      <div className="client-filter-list">{options.map((client) => {
        const state = stateOf(client.id);
        return <div className="client-filter-row" key={client.id}>
          <span>{client.name}</span>
          <span className="client-filter-actions">
            <button type="button" className={state === "include" ? "active" : ""} aria-pressed={state === "include"}
              onClick={() => set(client.id, state === "include" ? "off" : "include")}>Include</button>
            <button type="button" className={state === "exclude" ? "active" : ""} aria-pressed={state === "exclude"}
              onClick={() => set(client.id, state === "exclude" ? "off" : "exclude")}>Exclude</button>
          </span>
        </div>;
      })}</div>
      {count ? <button type="button" className="clear-section-filter"
        onClick={() => onChange(filters.filter((filter) => filter.field !== field))}>Clear {title.toLocaleLowerCase()} filter</button> : null}
    </div> : null}
  </section>;
}

export const companyKeywordScopeOptions: Array<{ id: CompanyKeywordScope; label: string; note?: string }> = [
  { id: "name", label: "Name" },
  { id: "keywords", label: "Keywords" },
  { id: "description", label: "Company description", note: "Broader coverage" },
];

// THE DEFAULT IS PER RAIL, AND THE REASON IS MEASURED.
//
// The Companies rail filters 418,000 companies directly and can afford to search
// descriptions by default. The People rail cannot: __company_keywords compiles to
// a correlated lookup per prospect, so searching descriptions by default means
// 683,784 company fetches each matching against a roughly one-kilobyte
// description.
//
// Measured on production 2026-09-16, same term, same data: keywords only 2.0s,
// all three scopes 2.9s standalone and about 7.6s through the workspace function
// - which straddles the 8s statement ceiling. The deployed People rail returned a
// mixture of 504 (the database timing out) and 503 (admission refusing the
// retries behind it), so the filter worked only sometimes.
//
// So People opens on keywords only, which is exactly what the field meant before
// the two filters were merged and is the same default the SQL side applies to a
// filter with no scopes key. Description is one tick away and is then a
// deliberate choice, the same as the advanced Company Description filter it
// replaced. Companies keeps all three.
export function CompanyKeywordFilter({ filters, defaultScopes = ["name", "keywords", "description"], onChange }: {
  filters: ProspectFilter[];
  /** What the tick boxes open on when the filter carries no scopes of its own. */
  defaultScopes?: CompanyKeywordScope[];
  onChange: (filters: ProspectFilter[]) => void;
}) {
  const initialScopes = filters.find((filter) => filter.scopes?.length)?.scopes ?? defaultScopes;
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
    {/* The sentence has to match the rail it is on, or it tells one of them the
        opposite of what its tick boxes are doing. */}
    <p className="company-keyword-scope-note">{defaultScopes.includes("description")
      ? "Selected fields are searched together. Description is on by default for wider coverage; untick it to return fewer, closer matches."
      : "Selected fields are searched together. Tick Company description for wider coverage - it searches every company's description, so it is slower."}</p>
    {/* Without an explicit endpoint TokenValuePicker falls back to the PEOPLE
        one, so typing here asked prospect_filter_values_v3 for a company field.
        It has no case for it, so every keystroke scanned 674k prospect_index
        rows to return nothing -- 2.4s a time, and a statement timeout under load. */}
    <TextBooleanFilter
      definition={{ id: "__company_keywords", label: "Company keywords" }}
      filters={filters}
      valuesEndpoint={COMPANY_VALUES_ENDPOINT}
      onChange={(next) => onChange(next.map((filter) => ({ ...filter, scopes })))}
    />
  </div>;
}
