import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("the planner has statistics for companies without text", async () => {
  const migration = await readFile(new URL("../supabase/migrations/20261001100000_companies_blank_text_statistics.sql", import.meta.url), "utf8");
  // The exact expressions the Incomplete Info filter uses, together, so their
  // combined selectivity is known - not 0.5% x 0.5%.
  assert.ok(migration.includes("on (btrim(coalesce(public.tag_array_text_v1(keywords), ''))), (btrim(coalesce(short_description, '')))"));
  assert.match(migration, /analyze public\.companies;/);
  assert.match(migration, /Blank-text statistics proof passed/);
});
