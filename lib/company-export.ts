import { arrayText, exportValue, type ExportColumn, type ProspectRow } from "./prospect-export.ts";
import { customFieldValue, normalizedFieldKey } from "./prospect-fields.ts";

// The company CSV, in one place.
//
// There are three paths to it now - the direct keyset stream, the background
// file assembled from job parts, and the picker in the Companies workspace that
// decides which columns any of it writes - and they have to agree on the
// headers, on the values, and on the bare-domain-to-URL rule. Three copies of
// that would be three copies to keep in step, which is the mistake
// search_prospect_export_v1 already made once with the filter CASE it carried
// privately.
//
// It uses the same ExportColumn shape as the prospect export, so csvHeaderLine
// and csvRowsBody render companies without knowing they are companies.

export function companyWebsiteUrl(value: unknown) {
  const domain = String(value ?? "").trim();
  if (!domain) return "";
  return /^https?:\/\//i.test(domain) ? domain : `https://${domain}`;
}

function employeeCountText(row: ProspectRow) {
  const minimum = row.employee_count_min == null ? null : Number(row.employee_count_min);
  const maximum = row.employee_count_max == null ? null : Number(row.employee_count_max);
  if (minimum == null && maximum == null) return "";
  if (minimum != null && maximum == null) return `${minimum}+`;
  return minimum === maximum ? String(minimum ?? "") : `${minimum ?? 0}-${maximum}`;
}

// Every field the picker offers, with the header it writes and the value it
// reads. `bytes` is the same kind of estimate lib/export-plan.ts carries for
// prospects: roughly what one row's cell contributes to the rendered file,
// which is what decides whether a browser can hold the download in memory.
// Description is the outlier and the reason the estimate is here at all - it
// averages about a kilobyte against twenty or thirty for everything else, so a
// checkbox that looks like any other on the picker is worth forty of them.
export type CompanyExportField = {
  id: string;
  label: string;
  header: string;
  value: (row: ProspectRow) => unknown;
  bytes: number;
};

export const companyExportFields: CompanyExportField[] = [
  { id: "__company_name", label: "Company Name", header: "Company Name", bytes: 32, value: (row) => String(row.name ?? "").trim() || String(row.domain ?? "").trim() || "Unnamed company" },
  { id: "__website", label: "Website", header: "Website", bytes: 34, value: (row) => companyWebsiteUrl(row.domain) },
  { id: "__domain", label: "Domain (bare)", header: "Domain", bytes: 26, value: (row) => row.domain },
  { id: "__industry", label: "Industry", header: "Industry", bytes: 26, value: (row) => row.industry },
  { id: "__company_keywords", label: "Keywords", header: "Keywords", bytes: 320, value: (row) => arrayText(row.keywords) },
  { id: "__short_description", label: "Description", header: "Description", bytes: 1000, value: (row) => row.short_description },
  { id: "__founded_year", label: "Founded Year", header: "Founded Year", bytes: 12, value: (row) => row.founded_year },
  { id: "__technologies", label: "Technologies", header: "Technologies", bytes: 400, value: (row) => arrayText(row.technologies) },
  { id: "__total_funding", label: "Total Funding", header: "Total Funding", bytes: 16, value: (row) => row.total_funding },
  { id: "__employee_count", label: "# Employees", header: "# Employees", bytes: 14, value: employeeCountText },
  { id: "__employee_count_min", label: "Employee Count Min", header: "Employee Count Min", bytes: 12, value: (row) => row.employee_count_min },
  { id: "__employee_count_max", label: "Employee Count Max", header: "Employee Count Max", bytes: 12, value: (row) => row.employee_count_max },
  { id: "__company_location", label: "Company Location", header: "Company Location", bytes: 40, value: (row) => row.location },
  { id: "__company_city", label: "Company City", header: "Company City", bytes: 20, value: (row) => row.city },
  { id: "__company_state", label: "Company State", header: "Company State", bytes: 20, value: (row) => row.state },
  { id: "__company_country", label: "Company Country", header: "Company Country", bytes: 20, value: (row) => row.country },
  { id: "__esp", label: "ESP", header: "ESP", bytes: 20, value: (row) => row.esp },
  { id: "__email_provider_type", label: "Email Provider Type", header: "Email Provider Type", bytes: 22, value: (row) => row.email_provider_type },
  { id: "__mx_records", label: "MX Records", header: "MX Records", bytes: 60, value: (row) => arrayText(row.mx_records) },
  { id: "__mx_status", label: "MX Status", header: "MX Status", bytes: 14, value: (row) => row.mx_status },
  { id: "__mx_checked_at", label: "MX Checked At", header: "MX Checked At", bytes: 34, value: (row) => row.mx_checked_at },
  { id: "__prospect_count", label: "Linked Prospects", header: "Linked Prospects", bytes: 10, value: (row) => row.prospect_count },
  { id: "__client_count", label: "Client Coverage", header: "Clients", bytes: 10, value: (row) => row.client_count },
  { id: "__created_at", label: "Added At", header: "Added At", bytes: 34, value: (row) => row.created_at },
  { id: "__updated_at", label: "Updated At", header: "Updated At", bytes: 34, value: (row) => row.updated_at },
];

// What an export writes when nobody chose. Name and Website is what the company
// file was before there was anything to choose; the three after it are the
// columns populated on nearly every row, which is what makes them a default
// rather than a preference.
export const defaultCompanyExportFields = ["__company_name", "__website", "__industry", "__employee_count", "__company_location"];

export const companyExportFieldIds = companyExportFields.map((field) => field.id);

// Uploaded keys on companies.all_data that no column above already carries.
//
// The import writes the company-scoped half of each source row into all_data,
// and most of what lands there is the same data as the typed columns under a
// different spelling - Industry, Keywords, # Employees. Offering both would be
// two checkboxes writing one value, so anything that normalizes onto a field
// above is dropped and only the genuinely extra keys become custom columns.
// "Company Name for Emails" is deliberately NOT in here. It looks like a
// duplicate of the name and is the most populated uploaded key in the database
// (17,165 companies), because it is the name with the legal suffix taken off -
// "Prudent Accounting" rather than "Prudent Accounting LLC". That is the one a
// campaign greets somebody with, so it is a column worth having, not a repeat.
const canonicalCompanyKeys = new Set([
  "company", "company name", "name",
  "website", "company website", "company url", "domain", "company domain", "url",
  "industry", "company industry",
  "keyword", "keywords", "company keywords",
  "short description", "description", "company description",
  "founded year", "founded",
  "technologies", "tech stack",
  "total funding", "funding",
  "employees", "employee count", "employees count", "number of employees", "headcount", "company employee count", "company employees",
  "company location", "location", "headquarters", "hq location", "account location",
  "company city", "city", "company state", "state", "company region", "company country", "country",
  "esp", "email provider type", "mx records", "mx status", "mx checked at",
  "prospect count", "client count", "created at", "updated at",
].map((key) => normalizedFieldKey(key)));

function fieldLabel(field: string) {
  return field.trim().replace(/[_-]+/g, " ").replace(/\s+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function buildCompanyCustomFields(fieldNames: string[]) {
  const groups = new Map<string, string[]>();
  fieldNames.forEach((field) => {
    const clean = field.trim();
    const normalized = normalizedFieldKey(clean);
    // A leading underscore marks the product's own bookkeeping rather than
    // anything an import brought: the fill-from-company enrichment stamps
    // _enriched_from and _enriched_at onto every row it touches. Tested on the
    // raw key, because normalizedFieldKey strips the underscore that says so.
    if (!clean || clean.startsWith("_") || !normalized || canonicalCompanyKeys.has(normalized)) return;
    const current = groups.get(normalized) ?? [];
    if (!current.some((value) => value.toLocaleLowerCase() === clean.toLocaleLowerCase())) current.push(clean);
    groups.set(normalized, current);
  });
  return [...groups.entries()]
    .map(([normalized, sourceFields]) => ({ id: `custom:${normalized}`, label: fieldLabel(sourceFields[0]), sourceFields }))
    .sort((left, right) => left.label.localeCompare(right.label));
}

// all_data arrives as jsonb from the database and as a string from anything
// that has been through JSON.stringify on the way; both shapes have turned up.
export function companyAllData(value: unknown): ProspectRow {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as ProspectRow;
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as ProspectRow : {};
  } catch {
    return {};
  }
}

// Resolve the ordered export columns for a set of available custom fields and
// the requested field ids (empty = the default set). Shared by the stream, the
// background download and the picker, so headers and values never drift.
export function buildCompanyExportColumns(customFieldNames: string[] = [], requestedFields?: string[]): ExportColumn[] {
  const selected = new Set(requestedFields?.length ? requestedFields : defaultCompanyExportFields);
  const standard = companyExportFields
    .filter((field) => selected.has(field.id))
    .map((field) => ({ header: field.header, value: (row: ProspectRow) => exportValue(field.value(row)) }));
  const custom = buildCompanyCustomFields(customFieldNames)
    .filter((field) => selected.has(field.id))
    .map((field) => {
      const normalized = field.id.slice(7);
      return { header: field.label, value: (row: ProspectRow) => exportValue(customFieldValue(companyAllData(row.all_data), normalized)) };
    });
  return [...standard, ...custom];
}

// Valid export field ids given the available custom fields (for request validation).
export function availableCompanyExportFieldIds(customFieldNames: string[] = []) {
  return new Set([...companyExportFieldIds, ...buildCompanyCustomFields(customFieldNames).map((field) => field.id)]);
}

// The row keys an export actually reads, discovered by running the renderer -
// the same trick lib/prospect-export.ts uses, and for the same reason. A second
// table mapping field ids to companies columns would be a second thing to keep
// in step, and the copies in this repository have drifted before. A column that
// starts reading a new field is covered the moment it is written.
//
// id is always included: it is half the keyset cursor and appears in no column.
export function companyExportRowKeys(customFieldNames: string[] = [], requestedFields?: string[]) {
  const keys = new Set<string>(["id"]);
  const probe = new Proxy({}, {
    get(_target, key) {
      if (typeof key === "string") keys.add(key);
      return undefined;
    },
  }) as ProspectRow;
  for (const column of buildCompanyExportColumns(customFieldNames, requestedFields)) column.value(probe);
  return [...keys].sort();
}

// Roughly what one company row costs in the rendered file. The company export
// streams, so this is not about the server: it is what decides whether the
// browser is being asked to hold the whole download in memory, which is the
// real limit on the direct path when the File System Access API is missing.
export function estimatedCompanyBytesPerRow(customFieldNames: string[] = [], requestedFields?: string[]) {
  const selected = new Set(requestedFields?.length ? requestedFields : defaultCompanyExportFields);
  const standard = companyExportFields.filter((field) => selected.has(field.id)).reduce((total, field) => total + field.bytes, 0);
  const custom = buildCompanyCustomFields(customFieldNames).filter((field) => selected.has(field.id)).length * 48;
  return standard + custom;
}

// The default column set, for the paths that were never given a choice: a
// background job recorded before the picker existed, and any caller with no
// field list to hand.
export const companyExportColumns: ExportColumn[] = buildCompanyExportColumns([], defaultCompanyExportFields);

// What the default query has to return. Derived, like everything else here.
export const companyExportKeys = companyExportRowKeys([], defaultCompanyExportFields);
