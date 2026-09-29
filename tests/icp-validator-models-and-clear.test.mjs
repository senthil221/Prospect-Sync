import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { icpModelsFromCatalog } from "../lib/openrouter-models.ts";
import { estimateRunCost, MAX_MODELS_PER_CHECK } from "../worker/icp-validator-core.mjs";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("any OpenRouter model with JSON output and reasoning can run a check", () => {
  const models = icpModelsFromCatalog({ data: [
    { id: "anthropic/claude-fable-5.1", name: "Anthropic: Claude Fable 5.1", pricing: { prompt: "0.00001", completion: "0.00005" }, supported_parameters: ["reasoning", "response_format"] },
    { id: "some/no-json", name: "No JSON", pricing: { prompt: "0", completion: "0" }, supported_parameters: ["reasoning"] },
    { id: "some/no-reasoning", name: "No reasoning", pricing: { prompt: "0", completion: "0" }, supported_parameters: ["response_format"] },
    { id: "google/gemini-2.5-flash:batch", name: "Batch", pricing: { prompt: "0", completion: "0" }, supported_parameters: ["reasoning", "response_format"] },
    { id: "~openai/gpt-luna-latest", name: "Alias", pricing: { prompt: "0", completion: "0" }, supported_parameters: ["reasoning", "response_format"] },
    { id: "openai/gpt-6-luna", name: "OpenAI: GPT-6 Luna", pricing: { prompt: "0.0000001", completion: "0.0000005" }, supported_parameters: ["reasoning", "response_format"] },
  ] });
  const ids = models.map((model) => model.id);
  assert.ok(ids.includes("anthropic/claude-fable-5.1"));
  assert.ok(!ids.includes("some/no-json") && !ids.includes("some/no-reasoning"));
  assert.ok(!ids.some((id) => id.startsWith("~")), "moving -latest aliases are not offered");
  assert.ok(!ids.some((id) => id.endsWith(":batch")), "delayed batch listings are not offered");
  // The three defaults come first and keep their short names, even offline.
  assert.deepEqual(models.slice(0, 3).map((model) => model.recommended), [true, true, true]);
  assert.equal(models.find((model) => model.id === "openai/gpt-6-luna").label, "GPT-6 Luna");
  assert.deepEqual(icpModelsFromCatalog(null).map((model) => model.id).length, 3);

  const fable = models.find((model) => model.id === "anthropic/claude-fable-5.1");
  assert.deepEqual([fable.inputPerM, fable.outputPerM], [10, 50]);
  assert.ok(estimateRunCost(fable, 1000) > estimateRunCost("openai/gpt-6-luna", 1000));
  assert.equal(MAX_MODELS_PER_CHECK, 3);
});

test("the route accepts catalog models, up to three, and clears through the shared selection", async () => {
  const route = await read("../app/api/clients/[id]/icp-validator/route.ts");
  assert.match(route, /models\.length > MAX_MODELS_PER_CHECK/);
  assert.match(route, /await unknownIcpModels\(/);
  assert.match(route, /if \(action === "clear_selection"\) return clearSelection\(/);
  // Both selection actions go through the one parser, which never widens an
  // explicit selection.
  assert.equal(route.match(/await readSelection\(/g).length, 2);
  assert.match(route, /p_filters: widening \? parsedFilters : \[\]/);
});

test("clearing an ICP check removes labels only, and keeps them off", async () => {
  const migration = await read("../supabase/migrations/20260930090000_clear_icp_check_for_a_company_selection.sql");
  assert.match(migration, /from public\.resolve_company_action_selection_v1\(\s*p_client_id, p_company_ids/);
  assert.match(migration, /delete from public\.client_company_icp_verdicts/);
  assert.match(migration, /set state = 'skipped'/);
  assert.doesNotMatch(migration, /(update|insert into|delete from)\s+public\.(companies|clients|client_companies|client_company_icp_validations)\b/i);
  assert.match(migration, /ICP clear proof passed and was rolled back/);

  const table = await read("../app/components/CompaniesWorkspace.tsx");
  assert.match(table, /<AppIcon name="close" size=\{14\}\/> Clear ICP check<\/button>/);
  assert.match(table, /action: "clear_selection", \.\.\.companySelectionPayload\(\)/);
});
