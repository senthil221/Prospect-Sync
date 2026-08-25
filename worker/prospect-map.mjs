const clean = (value) => String(value ?? "").trim();
const key = (value) => value.toLowerCase().replace(/[^a-z0-9]/g, "");

export function normalizeText(value) {
  return clean(value).toLowerCase().replace(/\s+/g, " ");
}

function normalizeDomain(value) {
  const candidate = clean(value).toLowerCase();
  if (!candidate) return "";
  try {
    const withProtocol = candidate.includes("://") ? candidate : `https://${candidate}`;
    return new URL(withProtocol).hostname.replace(/^www\./, "").replace(/\.$/, "");
  } catch {
    return candidate.replace(/^https?:\/\//, "").replace(/^www\./, "").split(/[/?#]/)[0];
  }
}

function normalizeLinkedin(value) {
  return clean(value).toLowerCase().split(/[?#]/)[0].replace(/\/$/, "");
}

function findValue(raw, aliases) {
  const aliasKeys = new Set(aliases.map(key));
  for (const [header, value] of Object.entries(raw)) {
    if (aliasKeys.has(key(header)) && clean(value)) return clean(value);
  }
  return "";
}

function findWorkEmail(raw) {
  const preferred = findValue(raw, ["work email", "business email", "company email", "email address"]);
  if (preferred) return preferred;
  for (const [header, value] of Object.entries(raw)) {
    const normalized = key(header);
    if ((normalized === "email" || /^email\d+$/.test(normalized)) && clean(value)) return clean(value);
  }
  return "";
}

function parseKeywords(value) {
  const seen = new Set();
  return value.split(/[,;|]/).map(clean).filter((item) => {
    const normalized = item.toLocaleLowerCase();
    if (!normalized || seen.has(normalized)) return false;
    seen.add(normalized);
    return true;
  });
}

function parseEmployeeCount(value) {
  const normalized = clean(value).toLocaleLowerCase();
  if (!normalized || ["unknown", "n/a", "na", "none", "null", "-"].includes(normalized)) return { min: null, max: null };
  const numbers = [...normalized.matchAll(/\d[\d,]*/g)].map((match) => Number(match[0].replaceAll(",", ""))).filter(Number.isFinite);
  if (!numbers.length) return { min: null, max: null };
  if (normalized.includes("+") || /(?:more|over|above)/.test(normalized)) return { min: numbers[0], max: null };
  if (numbers.length > 1) return { min: Math.min(numbers[0], numbers[1]), max: Math.max(numbers[0], numbers[1]) };
  return { min: numbers[0], max: numbers[0] };
}

export function mapProspect(headers, values) {
  const raw = {};
  headers.forEach((header, index) => { raw[header] = clean(values[index]); });
  const firstName = findValue(raw, ["first name", "firstname", "given name"]);
  const lastName = findValue(raw, ["last name", "lastname", "surname", "family name"]);
  const fullName = findValue(raw, ["full name", "fullname", "name"]) || [firstName, lastName].filter(Boolean).join(" ");
  const workEmail = findWorkEmail(raw).toLowerCase();
  const personalEmail = findValue(raw, ["personal email", "personalemail"]).toLowerCase();
  const linkedinUrl = normalizeLinkedin(findValue(raw, ["linkedin", "linkedin url", "linkedin profile", "linkedinurl", "personal linkedin url", "person linkedin url"]));
  const companyName = findValue(raw, ["casual company name", "company name", "company", "organization"]);
  const companyDomain = normalizeDomain(findValue(raw, ["company website", "website", "company domain", "domain", "companywebsite"]));
  const employeeCount = parseEmployeeCount(findValue(raw, ["# employees", "number of employees", "employee count", "employees count", "employees", "company employee count", "company employees", "company headcount", "headcount"]));
  const city = findValue(raw, ["city"]);
  const state = findValue(raw, ["state", "region"]);
  const country = findValue(raw, ["country"]);
  const identifiers = [];
  if (workEmail) identifiers.push({ type: "work_email", value: workEmail });
  if (personalEmail) identifiers.push({ type: "personal_email", value: personalEmail });
  if (linkedinUrl) identifiers.push({ type: "linkedin", value: linkedinUrl });
  if (fullName && companyDomain) identifiers.push({ type: "name_company", value: `${normalizeText(fullName)}|${companyDomain}` });
  if (fullName && companyName) identifiers.push({ type: "name_company_name", value: `${normalizeText(fullName)}|${normalizeText(companyName)}` });
  const explicitLocation = findValue(raw, ["person location", "location", "contact location"]);
  return {
    firstName, lastName, fullName, workEmail, personalEmail,
    mobileNumber: findValue(raw, ["mobile number", "mobile", "phone", "phone number"]),
    linkedinUrl, title: findValue(raw, ["title", "job title", "jobtitle"]),
    keywords: parseKeywords(findValue(raw, ["keywords", "keyword", "person keywords", "prospect keywords"])),
    seniority: findValue(raw, ["seniority", "seniority level"]),
    department: findValue(raw, ["department", "departments", "function"]),
    city, state, country, location: explicitLocation || [city, state, country].filter(Boolean).join(", "),
    companyName, companyDomain,
    companyEmployeeCountMin: employeeCount.min, companyEmployeeCountMax: employeeCount.max,
    companyLocation: findValue(raw, ["company location", "account location", "headquarters", "hq location"]),
    companyCity: findValue(raw, ["company city", "account city", "hq city"]),
    companyState: findValue(raw, ["company state", "account state", "hq state", "company region"]),
    companyCountry: findValue(raw, ["company country", "account country", "hq country"]),
    raw, identifiers,
  };
}
