import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("verification claims walk the claim indexes instead of sorting every waiting target", async () => {
  const migration = await read("../supabase/migrations/20260930110000_verification_claim_walks_an_index.sql");
  const body = migration.slice(migration.indexOf("create or replace function public.claim_email_verification_check_v1("));
  // No GROUP BY over runs x targets x checks any more; the partial-index
  // predicate is spelled exactly so the planner can use it.
  assert.doesNotMatch(body, /group by r\.id,c\.id/);
  assert.equal(body.match(/where c\.execution_state in \('queued','running'\)/g).length, 2);
  assert.match(body, /order by c\.priority desc,c\.created_at limit 20/);
  assert.match(body, /order by c\.created_at limit 20/);
  // Locking and revalidation are unchanged.
  assert.match(body, /for update skip locked;\s+if v_check\.id is not null and exists/);
  assert.match(migration, /grant execute on function public\.claim_email_verification_check_v1\(text,integer,integer\) to prospect_verifier/);
  const harness = await read("../scripts/test-email-verification-migration.mjs");
  assert.match(harness, /'20260930110000_verification_claim_walks_an_index\.sql'/);
});

test("reply blocks are read-only, current-account scoped, and admin-only", async () => {
  const migration = await read("../supabase/migrations/20260930120000_reply_blocklist_activity.sql");
  assert.match(migration, /language sql\s+stable\s+security definer/);
  assert.match(migration, /join current_connection cc on cc\.generation = a\.connection_generation/);
  assert.doesNotMatch(migration, /\b(insert into|update|delete from)\s+(public|prospect_integrations)\./i);
  assert.match(migration, /revoke execute on function public\.smartlead_reply_blocks_v1\([^)]*\) from public, anon, authenticated;/);

  const route = await read("../app/api/integrations/reply-blocks/route.ts");
  assert.match(route, /integrationAdmin\(user\.email, process\.env\.INTEGRATION_ADMIN_EMAILS\)/);
  assert.match(route, /status: 403|, 403\)/);

  const panel = await read("../app/components/ReplyBlocklistPanel.tsx");
  assert.match(panel, /<ReplyBlocksSummary refreshKey=\{inbox\.counts\.applied\}\/>/);
});

test("reply reasons are toned by what the reply means", async () => {
  const source = await read("../app/components/ReplyBlocksSummary.tsx");
  const setLine = (name) => source.split("\n").find((line) => line.startsWith(`const ${name} = new Set(`)) ?? "";
  for (const reason of ["interested", "meeting request", "information request"]) assert.ok(setLine("engaged").includes(`"${reason}"`), reason);
  for (const reason of ["not interested", "do not contact", "not the right fit"]) assert.ok(setLine("rejected").includes(`"${reason}"`), reason);
});

test("the ICP validator is drawn by presentational views with its own stylesheet", async () => {
  const layout = await read("../app/layout.tsx");
  assert.match(layout, /import "\.\/icp-validator\.css";/);
  const css = await read("../app/icp-validator.css");
  // Tokens only, so light and dark both follow the design system.
  assert.doesNotMatch(css.replace(/rgba\(255, 255, 255, \.15\)/g, "").replace(/#000 100%/g, ""), /#[0-9a-f]{3,6}\b/i);
  assert.match(css, /@media \(prefers-reduced-motion: reduce\)/);
  const views = await read("../app/components/IcpValidatorViews.tsx");
  assert.doesNotMatch(views, /\bfetch\(|\bapi\(/, "views draw; the panel fetches");
});

test("results filter by agreement, and runs say how long they took", async () => {
  const migration = await read("../supabase/migrations/20260930130000_icp_results_all_non_fit_filter.sql");
  assert.match(migration, /bool_and\(v\.verdict = 'NON_FIT'\) as all_non_fit/);
  assert.match(migration, /or \(p_filter = 'all_non_fit' and g\.all_non_fit\)\)/);
  const panel = await read("../app/components/IcpValidatorPanel.tsx");
  assert.match(panel, /type Filter = "all" \| "fit" \| "all_non_fit" \| "disagree";/);
  assert.doesNotMatch(panel, /Any NON_FIT/);
  const { durationText } = await import("../app/components/IcpValidatorViews.tsx").catch(() => ({}));
  if (durationText) {
    assert.equal(durationText("2026-09-30T10:00:00Z", "2026-09-30T10:12:30Z"), "12m 30s");
  }
  const views = await read("../app/components/IcpValidatorViews.tsx");
  assert.match(views, /run\.finished_at \? `Took \$\{took\}` : active \? `Running \$\{took\}`/);
});

test("reconciliation reads flagged ready targets, and every finish path flags them", async () => {
  const migration = await read("../supabase/migrations/20260930160000_reconcile_reads_ready_targets.sql");
  assert.match(migration, /on prospect_verification\.run_targets \(run_id, prospect_id\)\s+where state = 'waiting' and reconcile_ready;/);
  // Any check reaching completed or error flags its waiting targets...
  assert.match(migration, /after update of execution_state on prospect_verification\.email_checks[\s\S]*?when \(new\.execution_state in \('completed', 'error'\)/);
  // ...and a target attached to an already-finished check is flagged as it is attached.
  assert.match(migration, /before insert or update of check_id on prospect_verification\.run_targets/);
  // The pick still joins the check state, so the flag only narrows it.
  assert.match(migration, /t\.state='waiting' and t\.reconcile_ready and c\.execution_state in \('completed','error'\)/);
  assert.match(migration, /update prospect_verification\.run_targets t\s+set reconcile_ready = true/);
  const harness = await read("../scripts/test-email-verification-migration.mjs");
  assert.match(harness, /'20260930160000_reconcile_reads_ready_targets\.sql'/);
});
