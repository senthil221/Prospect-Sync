import { personImportFields, skipImportField } from "./import-schema.ts";

export const canonicalImportFields = ["Auto detect", skipImportField, ...personImportFields];

export const standardProspectFields = [
  { id: "__name", label: "Name" },
  { id: "__company", label: "Company Name" },
  { id: "__email", label: "Email" },
  { id: "__linkedin", label: "Personal LinkedIn URL" },
  { id: "__title", label: "Job Title" },
  { id: "__mobile_number", label: "Mobile Number" },
  { id: "__website", label: "Website" },
  // Classifier outputs, shown beside the uploaded columns rather than replacing them.
  { id: "__title_seniority_tier", label: "Seniority Tier (from title)" },
  { id: "__title_department", label: "Department (from title)" },
  { id: "__title_sub_department", label: "Sub-dept (from title)" },
  // Workspace-applied, not imported: the tags added from the bulk actions bar.
  { id: "__tags", label: "Tags" },
];

// Available in the column picker but off by default. The classifier columns sit
// beside the uploaded Seniority/Departments columns rather than replacing them, and
// showing both pairs at once makes the default table needlessly wide; Tags is empty
// for most rows until it has been used.
const optionalColumnIds = new Set(["__title_seniority_tier", "__title_department", "__title_sub_department", "__tags"]);
export const defaultProspectColumns = standardProspectFields.map((field) => field.id).filter((id) => !optionalColumnIds.has(id));
export const standardProspectExportFields = [
  { id: "__name", label: "Full Name" }, { id: "__first_name", label: "First Name" }, { id: "__last_name", label: "Last Name" },
  { id: "__work_email", label: "Email" }, { id: "__mobile_number", label: "Mobile Number" },
  { id: "__linkedin", label: "LinkedIn" }, { id: "__title", label: "Title" },
  { id: "__title_seniority_tier", label: "Seniority Tier (from title)" }, { id: "__title_department", label: "Department (from title)" }, { id: "__title_sub_department", label: "Sub-department (from title)" },
  { id: "__company", label: "Company" }, { id: "__website", label: "Website" }, { id: "__employee_count", label: "# Employees" },
  { id: "__employee_count_min", label: "Employee Count Min" }, { id: "__employee_count_max", label: "Employee Count Max" },
  { id: "__company_location", label: "Company Location" }, { id: "__company_city", label: "Company City" }, { id: "__company_state", label: "Company State" },
  { id: "__company_country", label: "Company Country" },
  { id: "__company_industry", label: "Company Industry" }, { id: "__company_keywords", label: "Company Keywords" },
  { id: "__company_description", label: "Company Description" }, { id: "__company_founded_year", label: "Company Founded Year" },
  { id: "__company_technologies", label: "Company Technologies" }, { id: "__company_total_funding", label: "Company Total Funding" },
  { id: "__esp", label: "ESP" }, { id: "__email_provider_type", label: "Email Provider Type" },
  { id: "__mx_records", label: "MX Records" }, { id: "__mx_status", label: "MX Status" }, { id: "__mx_checked_at", label: "MX Checked At" },
  { id: "__lists", label: "List Names" }, { id: "__clients", label: "Client Names" }, { id: "__tags", label: "Tags" },
  { id: "__last_contacted", label: "Last Contacted" }, { id: "__created_at", label: "Created At" }, { id: "__updated_at", label: "Updated At" },
];

export const defaultProspectExportFields = ["__name", "__work_email", "__company", "__website", "__title", "__esp"];
