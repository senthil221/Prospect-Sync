import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("prospect lists can be imported without entering a client name", async () => {
  const [panel, route, owner] = await Promise.all([
    readFile(new URL("../app/components/ImportsPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/start/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/import-owner.ts", import.meta.url), "utf8"),
  ]);

  assert.match(panel, /No client \(list only\)/);
  assert.match(panel, /withoutClient = clientId === unassignedClientId/);
  assert.match(route, /payload\.withoutClient === true/);
  assert.match(route, /from\("clients"\)\.upsert/);
  assert.match(route, /client_id: clientId/);
  assert.match(owner, /unassignedClientId = "prospect-sync-no-client"/);
});
