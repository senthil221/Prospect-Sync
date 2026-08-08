import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { classifyMxRecords, parseDnsOverHttpsMx } from "../lib/email-provider.ts";

test("classifies common secure email gateways before downstream mailbox providers", () => {
  assert.deepEqual(classifyMxRecords([
    { exchange: "mx1-us1.ppe-hosted.com", priority: 10 },
    { exchange: "example-com.mail.protection.outlook.com", priority: 20 },
  ]), {
    esp: "Proofpoint",
    category: "SEG",
    mxRecords: ["mx1-us1.ppe-hosted.com", "example-com.mail.protection.outlook.com"],
    status: "resolved",
  });
  assert.equal(classifyMxRecords(["eu-smtp-inbound-1.mimecast.com."]).esp, "Mimecast");
  assert.equal(classifyMxRecords(["d123.ess.barracudanetworks.com"]).esp, "Barracuda");
  assert.equal(classifyMxRecords(["example.c3s2.iphmx.com"]).esp, "Cisco Secure Email");
  assert.equal(classifyMxRecords(["mx-01-us-west-2.prod.hydra.sophos.com"]).esp, "Sophos Email");
});

test("classifies direct mailbox providers and preserves unknown MX evidence", () => {
  assert.equal(classifyMxRecords(["aspmx.l.google.com"]).esp, "Google Workspace");
  assert.equal(classifyMxRecords(["example-com.mail.protection.outlook.com"]).esp, "Microsoft 365");
  assert.deepEqual(classifyMxRecords(["mail.example.com"]), {
    esp: "Custom / unknown",
    category: "Unknown",
    mxRecords: ["mail.example.com"],
    status: "resolved",
  });
});

test("marks a domain with no MX without guessing a provider", () => {
  assert.deepEqual(classifyMxRecords([]), {
    esp: "No MX record",
    category: "Unknown",
    mxRecords: [],
    status: "no_mx",
  });
});

test("parses DNS-over-HTTPS MX answers for restricted runtimes", () => {
  assert.deepEqual(parseDnsOverHttpsMx({ Status: 0, Answer: [
    { type: 15, data: "20 alt2.aspmx.l.google.com." },
    { type: 1, data: "192.0.2.1" },
    { type: 15, data: "10 aspmx.l.google.com." },
  ] }), [
    { priority: 10, exchange: "aspmx.l.google.com" },
    { priority: 20, exchange: "alt2.aspmx.l.google.com" },
  ]);
  assert.deepEqual(parseDnsOverHttpsMx({ Status: 3 }), []);
});

test("wires ESP enrichment into the database-wide prospect filter", async () => {
  const [migration, route, dashboard] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260809000000_email_provider_enrichment.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/email-providers/scan/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(migration, /add column if not exists esp text/);
  assert.match(migration, /when '__esp' then ps\.esp/);
  assert.match(migration, /when '__email_provider_type' then ps\.email_provider_type/);
  assert.ok(migration.indexOf("filtered as materialized") < migration.indexOf("limit greatest"), "ESP filters must run before pagination");
  assert.match(route, /authorizeApi/);
  assert.match(route, /\.is\("mx_checked_at", null\)/);
  assert.match(dashboard, /Detect ESPs/);
  assert.match(dashboard, /Email provider type/);
});
