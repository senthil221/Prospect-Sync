import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Release 1B, item 5: the section 6.7 index evaluation. Every Tier 1 and Tier 2
// column named in the plan is either built here or has its reason recorded, so a
// skipped column is a decision rather than an omission.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000080_index_the_selective_substring_filters.sql");

test("the selective columns are indexed and the broad ones are not", async () => {
  const sql = await migration();

  for (const index of [
    "idx_prospect_index_full_name_trgm",
    "idx_prospect_index_first_name_trgm",
    "idx_prospect_index_last_name_trgm",
    "idx_prospect_index_linkedin_trgm",
    "idx_prospect_index_company_domain_trgm",
    "idx_prospect_index_personal_email_trgm",
    "idx_prospect_index_tag_text_trgm",
    "idx_prospect_index_company_country_trgm",
  ]) {
    assert.ok(sql.includes(`create index if not exists ${index}`), `${index} must be built`);
  }

  // Broad columns must not be indexed just because a filter exists for them.
  const statements = sql.split("\n").filter((line) => line.startsWith("create index"));
  for (const broad of ["company_state", "esp gin_trgm", "email_provider_type", "company_city"]) {
    assert.ok(!statements.some((line) => line.includes(broad)), `${broad} must stay unindexed`);
  }
});

test("every column the plan names has a recorded outcome", async () => {
  const sql = await migration();

  // Tier 1 from section 6.7.
  for (const column of ["full_name", "first_name", "last_name", "personal_email", "linkedin_url", "company_domain", "tag_text"]) {
    assert.ok(sql.includes(column), `Tier 1 column ${column} must appear`);
  }
  // Tier 2, each with its measured share so a skip is justified rather than assumed.
  assert.match(sql, /company_state[\s\S]*22%/);
  assert.match(sql, /esp[\s\S]*32%/);
  assert.match(sql, /company_city[\s\S]*4\.7%/);
  assert.match(sql, /email_provider_type/);

  // The two audit-cited Seq Scan shapes are named as resolved.
  assert.match(sql, /plan A/);
  assert.match(sql, /plan F/);
});

test("the costs are recorded, not just the wins", async () => {
  const sql = await migration();

  // A sub-three-character substring gets slower, and pg_trgm is why.
  assert.match(sql, /1,107 ms/);
  assert.match(sql, /rows removed by index recheck/i);

  // Write amplification, measured against the index set that already existed
  // rather than against no indexes at all.
  assert.match(sql, /2,292 ms \/ 10k/);
  assert.match(sql, /\+21\.9%/);
  assert.match(sql, /\+15\.9%/);
  // And it is stated against the right budget, not conflated with it.
  assert.match(sql, /end-to-end import throughput/);

  // A broad value must still get the sequential scan.
  assert.match(sql, /Parallel Seq Scan, 526 ms/);
});

test("the build method matches the one the repo already uses", async () => {
  const [sql, precedent, migrateScript] = await Promise.all([
    migration(),
    read("../supabase/migrations/20260901000030_index_prospect_index_company_domain.sql"),
    read("../deploy/scripts/migrate.sh"),
  ]);

  // migrate.sh wraps each file in a transaction, so CONCURRENTLY cannot be in
  // one -- the same reason 20260901000030 gives.
  assert.match(migrateScript, /echo "begin;"/);
  assert.match(precedent, /CREATE INDEX CONCURRENTLY, outside the\s*--\s*migration runner/);
  assert.doesNotMatch(sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n"), /concurrently/i);
  assert.match(sql, /create index if not exists/);
  assert.match(sql, /indisvalid/);

  // The partial-index attempt and why it failed, so nobody re-tries it.
  assert.match(sql, /PARTIAL/);
  assert.match(sql, /cannot prove/);
});
