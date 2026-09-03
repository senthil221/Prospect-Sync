import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  checkCoverageFile, checkCoverageTable, coverageMappingProblem, coverageReadProblem,
  coverageRowNotice, coverageServerProblem, formatFileSize, maxCoverageBytes, maxCoverageRows, problemText,
} from "../lib/coverage-file.ts";

// COVERAGE-01..04 from the UI redesign plan.
//
// The panel framed the whole job before any of it could be done: a 350px upload
// card next to a 470px empty bordered canvas, both painted on first load, with
// the mapping selects living in the upload card whether or not a file had ever
// been read. And it had exactly one error message - whatever string the reader
// or the server threw - for five different failures with five different fixes.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const file = (name, size) => ({ name, size });

test("every validation names the cause and one concrete remedy", () => {
  // COVERAGE-AC-02. A message with only a cause is a dead end; one with only a
  // remedy is a guess. Each of these is asserted as a pair.
  const wrongType = checkCoverageFile(file("prospects.pdf", 4096));
  assert.match(wrongType.cause, /prospects\.pdf/, "the cause quotes the file the user actually chose");
  assert.match(wrongType.cause, /not a spreadsheet/);
  assert.match(wrongType.remedy, /CSV or Excel/);

  const empty = checkCoverageFile(file("list.csv", 0));
  assert.match(empty.cause, /0 bytes/);
  assert.match(empty.remedy, /Export the list/);

  const huge = checkCoverageFile(file("list.csv", maxCoverageBytes + 1));
  assert.match(huge.cause, /15\.0 MB/, "the cause states the ceiling, not just that it was exceeded");
  assert.match(huge.remedy, /split the list/i);

  // The two the reader only discovers after parsing.
  const headerless = checkCoverageTable("list.csv", { headers: [], rows: [] });
  assert.match(headerless.cause, /no header row/);
  const rowless = checkCoverageTable("list.csv", { headers: ["Company"], rows: [] });
  assert.match(rowless.cause, /no companies/);
  assert.match(rowless.remedy, /rows included/);

  // A well formed file the reader still choked on keeps the reader's words.
  const unreadable = coverageReadProblem("list.xlsx", new Error("Unsupported compression method"));
  assert.match(unreadable.cause, /Unsupported compression method/);
  assert.match(unreadable.remedy, /save a fresh copy as CSV/);

  for (const problem of [wrongType, empty, huge, headerless, rowless, unreadable]) {
    assert.ok(problem.cause.trim() && problem.remedy.trim(), "both halves are required");
    assert.equal(problemText(problem), `${problem.cause} ${problem.remedy}`);
  }
});

test("a valid file passes every gate", () => {
  assert.equal(checkCoverageFile(file("Target accounts.xlsx", 240_000)), null);
  assert.equal(checkCoverageFile(file("accounts.CSV", 900)), null, "extensions are matched case-insensitively");
  assert.equal(checkCoverageTable("accounts.csv", { headers: ["Company", "Website"], rows: [["Acme", "acme.com"]] }), null);
});

test("a retry never costs the user their file", async () => {
  // COVERAGE-AC-04. The remedy for a server failure has to be a control that is
  // already on screen, which only works if the parsed file survives the error.
  const failure = coverageServerProblem(new Error("statement timeout"));
  assert.match(failure.cause, /statement timeout/);
  assert.match(failure.remedy, /still loaded/);

  const source = await read("../app/components/CoveragePanel.tsx");
  // forget() is the only thing that drops the file, and the server catch does
  // not call it - it sets the problem and leaves file/table in place.
  assert.match(source, /catch \(caught\) \{ setProblem\(coverageServerProblem\(caught\)\); \}/,
    "a server failure must not discard the parsed table");
});

test("the one server refusal a retry cannot fix says so instead", () => {
  // The API answers 400 "No usable company names or domains were found." when
  // the mapped columns are blank for every row. Telling someone to press Check
  // again there is a loop, not a remedy.
  const blank = coverageServerProblem(new Error("No usable company names or domains were found."));
  assert.match(blank.cause, /empty for every row/);
  assert.match(blank.remedy, /Map a different pair/);
  assert.doesNotMatch(blank.remedy, /Check again/);
});

test("checking a prefix of the list is stated, not silent", () => {
  assert.equal(coverageRowNotice(maxCoverageRows), "", "a list at the limit is checked whole");
  const notice = coverageRowNotice(12_000);
  assert.match(notice, /12,000 rows/);
  assert.match(notice, /first 5,000/);
  assert.match(notice, /split the file/);
});

test("an unmapped file is refused with the reason, not just a dead button", () => {
  assert.equal(coverageMappingProblem({ headers: ["A"], nameField: "", domainField: "Website" }), null);
  assert.equal(coverageMappingProblem({ headers: ["A"], nameField: "Company", domainField: "" }), null,
    "either column alone is enough to look companies up");
  const unmapped = coverageMappingProblem({ headers: ["A"], nameField: "", domainField: "" });
  assert.match(unmapped.cause, /nothing to match on/);
  assert.match(unmapped.remedy, /at least one/);
});

test("file sizes are rounded the way a person reads them", () => {
  assert.equal(formatFileSize(512), "512 bytes");
  assert.equal(formatFileSize(4096), "4 KB");
  assert.equal(formatFileSize(15 * 1024 * 1024), "15.0 MB");
});

test("the panel reveals one stage at a time", async () => {
  const source = await read("../app/components/CoveragePanel.tsx");

  // COVERAGE-02. The stage is derived from the data rather than tracked in its
  // own state, so it cannot disagree with what is actually loaded.
  assert.match(source, /const stage = summary \? "results" : table && file \? "mapping" : "upload";/);

  // COVERAGE-AC-01: on the first screen the dropzone is the only control.
  const upload = source.slice(source.indexOf('{stage === "upload" ? <article'), source.indexOf('{stage === "mapping" && table ?'));
  assert.match(upload, /className="dropzone"/);
  assert.doesNotMatch(upload, /<select/, "no mapping control before there are headers to map");
  assert.doesNotMatch(upload, /<button/, "no second next action");

  // Mapping is reachable only with a parsed table; results only with a summary.
  assert.match(source, /\{stage === "mapping" && table \?/);
  assert.match(source, /\{stage === "results" && summary \?/);

  // The empty bordered canvas is gone, along with its stylesheet.
  const styles = await read("../app/workspace.css");
  for (const dead of [".coverage-placeholder", ".coverage-workspace", ".coverage-upload", ".coverage-results"]) {
    assert.ok(!styles.includes(dead), `${dead} was removed with the two-column layout`);
  }
  assert.match(styles, /\.coverage-task \{[^}]*margin: 0 auto/, "the task panel is centred");
});

test("progress and totals are announced, and replacing the file always works", async () => {
  const source = await read("../app/components/CoveragePanel.tsx");

  // COVERAGE-04. An indeterminate bar with a counted label while it runs...
  assert.match(source, /\{busy \? <ProgressBar label=\{`Checking \$\{formatNumber\(checking\)\} companies/);
  // ...and the totals in a polite live region once it lands, not only drawn in
  // tiles that a screen reader has no reason to revisit.
  assert.match(source, /<StatusMessage>\s*\{formatNumber\(summary\.total\)\} companies checked/);

  // Replace file is present in both post-upload stages, because fileSummary is.
  assert.match(source, /className="coverage-replace">Replace file\{fileInput\}/);
  const results = source.slice(source.indexOf('{stage === "results" && summary'));
  assert.ok(results.includes("{fileSummary}"), "a result must always be replaceable");

  // Re-picking the same path is the case a single kept-mounted input silently
  // ignores: the input's value never changed, so no change event fires.
  assert.match(source, /Remounted per stage on purpose/);

  // COVERAGE-AC-03: the export names its contents on the button itself.
  assert.match(source, /Export \$\{formatNumber\(summary\.new\)\} net-new companies/);
  assert.match(source, /nothing already in the database is included/);
  assert.match(source, /disabled=\{!summary\.new\}/, "an export of zero rows is not offered");
});

test("the upload control is reachable from the keyboard", async () => {
  const styles = await read("../app/workspace.css");
  // `display: none` on the input took the only control on the first screen of
  // this flow out of the tab order completely - the dropzone was pointer-only.
  const rule = styles.split("\n").find((line) => line.startsWith(".dropzone input {"));
  assert.doesNotMatch(rule, /display: none/);
  assert.match(rule, /width: 1px/);
  assert.match(styles, /\.dropzone:focus-within \{[^}]*outline: 2px solid var\(--accent\)/);
  // Absolutely positioned children need a positioned parent or they escape it.
  assert.match(styles, /\.dropzone \{ position: relative/);
  assert.match(styles, /\.coverage-replace \{ position: relative/);
});
