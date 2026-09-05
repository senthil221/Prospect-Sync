// Stress the deployed application through the real HTTP path.
//
// This exists because the obvious way to load-test a database - open N psql
// connections and fire queries - measures the wrong thing. It bypasses Next.js,
// so it never exercises the admission guard, never produces a 503, never uses
// the PostgREST pool, and never tells you whether a browser would have got an
// answer. Everything here goes through /api, authenticated the way a user is.
//
// Listing requests may create disposable prepared-search jobs. No customer
// records are mutated. Remote targets require an explicit opt-in: this workload
// can impair a live service and must not run against production by accident.
//
//   E2E_BASE_URL=https://app.example.com \
//   E2E_USER_EMAIL=... E2E_USER_PASSWORD=... \
//   node scripts/load-test.mjs
//
// Options (env):
//   LOAD_USERS      concurrent users              default 20  (the plan's target)
//   LOAD_SECONDS    how long to sustain them      default 900 (15-minute soak)
//   LOAD_SPIKE      users for a 60s spike after   default 40  (0 to skip)
//   LOAD_PROFILE    "soak" | "smoke"              default soak; smoke = 5 users, 60s
//
// It checks the section 2 service-level objectives and prints a verdict per
// journey, plus the server's own refusal counters from /api/health, which is the
// only place a 503 or a 504 that a user absorbed silently shows up.

import { chromium } from "@playwright/test";
import { expectedStatus, runReadJourney, validateLoadTarget } from './load-journey.mjs';

const baseURL = process.env.E2E_BASE_URL || "http://127.0.0.1:3000";
const email = process.env.E2E_USER_EMAIL || "";
const password = process.env.E2E_USER_PASSWORD || "";
const smoke = process.env.LOAD_PROFILE === "smoke";
const users = Number(process.env.LOAD_USERS ?? (smoke ? 5 : 20));
const seconds = Number(process.env.LOAD_SECONDS ?? (smoke ? 60 : 900));
const spikeUsers = Number(process.env.LOAD_SPIKE ?? (smoke ? 0 : 40));
const overloadTest = process.env.LOAD_EXPECT_OVERLOAD === '1';
validateLoadTarget(baseURL, process.env.LOAD_ALLOW_REMOTE === '1');
for (const [name, value, min, max] of [['LOAD_USERS', users, 1, 100], ['LOAD_SECONDS', seconds, 1, 7200], ['LOAD_SPIKE', spikeUsers, 0, 100]]) {
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${name} must be an integer from ${min} to ${max}`);
}

if (!email || !password) {
  console.error("Set E2E_USER_EMAIL and E2E_USER_PASSWORD (an allow-listed login).");
  process.exit(2);
}

const encode = (value) => encodeURIComponent(JSON.stringify(value));

// Weighted so the mix resembles real use: mostly ordinary pages, some filtered
// work, a little autocomplete, and one shape that must be refused.
const scenarios = [
  { name: "page 1, unfiltered", weight: 30, slo: 2000,
    path: () => `/api/prospects?page=1&sort=created_at&direction=desc&withTotal=1` },
  { name: "page 1, sorted by name", weight: 10, slo: 2000,
    path: () => `/api/prospects?page=1&sort=name&direction=asc&withTotal=1` },
  { name: "deep page", weight: 8, slo: 2000,
    path: () => `/api/prospects?page=${200 + Math.floor(Math.random() * 800)}&sort=created_at&direction=desc&withTotal=0` },
  { name: "search", weight: 12, slo: 2000,
    path: () => `/api/prospects?page=1&search=${["kumar", "singh", "sharma", "patel"][Math.floor(Math.random() * 4)]}&withTotal=1` },
  { name: "one filter", weight: 15, slo: 2000,
    path: () => `/api/prospects?page=1&withTotal=1&filters=${encode([{ field: "__title", operator: "contains", values: ["manager"] }])}` },
  { name: "complex filter set", weight: 10, slo: 5000,
    path: () => `/api/prospects?page=1&withTotal=1&filters=${encode([
      { field: "__title", operator: "contains", values: ["manager", "director", "head"] },
      { field: "__country", operator: "equals", values: ["India"] },
      { field: "__name", operator: "contains", values: ["a"] },
      { field: "__company", operator: "not_contains", values: ["test"] },
    ])}` },
  { name: "companies listing", weight: 8, slo: 2000,
    path: () => `/api/companies?page=1&pageSize=50` },
  { name: "filter-value suggestions", weight: 5, slo: 500,
    path: () => `/api/prospects/filter-values?field=__title&search=eng&limit=50` },
  // Must be refused with 413 rather than served or 500'd. Counted separately.
  { name: "over-cap (expects 413)", weight: 2, slo: 2000, expect: 413,
    path: () => `/api/prospects?page=1&filters=${encode([
      { field: "__title", operator: "equals", values: Array.from({ length: 5001 }, (_, i) => `v${i}`) },
    ])}` },
];

// Supply the exact keyword fixture for this run, without putting prospect data
// into logs. Repeated requests measure reuse; distinct cold-search bursts need
// separate scenarios and explicit arrival rates, not random query cache-busting.
if (process.env.LOAD_COMPANY_KEYWORDS) {
  const terms = JSON.parse(process.env.LOAD_COMPANY_KEYWORDS);
  if (!Array.isArray(terms) || !terms.length || terms.length > 150 || terms.some(t => typeof t !== 'string' || t.length > 160)) {
    throw new Error('LOAD_COMPANY_KEYWORDS must be a JSON array of 1–150 short strings');
  }
  scenarios.push({ name: 'description → People', weight: 5, slo: 60000,
    path: () => `/api/prospects?page=1&withTotal=1&companyScope=${encode({ search: '', limit: 250000,
      filters: [{ field: '__company_keywords', operator: 'contains', scopes: ['name', 'keywords', 'description'], values: terms }] })}` });
}

const pool = scenarios.flatMap((scenario) => Array(scenario.weight).fill(scenario));
const pick = () => pool[Math.floor(Math.random() * pool.length)];

const results = new Map();
function record(name, ms, status, expected, pendingResponses = 0) {
  const bucket = results.get(name) ?? { ms: [], statuses: new Map(), unexpected: 0, pendingResponses: 0 };
  bucket.pendingResponses += pendingResponses;
  bucket.ms.push(ms);
  bucket.statuses.set(status, (bucket.statuses.get(status) ?? 0) + 1);
  if (!expectedStatus(status, expected, overloadTest)) bucket.unexpected += 1;
  results.set(name, bucket);
}

const percentile = (sorted, p) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] : 0;

async function health(request) {
  try {
    const response = await request.get("/api/health", { headers: { "cache-control": "no-store" } });
    return await response.json();
  } catch { return null; }
}

async function drive(request, until) {
  while (Date.now() < until) {
    const scenario = pick();
    const startedAt = Date.now();
    try {
      const path = scenario.path(); // Every poll must ask the SAME question.
      const result = await runReadJourney(timeout => request.get(path, { headers: { "cache-control": "no-store" }, timeout }));
      record(scenario.name, Math.round(result.durationMs), result.status, scenario.expect, result.pendingResponses);
    } catch {
      record(scenario.name, Date.now() - startedAt, 0, scenario.expect);
    }
    // A real user reads the page before clicking again.
    await new Promise((resolve) => setTimeout(resolve, 200 + Math.random() * 800));
  }
}

async function phase(context, label, count, durationSeconds) {
  console.log(`\n=== ${label}: ${count} concurrent users for ${durationSeconds}s ===`);
  const until = Date.now() + durationSeconds * 1000;
  const workers = Array.from({ length: count }, () => drive(context.request, until));
  const ticker = setInterval(() => {
    const remaining = Math.max(0, Math.round((until - Date.now()) / 1000));
    const done = [...results.values()].reduce((sum, bucket) => sum + bucket.ms.length, 0);
    process.stdout.write(`  ${remaining}s left, ${done} requests so far\r`);
  }, 5000);
  await Promise.all(workers);
  clearInterval(ticker);
  process.stdout.write("\n");
}

function report(before, after) {
  console.log("\n=== latency by journey ===");
  console.log("journey".padEnd(28), "n".padStart(6), "p50".padStart(8), "p95".padStart(8), "p99".padStart(8), "max".padStart(8), "  slo   verdict");
  let failures = 0;
  for (const scenario of scenarios) {
    const bucket = results.get(scenario.name);
    if (!bucket) continue;
    const sorted = [...bucket.ms].sort((a, b) => a - b);
    const p95 = percentile(sorted, 0.95);
    const withinSlo = p95 <= scenario.slo;
    if (!withinSlo || bucket.unexpected) failures += 1;
    console.log(
      scenario.name.padEnd(28),
      String(sorted.length).padStart(6),
      `${percentile(sorted, 0.5)}ms`.padStart(8),
      `${p95}ms`.padStart(8),
      `${percentile(sorted, 0.99)}ms`.padStart(8),
      `${sorted.at(-1)}ms`.padStart(8),
      ` ${scenario.slo}ms`.padStart(8),
      withinSlo ? "PASS" : "OVER SLO",
      bucket.unexpected ? `  ${bucket.unexpected} unexpected statuses` : "",
    );
  }

  console.log(`\n=== status codes (503 ${overloadTest ? 'allowed in explicit overload test' : 'FAILS the certified-load gate'}) ===`);
  const totals = new Map();
  for (const bucket of results.values()) {
    for (const [status, count] of bucket.statuses) totals.set(status, (totals.get(status) ?? 0) + count);
  }
  for (const [status, count] of [...totals].sort((a, b) => b[1] - a[1])) {
    const meaning = { 200: "served", 413: "over-cap refusal", 503: "admission refusal", 504: "statement timeout", 0: "client/network error" }[status] ?? "";
    console.log(`  ${status || "ERR"}  ${String(count).padStart(6)}  ${meaning}`);
  }

  const serverErrors = [...totals].filter(([status]) => status >= 500 && status !== 503 && status !== 504)
    .reduce((sum, [, count]) => sum + count, 0);

  console.log("\n=== what the server itself counted (per app slot, from /api/health) ===");
  for (const [label, snapshot] of [["before", before], ["after", after]]) {
    if (!snapshot?.load) { console.log(`  ${label}: unavailable`); continue; }
    const { admission, requests, outcomes, slowestMs } = snapshot.load;
    console.log(`  ${label}: requests=${requests} admission=${admission.inFlight}/${admission.limit} (waiting ${admission.waiting})`);
    console.log(`          outcomes=${JSON.stringify(outcomes)}`);
    console.log(`          slowest=${JSON.stringify(slowestMs)}`);
  }

  console.log("\n=== verdict ===");
  console.log('  This run alone is NOT capacity certification: require the workload matrix, cold-cache runs, sufficient samples and recovery checks.');
  console.log(`  pending HTTP responses excluded from success .... ${[...results.values()].reduce((sum, b) => sum + b.pendingResponses, 0)}`);
  console.log(`  unhandled 5xx (must be 0) .............. ${serverErrors}`);
  console.log(`  journeys over their SLO ................ ${failures}`);
  console.log(`  overall ................................ ${serverErrors === 0 && failures === 0 ? "PASS" : "NEEDS ATTENTION"}`);
  return serverErrors === 0 && failures === 0 ? 0 : 1;
}

const browser = await chromium.launch();
const context = await browser.newContext({ baseURL });
const page = await context.newPage();

console.log(`Signing in to ${baseURL} as ${email} ...`);
await page.goto("/login");
await page.getByLabel("Email address").fill(email);
await page.getByLabel("Password").fill(password);
await page.getByRole("button", { name: "Sign in securely" }).click();
await page.getByRole("navigation", { name: "Primary navigation" }).waitFor({ timeout: 60_000 });
await page.close();
console.log("Signed in. The session cookie is reused for every request below.");

const before = await health(context.request);
await phase(context, "soak", users, seconds);
if (spikeUsers > 0) await phase(context, "spike", spikeUsers, 60);
const after = await health(context.request);

const exitCode = report(before, after);
await context.close();
await browser.close();
process.exit(exitCode);
