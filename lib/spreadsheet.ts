// Shared spreadsheet helpers so the CSV importers can also accept .xlsx.
// The xlsx parser (read-excel-file) is imported lazily so it only loads when a
// user actually picks an Excel file — CSV imports pull in nothing extra.

export function isXlsxFile(file: File): boolean {
  return /\.xlsx$/i.test(file.name)
    || file.type === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
}

// Reads the FIRST worksheet as raw string rows (header row included), matching
// the [][]-of-strings shape parseCsv produces. Numbers/booleans are stringified;
// dates become YYYY-MM-DD so downstream normalization (e.g. Founded Year) is stable.
export async function readXlsxRows(file: File): Promise<string[][]> {
  const readXlsxFile = (await import("read-excel-file/browser")).default;
  const result = (await readXlsxFile(file)) as unknown;
  // read-excel-file v9 returns Sheet[] ({ sheet, data }); older versions return
  // Row[][] directly. Take the first sheet's rows either way.
  const first = Array.isArray(result) ? result[0] : undefined;
  const sheetRows: unknown[][] = (first && typeof first === "object" && !Array.isArray(first) && "data" in first)
    ? ((first as { data: unknown[][] }).data ?? [])
    : ((result as unknown[][]) ?? []);
  return sheetRows.map((row) => (Array.isArray(row) ? row : []).map((cell) =>
    cell == null ? "" : cell instanceof Date ? cell.toISOString().slice(0, 10) : String(cell),
  ));
}
