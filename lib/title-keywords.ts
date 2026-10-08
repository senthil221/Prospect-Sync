import { csvDocument } from "./csv.ts";

// The job title keyword lists as files: what the Job titles tab downloads, and
// how an edited file (CSV or XLSX) becomes rows for apply_title_keywords_v1.

export type KeywordKind = "seniority" | "department";

export const keywordKinds: KeywordKind[] = ["seniority", "department"];

export const seniorityTiers = ["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry", "none"];
export const keywordDepartments = ["Sales", "Marketing", "Engineering", "IT", "Product", "Design", "Data & Analytics", "HR", "Finance", "Legal", "Operations", "Supply Chain", "Manufacturing", "Quality", "Support", "Admin", "Strategy", "R&D"];

const columns: Record<KeywordKind, string[]> = {
  seniority: ["keyword", "tier", "notes"],
  department: ["keyword", "department", "sub_department", "notes"],
};

export type KeywordRow = Record<string, string | number>;

export function isKeywordKind(value: unknown): value is KeywordKind {
  return value === "seniority" || value === "department";
}

// Same columns as data/seniority_map.csv and data/department_map.csv. The first
// row after the header is a # comment naming the allowed values; the upload
// skips # rows, so it can stay in the file.
export function keywordListCsv(kind: KeywordKind, rows: Array<Record<string, string>>) {
  const header = columns[kind];
  const allowed = kind === "seniority" ? `# tier is one of: ${seniorityTiers.join(" ")}` : `# department is one of: ${keywordDepartments.join(", ")}`;
  return csvDocument(header, [[allowed, ...header.slice(1).map(() => "")], ...rows.map((row) => header.map((name) => row[name] ?? ""))]);
}

// Header names are matched loosely ("Keyword", "Sub department"), # rows and blank
// rows are dropped, and each row keeps its line in the file for error messages.
export function keywordRowsFromTable(kind: KeywordKind, headers: string[], rows: string[][]): KeywordRow[] {
  const key = (value: string) => value.replace(/^\uFEFF/, "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  const positions = new Map(headers.map((header, index) => [key(header), index]));
  const missing = columns[kind].filter((name) => name !== "notes" && name !== "sub_department" && !positions.has(name));
  if (missing.length) throw new Error(`The file needs a ${missing.join(" and ")} column (download the list to see the layout).`);
  const result: KeywordRow[] = [];
  rows.forEach((cells, index) => {
    const keyword = String(cells[positions.get("keyword")!] ?? "").trim();
    if (!cells.some((cell) => String(cell ?? "").trim()) || keyword.startsWith("#")) return;
    const row: KeywordRow = { line: index + 2 };
    for (const name of columns[kind]) row[name] = positions.has(name) ? String(cells[positions.get(name)!] ?? "").trim() : "";
    result.push(row);
  });
  return result;
}
