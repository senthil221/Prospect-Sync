import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships agency operations without enrichment or reporting modules", async () => {
  const [dashboard, filterPanel, migration, coverage, operations, quality, lists, savedViews] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260808000000_agency_operations.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/coverage/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/operations/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/data-quality/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/lists/[id]/rows/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/saved-views/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Company coverage checker/);
  assert.match(dashboard, /Data quality centre/);
  assert.match(dashboard, /LIST WORKSPACE|ListWorkspace/);
  assert.match(dashboard, /Mark contacted/);
  assert.match(dashboard, /Saved views/);
  assert.match(filterPanel, /Exclude/);
  assert.match(dashboard, /Field mapping/);
  assert.match(dashboard, /Skip to main content/);
  assert.match(migration, /create table if not exists public\.contact_events/);
  assert.match(migration, /create table if not exists public\.saved_views/);
  assert.match(migration, /create or replace function public\.merge_prospects/);
  assert.match(migration, /create or replace function public\.data_quality_overview/);
  assert.match(coverage, /normalized_domain/);
  assert.match(operations, /mark_contacted/);
  assert.match(quality, /data_quality_overview/);
  assert.match(lists, /list_workspace/);
  assert.match(savedViews, /saved_views/);
  assert.doesNotMatch(migration, /enrichment_provider|campaign_reporting/);
});
