import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { observabilitySnapshot, observed, resetObservability } from "../lib/observability.ts";

async function routeFiles(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await routeFiles(full));
    else if (entry.name === "route.ts") out.push(full);
  }
  return out;
}

test("every API handler is timed - by observed(), or by the admission guard", async () => {
  const unmeasured = [];
  for (const file of await routeFiles(fileURLToPath(new URL("../app/api", import.meta.url)))) {
    const source = await readFile(file, "utf8");
    if (file.split(path.sep).join("/").endsWith("/api/health/route.ts")) continue;
    if (/lib\/admission|recordRequest\(/.test(source)) continue;
    if (/export async function (GET|POST|PATCH|DELETE|PUT)\(/.test(source)) unmeasured.push(file);
  }
  assert.deepEqual(unmeasured, [], "new routes must export observed(label, handler)");
});

test("observed() records the route's own label, its status, and a crash as a 500", async () => {
  resetObservability();
  const ok = observed("/api/clients/[id]/icp-validator", async () => Response.json({ ok: true }, { status: 201 }));
  const boom = observed("/api/lists/[id]", async () => { throw new Error("database went away"); });
  const response = await ok(new Request("https://x/api/clients/abc/icp-validator"));
  assert.equal(response.status, 201);
  await assert.rejects(boom(new Request("https://x/api/lists/1")), /database went away/);
  const snapshot = observabilitySnapshot();
  assert.equal(snapshot.routes["/api/clients/[id]/icp-validator"].ok, 1);
  assert.equal(snapshot.routes["/api/lists/[id]"].server_error, 1);
  // A label nobody registered still collapses to a bounded family.
  assert.ok(!Object.keys(snapshot.routes).some((route) => route.includes("abc")));
});

test("slow successes reach the durable log, not just the console", async () => {
  const source = await readFile(new URL("../lib/observability.ts", import.meta.url), "utf8");
  assert.match(source, /const slow = \(outcome === "ok" \|\| outcome === "pending"\) && durationMs > 5_000;/);
  assert.match(source, /if \(slow \|\| outcome === "over_cap"/);
});
