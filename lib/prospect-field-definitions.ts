import { requiredPersonImportFields, skipImportField } from "./import-schema.ts";

export const canonicalImportFields = ["Auto detect", skipImportField, ...requiredPersonImportFields, "Name", "Personal Email", "Mobile Number", "Keywords", "Seniority", "Departments", "Sub Departments", "City", "State", "Country", "Person Location", "Company Website", "Company Employee Count", "Company Location", "Company City", "Company State", "Company Country"];

export const standardProspectFields = [
  { id: "__name", label: "Name" },
  { id: "__company", label: "Company Name" },
  { id: "__email", label: "Email" },
  { id: "__linkedin", label: "Personal LinkedIn URL" },
  { id: "__title", label: "Job Title" },
  { id: "__seniority", label: "Seniority" },
  { id: "__department", label: "Departments" },
  { id: "__sub_department", label: "Sub Departments" },
  { id: "__person_location", label: "Location" },
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
  { id: "__work_email", label: "Work Email" }, { id: "__personal_email", label: "Personal Email" }, { id: "__mobile_number", label: "Mobile Number" },
  { id: "__linkedin", label: "LinkedIn" }, { id: "__title", label: "Title" }, { id: "__keywords", label: "Keywords" },
  { id: "__seniority", label: "Seniority" }, { id: "__department", label: "Department" }, { id: "__city", label: "City" },
  { id: "__title_seniority_tier", label: "Seniority Tier (from title)" }, { id: "__title_department", label: "Department (from title)" }, { id: "__title_sub_department", label: "Sub-department (from title)" },
  { id: "__state", label: "State" }, { id: "__country", label: "Country" }, { id: "__person_location", label: "Person Location" },
  { id: "__company", label: "Company" }, { id: "__website", label: "Website" }, { id: "__employee_count", label: "# Employees" },
  { id: "__employee_count_min", label: "Employee Count Min" }, { id: "__employee_count_max", label: "Employee Count Max" },
  { id: "__company_location", label: "Company Location" }, { id: "__company_city", label: "Company City" }, { id: "__company_state", label: "Company State" },
  { id: "__company_country", label: "Company Country" }, { id: "__esp", label: "ESP" }, { id: "__email_provider_type", label: "Email Provider Type" },
  { id: "__mx_records", label: "MX Records" }, { id: "__mx_status", label: "MX Status" }, { id: "__mx_checked_at", label: "MX Checked At" },
  { id: "__lists", label: "List Names" }, { id: "__clients", label: "Client Names" }, { id: "__tags", label: "Tags" },
  { id: "__last_contacted", label: "Last Contacted" }, { id: "__created_at", label: "Created At" }, { id: "__updated_at", label: "Updated At" },
];

export const defaultProspectExportFields = ["__name", "__work_email", "__company", "__website", "__title", "__esp"];
