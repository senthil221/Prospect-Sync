import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  destinationProblems, importStepOrder, mapProblems,
  prospectImportOutcome, sourceProblems, stepStatus, uploadProblems,
} from "../lib/import-steps.ts";

// IMPORT-01..06 from the UI redesign plan.
//
// The import screen presented setup, explanatory copy, destination, upload,
// mapping, validation and submission at once across four competing regions -
// and opened by telling you a data source was required, before you had touched
// anything.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const destination = (over) => ({ listName: "Q3 outreach", clientId: "c1", newClient: "", dateContacted: "2026-09-03", noDateContacted: false, ...over });

test("nothing is wrong until it has been asked for", async () => {
  // IMPORT-AC-01. The panel rendered "A data source is required before the
  // import can start" on first paint - an error about a field nobody had
  // reached. The message still exists; it now waits for a Continue press.
  const source = await read("../app/components/ImportsPanel.tsx");
  assert.doesNotMatch(source, /source-required-note/, "the always-on error note is gone");
  assert.match(source, /attempted=\{sourceAttempted\}/);
  assert.match(source, /setSourceAttempted\(true\);/);

  const styles = await read("../app/workspace.css");
  assert.ok(!styles.includes(".source-required-note"), "and so is its stylesheet");

  // The footer only renders a summary once a press has happened.
  const footer = await read("../app/components/ImportStepper.tsx");
  assert.match(footer, /\{attempted && problems\.length \?/);
});

test("each step says which control is at fault", () => {
  // IMPORT-AC-03: a refusal has to be actionable, so every problem carries the
  // id of the control that caused it and focus moves there.
  const noSource = sourceProblems({ dataSource: "", usingCustomSource: false });
  assert.equal(noSource[0].field, "import-data-source");
  assert.match(noSource[0].message, /lineage/);
  // "Other" points at the text box, not the select that is already answered.
  assert.equal(sourceProblems({ dataSource: "", usingCustomSource: true })[0].field, "import-custom-source");
  assert.deepEqual(sourceProblems({ dataSource: "Apollo", usingCustomSource: false }), []);

  assert.equal(uploadProblems({ hasSource: false, rows: 0 }, "prospect-file")[0].field, "prospect-file");
  // A file that parsed but holds nothing is a different problem from no file.
  assert.match(uploadProblems({ hasSource: true, rows: 0 }, "prospect-file")[0].message, /no data rows/);
  assert.deepEqual(uploadProblems({ hasSource: true, rows: 12 }, "prospect-file"), []);

  // The prospect flow can be overridden; the company flow cannot, because
  // without a name or a website there is nothing to match a company on.
  const overridable = mapProblems({ missingFields: ["Email"], overrideField: "import-allow-missing" }, "prospect-mapping");
  assert.equal(overridable[0].field, "import-allow-missing");
  assert.match(overridable[0].message, /tick the box/);
  assert.deepEqual(mapProblems({ missingFields: ["Email"], allowMissing: true, overrideField: "x" }, "y"), []);
  const blocking = mapProblems({ missingFields: ["Company Name", "Website"] }, "company-mapping");
  assert.equal(blocking[0].field, "company-mapping");
  assert.doesNotMatch(blocking[0].message, /tick the box/);
});

test("the destination reports every missing field at once, not one at a time", () => {
  assert.deepEqual(destinationProblems(destination()), []);
  // An existing client satisfies the client requirement without a name.
  assert.deepEqual(destinationProblems(destination({ clientId: "c9", newClient: "" })), []);
  const empty = destinationProblems({ listName: "", clientId: "", newClient: "", dateContacted: "", noDateContacted: false });
  assert.deepEqual(empty.map((problem) => problem.field), ["new-client-name", "list-name", "prospect-date-contacted"]);
  // Ticking "No contact date" is an answer, not an omission.
  assert.deepEqual(destinationProblems(destination({ dateContacted: "", noDateContacted: true })), []);
});

test("the stepper marks what is done, current, and not yet earned", () => {
  assert.deepEqual(importStepOrder, ["source", "upload", "map", "review"]);
  assert.equal(stepStatus("source", "map", "map"), "complete");
  assert.equal(stepStatus("map", "map", "map"), "current");
  assert.equal(stepStatus("review", "map", "map"), "upcoming", "a step you have not earned is not clickable");
  // Going back does not un-earn the steps you already passed.
  assert.equal(stepStatus("map", "source", "review"), "complete");
});

test("going back to fix one field does not cost you the way forward", async () => {
  // Without a high-water mark, clicking Source from the review step would make
  // every later step unreachable again - three Continue presses to return to
  // where you were, which is exactly what IMPORT-AC-02 is about.
  const source = await read("../app/components/ImportsPanel.tsx");
  assert.match(source, /setFurthest\(\(current\) => stepIndex\(next\) > stepIndex\(current\) \? next : current\)/);
  assert.match(source, /<ImportStepper current=\{step\} furthest=\{furthest\}/);
  // The child views advance through goToStep, so their Continue presses raise
  // the mark too - a Back that only setStep would silently lower it.
  assert.equal(source.match(/onStep=\{goToStep\}/g)?.length, 2);
});

test("the success panel reports the response, not the preview", () => {
  // IMPORT-06. "Fields preserved" came from the client-side CSV preview: not a
  // response value at all, and after a background import it described a sample
  // of the file rather than the import that ran.
  const outcome = prospectImportOutcome({ processed_rows: 1000, unique_added: 700, duplicates_linked: 250 });
  assert.deepEqual(outcome, { processed: 1000, added: 700, linked: 250, unlinked: 50 });
  // Every row is one of the three, so the third figure is the remainder.
  assert.equal(outcome.added + outcome.linked + outcome.unlinked, outcome.processed);
  // A response that does not add up cannot produce a negative count.
  assert.equal(prospectImportOutcome({ processed_rows: 10, unique_added: 8, duplicates_linked: 8 }).unlinked, 0);
  assert.deepEqual(prospectImportOutcome({}), { processed: 0, added: 0, linked: 0, unlinked: 0 });
});

test("the panel renders one step at a time and keeps what you entered", async () => {
  const source = await read("../app/components/ImportsPanel.tsx");

  // IMPORT-AC-02. The state hooks live above the step switch, so a Back is a
  // change of which branch renders - never an unmount, never a reset.
  const prospectView = source.slice(source.indexOf("function ProspectImportView"));
  assert.ok(prospectView.indexOf("const [file, setFile]") < prospectView.indexOf('if (step === "source") return null;'),
    "every field must outlive the step that shows it");
  assert.match(prospectView, /\{step === "upload" \? <>/);
  assert.match(prospectView, /\{step === "map" && fileAudit \? <>/);
  assert.match(prospectView, /\{step === "review" \? <>/);

  // Destination moved off the first screen: it was the first thing you saw and
  // the last thing you could answer.
  const upload = prospectView.slice(prospectView.indexOf('{step === "upload" ? <>'), prospectView.indexOf('{step === "map" && fileAudit'));
  assert.doesNotMatch(upload, /import-client|list-name/);

  const companyView = source.slice(source.indexOf("function CompanyImportView"), source.indexOf("function ProspectImportView"));
  assert.match(companyView, /\{step === "review" && parsed \? <>/);
});

test("both tab strips are the shared control", async () => {
  // IMPORT-03. Two hand-rolled strips: role="tab" on bare buttons, no arrow
  // keys, no roving tabindex, no panels - the same shape already replaced in
  // the prospect drawer.
  const source = await read("../app/components/ImportsPanel.tsx");
  assert.doesNotMatch(source, /import-kind-switch/);
  assert.equal(source.match(/<Tabs\b/g)?.length, 2, "import type and file/paste both use it");
  assert.match(source, /label="Import type"/);
  assert.match(source, /label="How to supply the companies"/);

  const styles = await read("../app/workspace.css");
  assert.ok(!styles.includes(".import-kind-switch"), "and the duplicated strip styles are gone");
});

test("progress carries its numbers", async () => {
  // IMPORT-05. The bar was a div with a width percentage - no role, no value,
  // nothing for assistive technology to read.
  const source = await read("../app/components/ImportsPanel.tsx");
  assert.doesNotMatch(source, /className="progress"/);
  assert.equal(source.match(/<ProgressBar\b/g)?.length, 4, "both flows, both the live and the resumed path");
  // The background phase has no known total until the server reports one;
  // omitting valuenow is what marks it indeterminate rather than stuck at zero.
  assert.match(source, /value=\{progress \? progress : undefined\} total=\{progress \? 100 : undefined\}/);

  const styles = await read("../app/workspace.css");
  assert.ok(!styles.includes(".progress >"), "the hand-rolled bar's stylesheet went with it");
});

test("a finished import says whether it can be undone", async () => {
  const source = await read("../app/components/ImportsPanel.tsx");
  assert.doesNotMatch(source, /Fields preserved/);
  assert.match(source, /Kept without a People DB link/);
  assert.match(source, /Matched to existing/);
  // A prospect import is reversible and says where; a company import updates in
  // place and says that instead of implying an undo that does not exist.
  assert.match(source, /can be undone from Overview → Recent imports/);
  assert.match(source, /cannot be rolled back as a unit/);
});
