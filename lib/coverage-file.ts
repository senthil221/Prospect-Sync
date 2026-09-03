// What is wrong with this file, and what to do about it.
//
// COVERAGE-03. The coverage checker had one error path: whatever string the CSV
// reader or the server threw, printed raw. "Unable to read this CSV." tells you
// the thing you already know - it did not work - and nothing about which of the
// five reasons applied or which of the five different fixes to reach for.
//
// Every problem here is a pair. The cause names the constraint in the user's own
// terms, quoting their file name and their numbers; the remedy is one concrete
// next action. A message with only a cause is a dead end, and a message with
// only a remedy is a guess.

export const maxCoverageBytes = 15 * 1024 * 1024;
/** The server slices to this; saying so beats silently checking a prefix. */
export const maxCoverageRows = 5000;

const spreadsheetExtensions = [".csv", ".tsv", ".txt", ".xlsx", ".xls"];

export type CoverageProblem = { cause: string; remedy: string };

export function formatFileSize(bytes: number) {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Reads as one sentence of cause followed by one sentence of remedy. */
export function problemText(problem: CoverageProblem) {
  return `${problem.cause} ${problem.remedy}`;
}

/** Type, size and emptiness - everything knowable before the file is parsed. */
export function checkCoverageFile(file: { name: string; size: number }): CoverageProblem | null {
  const name = file.name.toLowerCase();
  if (!spreadsheetExtensions.some((extension) => name.endsWith(extension))) {
    return {
      cause: `“${file.name}” is not a spreadsheet.`,
      remedy: "Save your list as CSV or Excel (.xlsx) and upload it again.",
    };
  }
  if (file.size === 0) {
    return {
      cause: `“${file.name}” is empty — it contains 0 bytes.`,
      remedy: "Export the list from your spreadsheet again and check it has rows before uploading.",
    };
  }
  if (file.size > maxCoverageBytes) {
    return {
      cause: `“${file.name}” is ${formatFileSize(file.size)}; the checker reads up to ${formatFileSize(maxCoverageBytes)}.`,
      remedy: "Delete the columns you are not checking, or split the list in two and check each half.",
    };
  }
  return null;
}

/** What the file turned out to contain once it was actually parsed. */
export function checkCoverageTable(fileName: string, table: { headers: string[]; rows: string[][] }): CoverageProblem | null {
  if (!table.headers.length) {
    return {
      cause: `“${fileName}” has no header row, so there are no columns to map.`,
      remedy: "Add a first row naming each column — Company and Website is enough — then upload it again.",
    };
  }
  if (!table.rows.length) {
    return {
      cause: `“${fileName}” has a header row but no companies under it.`,
      remedy: "Export the list again with its rows included.",
    };
  }
  return null;
}

/** The reader threw. Keep its words, add the recovery it cannot know about. */
export function coverageReadProblem(fileName: string, caught: unknown): CoverageProblem {
  const detail = caught instanceof Error ? caught.message : "";
  return {
    cause: `“${fileName}” could not be read${detail ? `: ${detail.replace(/\.$/, "")}` : ""}.`,
    remedy: "Open it in your spreadsheet app and save a fresh copy as CSV, then upload that.",
  };
}

/**
 * The server refused or failed. The file is still parsed and still mapped, so
 * the remedy is a button that is already on screen - COVERAGE-AC-04 is the rule
 * that a retry must never cost the user their file selection.
 */
export function coverageServerProblem(caught: unknown): CoverageProblem {
  const detail = caught instanceof Error ? caught.message : "";
  // The one server refusal that is really a mapping mistake: the columns were
  // chosen, but every cell under them is blank. Retrying cannot fix that.
  if (/no usable company/i.test(detail)) {
    return {
      cause: "The mapped columns are empty for every row, so there was nothing to look up.",
      remedy: "Map a different pair of columns above, or check that the file has values under the ones you chose.",
    };
  }
  return {
    cause: detail ? `The coverage check failed: ${detail.replace(/\.$/, "")}.` : "The coverage check failed.",
    remedy: "Your file is still loaded — press Check again. If it keeps failing, check a few hundred rows to find the row that breaks it.",
  };
}

/** Neither column is mapped, so there is nothing to look the companies up by. */
export function coverageMappingProblem(input: { headers: string[]; nameField: string; domainField: string }): CoverageProblem | null {
  if (input.nameField || input.domainField) return null;
  return {
    cause: "No column is mapped to a company name or a website, so there is nothing to match on.",
    remedy: "Choose at least one above. A website matches more precisely than a name.",
  };
}

/**
 * Not a problem - a notice. Checking the first 5,000 of 12,000 rows silently is
 * how a coverage report gets trusted for the whole list.
 */
export function coverageRowNotice(rowCount: number) {
  if (rowCount <= maxCoverageRows) return "";
  return `This file holds ${rowCount.toLocaleString("en-US")} rows. Only the first ${maxCoverageRows.toLocaleString("en-US")} companies are checked — split the file to check the rest.`;
}
