import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships guarded deletion APIs and confirmation controls", async () => {
  const [dashboard, migration, importRoute, listRoute, clientRoute] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260807010000_deletion_management.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/imports/[id]/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/lists/[id]/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /DeleteConfirmation/);
  assert.match(dashboard, /Remove unused master records/);
  assert.match(dashboard, /Shared prospects remain untouched/);
  assert.match(migration, /not exists \(\s*select 1 from public\.list_memberships/s);
  assert.match(migration, /delete_client_with_cleanup/);
  assert.match(migration, /delete_list_with_cleanup/);
  assert.match(migration, /delete_import_with_cleanup/);
  assert.match(importRoute, /authorizeApi/);
  assert.match(listRoute, /authorizeApi/);
  assert.match(clientRoute, /authorizeApi/);
});
