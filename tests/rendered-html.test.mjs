import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships the ProspectHub product instead of the starter", async () => {
  const [page, layout, dashboard] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(page, /<DashboardApp currentUserEmail=/);
  assert.match(layout, /ProspectHub/);
  assert.match(dashboard, /Master database/);
  assert.match(dashboard, /Import CSV/);
  assert.match(dashboard, /currentUserEmail/);
  assert.doesNotMatch(page, /SkeletonPreview|codex-preview/);
});
