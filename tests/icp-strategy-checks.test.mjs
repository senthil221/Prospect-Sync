import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  CHEAPEST_QUANTIZATIONS, ICP_STRATEGIES, openRouterBody, sourceLabel, strategyVerdict,
} from "../worker/icp-validator-core.mjs";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260930210000_icp_strategy_checks.sql";

test("the three strategies are the agreed combos: DeepSeek high + GPT Luna low", () => {
  const byId = Object.fromEntries(ICP_STRATEGIES.map((strategy) => [strategy.id, strategy]));
  const ds = { model: "deepseek/deepseek-v4.1-flash", effort: "high" };
  const gpt = { model: "openai/gpt-6-luna", effort: "low" };
  assert.deepEqual(byId.strict.passes, [ds, gpt]);
  assert.deepEqual(byId.lenient.passes, [ds, ds]);
  assert.deepEqual(byId.balanced.passes, [ds, ds, gpt]);
});

test("the app's strategies are exactly the ones the database runs", async () => {
  const migration = await read(migrationPath);
  const rows = [...migration.matchAll(/\('(strict|lenient|balanced)',\s*(\d), '([^']+)',\s*'(\w+)'\)/g)]
    .map(([, strategy, pass, model, effort]) => ({ strategy, pass: Number(pass), model, effort }));
  for (const strategy of ICP_STRATEGIES) {
    const sql = rows.filter((row) => row.strategy === strategy.id).sort((a, b) => a.pass - b.pass);
    assert.deepEqual(sql.map(({ model, effort }) => ({ model, effort })), strategy.passes, strategy.id);
  }
  // passes and need_fit, as the rule function states them
  assert.match(migration, /select case p_strategy when 'balanced' then 3 else 2 end,\s+case p_strategy when 'strict' then 2 when 'lenient' then 1 else 2 end/);
  assert.deepEqual(ICP_STRATEGIES.map((strategy) => [strategy.id, strategy.needFit]), [["strict", 2], ["balanced", 2], ["lenient", 1]]);
});

test("a company is decided as soon as the votes make the outcome certain", () => {
  // Strict: both FIT, or one NON_FIT.
  assert.equal(strategyVerdict("strict", 1, 0), null);
  assert.equal(strategyVerdict("strict", 2, 0), "FIT");
  assert.equal(strategyVerdict("strict", 0, 1), "NON_FIT");
  assert.equal(strategyVerdict("strict", 1, 1), "NON_FIT");
  // Lenient: one FIT, or both NON_FIT.
  assert.equal(strategyVerdict("lenient", 1, 0), "FIT");
  assert.equal(strategyVerdict("lenient", 0, 1), null);
  assert.equal(strategyVerdict("lenient", 0, 2), "NON_FIT");
  assert.equal(strategyVerdict("lenient", 1, 1), "FIT");
  // Balanced: two alike.
  assert.equal(strategyVerdict("balanced", 1, 1), null);
  assert.equal(strategyVerdict("balanced", 2, 0), "FIT");
  assert.equal(strategyVerdict("balanced", 0, 2), "NON_FIT");
  assert.equal(strategyVerdict("balanced", 2, 1), "FIT");
  assert.equal(strategyVerdict("balanced", 1, 2), "NON_FIT");
});

test("cheapest routing sorts by price, keeps JSON + reasoning, and leaves out 4-bit hosts", () => {
  const cheap = openRouterBody({ model: "deepseek/deepseek-v4.1-flash", effort: "high", system: "s", user: "u", providerMode: "cheapest" });
  assert.equal(cheap.provider.sort, "price");
  assert.equal(cheap.provider.require_parameters, true);
  assert.equal(cheap.provider.allow_fallbacks, undefined, "fallbacks stay on (OpenRouter's default)");
  for (const low of ["fp4", "int4", "mxfp4", "nvfp4"]) assert.ok(!CHEAPEST_QUANTIZATIONS.includes(low), low);
  assert.ok(CHEAPEST_QUANTIZATIONS.includes("fp8") && CHEAPEST_QUANTIZATIONS.includes("unknown"));
  const plain = openRouterBody({ model: "deepseek/deepseek-v4.1-flash", effort: "high", system: "s", user: "u" });
  assert.deepEqual(plain.provider, { require_parameters: true });
});

test("the worker routes each run by its provider mode and reports who answered", async () => {
  const worker = await read("../worker/icp-worker.mjs");
  assert.match(worker, /providerMode: unit\.provider_mode \?\? 'default'/);
  assert.match(worker, /JSON\.stringify\(\{ \.\.\.answer\.usage, provider: answer\.provider \}\)/);
  const migration = await read(migrationPath);
  assert.match(migration, /'reasoning_effort', v_run\.reasoning_effort, 'provider_mode', v_run\.provider_mode/);
  assert.match(migration, /providers = case when v_provider = '' then providers/);
});

test("passes are independent calls and only the final verdict becomes a label", async () => {
  const migration = await read(migrationPath);
  // Never reuse: two DeepSeek passes must be two real calls.
  assert.match(migration, /v_total::text, v_ids, false, v_check_id, p_created_by\);/);
  // A pass writes no per-model label ...
  assert.match(migration, /from done\s+where v_run\.strategy_check_id is null\s+on conflict/);
  // ... and settles its companies under the check lock.
  assert.match(migration, /select \* into v_check from public\.icp_strategy_checks where id = p_check_id for update;/);
  assert.match(migration, /'strategy:' \|\| v_check\.strategy, d\.company_id, d\.verdict/);
  // Decided once, never flipped.
  assert.match(migration, /and s\.verdict is null\s+and \(s\.fit_votes >= v_need or s\.non_fit_votes > v_passes - v_need\)/);
  assert.match(migration, /ICP strategy proof passed and was rolled back/);
  // Every security-definer function added here is closed to the public roles.
  for (const fn of ["settle_icp_strategy_companies_v1", "start_icp_strategy_check_v1", "set_icp_strategy_check_state_v1",
    "icp_strategy_checks_v1", "icp_strategy_results_v1", "icp_strategy_scope_counts_v1"]) {
    assert.match(migration, new RegExp(`revoke execute on function public\\.${fn}\\([^)]*\\) from public, anon, authenticated;`), fn);
  }
});

test("the ICP Validator bench leaves strategy passes and labels out", async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /and v\.source not like 'strategy:%'/);
  assert.match(migration, /and strategy_check_id is null\s+order by created_at desc limit 30/);
});

test("the ICP checks route is measured, and starts, steers and reads checks", async () => {
  const route = await read("../app/api/icp-checks/route.ts");
  assert.match(route, /export const GET = observed\("\/api\/icp-checks", handleGET\);/);
  assert.match(route, /export const POST = observed\("\/api\/icp-checks", handlePOST\);/);
  assert.match(route, /rpc\("start_icp_strategy_check_v3"/);
  assert.match(route, /p_auto_apply: body\.autoApply !== false,/);
  assert.match(route, /p_force: body\.force === true,/);
  assert.match(route, /rpc\("icp_strategy_scope_counts_v2"/);
  assert.match(route, /rpc\("set_icp_strategy_check_state_v1"/);
  assert.match(route, /await readIcpSelection\(clientId, body/);
  assert.match(route, /const unauthorized = await authorizeApi\(\);/g);
});

test("a strategy label is the Company DB row's verdict, named by its method", async () => {
  const { summarizeIcpLabels } = await import("../lib/icp-labels.ts");
  const label = (source, verdict, extra = {}) => ({
    company_id: "c1", icp_profile_id: "icp-1", icp_name: "Growers", source, verdict, reason: "", current: true, ...extra,
  });
  const summary = summarizeIcpLabels([
    label("openai/gpt-6-luna", "NON_FIT"),
    label("strategy:strict", "NON_FIT", { decided_at: "2026-09-30T10:00:00Z" }),
    label("strategy:lenient", "FIT", { decided_at: "2026-09-30T11:00:00Z" }),
  ])[0];
  assert.equal(summary.verdict, "FIT");
  assert.equal(summary.method, "Lenient");
  assert.equal(summary.nonFit, 1, "model labels are still counted on their own");
  assert.equal(summarizeIcpLabels([label("a/x", "FIT")])[0].method, null);
  assert.equal(sourceLabel("strategy:balanced"), "Balanced");
});


test("ICP checks sits inside each client, and the ICP validator is a Data tool", async () => {
  const clients = await read("../app/components/ClientsPanel.tsx");
  assert.match(clients, /\{ id: "icp_checks" as const, label: "ICP checks"/);
  assert.match(clients, /<IcpChecksWorkspace key=\{client\.id\} client=\{client\} clients=\{clients\}\/>/);
  assert.doesNotMatch(clients, /IcpValidatorPanel/);
  const app = await read("../app/DashboardApp.tsx");
  assert.match(app, /\{ id: "icp-validator", label: "ICP validator", mark: "target" \}/);
  assert.match(app, /section === "icp-validator" && <IcpValidatorWorkspace clients=\{clients\}\/>/);
  assert.doesNotMatch(app, /"icp-checks"|"integrations"|IntegrationsPanel/);
  const dialog = await read("../app/components/IcpCheck.tsx");
  assert.match(dialog, /useState<"strategy" \| "models">\("strategy"\)/);
  assert.match(dialog, /\("\/api\/icp-checks", \{/);
  assert.match(dialog, /label="Force re-check"/);
});

test("a check starts on ICP unverified companies and skips already-checked ones unless forced", async () => {
  const screen = await read("../app/components/IcpChecksWorkspace.tsx");
  assert.match(screen, /useState<Scope>\("unverified"\)/);
  assert.match(screen, /const \[force, setForce\] = useState\(false\);/);
  const migration = await read("../supabase/migrations/20260930220000_icp_checks_skip_checked_and_unverified_scope.sql");
  // Unverified = no manual ICP verification for this client.
  assert.match(migration, /p_scope = 'all' or not exists \(\s*select 1 from public\.client_company_icp_validations iv/);
  // Skipped = a current result from any method for this ICP.
  assert.match(migration, /where coalesce\(p_force, false\) or not exists \([\s\S]*?v\.source like 'strategy:%' and v\.icp_hash = v_hash\)/);
  assert.match(migration, /skipped_items = greatest\(0, v_checkable - v_total\)/);
  assert.match(migration, /Turn on "Force re-check" to run them again\./);
  assert.match(migration, /ICP skip proof passed and was rolled back/);
  for (const fn of ["start_icp_strategy_check_v2", "icp_strategy_scope_counts_v2"]) {
    assert.ok(migration.includes(`revoke execute on function public.${fn}(`) && migration.includes("from public, anon, authenticated;"), fn);
  }
});

test("a downloaded check is named after its method, client, ICP and view", async () => {
  const { attachmentDisposition } = await import("../lib/csv.ts");
  const header = attachmentDisposition("ICP check - Balanced - Acme/Co - Growers: India - FIT - 2026-09-30.csv");
  assert.match(header, /^attachment; filename="ICP check - Balanced - Acme Co - Growers India - FIT - 2026-09-30\.csv"; filename\*=UTF-8''/);
  assert.match(attachmentDisposition("ICP check - Strict - Café - 2026-09-30.csv"), /filename="ICP check - Strict - Caf_ - 2026-09-30\.csv"; filename\*=UTF-8''ICP%20check%20-%20Strict%20-%20Caf%C3%A9/);
  const route = await read("../app/api/icp-checks/route.ts");
  assert.match(route, /"ICP check", method, client\?\.name, check\?\.icp_name, view/);
  assert.match(route, /"Content-Disposition": attachmentDisposition\(await csvFileName\(clientId, checkId, url\)\)/);
});

test("the Company DB filters by ICP check result, and a check's FIT can be marked ICP verified", async () => {
  const migration = await read("../supabase/migrations/20260930230000_icp_check_filter_and_mark_fit_verified.sql");
  // One helper for the compiled filter and the row matcher, so they agree.
  assert.match(migration, /format\('public\.company_icp_check_matches_v1\(c\.id, %L, %L\)'/);
  assert.match(migration, /where public\.company_icp_check_matches_v1\(\(p_row\)\.id, split_part\(selected\.value, '\|', 1\)/);
  // Latest current result per ICP; an edited brief does not count.
  assert.match(migration, /order by v\.icp_profile_id, v\.decided_at desc\) latest/);
  assert.match(migration, /v\.source like 'strategy:%' and v\.icp_hash = md5\(p\.description\)/);
  // Inlinable: no SET clause on the helper.
  assert.doesNotMatch(migration.split("company_icp_check_matches_v1(p_company_id text")[1].split("$$")[0], /set search_path/);
  // FIT -> ICP verified through the Company DB's own path.
  assert.match(migration, /public\.set_company_icp_verified_v2\(p_client_id, true, v_ids, '', '\[\]'::jsonb, null, null, p_actor\)/);
  assert.match(migration, /ICP check filter proof passed and was rolled back/);

  const table = await read("../app/components/CompaniesWorkspace.tsx");
  assert.match(table, /field: "__company_icp_check",/);
  assert.match(table, /\["UNCHECKED", "Not checked"\]/);
  const { filterChipValue } = await import("../lib/dashboard-helpers.ts");
  assert.equal(filterChipValue("__company_icp_check", "client-1|FIT"), "ICP check FIT");
  assert.equal(filterChipValue("__company_icp_check", "client-1|UNCHECKED"), "ICP not checked");

  const route = await read("../app/api/icp-checks/route.ts");
  assert.match(route, /rpc\("mark_icp_check_fit_verified_v1"/);
  const screen = await read("../app/components/IcpChecksWorkspace.tsx");
  assert.match(screen, /action: "mark_fit_verified"/);
});

test("a result can be set by hand, survives later votes, and undoes back to the rule", async () => {
  const migration = await read("../supabase/migrations/20260930240000_icp_check_review.sql");
  assert.match(migration, /select \* into v_check from public\.icp_strategy_checks\s+where id = p_check_id and client_id = p_client_id\s+for update;/);
  // Undo recomputes the rule from the votes.
  assert.match(migration, /v_rule := case when v_row\.fit_votes >= v_need then 'FIT'\s+when v_row\.non_fit_votes > v_passes - v_need then 'NON_FIT' end;/);
  assert.match(migration, /when 'reviewed' then s\.reviewed_at is not null/);
  assert.match(migration, /'split_unreviewed', count\(\*\) filter/);
  assert.match(migration, /ICP review proof passed and was rolled back/);
  // settle_ still decides only undecided rows, so a review is never overwritten.
  const settle = await read("../supabase/migrations/20260930210000_icp_strategy_checks.sql");
  assert.match(settle, /and s\.verdict is null\s+and \(s\.fit_votes >= v_need/);

  const route = await read("../app/api/icp-checks/route.ts");
  assert.match(route, /rpc\("review_icp_check_company_v1"/);
  assert.match(route, /if \(!\["FIT", "NON_FIT", ""\]\.includes\(verdict\)\) return bad/);
  const screen = await read("../app/components/IcpChecksWorkspace.tsx");
  assert.match(screen, /action: "review", clientId: check\.client_id, checkId: check\.id, companyId, verdict/);
});

test("the Clients list reuses its counts until memberships or company text change", async () => {
  const migration = await read("../supabase/migrations/20260930250000_client_summaries_cached.sql");
  for (const table of ["client_prospects", "client_companies"]) {
    assert.ok(migration.includes(`after insert or update or delete on public.${table}\n  for each statement execute function public.bump_data_version_client_counts();`), table);
  }
  assert.match(migration, /after update of keywords, short_description on public\.companies/);
  assert.match(migration, /after update of company_id or delete on public\.prospects/);
  assert.match(migration, /v_cache\.computed_at > now\(\) - interval '5 minutes'/);
  assert.match(migration, /Client summaries proof passed and was rolled back/);
  const list = await read("../app/api/clients/route.ts");
  assert.match(list, /supabase\.rpc\("client_summaries_v1", \{ p_client_id: null \}\)/);
  const one = await read("../app/api/clients/[id]/route.ts");
  assert.match(one, /supabase\.rpc\("client_summaries_v1", \{ p_client_id: id \}\)/);
});
