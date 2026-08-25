import { uniqueHeaders } from "./dashboard-helpers.ts";
import { suggestedCompanyImportField } from "./import-schema.ts";

// Company lists are collected by copying, not by exporting: a column of domains out
// of a spreadsheet, a list of names out of a doc, a two-column block out of Sheets.
// None of that arrives as a file, and most of it has no header row -- so the paste
// path has to work out the delimiter, whether row one names the columns, and what
// each column holds, then hand back exactly what readImportTable hands back so the
// mapping UI and the chunked upload stay unchanged.

// Tabs first: that is what a spreadsheet copy uses, and a pasted cell can legally
// contain a comma. Semicolons cover the European CSV dialect.
const delimiters = ["\t", ",", ";"] as const;

const websitePattern = /^(?:https?:\/\/)?(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:[/?#]|$)/i;

// Quote-aware, matching parseCsv: a spreadsheet quotes any cell that contains the
// delimiter, so "Acme, Inc." has to survive a comma-delimited paste as one company.
function splitRow(line: string, delimiter: string) {
  if (!delimiter) return [line.trim()];
  const cells: string[] = [];
  let value = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (char === '"') {
      if (quoted && line[index + 1] === '"') { value += '"'; index += 1; }
      else quoted = !quoted;
    } else if (char === delimiter && !quoted) { cells.push(value); value = ""; }
    else value += char;
  }
  cells.push(value);
  return cells.map((cell) => cell.trim());
}

// A separator only counts as the delimiter when most lines carry it. Otherwise a
// single stray comma -- "Acme, Inc." in a plain list of names -- would split every
// name in the paste and quietly drop half of each one.
function detectDelimiter(lines: string[]) {
  return delimiters.find((candidate) => lines.filter((line) => line.includes(candidate)).length * 2 >= lines.length) ?? "";
}

// Row one is a header only when every cell in it names a company field we know. A
// data row does not: "Acme" and "acme.com" are aliases of nothing, so a bare list of
// companies is read as data rather than quietly losing its first entry.
function looksLikeHeader(cells: string[]) {
  const named = cells.filter(Boolean);
  return named.length > 0 && named.every((cell) => suggestedCompanyImportField(cell) !== "Not mapped");
}

// With no header row, name each column after what it holds. Domains are
// unambiguous. The first column that is not domains is the company name; anything
// further is left unnamed for the mapping picker rather than guessed at.
function inferHeaders(rows: string[][], width: number) {
  let namedColumn = false;
  return Array.from({ length: width }, (_unused, index) => {
    const values = rows.map((row) => row[index]).filter(Boolean);
    if (values.length && values.filter((value) => websitePattern.test(value)).length > values.length / 2) return "Website";
    if (values.length && !namedColumn) { namedColumn = true; return "Company Name"; }
    return `Column ${index + 1}`;
  });
}

export function parsePastedCompanyTable(text: string): { headers: string[]; rows: string[][]; inferredHeaders: boolean } {
  const lines = text.split(/\r\n|\r|\n/).map((line) => line.trim()).filter(Boolean);
  if (!lines.length) throw new Error("Paste at least one company row.");

  const delimiter = detectDelimiter(lines);
  const cells = lines.map((line) => splitRow(line, delimiter)).filter((row) => row.some(Boolean));
  if (!cells.length) throw new Error("Paste at least one company row.");

  const width = Math.max(...cells.map((row) => row.length));
  const padded = cells.map((row) => (row.length === width ? row : [...row, ...Array<string>(width - row.length).fill("")]));

  const hasHeader = padded.length > 1 && looksLikeHeader(padded[0]);
  const rows = hasHeader ? padded.slice(1) : padded;
  if (!rows.length) throw new Error("The paste has a header row but no company rows.");

  return {
    headers: uniqueHeaders(hasHeader ? padded[0] : inferHeaders(rows, width)),
    rows,
    inferredHeaders: !hasHeader,
  };
}
