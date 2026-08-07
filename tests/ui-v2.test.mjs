import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships the readable Prospect Sync UI v2 system", async () => {
  const [dashboard, styles] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/workspace.css", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /Your agency’s prospect intelligence/);
  assert.match(dashboard, /function AppIcon/);
  assert.match(dashboard, /company-table/);
  assert.match(dashboard, /filtersOpen/);
  assert.match(styles, /html, body[\s\S]*font-size: 14px/);
  assert.match(styles, /\.master-data-table td[\s\S]*font-size: 13px/);
  assert.match(styles, /\.company-table/);
  assert.match(styles, /@media \(max-width: 760px\)/);
  assert.match(styles, /prefers-reduced-motion/);
  assert.doesNotMatch(styles, /font-size: 6(?:\.5)?px/);
});
