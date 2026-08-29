export const requiredPersonImportFields = [
  "First Name",
  "Last Name",
  "Company Name",
  "Email",
  "Personal LinkedIn URL",
  "Job Title",
] as const;

// A company row is identifiable by either its name or its website; at least one
// of these must be mapped, but not both.
export const companyIdentityFields = ["Company Name", "Website"] as const;

// Geography is one thing, not three. A file that carries a single "Location"
// column describes a company just as well as one with city, state and country -
// which is how most exports actually ship it. Whichever arrives, the import stores
// both the composed location and any parts it was given.
export const companyGeographyFields = ["Company Location", "Company City", "Company State", "Company Country"] as const;

// The rest of the canonical company profile. Wanted on a complete dataset upload,
// but not required -- see missingCompanyImportFields.
export const companyDetailFields = [
  "#employees",
  "Industry",
  "Keywords",
  "Short Description",
  "Founded Year",
  "Technologies",
  "Total Funding",
] as const;

// Every mappable company target, for the import column picker (identity first).
export const companyImportFields = [...companyIdentityFields, ...companyGeographyFields, ...companyDetailFields] as const;

const personAliases: Record<string, string> = {
  name: "Name", fullname: "Name", firstname: "First Name", lastname: "Last Name",
  email: "Email", emailaddress: "Email", workemail: "Email", businessemail: "Email",
  personalemail: "Personal Email", mobile: "Mobile Number", mobilenumber: "Mobile Number", phone: "Mobile Number", phonenumber: "Mobile Number",
  linkedin: "Personal LinkedIn URL", linkedinurl: "Personal LinkedIn URL", personlinkedinurl: "Personal LinkedIn URL", personallinkedinurl: "Personal LinkedIn URL", linkedinprofile: "Personal LinkedIn URL",
  title: "Job Title", jobtitle: "Job Title", seniority: "Seniority", senioritylevel: "Seniority",
  department: "Departments", departments: "Departments", function: "Departments",
  subdepartment: "Sub Departments", subdepartments: "Sub Departments", subdepartmentname: "Sub Departments",
  company: "Company Name", companyname: "Company Name", casualcompanyname: "Company Name", organization: "Company Name",
  companywebsite: "Company Website", website: "Company Website", domain: "Company Website", companydomain: "Company Website",
  employees: "Company Employee Count", employeecount: "Company Employee Count", employeescount: "Company Employee Count", numberofemployees: "Company Employee Count", companyemployeecount: "Company Employee Count", companyemployees: "Company Employee Count", companyheadcount: "Company Employee Count", headcount: "Company Employee Count",
  keyword: "Keywords", keywords: "Keywords", personkeywords: "Keywords", prospectkeywords: "Keywords",
  city: "City", state: "State", country: "Country", location: "Person Location", personlocation: "Person Location",
  companylocation: "Company Location", accountlocation: "Company Location", headquarters: "Company Location", hqlocation: "Company Location",
  companycity: "Company City", accountcity: "Company City", hqcity: "Company City",
  companystate: "Company State", accountstate: "Company State", hqstate: "Company State", companyregion: "Company State",
  companycountry: "Company Country", accountcountry: "Company Country", hqcountry: "Company Country",
};

const companyAliases: Record<string, string> = {
  company: "Company Name", companyname: "Company Name", name: "Company Name", organization: "Company Name", accountname: "Company Name",
  employees: "#employees", employeecount: "#employees", employeescount: "#employees", numberofemployees: "#employees", companyemployeecount: "#employees", companyemployees: "#employees", headcount: "#employees",
  industry: "Industry", companyindustry: "Industry",
  website: "Website", domain: "Website", companywebsite: "Website", companydomain: "Website", url: "Website",
  companylocation: "Company Location", location: "Company Location", headquarters: "Company Location", hqlocation: "Company Location", accountlocation: "Company Location",
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
// only, so that uploading a partial dataset is a visible choice rather than a
// silent one. Geography stays one line, not three: a single Company Location
// column answers it just as well as separate city / state / country.
export function unmappedCompanyDetailFields(mapped: string[]) {
  const missing = missingRequiredFields(companyDetailFields, mapped);
  if (!companyGeographyFields.some((field) => mapped.includes(field))) {
    missing.unshift("Company Location (or Company City / State / Country)");
  }
  return missing;
}
