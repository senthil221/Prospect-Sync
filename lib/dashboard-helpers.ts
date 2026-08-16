import { customFieldValue } from "./prospect-fields";
import { isXlsxFile, readXlsxRows } from "./spreadsheet";
import type { Prospect } from "./types";

export function formatNumber(value: unknown) {
  return new Intl.NumberFormat("en-IN").format(Number(value ?? 0));
}

export function filterChipValue(field: string, value: string) {
  if (field !== "__employee_count") return value;
  if (value === "unknown") return "Unknown";
  const [minimum, maximum] = value.split(":");
  if (!minimum) return value;
  return maximum ? `${formatNumber(minimum)}–${formatNumber(maximum)}` : `${formatNumber(minimum)}+`;
}

export function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "CL";
}

export function colorTone(value: string) {
  return Array.from(value).reduce((sum, character) => sum + character.charCodeAt(0), 0) % 6;
}

export function uniqueHeaders(headers: string[]) {
  const used = new Map<string, number>();
  return headers.map((header, index) => {
    const base = header.trim() || `Column ${index + 1}`;
    const normalized = base.toLowerCase();
    const count = (used.get(normalized) ?? 0) + 1;
    used.set(normalized, count);
    return count === 1 ? base : `${base} (${count})`;
  });
}

export function deriveListName(fileName: string) {
  return fileName
    .replace(/^.*[\\/]/, "")
    .replace(/\.csv$/i, "")
    .replace(/[_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function parseCsv(text: string) {
  const rows: string[][] = [];
  let row: string[] = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"') {
      if (quoted && text[index + 1] === '"') { value += '"'; index += 1; }
      else quoted = !quoted;
    } else if (char === "," && !quoted) {
      row.push(value); value = "";
    } else if ((char === "\n" || char === "\r") && !quoted) {
      if (char === "\r" && text[index + 1] === "\n") index += 1;
      row.push(value); value = "";
      if (row.some((cell) => cell.trim())) rows.push(row);
      row = [];
    } else value += char;
  }
  row.push(value);
  if (row.some((cell) => cell.trim())) rows.push(row);
  if (!rows.length) throw new Error("The CSV is empty.");
  return { headers: uniqueHeaders(rows[0]), rows: rows.slice(1) };
}

export async function readImportTable(file: File): Promise<{ headers: string[]; rows: string[][] }> {
  if (!isXlsxFile(file)) return parseCsv(await file.text());
  const rows = (await readXlsxRows(file)).filter((row) => row.some((cell) => cell.trim()));
  if (!rows.length) throw new Error("The spreadsheet is empty.");
  return { headers: uniqueHeaders(rows[0]), rows: rows.slice(1) };
}

export function parseAllData(data: Prospect["all_data"]) {
  if (typeof data === "object" && data) return data as Record<string, string>;
  try { return JSON.parse(String(data || "{}")) as Record<string, string>; } catch { return {}; }
}

export function prospectFieldValue(prospect: Prospect, field: string) {
  if (field === "__name") return String(prospect.full_name || "");
  if (field === "__first_name") return String(prospect.first_name || "");
  if (field === "__last_name") return String(prospect.last_name || "");
  if (field === "__company") return String(prospect.company_name || "");
  if (field === "__email") return String(prospect.work_email || prospect.personal_email || "");
  if (field === "__title") return String(prospect.title || "");
  if (field === "__keywords") return Array.isArray(prospect.keywords) ? prospect.keywords.join(", ") : "";
  if (field === "__lists") return Array.isArray(prospect.list_names) ? prospect.list_names.join(", ") : "";
  if (field === "__clients") return Array.isArray(prospect.client_names) ? prospect.client_names.join(", ") : "";
  if (field === "__linkedin") return String(prospect.linkedin_url || "");
  if (field === "__country") return String(prospect.country || "");
  if (field === "__person_location") return [prospect.city, prospect.state, prospect.country].filter(Boolean).join(", ");
  if (field === "__company_location") return [prospect.company_location, prospect.company_city, prospect.company_state, prospect.company_country].filter(Boolean).join(", ");
  if (field === "__employee_count") {
    const minimum = prospect.employee_count_min;
    const maximum = prospect.employee_count_max;
    if (minimum == null && maximum == null) return "";
    if (minimum != null && maximum == null) return `${formatNumber(minimum)}+`;
    return minimum === maximum ? formatNumber(minimum) : `${formatNumber(minimum)}–${formatNumber(maximum)}`;
  }
  if (field === "__seniority") return String(prospect.seniority || "");
  if (field === "__department") return String(prospect.department || "");
  if (field === "__sub_department") {
    const data = parseAllData(prospect.all_data);
    const key = Object.keys(data).find((candidate) => { const normalized = candidate.toLowerCase().replace(/[^a-z0-9]/g, ""); return normalized === "subdepartments" || normalized === "subdepartment" || normalized === "subdepartmentname"; });
    return key ? String(data[key] || "") : "";
  }
  if (field === "__esp") return String(prospect.esp || "");
  if (field === "__email_provider_type") return String(prospect.email_provider_type || "Unknown");
  if (field === "__tags") return Array.isArray(prospect.tags) ? prospect.tags.map((tag) => tag.name).join(", ") : "";
  if (field === "__last_contacted") return prospect.last_contacted_at ? new Date(prospect.last_contacted_at).toLocaleDateString("en-IN") : "";
  if (field.startsWith("custom:")) return customFieldValue(parseAllData(prospect.all_data), field.slice(7));
  return String(parseAllData(prospect.all_data)[field] || "");
}

export function prospectMembershipItems(prospect: Prospect, includeClient: boolean) {
  const memberships = Array.isArray(prospect.list_memberships) ? prospect.list_memberships : [];
  if (memberships.length) {
    return memberships
      .filter((membership) => membership?.listName)
      .map((membership) => ({
        key: membership.listId || `${membership.clientId}:${membership.listName}`,
        listName: membership.listName,
        clientName: membership.clientName || "Unknown client",
        label: includeClient ? `${membership.clientName || "Unknown client"}: ${membership.listName}` : membership.listName,
      }))
      .sort((left, right) => left.label.localeCompare(right.label));
  }
  return (prospect.list_names ?? []).map((listName) => ({ key: listName, listName, clientName: "", label: listName }));
}
