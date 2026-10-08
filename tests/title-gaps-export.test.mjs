import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-08: the Job titles tab showed 200 of 84,252 undefined titles; Export all
// downloads every one for the chosen filter.
test("Export all downloads every undefined title, past PostgREST's row cap", async () => {
  const migration = await read("../supabase/migrations/20261008090000_title_classification_gaps_export.sql");
  assert.match(migration, /returns jsonb/);
  assert.doesNotMatch(migration, /\blimit\b/i);
  assert.match(migration, /revoke execute on function public\.title_classification_gaps_export_v1\(text\) from public, anon, authenticated;/);
  const route = await read("../app/api/prospects/classify/export/route.ts");
  assert.match(route, /await authorizeApi\(\)/);
  assert.match(route, /rpc\("title_classification_gaps_export_v1", \{ p_missing: missing \}\)/);
  assert.match(route, /csvDocument\(\["Job title", "Normalized title", "People", "Seniority", "Department", "Missing"\]/);
  const panel = await read("../app/components/TitleClassifierPanel.tsx");
  assert.ok(panel.includes("href={`/api/prospects/classify/export?missing=${missing}`} download"));
  assert.match(panel, />⤓ Export all<\/a>/);
});
