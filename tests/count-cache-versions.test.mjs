import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { prospectApiPath } from "../lib/dashboard-api.ts";

// Release 1B, item 4: a cached count is only valid at the dependency-version
// vector it was counted at, and a completed mutation invalidates it.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000070_version_the_count_caches.sql");
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("versions are sequences, not a counter row every writer must lock", async () => {
  const sql = executable(await migration());

  assert.match(sql, /create sequence if not exists public\.data_version_prospect/);
  assert.match(sql, /create sequence if not exists public\.data_version_company/);
  assert.match(sql, /perform nextval\('public\.data_version_prospect'\)/);
  assert.match(sql, /perform nextval\('public\.data_version_company'\)/);

  // A counter row would hold its lock until the writing transaction commits, so
  // two concurrent imports would queue behind each other for their duration.
  assert.doesNotMatch(sql, /create table[^;]*data_versions/i);
  assert.doesNotMatch(sql, /update public\.data_versions/i);

  // A fresh sequence reads last_value = 1 with is_called = false, so the first
  // nextval would be invisible to `select last_value` -- which is exactly the
  // first mutation after deploy.
  assert.match(sql, /pg_sequence_last_value\('public\.data_version_prospect'::regclass\)/);
  assert.match(sql, /pg_sequence_last_value\('public\.data_version_company'::regclass\)/);
  assert.doesNotMatch(sql, /select last_value from public\.data_version/);
});

test("companies finally has a statement-level trigger, and so does prospect_index", async () => {
  const sql = executable(await migration());

  for (const table of ["prospect_index", "companies"]) {
    for (const event of ["insert", "update", "delete"]) {
      const name = `trg_data_version_${table === "companies" ? "company" : "prospect"}_${event}`;
      assert.ok(sql.includes(`create trigger ${name} after ${event} on public.${table}`), `${name} missing`);
    }
  }
  // Once per statement over transition tables, not once per row: an import batch
  // of 5,000 rows must bump the version once.
  const triggerLines = sql.split("\n").filter((line) => line.includes("for each"));
  assert.ok(triggerLines.length >= 6, "expected six version triggers");
  for (const line of triggerLines) assert.match(line, /for each statement/);
  assert.doesNotMatch(sql, /trg_data_version[\s\S]*for each row/);
});

test("a query carries only the versions it actually reads", async () => {
  const sql = await migration();

  // A People query with no company scope must not depend on the company
  // version, or every company import would invalidate every People count.
  assert.match(sql, /case when v_has_scope then array\['prospect', 'company'\] else array\['prospect'\] end/);
  assert.match(sql, /data_versions_v1\(p_entities text\[\] DEFAULT ARRAY\['prospect', 'company'\]\)/);
  // data_versions_v1 returns only the requested keys.
  assert.match(sql, /where 'prospect' = any\(coalesce\(p_entities, array\[\]::text\[\]\)\)/);
  assert.match(sql, /where 'company' = any\(coalesce\(p_entities, array\[\]::text\[\]\)\)/);
});

test("the staleness decision is made where the data is, not one request later", async () => {
  const sql = await migration();

  assert.match(sql, /p_known_versions jsonb DEFAULT NULL::jsonb/);
  assert.match(sql, /RETURNS TABLE\(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean, data_versions jsonb\)/);
  // Recount when asked to, when the caller has no vector, or when its vector has
  // moved. Anything else would let a completed mutation leave a stale total.
  assert.match(sql, /v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;/);
  assert.match(sql, /if not v_want_total then/);
  assert.doesNotMatch(executable(sql), /if not p_with_total then/);
});

test("the vector travels client to server and back", async () => {
  const [route, workspace, clients] = await Promise.all([
    read("../app/api/prospects/route.ts"),
    read("../app/components/ProspectsWorkspace.tsx"),
    read("../app/components/ClientsPanel.tsx"),
  ]);

  // Request carries it...
  const withVersions = prospectApiPath({ knownVersions: { prospect: 7, company: 3 } });
  assert.match(withVersions, /knownVersions=%7B%22prospect%22%3A7%2C%22company%22%3A3%7D/);
  // ...and is omitted entirely when there is nothing cached yet.
  assert.doesNotMatch(prospectApiPath({}), /knownVersions/);

  // The route hands it to the database untouched and returns the live one.
  assert.match(route, /p_known_versions: query\.knownVersions/);
  assert.match(route, /versions: summary\.data_versions \?\? null/);
  // A malformed value must fall back to null, which recounts -- the safe way.
  assert.match(route, /catch \{ knownVersions = null; \}/);

  // Both grids cache the total together with the vector it was counted at.
  for (const source of [workspace, clients]) {
    assert.match(source, /knownVersions: cached\?\.versions \?\? null/);
    assert.match(source, /versions: data\.versions \?\? null/);
  }
});
