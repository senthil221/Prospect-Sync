import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Release 2, item 1: values live in the database and requests carry a set id.
// Verified behaviourally against production in a rolled-back transaction; these
// pin the properties that verification established.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000100_durable_filter_sets.sql");
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("a set's identity is its content, never its random id", async () => {
  const sql = executable(await migration());

  // Section 4.1: canonicalization uses the content hash and normalization
  // version, never the uuid - or two users pasting the same list would miss
  // each other's cached counts.
  assert.match(sql, /create unique index if not exists uq_filter_sets_identity[\s\S]*?\(owner_id, entity_type, client_scope, field, normalization_version, content_hash\)/);
  assert.match(sql, /v_hash := md5\(array_to_string\(v_values, E'\\n'\)\)/);
  // Ordered before hashing, so the hash does not depend on paste order.
  assert.match(sql, /array_agg\(value order by value\)/);
  // Normalized and deduplicated once, server side.
  assert.match(sql, /select distinct lower\(btrim\(unnested\)\) as value/);
  assert.match(sql, /normalization_version/);
});

test("a set id on its own is not authorization", async () => {
  const sql = executable(await migration());

  // Every resolve takes the owner and the scope, and matches on both.
  assert.match(sql, /create or replace function prospect_filters\.resolve_set_v1\(\s*p_set_id uuid,\s*p_owner_id text,\s*p_entity_type text,\s*p_client_scope text/);
  assert.match(sql, /and fs\.owner_id = p_owner_id/);
  assert.match(sql, /and fs\.client_scope = coalesce\(p_client_scope, ''\)/);
  assert.match(sql, /and fs\.expires_at > now\(\)/);
  // One message for missing, not-yours and expired, so probing ids teaches
  // nothing.
  assert.match(sql, /raise exception 'Filter set is not available'/);
});

test("the storage is private and the cap is enforced in the database", async () => {
  const sql = executable(await migration());

  // Same posture as prospect_import: nothing reachable through the Data API.
  assert.match(sql, /revoke all on schema prospect_filters from public, anon, authenticated;/);
  assert.match(sql, /revoke all on prospect_filters\.filter_sets from public, anon, authenticated;/);
  assert.match(sql, /revoke all on prospect_filters\.filter_set_values from public, anon, authenticated;/);
  for (const fn of [
    "create_set_v1\\(text, text, text, text, text\\[\\], interval\\)",
    "resolve_set_v1\\(uuid, text, text, text\\)",
    "expire_sets_v1\\(\\)",
    "usage_v1\\(\\)",
  ]) {
    assert.match(sql, new RegExp(`revoke execute on function prospect_filters\\.${fn} from public, anon, authenticated;`));
    assert.match(sql, new RegExp(`grant execute on function prospect_filters\\.${fn} to service_role;`));
  }

  // 10,000 is the section 6.3 ceiling, checked in the column and in the
  // function, so a direct insert cannot get past it either.
  assert.match(sql, /value_count integer not null check \(value_count between 1 and 10000\)/);
  assert.match(sql, /if v_count > 10000 then/);

  // TTL and storage monitoring, both named in section 6.3.
  assert.match(sql, /expire_sets_v1/);
  assert.match(sql, /usage_v1/);
  assert.match(sql, /idx_filter_sets_expires_at/);
});

test("the values table is keyed for the lookup it exists to serve", async () => {
  const sql = executable(await migration());
  assert.match(sql, /primary key \(filter_set_id, normalized_value\)/);
  assert.match(sql, /references prospect_filters\.filter_sets\(id\) on delete cascade/);
});

test("the honest measurement is recorded, including that it is not faster", async () => {
  const sql = await migration();

  // This is the claim that would be easiest to overstate, so it is written down
  // with the numbers that contradict it.
  assert.match(sql, /WHAT THIS DOES NOT DO: make the query faster/);
  assert.match(sql, /496 ms/);
  assert.match(sql, /650 ms/);
  assert.match(sql, /2,492 ms/);
  assert.match(sql, /must not be sold as one/);

  // And what it does buy instead.
  assert.match(sql, /82 KB to about 200 bytes/);
  assert.match(sql, /5,000 to 10,000/);
});

test("prospect_index.normalized_domain is skipped with its reason, not silently", async () => {
  const sql = await migration();
  assert.match(sql, /0 of 419,214/);
  assert.match(sql, /0 of 656,431/);
  // Rather than a duplicate column, the invariant that makes the existing index
  // correct is enforced.
  assert.match(executable(sql), /add constraint companies_domain_is_normalized/);
  assert.match(executable(sql), /check \(domain is null or normalized_domain is null or lower\(domain\) = normalized_domain\)/);
  // NOT VALID: no full-table lock to re-check rows measured to have zero
  // violations, but every future write is checked.
  assert.match(executable(sql), /not valid;/);
});
