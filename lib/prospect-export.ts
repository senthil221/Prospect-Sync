import { csvCell, csvDocument } from "./csv.ts";
import { buildCustomFieldDefinitions, customFieldValue } from "./prospect-fields.ts";

// A prospect row as returned by the workspace/export SQL functions (to_jsonb of prospect_index).
export type ProspectRow = Record<string, unknown>;

export function arrayText(value: unknown) {
  return Array.isArray(value) ? value.map((item) => String(item ?? "").trim()).filter(Boolean).join(" | ") : "";
}

export function tagsText(value: unknown) {
  if (!Array.isArray(value)) return "";
  return value.map((tag) => tag && typeof tag === "object" ? String((tag as ProspectRow).name ?? "") : String(tag ?? "")).filter(Boolean).join(" | ");
}

export function allData(value: unknown): ProspectRow {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as ProspectRow;
  if (typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as ProspectRow : {};
  } catch {
    return {};
  }
}

export function exportValue(value: unknown) {
  if (value == null) return "";
  if (Array.isArray(value)) return value.map((item) => typeof item === "object" ? JSON.stringify(item) : String(item)).join(" | ");
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function websiteUrl(value: unknown) {
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

export const standardExportColumns: Array<{ id: string; header: string; value: (row: ProspectRow) => unknown }> = [
  { id: "__name", header: "Full Name", value: (row) => row.full_name },
  { id: "__first_name", header: "First Name", value: (row) => row.first_name },
  { id: "__last_name", header: "Last Name", value: (row) => row.last_name },
  { id: "__work_email", header: "Work Email", value: (row) => row.work_email },
  { id: "__personal_email", header: "Personal Email", value: (row) => row.personal_email },
  { id: "__mobile_number", header: "Mobile Number", value: (row) => row.mobile_number },
  { id: "__linkedin", header: "LinkedIn", value: (row) => row.linkedin_url },
  { id: "__title", header: "Title", value: (row) => row.title },
  { id: "__keywords", header: "Keywords", value: (row) => arrayText(row.keywords) },
  { id: "__seniority", header: "Seniority", value: (row) => row.seniority },
  { id: "__department", header: "Department", value: (row) => row.department },
  // Derived from the job title by the classifier, alongside (never replacing) the
  // Seniority/Department columns the file was imported with.
  { id: "__title_seniority_tier", header: "Seniority Tier (from title)", value: (row) => row.title_seniority },
  { id: "__title_department", header: "Department (from title)", value: (row) => row.title_department },
  { id: "__title_sub_department", header: "Sub-department (from title)", value: (row) => row.title_sub_department },
  { id: "__city", header: "City", value: (row) => row.city },
  { id: "__state", header: "State", value: (row) => row.state },
  { id: "__country", header: "Country", value: (row) => row.country },
  // Stored location wins; the parts remain the fallback for rows indexed before
  // prospects.location existed.
  { id: "__person_location", header: "Person Location", value: (row) => String(row.location ?? "").trim() || [row.city, row.state, row.country].filter(Boolean).join(", ") },
  { id: "__company", header: "Company", value: (row) => row.company_name },
  { id: "__website", header: "Website", value: (row) => websiteUrl(row.company_domain) },
  { id: "__employee_count", header: "# Employees", value: employeeCountText },
  { id: "__employee_count_min", header: "Employee Count Min", value: (row) => row.employee_count_min },
  { id: "__employee_count_max", header: "Employee Count Max", value: (row) => row.employee_count_max },
  { id: "__company_location", header: "Company Location", value: (row) => row.company_location },
  { id: "__company_city", header: "Company City", value: (row) => row.company_city },
  { id: "__company_state", header: "Company State", value: (row) => row.company_state },
  { id: "__company_country", header: "Company Country", value: (row) => row.company_country },
  { id: "__esp", header: "ESP", value: (row) => row.esp },
  { id: "__email_provider_type", header: "Email Provider Type", value: (row) => row.email_provider_type },
  { id: "__mx_records", header: "MX Records", value: (row) => arrayText(row.mx_records) },
  { id: "__mx_status", header: "MX Status", value: (row) => row.mx_status },
  { id: "__mx_checked_at", header: "MX Checked At", value: (row) => row.mx_checked_at },
  { id: "__lists", header: "List Names", value: (row) => arrayText(row.list_names) },
  { id: "__clients", header: "Client Names", value: (row) => arrayText(row.client_names) },
  { id: "__tags", header: "Tags", value: (row) => tagsText(row.tags) },
  { id: "__last_contacted", header: "Last Contacted", value: (row) => row.last_contacted_at },
  { id: "__created_at", header: "Created At", value: (row) => row.created_at },
  { id: "__updated_at", header: "Updated At", value: (row) => row.updated_at },
];

export const standardExportFieldIds = standardExportColumns.map((column) => column.id);

function normalizedHeader(value: string) {
  return value.trim().toLocaleLowerCase().replace(/[^a-z0-9]+/g, "");
}

export type ExportColumn = { header: string; value: (row: ProspectRow) => string };

// Resolve the ordered export columns for a set of available custom fields and the
// requested field ids (undefined = every field). Shared by the server endpoint and
// the client-side export runner so headers/values never drift.
export function buildExportColumns(fields: string[], requestedFields?: string[]): ExportColumn[] {
  const selected = requestedFields ? new Set(requestedFields) : null;
  const standard = standardExportColumns.filter((column) => !selected || selected.has(column.id));
  const standardHeaders = new Set(standardExportColumns.map((column) => normalizedHeader(column.header)));
  const custom = buildCustomFieldDefinitions(fields)
    .filter((field) => !selected || selected.has(field.id))
    .map((field) => {
      const normalized = field.id.slice(7);
      const header = standardHeaders.has(normalizedHeader(field.label)) ? `${field.label} (Imported)` : field.label;
      return { header, value: (row: ProspectRow) => exportValue(customFieldValue(allData(row.all_data), normalized)) };
    });
  return [
    ...standard.map((column) => ({ header: column.header, value: (row: ProspectRow) => exportValue(column.value(row)) })),
    ...custom,
  ];
}

// Valid export field ids given the available custom fields (for request validation).
export function availableExportFieldIds(fields: string[]) {
  return new Set([...standardExportFieldIds, ...buildCustomFieldDefinitions(fields).map((field) => field.id)]);
}

// One CSV header line (cells quoted), no BOM.
export function csvHeaderLine(columns: ExportColumn[]) {
  return columns.map((column) => csvCell(column.header)).join(",");
}

// CSV body for the given rows (cells quoted, rows joined by CRLF), no header, no BOM.
export function csvRowsBody(rows: ProspectRow[], columns: ExportColumn[]) {
  return rows.map((row) => columns.map((column) => csvCell(column.value(row))).join(",")).join("\r\n");
}

// Full single-shot document (BOM + header + rows) - used by the legacy export path.
export function prospectsCsv(rows: ProspectRow[], fields: string[], requestedFields?: string[]) {
  const columns = buildExportColumns(fields, requestedFields);
  return csvDocument(columns.map((column) => column.header), rows.map((row) => columns.map((column) => column.value(row))));
}
