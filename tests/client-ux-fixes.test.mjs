import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("People company cap is a compact, accessible control and keeps an explicit no-limit choice", async () => {
  const table = await read("../app/components/ProspectTable.tsx");
  assert.match(table, /<MenuButton label="People \/ company"/);
  assert.match(table, /panelLabel="Maximum people per company"/);
  assert.match(table, /aria-label="Max people per company"/);
  assert.match(table, /if \(event\.key === "ArrowDown" \|\| event\.key === "ArrowUp"\) event\.stopPropagation\(\)/);
  assert.match(table, />No limit<\/button>/);
  assert.match(table, /setMaxPeoplePerCompany\(0\)/);
  assert.match(table, /exportMaxPeoplePerCompany/);
});

test("folder deletion preserves workspaces and makes affected clients unfiled", async () => {
  const [route, panel] = await Promise.all([
    read("../app/api/client-folders/[id]/route.ts"),
    read("../app/components/ClientsPanel.tsx"),
  ]);
  assert.match(route, /authorizeApi\(\)/);
  assert.match(route, /from\("client_folders"\)[\s\S]*\.delete\(\)\.eq\("id", id\)/);
  assert.match(route, /ON DELETE SET NULL/i);
  assert.doesNotMatch(route, /from\("clients"\)|movedClients/);
  assert.match(panel, /method: "DELETE"/);
  assert.match(panel, /onFolderSelection\("unfiled"\)/);
  assert.match(panel, /including archived clients, will be kept/);
  assert.match(panel, /error=\{deleteFolderError\}/);
});

test("client directory labels focus on workspace state rather than blocked counts", async () => {
  const panel = await read("../app/components/ClientsPanel.tsx");
  assert.match(panel, /archived \? "Archived" : "Active workspace"/);
  assert.doesNotMatch(panel, /client\.blocked_count \? `\$\{formatNumber\(client\.blocked_count\)\} blocked`/);
});

test("blocklist removal has per-row actions and confirms bulk changes", async () => {
  const panel = await read("../app/components/BlocklistPanel.tsx");
  assert.match(panel, /aria-label=\{`Remove \$\{entry\.value\} from this client blocklist`\}/);
  assert.match(panel, /setRemoveRequest\(\{ count: selectedCount, payload: selectionPayload\(\) \}\)/);
  assert.match(panel, /<ConfirmDialog title=\{`Remove \$\{formatNumber\(removeRequest\.count\)\}/);
  assert.match(panel, /onConfirm=\{\(\) => void removeSelected\(removeRequest\.payload\)\}/);
});

test("recent batches use source tabs over a bounded 48-hour database query", async () => {
  const [panel, clientsPanel, route, migration, sqlFixture, sqlRunner, workflow, css] = await Promise.all([
    read("../app/components/RecentlyAddedPanel.tsx"),
    read("../app/components/ClientsPanel.tsx"),
    read("../app/api/clients/[id]/recent/route.ts"),
    read("../supabase/migrations/20260928202444_client_recent_batches_v2.sql"),
    read("../supabase/tests/client_recent_batches_v2.sql"),
    read("../scripts/test-client-recent-batches-migration.mjs"),
    read("../.github/workflows/ci.yml"),
    read("../app/workspace.css"),
  ]);
  assert.match(panel, /type SourceFilter = "all" \| "import" \| "master" \| "client"/);
  assert.match(panel, /params\.set\("source", source\)/);
  assert.match(panel, /All sources/);
  assert.match(panel, /if \(batch\.source_kind === "import"\) return "Import"/);
  assert.match(panel, /if \(batch\.source_kind === "client"\) return "Pushed from Client DB"/);
  assert.match(panel, /Pushed from Master DB/);
  assert.match(panel, /outcome_kind === "historical_source_unavailable"/);
  assert.match(panel, /past 48 hours/);
  assert.match(panel, /source_client_name \|\| batch\.source_label/);
  assert.match(panel, /source_label \|\| "Imported file"/);
  assert.match(panel, /dateTime=\{batch\.created_at\}/);
  assert.match(panel, /View records/);
  assert.match(panel, /batches\.map\(\(batch\)/);
  assert.doesNotMatch(panel, /batchGroups|recent-source-group|windowKey|24 hours|7 days|30 days|All time|groupByDay|dayGroup/);
  assert.match(clientsPanel, /<RecentlyAddedPanel key=\{client\.id\} client=\{client\}/);
  assert.match(panel, /return \(\) => \{ current = false; controller\.abort\(\); \}/);

  assert.match(route, /rawSource === null[\s\S]*client_recent_batches_v1/);
  assert.match(route, /client_recent_batches_v2/);
  assert.match(route, /p_source: source/);
  assert.match(route, /p_hours: 48/);
  assert.match(route, /Unknown source/);
  assert.match(migration, /b\.created_at >= now\(\) - pg_catalog\.make_interval/);
  assert.match(migration, /b\.source_kind = p_source[\s\S]*b\.outcome_kind <> 'historical_source_unavailable'/);
  assert.ok(migration.indexOf("b.source_kind = p_source") < migration.indexOf("page_rows as"), "source filtering must happen before pagination");
  assert.match(migration, /security invoker/);
  assert.doesNotMatch(migration, /create index/i);
  assert.match(migration, /revoke execute on function public\.client_recent_batches_v2[\s\S]*from public, anon, authenticated/);
  assert.match(migration, /grant execute on function public\.client_recent_batches_v2[\s\S]*to service_role/);
  assert.match(sqlFixture, /generate_series\(1, 60\)/);
  assert.match(sqlFixture, /v_total <> 64/);
  assert.match(sqlFixture, /preserve newest-first SQL order/);
  assert.match(sqlFixture, /Master source must exclude source-unavailable history/);
  assert.match(sqlFixture, /Source, entity and search filters must run before pagination/);
  assert.match(sqlFixture, /exactly 48 hours ago must remain visible/);
  assert.match(sqlFixture, /older than 48 hours by one microsecond must be excluded/);
  assert.match(sqlFixture, /another client crossed the client boundary/);
  assert.match(sqlFixture, /rollback;/);
  assert.match(sqlRunner, /RECENT_BATCHES_MIGRATION_TEST_ALLOW/);
  assert.match(sqlRunner, /cursor_migration_test/);
  assert.match(sqlRunner, /source-first recent-batches behavior/);
  assert.match(workflow, /node scripts\/test-client-recent-batches-migration\.mjs/);
  assert.match(css, /\.recent-source-tabs/);
});

test("deleting a client link revokes it, hides it from active links, and keeps submission records", async () => {
  const [route, panel] = await Promise.all([
    read("../app/api/clients/[id]/blocklist-shares/route.ts"),
    read("../app/components/BlocklistPanel.tsx"),
  ]);
  const dialogs = await read("../app/components/DashboardUi.tsx");
  assert.match(route, /\.is\("revoked_at", null\)\.order\("created_at"/);
  assert.match(route, /update\(\{ revoked_at: new Date\(\)\.toISOString\(\) \}\)/);
  assert.match(panel, /setShares\(\(current\) => current\.filter\(\(share\) => share\.id !== shareId\)\)/);
  assert.match(panel, /Existing client submissions and their history will be kept/);
  assert.match(panel, />Delete link<\/button>/);
  assert.match(panel, /error=\{deleteShareError\}/);
  assert.match(panel, /setShareUrl\(""\)/);
  assert.match(dialogs, /error \? <p className="form-error" role="alert">\{error\}<\/p>/);
});
