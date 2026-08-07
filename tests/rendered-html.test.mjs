import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships the Prospect Sync product instead of the starter", async () => {
  const [page, layout, dashboard, login] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/login/page.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(page, /<DashboardApp currentUserEmail=/);
  assert.match(layout, /Prospect Sync/);
  assert.match(dashboard, /Master database/);
  assert.match(dashboard, /Import CSV/);
  assert.match(dashboard, /currentUserEmail/);
  assert.match(login, /signInWithPassword/);
  assert.doesNotMatch(login, /signInWithOtp/);
  assert.doesNotMatch(page, /SkeletonPreview|codex-preview/);
});
