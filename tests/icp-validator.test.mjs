import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  buildBatch, buildSystemPrompt, callOpenRouter, companyRow, estimateRunCost, failurePlan, ICP_MODELS, IcpOutputError,
  openRouterBody, OpenRouterError, parseModelOutput, sourceLabel,
} from "../worker/icp-validator-core.mjs";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const longText = "We manufacture organic fertilizer and crop nutrition products for farmers across India. ".repeat(10);

test("keywords ride along only when the description is short, and URLs never reach the model", () => {
  const long = companyRow({ name: "Agro Co", industry: "Farming", short_description: `${longText} https://agro.example/x`, keywords: ["seeds", "fertilizer"] }, "r1");
  assert.equal(long.keywords, undefined);
  assert.doesNotMatch(long.short_description, /https?:|agro\.example/);

  const short = companyRow({ name: "Seedy", industry: "", short_description: "Seeds. www.seedy.example", keywords: ["hybrid seeds", "", "agri inputs"] }, "r2");
  assert.equal(short.keywords, "hybrid seeds, agri inputs");
  assert.equal(short.short_description, "Seeds.");

  const huge = companyRow({ name: "Big", short_description: "x".repeat(5000), keywords: [] }, "r3");
  assert.ok(huge.short_description.length <= 1500);
});

test("a batch numbers rows so answers map back to company ids, not names", () => {
  const batch = buildBatch([
    { company_id: "c-1", name: "Acme", short_description: "a" },
    { company_id: "c-2", name: "Acme", short_description: "b" },
  ]);
  assert.deepEqual([...batch.idToCompany.entries()], [["r1", "c-1"], ["r2", "c-2"]]);
  assert.match(batch.user, /"id":"r1"/);
  assert.match(buildSystemPrompt("Agri input brands"), /ICP:\n<<<\nAgri input brands\n>>>/);
  assert.match(buildSystemPrompt("x"), /When unsure, FIT/);
});

test("answers are read tolerantly but never guessed", () => {
  const batch = buildBatch([
    { company_id: "c-1", name: "Alpha" },
    { company_id: "c-2", name: "Beta" },
    { company_id: "c-3", name: "Gamma" },
  ]);
  const text = `<think>hmm</think>\n\`\`\`json\n${JSON.stringify({ results: [
    { id: "r1", company_name: "Alpha", verdict: "non-fit", reason: "\"sells software to\" agri brands" },
    { company_name: "Beta", verdict: "FIT", reason: "insufficient text" },
    { id: "r1", verdict: "FIT", reason: "duplicate ignored" },
    { id: "r9", verdict: "FIT", reason: "unknown id ignored" },
  ] })}\n\`\`\``;
  const { results, missing } = parseModelOutput(text, batch);
  assert.deepEqual(results.map((row) => [row.company_id, row.verdict]), [["c-1", "NON_FIT"], ["c-2", "FIT"]]);
  assert.deepEqual(missing, ["c-3"]);

  assert.throws(() => parseModelOutput("not json", batch), (error) => error instanceof IcpOutputError && error.kind === "invalid_output");
  assert.throws(() => parseModelOutput('{"results":[{"id":"r1","verdict":"MAYBE"}]}', batch), (error) => error.kind === "invalid_output");
  assert.throws(
    () => parseModelOutput('{"error":"ICP_UNANSWERABLE","missing":["headcount","geography"]}', batch),
    (error) => error.kind === "unanswerable" && error.missing.join() === "headcount,geography",
  );
});

test("failures pause what cannot succeed and retry what might", () => {
  assert.deepEqual(failurePlan(new OpenRouterError("auth", "bad key")).pauseScope, "all");
  assert.deepEqual(failurePlan(new OpenRouterError("credits", "no credits")).pauseScope, "all");
  assert.deepEqual(failurePlan(new OpenRouterError("model_unavailable", "404")).pauseScope, "run");
  const unanswerable = failurePlan(new IcpOutputError("unanswerable", "ICP_UNANSWERABLE", { code: "ICP_UNANSWERABLE", missing: ["headcount"] }));
  assert.equal(unanswerable.pauseScope, "run");
  assert.match(unanswerable.message, /headcount/);
  assert.deepEqual(failurePlan(new OpenRouterError("transient", "502")), { retry: true, pauseScope: "", message: "" });
  assert.deepEqual(failurePlan(new IcpOutputError("invalid_output", "bad json")).retry, true);
});

test("OpenRouter is asked for JSON with the run's reasoning effort, and usage is recorded", async () => {
  const body = openRouterBody({ model: "openai/gpt-6-luna", effort: "medium", system: "s", user: "u" });
  assert.deepEqual(body.response_format, { type: "json_object" });
  assert.equal(body.reasoning.effort, "medium");
  assert.equal(body.provider.require_parameters, true);
  assert.equal(openRouterBody({ model: "m/x", effort: "bogus", system: "", user: "" }).reasoning.effort, "low");

  let sent;
  const ok = await callOpenRouter({
    apiKey: "k", model: "openai/gpt-6-luna", effort: "low", system: "s", user: "u",
    fetchImpl: async (url, init) => {
      sent = { url, init };
      return new Response(JSON.stringify({
        provider: "OpenAI",
        choices: [{ message: { content: '{"results":[]}' }, finish_reason: "stop" }],
        usage: { prompt_tokens: 1000, completion_tokens: 200, cost: 0.0003, prompt_tokens_details: { cached_tokens: 800 }, completion_tokens_details: { reasoning_tokens: 150 } },
      }), { status: 200 });
    },
  });
  assert.equal(sent.init.headers.Authorization, "Bearer k");
  assert.equal(ok.content, '{"results":[]}');
  assert.deepEqual({ ...ok.usage, ms: 0 }, { prompt_tokens: 1000, completion_tokens: 200, cached_tokens: 800, reasoning_tokens: 150, cost: 0.0003, ms: 0 });

  const failWith = (status, headers = {}) => callOpenRouter({ apiKey: "k", model: "m/x", system: "", user: "",
    fetchImpl: async () => new Response(JSON.stringify({ error: { message: "nope" } }), { status, headers }) });
  await assert.rejects(failWith(401), (error) => error.kind === "auth");
  await assert.rejects(failWith(402), (error) => error.kind === "credits");
  await assert.rejects(failWith(429, { "retry-after": "7" }), (error) => error.kind === "rate_limited" && error.retryAfterMs === 7000);
  await assert.rejects(failWith(404), (error) => error.kind === "model_unavailable");
  await assert.rejects(failWith(503), (error) => error.kind === "transient");
  await assert.rejects(callOpenRouter({ apiKey: "k", model: "m/x", system: "", user: "",
    fetchImpl: async () => new Response(JSON.stringify({ error: { code: 402, message: "credits" } }), { status: 200 }) }),
  (error) => error.kind === "credits");
});

test("the model catalog is the three requested models, with estimates", () => {
  assert.deepEqual(ICP_MODELS.map((model) => model.id), ["openai/gpt-6-luna", "deepseek/deepseek-v4.1-flash", "xiaomi/mimo-v2.6-flash"]);
  for (const model of ICP_MODELS) assert.ok(estimateRunCost(model.id, 1000) > 0);
  assert.equal(estimateRunCost("unknown/model", 1000), null);
  assert.equal(sourceLabel("reference:fable"), "fable (reference)");
  assert.equal(sourceLabel("openai/gpt-6-luna"), "GPT-6 Luna");
});

test("the migration is a label store with a fenced worker, and proves itself", async () => {
  const migration = await read("../supabase/migrations/20260929200000_icp_validator.sql");
  // The worker's role gets exactly the four queue functions.
  const grants = [...migration.matchAll(/grant execute on function (public\.\w+)\([^)]*\) to prospect_icp_validator/g)].map((match) => match[1]);
  assert.deepEqual(grants.sort(), [
    "public.claim_icp_validation_batch_v1", "public.complete_icp_validation_batch_v1",
    "public.fail_icp_validation_batch_v1", "public.report_icp_worker_v1",
  ]);
  // A label, never an action on the client's data.
  assert.doesNotMatch(migration, /(update|insert into|delete from)\s+public\.(companies|clients|client_companies|client_company_icp_validations|client_prospects)\b/i);
  assert.match(migration, /on conflict \(client_id, icp_profile_id, source, company_id\)/);
  assert.match(migration, /v_hash := md5\(v_profile\.description\)/);
  assert.match(migration, /ICP validator proof passed and was rolled back/);
  assert.match(migration, /set local lock_timeout = '5s';/);
});

test("the ICP worker ships with the release and idles without a key", async () => {
  const compose = await read("../deploy/docker-compose.yml");
  const start = compose.indexOf("\n  icp-worker:");
  const service = compose.slice(start, compose.indexOf("\n  app-router:", start));
  assert.match(service, /command: \["node", "worker\/icp-worker\.mjs"\]/);
  assert.match(service, /PGUSER: prospect_icp_worker/);
  assert.match(service, /OPENROUTER_API_KEY: \$\{OPENROUTER_API_KEY:-\}/);
  assert.match(service, /9094\/health/);

  const bootstrap = await read("../deploy/postgres/init/00-prospect-bootstrap.sh");
  assert.match(bootstrap, /create role prospect_icp_validator nologin noinherit/);
  assert.match(bootstrap, /grant prospect_icp_validator to prospect_icp_worker;/);
  assert.match(bootstrap, /revoke service_role from prospect_icp_worker;/);

  const update = await read("../deploy/scripts/update.sh");
  assert.match(update, /-f \/app\/worker\/icp-worker\.mjs; then\n {2}echo "==> This image predates the ICP validator/);
  assert.match(update, /wait_for_container prospect-icp-worker 18/);

  const worker = await read("../worker/icp-worker.mjs");
  assert.match(worker, /while \(apiKey && !stopping/);
  assert.match(await read("../deploy/.env.example"), /^OPENROUTER_API_KEY=$/m);
});

test("a Company DB row reads one summary per ICP, with stale verdicts kept apart", async () => {
  const { summarizeIcpLabels } = await import("../lib/icp-labels.ts");
  const label = (source, verdict, extra = {}) => ({ company_id: "c", icp_profile_id: "icp-1", icp_name: "Agri", source, verdict, reason: "", current: true, ...extra });
  assert.equal(summarizeIcpLabels([label("a/x", "FIT"), label("b/y", "FIT")])[0].verdict, "FIT");
  assert.equal(summarizeIcpLabels([label("a/x", "NON_FIT"), label("b/y", "NON_FIT")])[0].verdict, "NON_FIT");
  const mixed = summarizeIcpLabels([label("a/x", "NON_FIT"), label("b/y", "FIT"), label("c/z", "NON_FIT", { current: false })])[0];
  assert.deepEqual([mixed.verdict, mixed.fit, mixed.nonFit, mixed.stale], ["MIXED", 1, 1, 1]);
  assert.equal(summarizeIcpLabels([label("a/x", "FIT", { current: false })])[0].verdict, "STALE");
  assert.equal(summarizeIcpLabels([label("a/x", "FIT"), label("a/x", "FIT", { icp_profile_id: "icp-2", icp_name: "" })]).length, 2);
});

test("a Company DB selection is validated through the shared resolver, never widened", async () => {
  const migration = await read("../supabase/migrations/20260929210000_icp_validation_from_a_company_selection.sql");
  assert.match(migration, /from public\.resolve_company_action_selection_v1\(\s*p_client_id, p_company_ids/);
  assert.match(migration, /'selection'/);
  assert.match(migration, /ICP selection proof passed and was rolled back/);
  assert.doesNotMatch(migration, /(update|insert into|delete from)\s+public\.(companies|clients|client_companies|client_company_icp_validations)\b/i);

  const route = await read("../app/api/clients/[id]/icp-validator/route.ts");
  assert.match(route, /p_filters: widening \? filters : \[\]/);
  assert.match(route, /authorizeFilterSets\(supabase, filters, userId, "company", clientId/);

  const table = await read("../app/components/CompaniesWorkspace.tsx");
  assert.match(table, /onClick=\{\(\) => setValidateOpen\(true\)\}><AppIcon name="target" size=\{14\}\/> Validate ICP<\/button>/);
  assert.match(table, /selection=\{companySelectionPayload\(\)\}/);
});
