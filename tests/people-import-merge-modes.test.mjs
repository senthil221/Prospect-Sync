import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { companyMergeModes, defaultCompanyMergeMode, normalizeCompanyMergeMode, prospectMergeModeLabels } from "../lib/company-merge-mode.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260922060000_people_imports_choose_how_duplicates_merge.sql");

// A company import has asked what to do with a match since 20260825020000. A
// people import never did - it just had one hardcoded answer, and not even a
// consistent one.
test("people imports offer the same three modes companies do", () => {
  assert.deepEqual([...companyMergeModes], ["enrich", "overwrite", "skip"]);
  // Shared rather than duplicated: the same question, the same three answers,
  // only the wording differs.
  assert.deepEqual(Object.keys(prospectMergeModeLabels).sort(), ["enrich", "overwrite", "skip"]);
  for (const mode of companyMergeModes) {
    assert.ok(prospectMergeModeLabels[mode].label, mode);
    assert.ok(prospectMergeModeLabels[mode].description.length > 30, `${mode} needs to say what it does`);
  }
  // The default has to stay the non-destructive one: it is what an older client
  // that sends no mode at all gets.
  assert.equal(defaultCompanyMergeMode, "enrich");
  assert.equal(normalizeCompanyMergeMode("overwrite"), "overwrite");
  assert.equal(normalizeCompanyMergeMode("nonsense"), null);
});

test("the mode reaches the database on every people import path", async () => {
  const [panel, start, detail] = await Promise.all([
    read("../app/components/ImportsPanel.tsx"),
    read("../app/api/imports/start/route.ts"),
    read("../app/api/imports/[id]/route.ts"),
  ]);

  // Chosen in the review step, beside the other destination decisions.
  assert.match(panel, /<MergeModeChooser kind="prospect"/);
  assert.match(panel, /labels=\{prospectMergeModeLabels\}/);
  // All three start paths carry it: pasted rows, a browser file, and a
  // background upload. Missing one would silently import under the default.
  assert.equal((panel.match(/mergeMode[,}]/g) ?? []).length >= 3, true, "every /api/imports/start call must send mergeMode");
  // Resuming continues under the mode it began with.
  assert.match(panel, /if \(detail\.mergeMode\) setMergeMode\(detail\.mergeMode\)/);

  // Stored on the import row, not passed per chunk - which is what lets the
  // background worker honour it without knowing it exists.
  assert.match(start, /merge_mode: mergeMode/);
  assert.match(start, /normalizeCompanyMergeMode\(payload\.mergeMode\)/);
  // An older client sending nothing keeps the behaviour it already had.
  assert.match(start, /payload\.mergeMode === undefined \? defaultCompanyMergeMode/);
  // And the detail route reports it for people too, not only companies.
  assert.doesNotMatch(detail, /kind === "companies" \? String\(\(row as \{ merge_mode/);
  assert.match(detail, /mergeMode: String\(\(row as \{ merge_mode\?: unknown \}\)\.merge_mode \?\? "enrich"\)/);
});

test("the migration reads the mode per batch and leaves skipped people linked", async () => {
  const sql = await migration();

  assert.match(sql, /add column if not exists merge_mode text not null default 'enrich'/);
  assert.match(sql, /check \(merge_mode in \('enrich', 'overwrite', 'skip'\)\)/);

  // Read once per batch from the import row. The worker reaches this function
  // through four wrappers and never passes anything down, so looking it up
  // here is what makes background imports honour the choice at all.
  assert.match(sql, /select coalesce\(nullif\(i\.merge_mode, ''\), 'enrich'\) into merge_mode_value/);

  // skip leaves the prospects row alone but still counts the person as linked:
  // the membership, list_rows and identifiers are all still written, so calling
  // them skipped would move them into "Kept without a People DB link" on the
  // completion screen, which they are not.
  assert.match(sql, /if merge_mode_value <> 'skip' then/);
  assert.match(sql, /end if;\s*\n\s*duplicate_count := duplicate_count \+ 1;/);

  // Spliced against the live definition with an exact-occurrence assertion, not
  // reconstructed from a migration file.
  assert.match(sql, /pg_get_functiondef\('public\.import_prospect_batch_v2\(text,text,jsonb\)'::regprocedure\)/);
  assert.match(sql, /expected exactly 1/);
});

// The one behaviour change, stated where someone will find it: Job Title,
// Seniority and Department used to be overwritten by any import that carried
// them, regardless of what was stored. Nothing said so, and it contradicts what
// "fill in what's missing" promises - so enrich now fills blanks for those
// three like every other field, and refreshing a title is what overwrite is for.
test("enrich stops silently overwriting job title, seniority and department", async () => {
  const sql = await migration();

  for (const field of ["title", "seniority", "department"]) {
    assert.match(
      sql,
      new RegExp(`${field} = case when merge_mode_value = 'overwrite' then coalesce\\(nullif\\(row_data->>'${field}', ''\\), ${field}\\) else coalesce\\(nullif\\(${field}, ''\\), coalesce\\(row_data->>'${field}', ''\\)\\) end`),
      `${field} must follow the chosen mode, not always take the file's value`,
    );
  }
  // The old unconditional form is gone from the replacement.
  assert.doesNotMatch(
    sql.slice(sql.indexOf("v_merge_replacement")),
    /title = case when coalesce\(row_data->>'title', ''\) <> '' then row_data->>'title' else title end/,
  );
  // Called out in the migration itself, since it changes what an existing
  // workflow does without anyone asking for that specifically.
  assert.match(sql, /one behaviour change/i);
});
