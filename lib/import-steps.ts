// One import, four steps, and what is stopping each of them.
//
// IMPORT-01/02. The import screen presented setup, explanatory copy,
// destination, upload, mapping, validation and submission at once, across four
// competing regions, and told you "A data source is required before the import
// can start" before you had touched anything - an error about a field you had
// not reached yet, on first paint. The stages below are the order the work
// actually happens in, and the problems are what a Continue press has to say
// when it refuses.
//
// This module decides nothing about endpoints or import semantics. It answers
// one question - can this step be left, and if not, which control is at fault -
// so the answer is testable without a browser and identical for both flows.

export type ImportStepId = "source" | "upload" | "map" | "review";

export const importStepOrder: ImportStepId[] = ["source", "upload", "map", "review"];

export const importStepLabels: Record<ImportStepId, string> = {
  source: "Source",
  upload: "Upload",
  map: "Map & validate",
  review: "Destination & review",
};

/** `field` is the id of the control to move focus to - IMPORT-AC-03. */
export type StepProblem = { field: string; message: string };

export type SourceStepState = { dataSource: string; usingCustomSource: boolean };

export type UploadStepState = { hasSource: boolean; rows: number };

export type MapStepState = { missingFields: string[]; allowMissing?: boolean; overrideField?: string };

export type DestinationStepState = {
  listName: string;
  clientId: string;
  newClient: string;
  dateContacted: string;
  noDateContacted: boolean;
};

export function sourceProblems(state: SourceStepState): StepProblem[] {
  if (state.dataSource.trim()) return [];
  return [state.usingCustomSource
    ? { field: "import-custom-source", message: "Name the source this list came from - every import keeps its lineage." }
    : { field: "import-data-source", message: "Choose where this list came from. Every import keeps its lineage, so this cannot be skipped." }];
}

export function uploadProblems(state: UploadStepState, control: string): StepProblem[] {
  if (!state.hasSource) return [{ field: control, message: "Choose a file or paste the rows before continuing." }];
  if (!state.rows) return [{ field: control, message: "That file has a header row but no data rows under it." }];
  return [];
}

export function mapProblems(state: MapStepState, control: string): StepProblem[] {
  if (!state.missingFields.length) return [];
  // The prospect flow lets you proceed anyway; the company flow does not,
  // because without a name or a website there is nothing to match a company on.
  if (state.allowMissing) return [];
  const list = state.missingFields.join(", ");
  return [{
    field: state.overrideField ?? control,
    message: state.overrideField
      ? `Map a ${list} column, or tick the box to import anyway with whatever identity these rows have.`
      : `Map a ${list} column - one of them is what identifies each row.`,
  }];
}

export function destinationProblems(state: DestinationStepState): StepProblem[] {
  const problems: StepProblem[] = [];
  if (!state.clientId && !state.newClient.trim()) {
    problems.push({ field: "new-client-name", message: "Name the new client, or pick an existing one above." });
  }
  if (!state.listName.trim()) {
    problems.push({ field: "list-name", message: "Name the list these people land in." });
  }
  if (!state.noDateContacted && !state.dateContacted) {
    problems.push({ field: "prospect-date-contacted", message: "Set the contact date, or tick “No contact date”." });
  }
  return problems;
}

export function stepIndex(step: ImportStepId) {
  return importStepOrder.indexOf(step);
}

/** Complete, current, or not yet reachable - the three states a step marker has. */
export function stepStatus(step: ImportStepId, current: ImportStepId, furthest: ImportStepId) {
  if (step === current) return "current";
  return stepIndex(step) < stepIndex(furthest) || stepIndex(step) < stepIndex(current) ? "complete" : "upcoming";
}

/**
 * IMPORT-06: what the server actually said, plus the one figure it implies.
 *
 * The success panel reported "Fields preserved" from the client-side preview -
 * not a response value at all, and after a background import it described a
 * sample rather than the import. Every row either becomes a new prospect, links
 * to one already there, or is kept without a People DB link, so the third
 * number is the remainder and nothing else.
 */
export function prospectImportOutcome(summary: { processed_rows: number; unique_added: number; duplicates_linked: number }) {
  const processed = Math.max(0, Number(summary.processed_rows ?? 0));
  const added = Math.max(0, Number(summary.unique_added ?? 0));
  const linked = Math.max(0, Number(summary.duplicates_linked ?? 0));
  return { processed, added, linked, unlinked: Math.max(0, processed - added - linked) };
}
