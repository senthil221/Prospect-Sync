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

test("recent batches group by source while keeping batch times and record expansion", async () => {
  const panel = await read("../app/components/RecentlyAddedPanel.tsx");
  assert.match(panel, /key: "import", label: "Import"/);
  assert.match(panel, /key: "client", label: "Pushed from Client DB"/);
  assert.match(panel, /Pushed from Master DB/);
  assert.match(panel, /source_client_name \|\| batch\.source_label/);
  assert.match(panel, /source_label \|\| "Imported file"/);
  assert.match(panel, /dateTime=\{batch\.created_at\}/);
  assert.match(panel, /View records/);
  assert.doesNotMatch(panel, /groupByDay|dayGroup/);
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
