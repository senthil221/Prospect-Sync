import { personImportFields, skipImportField } from "./import-schema.ts";

// No separate "Auto detect" entry: a column with no recognized alias already
// defaults to Skip column (suggestedPersonImportField), and the two behaved
// identically once selected - keeping both was a redundant second name for
// the same "nothing happens to this column" state.
export const canonicalImportFields = [skipImportField, ...personImportFields];

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

// What the People export picker offers, and nothing else.
//
// The picker used to list all 37 entries above plus every uploaded custom key,
// which made choosing columns a job of its own and made two exports of "the
// same" data rarely match. This is the agreed fixed set: eighteen fields, all
// ticked, in this order.
//
// THE COMPANY HALF MIRRORS THE COMPANIES PICKER. The ten company fields below
// are the same ten that lib/company-export.ts offers, minus Company Name and
// Website, which the person half already carries. So "Industry" means the same
// column and writes the same header whichever database the file came out of.
//
// __company_location is deliberately NOT offered even though standardExportColumns
// resolves it: it is the same place as Company City/State/Country, all three of
// which are ticked, so offering it would put the location in the file twice.
//
// ORDER MATTERS AND IS NOT FREE. buildExportColumns emits in standardExportColumns
// order, not in the order the caller asked for, so this list has to follow that
// order or the dialog and the file disagree about the columns. That is why
// # Employees comes before the industry fields here.
//
// Company Description is about a kilobyte a row against twenty or thirty for
// everything else, so a fully-ticked People export is roughly forty times heavier
// than the eight-column one was. estimatedBytesPerRow prices every field below
// (lib/export-plan.ts), so planExport sends a file that size down the background
// path instead of building it in the browser's memory.
//
// standardProspectExportFields is deliberately NOT deleted. It still resolves
// values and headers for saved views, result sets and background exports queued
// before this change, so a job that asked for Seniority or MX Status still gets
// it - those columns are just no longer offered to pick.
//
// The labels here are the picker's, not the CSV's. __work_email writes a "Work
// Email" header and is shown as "Email"; that split already existed and is kept
// so downstream sheets keyed on the old headers do not break.
export const prospectExportPickerFields = [
  { id: "__first_name", label: "First Name" },
  { id: "__last_name", label: "Last Name" },
  { id: "__title", label: "Job Title" },
  { id: "__work_email", label: "Email" },
  { id: "__mobile_number", label: "Mobile Number" },
  { id: "__linkedin", label: "Personal LinkedIn URL" },
  { id: "__company", label: "Company Name" },
  { id: "__website", label: "Website" },
  { id: "__employee_count", label: "# Employees" },
  { id: "__company_city", label: "Company City" },
  { id: "__company_state", label: "Company State" },
  { id: "__company_country", label: "Company Country" },
  { id: "__company_industry", label: "Company Industry" },
  { id: "__company_keywords", label: "Company Keywords" },
  { id: "__company_description", label: "Company Description" },
  { id: "__company_founded_year", label: "Company Founded Year" },
  { id: "__company_technologies", label: "Company Technologies" },
  { id: "__company_total_funding", label: "Company Total Funding" },
];

// Every offered field, ticked. "Recommended" and the initial state are now the
// same thing, which is the point - there is no shorter sensible subset of a
// list this size.
export const defaultProspectExportFields = prospectExportPickerFields.map((field) => field.id);
