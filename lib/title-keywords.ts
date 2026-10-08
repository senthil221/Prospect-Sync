import { csvDocument } from "./csv.ts";

// The job title keyword lists as files: what the Job titles tab downloads, and
// how an edited file (CSV or XLSX) becomes rows for apply_title_keywords_v1.
//
// The two top management lists are one table in the database (each keyword is
// include or exclude) but two files, in the layout they were supplied in:
// data/top_management_include.csv and data/top_management_exclude.csv.

export type KeywordKind = "seniority" | "department" | "top_management_include" | "top_management_exclude";

export const keywordKinds: KeywordKind[] = ["seniority", "department", "top_management_include", "top_management_exclude"];

export const keywordKindLabels: Record<KeywordKind, string> = {
  seniority: "Seniority",
  department: "Department",
  top_management_include: "Top management include",
  top_management_exclude: "Top management exclude",
};

export const keywordFileNames: Record<KeywordKind, string> = {
  seniority: "seniority_map",
  department: "department_map",
  top_management_include: "top_management_include",
  top_management_exclude: "top_management_exclude",
};

export const seniorityTiers = ["owner", "c_suite", "vp", "director", "manager", "senior_ic", "entry", "none"];
export const keywordDepartments = ["Sales", "Marketing", "Engineering", "IT", "Product", "Design", "Data & Analytics", "HR", "Finance", "Legal", "Operations", "Supply Chain", "Manufacturing", "Quality", "Support", "Admin", "Strategy", "R&D", "Education", "Healthcare"];

const columns: Record<KeywordKind, string[]> = {
  seniority: ["keyword", "tier", "notes"],
  department: ["keyword", "department", "sub_department", "notes"],
  top_management_include: ["keyword", "notes"],
  top_management_exclude: ["keyword", "protects"],
};

// Columns an upload must have; the rest may be missing.
const requiredColumns: Record<KeywordKind, string[]> = {
  seniority: ["keyword", "tier"],
  department: ["keyword", "department"],
  top_management_include: ["keyword"],
  top_management_exclude: ["keyword"],
};

const guidance: Record<KeywordKind, string> = {
  seniority: `# tier is one of: ${seniorityTiers.join(" ")}`,
  department: `# department is one of: ${keywordDepartments.join(", ")}`,
  top_management_include: "# a job title containing any of these is top management",
  top_management_exclude: "# a longer phrase that stops an include keyword firing, e.g. vice president stops president",
};

export type KeywordRow = Record<string, string | number>;

export function isKeywordKind(value: unknown): value is KeywordKind {
  return typeof value === "string" && (keywordKinds as string[]).includes(value);
}

// Same columns as the files in data/. The first row after the header is a #
// comment saying what goes in the list; the upload skips # rows, so it can stay.
export function keywordListCsv(kind: KeywordKind, rows: Array<Record<string, string>>) {
  const header = columns[kind];
  return csvDocument(header, [[guidance[kind], ...header.slice(1).map(() => "")], ...rows.map((row) => header.map((name) => row[name] ?? ""))]);
}

// Header names are matched loosely ("Keyword", "Sub department"), # rows and blank
// rows are dropped, and each row keeps its line in the file for error messages.
export function keywordRowsFromTable(kind: KeywordKind, headers: string[], rows: string[][]): KeywordRow[] {
  const key = (value: string) => value.replace(/^\uFEFF/, "").trim().toLowerCase().replace(/[\s-]+/g, "_");
  const positions = new Map(headers.map((header, index) => [key(header), index]));
  const missing = requiredColumns[kind].filter((name) => !positions.has(name));
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
