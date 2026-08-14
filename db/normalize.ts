export type CanonicalProspect = {
  firstName: string;
  lastName: string;
  fullName: string;
  workEmail: string;
  personalEmail: string;
  mobileNumber: string;
  linkedinUrl: string;
  title: string;
  keywords: string[];
  seniority: string;
  department: string;
  city: string;
  state: string;
  country: string;
  companyName: string;
  companyDomain: string;
  companyEmployeeCountMin: number | null;
  companyEmployeeCountMax: number | null;
  companyLocation: string;
  companyCity: string;
  companyState: string;
  companyCountry: string;
  raw: Record<string, string>;
  identifiers: Array<{ type: string; value: string }>;
};

const clean = (value: unknown) => String(value ?? "").trim();
const key = (value: string) => value.toLowerCase().replace(/[^a-z0-9]/g, "");

export function normalizeText(value: string) {
  return clean(value).toLowerCase().replace(/\s+/g, " ");
}

export function normalizeDomain(value: string) {
  const candidate = clean(value).toLowerCase();
  if (!candidate) return "";
  try {
    const withProtocol = candidate.includes("://") ? candidate : `https://${candidate}`;
    return new URL(withProtocol).hostname.replace(/^www\./, "").replace(/\.$/, "");
  } catch {
    return candidate.replace(/^https?:\/\//, "").replace(/^www\./, "").split(/[/?#]/)[0];
  }
}

export function normalizeLinkedin(value: string) {
  return clean(value).toLowerCase().split(/[?#]/)[0].replace(/\/$/, "");
}

function findValue(raw: Record<string, string>, aliases: string[]) {
  const aliasKeys = new Set(aliases.map(key));
  for (const [header, value] of Object.entries(raw)) {
    if (aliasKeys.has(key(header)) && clean(value)) return clean(value);
  }
  return "";
}

function findWorkEmail(raw: Record<string, string>) {
  const preferred = findValue(raw, ["work email", "business email", "company email", "email address"]);
  if (preferred) return preferred;
  for (const [header, value] of Object.entries(raw)) {
    const normalized = key(header);
    if ((normalized === "email" || /^email\d+$/.test(normalized)) && clean(value)) return clean(value);
  }
  return "";
}

function parseKeywords(value: string) {
  const seen = new Set<string>();
  return value.split(/[,;|]/).map(clean).filter((item) => {
    const normalized = item.toLocaleLowerCase();
    if (!normalized || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  });
}

export function parseEmployeeCount(value: string): { min: number | null; max: number | null } {
  const normalized = clean(value).toLocaleLowerCase();
  if (!normalized || ["unknown", "n/a", "na", "none", "null", "-"].includes(normalized)) return { min: null, max: null };
  const numbers = [...normalized.matchAll(/\d[\d,]*/g)].map((match) => Number(match[0].replaceAll(",", ""))).filter(Number.isFinite);
  if (!numbers.length) return { min: null, max: null };
  if (normalized.includes("+") || /(?:more|over|above)/.test(normalized)) return { min: numbers[0], max: null };
  if (numbers.length > 1) return { min: Math.min(numbers[0], numbers[1]), max: Math.max(numbers[0], numbers[1]) };
  return { min: numbers[0], max: numbers[0] };
}

export function mapProspect(headers: string[], values: string[]): CanonicalProspect {
  const raw: Record<string, string> = {};
  headers.forEach((header, index) => { raw[header] = clean(values[index]); });

  const firstName = findValue(raw, ["first name", "firstname", "given name"]);
  const lastName = findValue(raw, ["last name", "lastname", "surname", "family name"]);
  const suppliedFullName = findValue(raw, ["full name", "fullname", "name"]);
  const fullName = suppliedFullName || [firstName, lastName].filter(Boolean).join(" ");
  const workEmail = findWorkEmail(raw).toLowerCase();
  const personalEmail = findValue(raw, ["personal email", "personalemail"]).toLowerCase();
  const linkedinUrl = normalizeLinkedin(findValue(raw, ["linkedin", "linkedin url", "linkedin profile", "linkedinurl", "personal linkedin url", "person linkedin url"]));
  const companyName = findValue(raw, ["casual company name", "company name", "company", "organization"]);
  const companyDomain = normalizeDomain(findValue(raw, ["company website", "website", "company domain", "domain", "companywebsite"]));
  const employeeCount = parseEmployeeCount(findValue(raw, ["# employees", "number of employees", "employee count", "employees count", "employees", "company employee count", "company employees", "company headcount", "headcount"]));
  const identifiers: Array<{ type: string; value: string }> = [];
  if (workEmail) identifiers.push({ type: "work_email", value: workEmail });
  if (personalEmail) identifiers.push({ type: "personal_email", value: personalEmail });
  if (linkedinUrl) identifiers.push({ type: "linkedin", value: linkedinUrl });
  if (fullName && companyDomain) identifiers.push({ type: "name_company", value: `${normalizeText(fullName)}|${companyDomain}` });
  // Fallback identity when there is no email/LinkedIn/domain: full name + company name.
  // Matching still prefers email/LinkedIn (see the ordering in import_prospect_batch),
  // so this only ever links rows that share no stronger signal.
  if (fullName && companyName) identifiers.push({ type: "name_company_name", value: `${normalizeText(fullName)}|${normalizeText(companyName)}` });

  return {
    firstName,
    lastName,
    fullName,
    workEmail,
    personalEmail,
    mobileNumber: findValue(raw, ["mobile number", "mobile", "phone", "phone number"]),
    linkedinUrl,
    title: findValue(raw, ["title", "job title", "jobtitle"]),
    keywords: parseKeywords(findValue(raw, ["keywords", "keyword", "person keywords", "prospect keywords"])),
    seniority: findValue(raw, ["seniority", "seniority level"]),
    department: findValue(raw, ["department", "departments", "function"]),
    city: findValue(raw, ["city"]),
    state: findValue(raw, ["state", "region"]),
    country: findValue(raw, ["country"]),
    companyName,
    companyDomain,
    companyEmployeeCountMin: employeeCount.min,
    companyEmployeeCountMax: employeeCount.max,
    companyLocation: findValue(raw, ["company location", "account location", "headquarters", "hq location"]),
    companyCity: findValue(raw, ["company city", "account city", "hq city"]),
    companyState: findValue(raw, ["company state", "account state", "hq state", "company region"]),
    companyCountry: findValue(raw, ["company country", "account country", "hq country"]),
    raw,
    identifiers,
  };
}

export function mergeRaw(existing: string | null, incoming: Record<string, string>) {
  let current: Record<string, string> = {};
  try { current = JSON.parse(existing || "{}"); } catch { current = {}; }
  for (const [field, value] of Object.entries(incoming)) {
    if ((!current[field] || !String(current[field]).trim()) && value) current[field] = value;
  }
  return current;
}
