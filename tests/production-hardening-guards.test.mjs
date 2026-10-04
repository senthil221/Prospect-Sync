import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { publicAppOrigin } from "../lib/public-app-origin.ts";
import { hasUnsupportedPeoplePivot } from "../lib/workspace-scopes.ts";

const read = path => readFile(new URL(path, import.meta.url), "utf8");

test("public redirects trust configured origins and only fall back to explicit local development", () => {
  assert.equal(publicAppOrigin("https://app.example.test", "https://poisoned.example/login", true), "https://app.example.test");
  assert.equal(publicAppOrigin(undefined, "http://127.0.0.1:3000/auth/signout", false), "http://127.0.0.1:3000");
  assert.throws(() => publicAppOrigin(undefined, "https://poisoned.example/auth/signout", true), /APP_PUBLIC_URL/);
  assert.throws(() => publicAppOrigin(undefined, "https://poisoned.example/auth/signout", false), /local development/);
  assert.throws(() => publicAppOrigin("https://app.example.test/path", "http://localhost:3000", true), /valid public origin/);
  assert.throws(() => publicAppOrigin("http://app.example.test", "http://localhost:3000", true), /valid public origin/);
  assert.throws(() => publicAppOrigin("https://0.0.0.0:3000", "http://localhost:3000", true), /valid public origin/);
});

test("People pivot guard distinguishes absent, malformed, empty and narrowing values", () => {
  assert.equal(hasUnsupportedPeoplePivot({}), false);
  assert.equal(hasUnsupportedPeoplePivot({ peopleScope: null }), false);
  assert.equal(hasUnsupportedPeoplePivot({ peopleScope: {} }), false);
  assert.equal(hasUnsupportedPeoplePivot({ peopleScope: { search: "", filters: [] } }), false);
  assert.equal(hasUnsupportedPeoplePivot({ peopleScope: { search: "manager", filters: [] } }), true);
  assert.throws(() => hasUnsupportedPeoplePivot({ peopleScope: false }), /pivot scope must be an object/);
  assert.throws(() => hasUnsupportedPeoplePivot({ peopleScope: 0 }), /pivot scope must be an object/);
  assert.throws(() => hasUnsupportedPeoplePivot({ peopleScope: "" }), /pivot scope must be an object/);
});

test("background APIs reject unsupported People pivots before a database client or RPC", async () => {
  for (const path of ["../app/api/exports/route.ts", "../app/api/result-sets/route.ts"]) {
    const source = await read(path);
    const parseAt = source.indexOf("hasUnsupportedPeoplePivot(payload)");
    const rejectAt = source.indexOf("if (unsupportedPeoplePivot)");
    const clientAt = source.indexOf("createAdminClient()");
    const rpcAt = source.indexOf('.rpc("request_result_set_v1"');
    assert.ok(parseAt >= 0 && rejectAt > parseAt, `${path} validates People scope`);
    assert.ok(clientAt > rejectAt, `${path} rejects before creating a database client`);
    assert.ok(rpcAt > rejectAt, `${path} rejects before requesting a result set`);
  }
});

test("mobile sheet mounts its focus owner only while the dialog exists", async () => {
  const source = await read("../app/components/MobileNav.tsx");
  const componentAt = source.indexOf("function MobileNavSheet");
  const hookAt = source.indexOf("useDialogFocus(sheet", componentAt);
  const conditionalAt = source.indexOf("open ? <MobileNavSheet");
  assert.ok(componentAt >= 0 && hookAt > componentAt && conditionalAt > hookAt);
  assert.doesNotMatch(source.slice(source.indexOf("export default function MobileNav"), conditionalAt), /useDialogFocus/);
});

test("visual smoke uses current navigation and fails rather than skipping missing screens", async () => {
  const source = await read("../tests/e2e/visual-workspaces.spec.ts");
  assert.match(source, /People database/);
  assert.match(source, /Clients & lists/);
  assert.doesNotMatch(source, /if \(await link\.count\(\) === 0\) continue/);
  assert.match(source, /localStorage\.setItem\("prospecthub-theme"/);
});
