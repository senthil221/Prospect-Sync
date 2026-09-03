import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { compareProspects, conflictCount, describeMerge, describeProspect, matchCount } from "../lib/duplicate-compare.ts";
import { formatShare, qualityIssues, severityLabel } from "../lib/quality-issues.ts";

// QUALITY-01..05 from the UI redesign plan.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const summary = (over) => ({
  total: 681_085, missingEmail: 0, missingTitle: 0, missingLinkedin: 0,
  missingCompany: 0, missingDomain: 0, staleRecords: 0, potentialDuplicateGroups: 0, ...over,
});
const person = (over) => ({
  id: "p1", full_name: "", title: "", company_name: "", work_email: "", personal_email: "",
  linkedin_url: "", mobile_number: "", seniority: "", department: "", city: "", state: "",
  country: "", all_data: {}, ...over,
});

test("a non-zero count never reads as 0%", () => {
  // QUALITY-03, and the sharpest form of it: 412 people with no email in a
  // database of 681,085 rounds to 0, so the panel reported a real gap as
  // nothing to do.
  assert.equal(formatShare(412, 681_085), "<1%");
  assert.equal(formatShare(1, 681_085), "<1%");
  // The mirror of the same bug at the other end.
  assert.equal(formatShare(681_000, 681_085), ">99%");
  // Genuine zero, and genuine everything, still say so exactly.
  assert.equal(formatShare(0, 681_085), "0%");
  assert.equal(formatShare(681_085, 681_085), "100%");
  assert.equal(formatShare(5, 0), "0%", "an empty database is not a division");
  assert.equal(formatShare(340_542, 681_085), "50%");
});

test("the checks are ranked by what they cost, not by declaration order", () => {
  // QUALITY-01. A LinkedIn gap ten times the size of an email gap is still the
  // less urgent of the two, so severity has to beat count.
  const issues = qualityIssues(summary({ missingLinkedin: 400_000, missingEmail: 40_000, staleRecords: 90_000 }));
  assert.deepEqual(issues.filter((issue) => issue.severity !== "clear").map((issue) => issue.id), ["email", "stale", "linkedin"]);

  // Count only orders checks that are already equally severe.
  const tied = qualityIssues(summary({ missingEmail: 10, missingDomain: 900, missingCompany: 50 }));
  assert.deepEqual(tied.slice(0, 3).map((issue) => issue.id), ["domain", "company", "email"]);
});

test("every issue explains its impact and names one next action", () => {
  // QUALITY-AC-01. A tile reading "412,883" is a fact, not a task.
  for (const issue of qualityIssues(summary({ missingEmail: 1, missingTitle: 1, missingLinkedin: 1, missingCompany: 1, missingDomain: 1, staleRecords: 1 }))) {
    assert.ok(issue.impact.length > 40, `${issue.id} must say what the gap breaks`);
    assert.ok(issue.action.length > 20, `${issue.id} must say what to do about it`);
    assert.notEqual(issue.severity, "clear");
    assert.ok(severityLabel(issue.severity).length > 3);
  }
  // The action has to be honest about what the product can actually do: title
  // is a person-level field, so "fill gaps from company records" cannot supply
  // it, and the copy says so rather than sending you round a loop.
  const title = qualityIssues(summary({ missingTitle: 5 })).find((issue) => issue.id === "title");
  assert.match(title.action, /person-level field/);
});

test("a check that finds nothing stays on the list as clear", () => {
  const issues = qualityIssues(summary({ missingEmail: 12 }));
  assert.equal(issues.length, 6, "all six checks are always reported");
  const clear = issues.filter((issue) => issue.severity === "clear");
  assert.equal(clear.length, 5);
  // Clear checks sort last, so the queue reads worst-first from the top.
  assert.equal(issues[0].id, "email");
  assert.equal(issues.at(-1).severity, "clear");
});

test("the comparison marks conflicts, matches and one-sided fields apart", () => {
  // QUALITY-04. Twenty identical fields and two conflicting ones rendered at
  // identical weight, so finding the difference was a manual scan of both cards.
  const rows = compareProspects(
    person({ id: "a", full_name: "Vijay Kumar", title: "VP Sales", company_name: "Acme", work_email: "v@acme.com" }),
    person({ id: "b", full_name: "vijay  kumar", title: "VP Marketing", company_name: "Acme", linkedin_url: "in/vk" }),
  );
  const byField = new Map(rows.map((row) => [row.field, row]));
  // Case and repeated whitespace are not a conflict.
  assert.equal(byField.get("Full name").state, "same");
  assert.equal(byField.get("Company").state, "same");
  assert.equal(byField.get("Title").state, "differs");
  assert.equal(byField.get("Work email").state, "only-left");
  assert.equal(byField.get("LinkedIn").state, "only-right");
  // A field neither side has never appears.
  assert.equal(byField.has("Mobile"), false);

  assert.equal(conflictCount(rows), 1, "only a real disagreement is a conflict");
  assert.equal(matchCount(rows), 2);

  // Named columns keep their position and beat the raw import header that
  // carries the same label in all_data.
  const withExtras = compareProspects(
    person({ full_name: "A", all_data: { "Full name": "SHOULD NOT WIN", Industry: "SaaS" } }),
    person({ full_name: "A", all_data: { Industry: "Fintech" } }),
  );
  assert.equal(withExtras[0].field, "Full name");
  assert.equal(withExtras[0].state, "same");
  assert.equal(withExtras.find((row) => row.field === "Industry").state, "differs");
});

test("the merge buttons name the record, not the column it landed in", () => {
  // QUALITY-05. "Keep left" is a fact about the layout: reordering the API
  // response would silently invert the meaning of both buttons.
  assert.equal(describeProspect(person({ full_name: "Vijay Kumar", company_name: "Acme" })), "Vijay Kumar at Acme");
  assert.equal(describeProspect(person({ full_name: "Vijay Kumar", work_email: "v@acme.com" })), "Vijay Kumar (v@acme.com)");
  assert.equal(describeProspect(person({ full_name: "Vijay Kumar" })), "Vijay Kumar");
  assert.equal(describeProspect(person({ personal_email: "v@gmail.com" })), "v@gmail.com");
  assert.equal(describeProspect(person({})), "this unnamed record");

  // The confirmation says which record stops existing and what moves.
  const merge = describeMerge(person({ full_name: "A", company_name: "Acme" }), person({ full_name: "B", company_name: "Globex" }));
  assert.match(merge, /B at Globex is merged into A at Acme/);
  assert.match(merge, /Lists and client links move across/);
});

test("a duplicate decision is confirmed, per-row, and survives a failure", async () => {
  const source = await read("../app/components/DataQualityPanel.tsx");

  // The confirmation is the shared dialog, so it inherits the focus lifecycle -
  // merging is not reversible from this screen.
  assert.match(source, /<ConfirmDialog/);
  assert.match(source, /title=\{`Keep \$\{describeProspect\(pending\.keep\)\}\?`\}/);
  assert.match(source, /confirmLabel="Merge records"/);

  // QUALITY-05: state keyed by pair. One global `merging` string meant a
  // failure on one row blanked the panel's single error slot and left every
  // other row looking untouched.
  assert.match(source, /rowStates, setRowStates\] = useState<Record<string, RowState>>/);
  assert.doesNotMatch(source, /const \[merging, setMerging\]/);

  // QUALITY-AC-04: a failed merge leaves the pair on screen and retryable - the
  // catch sets a row error and never removes the candidate.
  const failure = source.slice(source.indexOf("} catch (caught) {\n      // QUALITY-AC-04"), source.indexOf("async function drainBacklog"));
  assert.match(failure, /status: "error"/);
  assert.doesNotMatch(failure, /setCandidates/);
  assert.match(source, /Both records are unchanged — choose again to retry/);

  // QUALITY-AC-03: complete or skip, both from the keyboard, both real buttons.
  assert.match(source, /className="ghost" disabled=\{busy\} onClick=\{\(\) => setSkipped/);
  assert.match(source, /Keep \{describeProspect\(candidate\.left\)\}/);
  assert.match(source, /Keep \{describeProspect\(candidate\.right\)\}/);
  assert.doesNotMatch(source, /Keep left|Keep right/);
});

test("the sample chips are folded away and the queue replaces the tiles", async () => {
  const source = await read("../app/components/DataQualityPanel.tsx");

  // QUALITY-02: eight company chips were the loudest thing in the panel and
  // the least actionable.
  assert.match(source, /aria-expanded=\{showAffected\}/);
  assert.match(source, /View affected companies/);
  assert.match(source, /\{showAffected \? <div className="enrichment-sample">/);

  // QUALITY-01: the six identical tiles are gone; the master total survives as
  // context on the panel head rather than as a seventh tile.
  assert.doesNotMatch(source, /<div className="quality-metrics">/);
  assert.match(source, /master prospects/);
  assert.match(source, /className="quality-issue-list"/);
  assert.match(source, /\{issue\.shareText\} of database/);

  // The old side-by-side cards, and their stylesheet, are gone with them.
  const duplicates = await read("../app/components/DuplicatesPanel.tsx");
  assert.doesNotMatch(duplicates, /ProspectCompareCard/);
  assert.match(duplicates, /className="compare-table"/);
  const styles = await read("../app/workspace.css");
  for (const dead of [".compare-card", ".compare-fields", ".compare-client-list"]) {
    assert.ok(!styles.includes(dead), `${dead} went with the two-card layout`);
  }
});

test("the duplicate list is a list, and its rows are announced", async () => {
  const source = await read("../app/components/DataQualityPanel.tsx");
  // It was a div of divs; a screen reader had no way to know how many pairs
  // were left or which one it was on.
  assert.match(source, /<ul className="duplicate-list">/);
  assert.match(source, /<li className="duplicate-pair" key=\{key\}>/);
  // Busy, done and failed each announce politely or assertively as appropriate.
  assert.match(source, /\{busy \? <StatusMessage>Merging…<\/StatusMessage> : null\}/);
  assert.match(source, /state\?\.status === "done" \? <StatusMessage>/);
  assert.match(source, /state\?\.status === "error" \? <StatusMessage tone="alert">/);

  const styles = await read("../app/workspace.css");
  assert.match(styles, /\.duplicate-list \{[^}]*list-style: none/);
  assert.match(styles, /\.quality-severity\.high \{/);
});
