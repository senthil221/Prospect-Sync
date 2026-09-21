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
  location: string;
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

/**
 * Title-case a name, but only when nobody has already cased it.
 *
 * WHY THE GUARD. Blind title-casing is wrong on real names: McDonald becomes
 * Mcdonald, DeShawn becomes Deshawn. Measured on production 2026-09-15, 889
 * prospects carry a mixed-case first name - 98 of them Mc/Mac/De/Van/O style,
 * most of the rest run-together spellings like SenthilKumar. Every one of those
 * is somebody's casing decision, and a bulk rule has no standing to overrule it.
 *
 * So only a name that is entirely one case is touched: PRAKHAR and prakhar are
 * unambiguously uncased, and become Prakhar.
 *
 * The word-boundary rule matches PostgreSQL's initcap() - any non-alphanumeric
 * starts a new word - so this and the backfill in
 * 20260915160000_first_and_last_names_are_title_case.sql cannot disagree about
 * the same input. o'brien and jean-luc come out O'Brien and Jean-Luc in both.
 */
export function titleCaseName(value: string) {
  const trimmed = value.trim();
  if (!trimmed || !/\p{L}/u.test(trimmed)) return trimmed;
  const lower = trimmed.toLocaleLowerCase();
  // Mixed case already: leave it exactly as it arrived.
  if (trimmed !== trimmed.toLocaleUpperCase() && trimmed !== lower) return trimmed;
  return lower.replace(/(^|[^\p{L}\p{N}])(\p{L})/gu, (_match, boundary: string, letter: string) => boundary + letter.toLocaleUpperCase());
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

// A free/personal provider is never the employer's domain - falling back to it
// would file "gmail.com" itself as a company shared by every Gmail user in the
// import. Deliberately not exhaustive: it only needs to catch the handful of
// providers common enough to show up as noise across many different companies.
const freeEmailDomains = new Set([
  "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.in", "yahoo.co.uk",
  "outlook.com", "outlook.in", "hotmail.com", "hotmail.co.uk", "live.com", "msn.com",
  "aol.com", "icloud.com", "me.com", "mac.com", "protonmail.com", "proton.me",
  "zoho.com", "gmx.com", "mail.com", "yandex.com", "yandex.ru", "rediffmail.com", "rocketmail.com", "ymail.com",
]);

// A row with no explicit website often still carries a work email, and that
// email's domain usually IS the company's website - just not spelled that way
// in the file. Used only as a fallback, and only for the work email: a
// personal email's domain says nothing about who the person works for.
export function domainFromEmail(email: string) {
  const at = email.lastIndexOf("@");
  if (at < 0) return "";
  const domain = clean(email.slice(at + 1)).toLowerCase();
  return domain && !freeEmailDomains.has(domain) ? domain : "";
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

// Apollo-style single location: an explicit column wins, otherwise compose it
// from whichever parts the file supplied. Kept in sync with the same fallback in
// import_prospect_batch_v2 so a row means the same thing on either write path.
export function personLocation(explicit: string, city: string, state: string, country: string) {
  return clean(explicit) || [city, state, country].map(clean).filter(Boolean).join(", ");
}

export function mapProspect(headers: string[], values: string[]): CanonicalProspect {
  const raw: Record<string, string> = {};
  headers.forEach((header, index) => { raw[header] = clean(values[index]); });

  // Cased before the full name is derived, so a full name we build inherits the
  // correction. A SUPPLIED full name is never rewritten - that column is left
  // exactly as the file gave it.
  const firstName = titleCaseName(findValue(raw, ["first name", "firstname", "given name"]));
  const lastName = titleCaseName(findValue(raw, ["last name", "lastname", "surname", "family name"]));
  const suppliedFullName = findValue(raw, ["full name", "fullname", "name"]);
  const fullName = suppliedFullName || [firstName, lastName].filter(Boolean).join(" ");
  const workEmail = findWorkEmail(raw).toLowerCase();
  const personalEmail = findValue(raw, ["personal email", "personalemail"]).toLowerCase();
  const linkedinUrl = normalizeLinkedin(findValue(raw, ["linkedin", "linkedin url", "linkedin profile", "linkedinurl", "personal linkedin url", "person linkedin url"]));
  const companyName = findValue(raw, ["casual company name", "company name", "company", "organization"]);
  // A missing Website column falls back to the work email's domain - see
  // domainFromEmail above for why only the work email, not the personal one.
  const companyDomain = normalizeDomain(findValue(raw, ["website", "company website", "company domain", "domain", "companywebsite"])) || domainFromEmail(workEmail);
  const employeeCount = parseEmployeeCount(findValue(raw, ["# employees", "number of employees", "employee count", "employees count", "employees", "company employee count", "company employees", "company headcount", "headcount"]));
  const city = findValue(raw, ["city"]);
  const state = findValue(raw, ["state", "region"]);
  const country = findValue(raw, ["country"]);
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
    city,
    state,
    country,
    location: personLocation(findValue(raw, ["person location", "location", "contact location"]), city, state, country),
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
