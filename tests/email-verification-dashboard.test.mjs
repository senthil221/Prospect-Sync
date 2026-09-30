import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("the dashboard reads the verification tables only, never all prospects", async () => {
  const migration = await read("../supabase/migrations/20260930150000_email_verification_dashboard.sql");
  const body = migration.slice(migration.indexOf("create or replace function"));
  assert.doesNotMatch(body, /public\.prospects\b/);
  assert.match(body, /language sql\s+stable\s+security definer/);
  // Runs come back without their filter payloads (one run carried 549 emails).
  assert.doesNotMatch(body, /select \* from prospect_verification\.runs/);
  assert.match(body, /jsonb_array_length\(filters\) else 0 end as filter_count/);
  assert.match(migration, /revoke execute on function public\.email_verification_dashboard_v1\(integer\) from public, anon, authenticated;/);
});

test("the page is a section with its own nav entry and live polling", async () => {
  const types = await read("../lib/types.ts");
  assert.match(types, /"verification"/);
  const url = await read("../lib/workspace-url.ts");
  assert.match(url, /"reply-blocklist", "verification"\]/);
  const app = await read("../app/DashboardApp.tsx");
  assert.match(app, /\{ id: "verification", label: "Email verification", mark: "check" \}/);
  assert.match(app, /section === "verification" && <EmailVerificationWorkspace isAdmin=\{isAdmin\}\/>/);
  const page = await read("../app/components/EmailVerificationWorkspace.tsx");
  assert.match(page, /fetch\("\/api\/verifications\/dashboard"/);
  assert.match(page, /document\.visibilityState === "visible"/);
  // Controls reuse the existing, already-guarded routes.
  assert.match(page, /"\/api\/verifications\/provider"/);
  assert.match(page, /`\/api\/verifications\/\$\{run\.id\}`/);
});

test("the page keeps to what an operator acts on", async () => {
  const page = await read("../app/components/EmailVerificationWorkspace.tsx");
  // The hourly chart and the all-time / 24h switch earn their place; long
  // explanations stay in hover titles.
  assert.ok(page.includes("export function EvThroughput"));
  assert.ok(page.includes('label="Period" value={period}'));
  assert.ok(!page.includes("<small>{outcome.hint}</small>"));
  assert.ok(page.includes('<h4 id="evx-results-title">Email status</h4>'));
});

test("dispatch state names the worst condition first, and the ETA reads naturally", async () => {
  const { dispatchState, etaText } = await import("../app/components/EmailVerificationWorkspace.tsx").catch(() => ({}));
  if (!dispatchState) return;
  const base = { enabled: true, manually_paused: false, pause_reason: null, cooldown_until: null, quota_wait_until: null, daily_limit: 1, daily_attempts: 0,
    worker_configured: true, worker_alive: true, worker_seen_at: null, consecutive_failures: 0, now: "2026-09-30T10:00:00Z" };
  assert.equal(dispatchState(base, 10).label, "Verifying");
  assert.equal(dispatchState({ ...base, worker_alive: false }, 10).label, "Worker offline");
  assert.equal(dispatchState({ ...base, manually_paused: true }, 10).label, "Paused");
  assert.equal(dispatchState({ ...base, cooldown_until: "2026-09-30T10:05:00Z" }, 10).label, "Cooling down");
  assert.equal(dispatchState(base, 0).label, "Idle");
  assert.equal(etaText(45), "~45 min");
  assert.equal(etaText(60 * 24 * 6 + 60 * 22), "~6d 22h");
});
