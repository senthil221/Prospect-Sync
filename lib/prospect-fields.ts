export type ProspectFieldDefinition = { id: string; label: string; sourceFields?: string[] };

export function normalizedFieldKey(value: string) {
  return value.trim().toLocaleLowerCase().replace(/[^a-z0-9]+/g, "");
}

const canonicalAliases: Record<string, string> = {};

function register(id: string, aliases: string[]) {
  aliases.forEach((alias) => { canonicalAliases[normalizedFieldKey(alias)] = id; });
}

register("__first_name", ["first name", "firstname", "given name"]);
register("__last_name", ["last name", "lastname", "surname", "family name"]);
register("__name", ["full name", "fullname", "name"]);
register("__work_email", ["email", "email address", "work email", "business email", "company email"]);
register("__personal_email", ["personal email", "personalemail"]);
register("__mobile_number", ["mobile", "mobile number", "phone", "phone number"]);
register("__linkedin", ["linkedin", "linkedin url", "linkedin profile"]);
register("__title", ["title", "job title", "jobtitle"]);
register("__keywords", ["keyword", "keywords", "person keywords", "prospect keywords"]);
register("__seniority", ["seniority", "seniority level"]);
register("__department", ["department", "function"]);
register("__city", ["city"]);
register("__state", ["state", "region"]);
register("__country", ["country"]);
register("__company", ["company", "company name", "casual company name", "organization"]);
register("__website", ["website", "company website", "domain", "company domain"]);
register("__employee_count", ["employees", "employee count", "number of employees", "# employees", "company employee count", "company employees", "company headcount", "headcount"]);
register("__company_location", ["company location", "account location", "headquarters", "hq location"]);
register("__company_city", ["company city", "account city", "hq city"]);
register("__company_state", ["company state", "account state", "hq state", "company region"]);
register("__company_country", ["company country", "account country", "hq country"]);

export function canonicalFieldId(field: string) {
  return canonicalAliases[normalizedFieldKey(field)] ?? "";
}

function fieldLabel(field: string) {
  return field.trim().replace(/[_-]+/g, " ").replace(/\s+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

export function buildCustomFieldDefinitions(fields: string[]): ProspectFieldDefinition[] {
  const groups = new Map<string, string[]>();
  fields.forEach((field) => {
    const clean = field.trim();
    const normalized = normalizedFieldKey(clean);
    if (!clean || !normalized || canonicalFieldId(clean)) return;
    const current = groups.get(normalized) ?? [];
    if (!current.some((value) => value.toLocaleLowerCase() === clean.toLocaleLowerCase())) current.push(clean);
    groups.set(normalized, current);
  });
  return [...groups.entries()].map(([normalized, sourceFields]) => ({
    id: `custom:${normalized}`,
    label: fieldLabel(sourceFields[0]),
    sourceFields,
  })).sort((left, right) => left.label.localeCompare(right.label));
}

export function customFieldValue(data: Record<string, unknown>, normalized: string) {
  const values = Object.entries(data)
    .filter(([field, value]) => normalizedFieldKey(field) === normalized && String(value ?? "").trim())
    .map(([, value]) => String(value));
  return [...new Set(values)].join(" | ");
}
