export const requiredPersonImportFields = [
  "Name",
  "Company Name",
  "Email",
  "Personal LinkedIn URL",
  "Job Title",
  "Seniority",
  "Departments",
  "Sub Departments",
] as const;

export const requiredCompanyImportFields = [
  "Company Name",
  "#employees",
  "Industry",
  "Website",
  "Company City",
  "Company State",
  "Company Country",
  "Keywords",
  "Short Description",
  "Founded Year",
  "Technologies",
  "Total Funding",
] as const;

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

export function resolvedImportFields(headers: string[], fieldMap: Record<string, string> | undefined, suggest: (header: string) => string) {
  return headers.map((header) => fieldMap?.[header] || suggest(header)).filter((field) => field !== "Auto detect" && field !== "Not mapped");
}

export function missingRequiredFields(required: readonly string[], mapped: string[]) {
  const present = new Set(mapped);
  return required.filter((field) => !present.has(field));
}
