import assert from "node:assert/strict";
import test from "node:test";
import { blocklistShareOrigin } from "../app/api/clients/[id]/blocklist-shares/public-origin.ts";

test("production client links use the configured public site, even behind an internal proxy", () => {
  assert.equal(blocklistShareOrigin("https://app.clearroadco.link", "http://0.0.0.0:3000/api/clients/1/blocklist-shares", true), "https://app.clearroadco.link");
});

test("production rejects missing or malformed public origins", () => {
  assert.throws(() => blocklistShareOrigin(undefined, "http://0.0.0.0:3000", true), /APP_PUBLIC_URL/);
  assert.throws(() => blocklistShareOrigin("http://app.clearroadco.link", "http://0.0.0.0:3000", true), /APP_PUBLIC_URL/);
  assert.throws(() => blocklistShareOrigin("https://app.clearroadco.link/path", "http://0.0.0.0:3000", true), /APP_PUBLIC_URL/);
});

test("local development uses the request origin when no public URL is configured", () => {
  assert.equal(blocklistShareOrigin(undefined, "http://localhost:3000/api/clients/1/blocklist-shares", false), "http://localhost:3000");
});
