// The import boundary is deliberately fixed. These are the only source values
// a People import may persist; every other CSV column is ignored before it can
// reach typed columns, all_data, or the field catalogue.
export const personImportFields = [
  "First Name",
  "Last Name",
  "Job Title",
  "Email",
  "Mobile Number",
  "Personal LinkedIn URL",
  "Company Name",
  "Website",
] as const;

// People columns are optional. Row-level identity validation is separate: at
// least one usable email/LinkedIn/name+company identity still has to exist.
export const requiredPersonImportFields: readonly string[] = [];

// A company row is identifiable by either its name or its website; at least one
// of these must be mapped, but not both.
export const companyIdentityFields = ["Company Name", "Website"] as const;

export const companyGeographyFields = ["Company City", "Company State", "Company Country"] as const;

// The rest of the fixed company profile. These are advisory, not required.
export const companyDetailFields = [
  "Industry",
  "Keywords",
  "Short Description",
  "Founded Year",
  "#employees",
  ...companyGeographyFields,
  "Technologies",
  "Total Funding",
] as const;

// Every mappable company target, in the order of the approved import contract.
export const companyImportFields = [...companyIdentityFields, ...companyDetailFields] as const;

const personAliases: Record<string, string> = {
  firstname: "First Name", lastname: "Last Name",
  email: "Email", emailaddress: "Email", workemail: "Email", businessemail: "Email",
  mobile: "Mobile Number", mobilenumber: "Mobile Number", phone: "Mobile Number", phonenumber: "Mobile Number",
  linkedin: "Personal LinkedIn URL", linkedinurl: "Personal LinkedIn URL", personlinkedinurl: "Personal LinkedIn URL", personallinkedinurl: "Personal LinkedIn URL", linkedinprofile: "Personal LinkedIn URL",
  title: "Job Title", jobtitle: "Job Title",
  company: "Company Name", companyname: "Company Name", casualcompanyname: "Company Name", organization: "Company Name",
  companywebsite: "Website", website: "Website", domain: "Website", companydomain: "Website",
};

const companyAliases: Record<string, string> = {
  company: "Company Name", companyname: "Company Name", name: "Company Name", organization: "Company Name", accountname: "Company Name",
  employees: "#employees", employeecount: "#employees", employeescount: "#employees", numberofemployees: "#employees", companyemployeecount: "#employees", companyemployees: "#employees", headcount: "#employees",
  industry: "Industry", companyindustry: "Industry",
  website: "Website", domain: "Website", companywebsite: "Website", companydomain: "Website", url: "Website",
  companycity: "Company City", city: "Company City", accountcity: "Company City", hqcity: "Company City",
  companystate: "Company State", state: "Company State", accountstate: "Company State", hqstate: "Company State", companyregion: "Company State",
  companycountry: "Company Country", country: "Company Country", accountcountry: "Company Country", hqcountry: "Company Country",
  keyword: "Keywords", keywords: "Keywords", companykeywords: "Keywords",
  shortdescription: "Short Description", description: "Short Description", companydescription: "Short Description",
  foundedyear: "Founded Year", founded: "Founded Year", yearfounded: "Founded Year",
  technology: "Technologies", technologies: "Technologies", techstack: "Technologies",
  totalfunding: "Total Funding", funding: "Total Funding", totalfundingamount: "Total Funding",
};

export function normalizeImportHeader(value: string) {
  return value.toLocaleLowerCase().replace(/[^a-z0-9]/g, "");
}

export function suggestedPersonImportField(header: string) {
  return personAliases[normalizeImportHeader(header)] ?? "Auto detect";
}

export function suggestedCompanyImportField(header: string) {
  return companyAliases[normalizeImportHeader(header)] ?? "Not mapped";
}

// Sentinel a user can pick in the mapping UI to drop an unwanted column entirely
// (from the mapped fields, the preserved raw all_data, and the field catalog).
export const skipImportField = "Skip column";

export function isPersonImportField(value: unknown): value is (typeof personImportFields)[number] {
  return typeof value === "string" && (personImportFields as readonly string[]).includes(value);
}

export function isCompanyImportField(value: unknown): value is (typeof companyImportFields)[number] {
  return typeof value === "string" && (companyImportFields as readonly string[]).includes(value);
}

/** Resolve one source header only when it maps onto the fixed import contract. */
export function resolvedImportField(
  header: string,
  fieldMap: Record<string, string> | undefined,
  suggest: (header: string) => string,
  allowed: readonly string[],
) {
  const candidate = fieldMap?.[header] || suggest(header);
  return allowed.includes(candidate) ? candidate : null;
}

export function fixedImportColumns(
  headers: string[],
  fieldMap: Record<string, string> | undefined,
  suggest: (header: string) => string,
  allowed: readonly string[],
) {
  const seen = new Set<string>();
  return headers.flatMap((header, column) => {
    const field = resolvedImportField(header, fieldMap, suggest, allowed);
    if (!field || seen.has(field)) return [];
    seen.add(field);
    return [{ header, column, field }];
  });
}

export function resolvedImportFields(headers: string[], fieldMap: Record<string, string> | undefined, suggest: (header: string) => string) {
  return headers.map((header) => fieldMap?.[header] || suggest(header)).filter((field) => field !== "Auto detect" && field !== "Not mapped" && field !== skipImportField);
}

export function missingRequiredFields(required: readonly string[], mapped: string[]) {
  const present = new Set(mapped);
  return required.filter((field) => !present.has(field));
}

// A company import needs one identity column (Company Name or Website) and nothing
// else. The detail columns used to be mandatory, which made the most common real
// input -- a pasted column of names, or of domains -- impossible to import at all.
// Every merge mode is blank-safe (see 20260825020000_company_merge_modes.sql), so a
// narrow import can only add identities and fill blanks; it can never blank out a
// detail already stored against a company.
export function missingCompanyImportFields(mapped: string[]) {
  return companyIdentityFields.some((field) => mapped.includes(field)) ? [] : [companyIdentityFields.join(" or ")];
}

// What a complete profile would have carried and this import does not. Advisory
// only, so that uploading a partial dataset is a visible choice.
export function unmappedCompanyDetailFields(mapped: string[]) {
  return missingRequiredFields(companyDetailFields, mapped);
}
