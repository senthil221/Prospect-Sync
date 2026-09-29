import { authorizeApi, getAuthorizedUser } from "../../../../../lib/auth.ts";
import { readBoundedJson } from "../../../../../lib/bounded-json.ts";
import { withClientWorkspaceCompleteness } from "../../../../../lib/client-workspace-completeness.ts";
import { csvCell } from "../../../../../lib/csv.ts";
import { authorizeFilterSets } from "../../../../../lib/filter-sets.ts";
import { icpModelCatalog, unknownIcpModels } from "../../../../../lib/openrouter-models.ts";
import { filterErrorResponse, parseFilters } from "../../../../../lib/prospect-filters.ts";
import { createAdminClient } from "../../../../../lib/supabase/admin";
import { parsePeopleScope } from "../../../../../lib/workspace-scopes.ts";
import { ICP_MODELS, MAX_MODELS_PER_CHECK, REASONING_EFFORTS, estimateRunCost, sourceLabel } from "../../../../../worker/icp-validator-core.mjs";

// The ICP validator's API. The model calls happen in the ICP worker, never
// here: this route starts and steers runs and reads results. Comparing with
// results produced elsewhere (e.g. a Claude Fable run) is done on the CSV.
//
// GET  ?icp=<profile id>                             overview (runs, sources, worker)
// GET  ?icp=…&view=rows&sources=a,b&filter=…&page=…  companies with verdicts side by side
// GET  ?icp=…&view=csv&sources=a,b&filter=…          the same rows as a CSV download
// GET  ?view=labels&ids=a,b,…                        verdicts for one page of Company DB rows
// GET  ?view=models                                  every OpenRouter model that can run a check
// POST {action:"start", icpId, models[], effort, scope, sampleSize, reuse}
// POST {action:"start_selection", icpId, models[], effort, reuse, companyIds[] |
//        allMatching + search + filters + peopleScope + excludedIds}
//                                                    a Company DB selection
// POST {action:"clear_selection", icpId?, <same selection>}
//                                                    take the ICP check labels off a selection
// POST {action:"set_default_models", models[]}         the team's pre-selected models
// POST {action:"pause"|"resume"|"cancel"|"retry_failed", runId}
// POST {action:"delete_source", icpId, source}

const missingCodes = new Set(["PGRST202", "PGRST205", "42883", "42P01"]);
const pageSize = 100;
const csvLimit = 100_000;
const scopes = new Set(["all", "unchecked", "sample"]);
const filters = new Set(["all", "disagree", "non_fit", "fit", "all_non_fit"]);

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to enable the ICP validator." : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : error.code === "22023" ? 400 : error.code === "57014" ? 504 : 500 },
  );
}

const bad = (error: string, status = 400) => Response.json({ error }, { status });

function sourcesParam(url: URL) {
  return (url.searchParams.get("sources") ?? "").split(",").map((value) => value.trim()).filter(Boolean).slice(0, 8);
}

function rowsArgs(clientId: string, icpId: string, url: URL, limit: number, offset: number) {
  const filter = url.searchParams.get("filter") ?? "all";
  return {
    p_client_id: clientId,
    p_icp_profile_id: icpId,
    p_sources: sourcesParam(url),
    p_filter: filters.has(filter) ? filter : "all",
    p_search: (url.searchParams.get("search") ?? "").trim().slice(0, 200),
    p_limit: limit,
    p_offset: offset,
    p_verdict_source: url.searchParams.get("verdictSource") ?? "",
    p_verdict: url.searchParams.get("verdict") === "NON_FIT" ? "NON_FIT" : url.searchParams.get("verdict") === "FIT" ? "FIT" : "",
  };
}

type VerdictRow = {
  company_id: string; name: string; domain: string; industry: string; short_description: string; keywords: string;
  verdicts: Record<string, { verdict: string; reason: string; current: boolean }>;
};

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const url = new URL(request.url);
  const view = url.searchParams.get("view") ?? "overview";
  const supabase = createAdminClient();

  if (view === "models") {
    const [catalog, defaults] = await Promise.all([icpModelCatalog(), teamDefaultModels()]);
    // The team's defaults are the ones marked "default" and listed first, in
    // the order they were saved; a default the catalog no longer lists is
    // still shown (by slug) so it can be unticked.
    const byId = new Map(catalog.map((model) => [model.id, model]));
    const first = defaults.map((id) => ({ ...(byId.get(id) ?? { id, label: sourceLabel(id), inputPerM: 0, outputPerM: 0, contextLength: null }), recommended: true }));
    const rest = catalog.filter((model) => !defaults.includes(model.id)).map((model) => ({ ...model, recommended: false }));
    return Response.json({ models: [...first, ...rest], defaults, maxPerCheck: MAX_MODELS_PER_CHECK }, { headers: { "Cache-Control": "no-store" } });
  }

  // Not per ICP: a Company DB row shows every ICP's verdicts.
  if (view === "labels") {
    const ids = [...new Set((url.searchParams.get("ids") ?? "").split(",").map((value) => value.trim()).filter(Boolean))].slice(0, 200);
    if (!ids.length) return Response.json({ labels: [] });
    const { data, error } = await supabase.rpc("icp_verdict_labels_v1", { p_client_id: id, p_company_ids: ids });
    if (error) return failure(error);
    return Response.json({ labels: data ?? [] }, { headers: { "Cache-Control": "no-store" } });
  }

  const icpId = (url.searchParams.get("icp") ?? "").trim();
  if (!icpId) return bad("Which ICP?");

  if (view === "overview") {
    const { data, error } = await supabase.rpc("icp_validator_overview_v1", { p_client_id: id, p_icp_profile_id: icpId });
    if (error) return failure(error);
    const overview = data as { profile: { company_count: number; description_length: number } };
    return Response.json({
      overview: data,
      models: ICP_MODELS.map((model) => ({
        ...model,
        estimateAll: estimateRunCost(model.id, Number(overview.profile.company_count ?? 0), { briefLength: overview.profile.description_length }),
      })),
      efforts: REASONING_EFFORTS,
    }, { headers: { "Cache-Control": "no-store" } });
  }

  if (view === "rows") {
    if (!sourcesParam(url).length) return bad("Choose at least one source.");
    const page = Math.max(1, Math.min(Number(url.searchParams.get("page") ?? 1) || 1, 10_000));
    const { data, error } = await supabase.rpc("icp_verdict_rows_v1", rowsArgs(id, icpId, url, pageSize, (page - 1) * pageSize));
    if (error) return failure(error);
    return Response.json({ ...(data as object), page, pageSize }, { headers: { "Cache-Control": "no-store" } });
  }

  if (view === "csv") {
    const sources = sourcesParam(url);
    if (!sources.length) return bad("Choose at least one source.");
    const header = ["Company", "Domain", "Industry", ...sources.flatMap((source) => [`${sourceLabel(source)} verdict`, `${sourceLabel(source)} reason`]), "Short description"];
    const lines = [header.map(csvCell).join(",")];
    for (let offset = 0; offset < csvLimit; offset += 1000) {
      const { data, error } = await supabase.rpc("icp_verdict_rows_v1", rowsArgs(id, icpId, url, 1000, offset));
      if (error) return failure(error);
      const rows = ((data as { rows?: VerdictRow[] })?.rows ?? []);
      for (const row of rows) {
        lines.push([
          row.name, row.domain, row.industry,
          ...sources.flatMap((source) => {
            const verdict = row.verdicts[source];
            return verdict ? [verdict.current ? verdict.verdict : `${verdict.verdict} (stale)`, verdict.reason] : ["", ""];
          }),
          row.short_description,
        ].map(csvCell).join(","));
      }
      if (rows.length < 1000) break;
    }
    return new Response(String.fromCharCode(0xfeff) + `${lines.join("\r\n")}\r\n`, {
      headers: {
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": `attachment; filename="icp-verdicts-${new Date().toISOString().slice(0, 10)}.csv"`,
        "Cache-Control": "no-store",
      },
    });
  }

  return bad("Unknown view.");
}

// One to three models, each one OpenRouter can run with JSON output and
// reasoning (lib/openrouter-models.ts). The defaults always pass.
// The models pre-ticked for a new check: the team's saved choice
// (icp_validator_settings), or the built-in three when none is saved or the
// table is not there yet.
async function teamDefaultModels(): Promise<string[]> {
  const { data, error } = await createAdminClient().from("icp_validator_settings").select("default_models").eq("id", true).maybeSingle();
  const saved = !error && Array.isArray(data?.default_models) ? (data.default_models as unknown[]).map(String).filter(Boolean) : [];
  return saved.length ? saved.slice(0, MAX_MODELS_PER_CHECK) : ICP_MODELS.map((model) => model.id);
}

async function readModels(value: unknown): Promise<{ models: string[]; error?: never } | { models?: never; error: Response }> {
  const models = Array.isArray(value) ? [...new Set(value.map((item) => String(item ?? "").trim()).filter(Boolean))] : [];
  if (!models.length || models.length > MAX_MODELS_PER_CHECK) return { error: bad(`Choose one to ${MAX_MODELS_PER_CHECK} models.`) };
  const defaults = new Set(ICP_MODELS.map((model) => model.id));
  const unknown = await unknownIcpModels(models.filter((model) => !defaults.has(model)));
  if (unknown.length) return { error: bad(`${unknown.join(", ")} is not an OpenRouter model that supports JSON output and reasoning.`) };
  return { models };
}

type StartBody = {
  icpId?: unknown; models?: unknown; effort?: unknown; scope?: unknown; sampleSize?: unknown; reuse?: unknown;
};

async function startRuns(clientId: string, body: StartBody, actor: string) {
  const icpId = String(body.icpId ?? "").trim();
  if (!icpId) return bad("Which ICP?");
  const chosen = await readModels(body.models);
  if (chosen.error) return chosen.error;
  const models = chosen.models;
  const effort = REASONING_EFFORTS.includes(String(body.effort)) ? String(body.effort) : "low";
  const scope = String(body.scope ?? "all");
  if (!scopes.has(scope)) return bad("Unknown scope.");
  const sampleSize = scope === "sample" ? Math.floor(Number(body.sampleSize)) : null;
  if (scope === "sample" && !(sampleSize && sampleSize >= 1 && sampleSize <= 5000)) return bad("A sample is between 1 and 5,000 companies.");
  const reuse = body.reuse !== false;

  const supabase = createAdminClient();
  // Several models started together form one bake-off, and must judge the
  // same companies: a random sample is drawn once, and the other models
  // repeat that run's exact set.
  const bakeOffId = models.length > 1 ? crypto.randomUUID() : null;
  const runs: unknown[] = [];
  let firstRunId = "";
  for (const model of models) {
    const sameAsFirst = scope === "sample" && firstRunId;
    const { data, error } = await supabase.rpc("start_icp_validation_run_v1", {
      p_client_id: clientId,
      p_icp_profile_id: icpId,
      p_model: model,
      p_reasoning_effort: effort,
      p_scope: sameAsFirst ? "same_as" : scope,
      p_scope_detail: sameAsFirst ? firstRunId : "",
      p_sample_size: sameAsFirst ? null : sampleSize,
      p_reuse: reuse,
      p_batch_size: 20,
      p_bake_off_id: bakeOffId,
      p_created_by: actor,
    });
    if (error) {
      if (runs.length) return Response.json({ runs, error: `Started ${runs.length} of ${models.length}: ${error.message}` }, { status: 207 });
      return failure(error);
    }
    runs.push(data);
    if (!firstRunId) firstRunId = String((data as { id: string }).id);
  }
  return Response.json({ runs });
}

type SelectionArgs = {
  p_company_ids: string[] | null; p_search: string; p_filters: unknown; p_people_scope: unknown; p_excluded_ids: string[] | null;
};

// A Company DB selection: the ticked ids, or everything matching the
// workspace's search and filters. Parsed and checked exactly as the Company
// DB's other bulk actions are (app/api/clients/[id]/companies), and resolved
// once in the database.
async function readSelection(clientId: string, body: Record<string, unknown>, userId: string, verb: string): Promise<
  { args: SelectionArgs; error?: never } | { args?: never; error: Response }
> {
  const companyIds = Array.isArray(body.companyIds)
    ? [...new Set(body.companyIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const allMatching = body.allMatching === true;
  if (!companyIds.length && !allMatching) return { error: bad(`Select companies to ${verb}.`) };

  let parsedFilters;
  let peopleScope;
  try {
    parsedFilters = withClientWorkspaceCompleteness(parseFilters(JSON.stringify(body.filters ?? [])), clientId);
    peopleScope = body.peopleScope ? parsePeopleScope(JSON.stringify(body.peopleScope)) : null;
  } catch (error) {
    return { error: filterErrorResponse(error, "Invalid company selection.") };
  }
  const excludedIds = Array.isArray(body.excludedIds)
    ? [...new Set(body.excludedIds.map((value) => String(value ?? "").trim()).filter(Boolean))].slice(0, 50000)
    : [];
  const widening = allMatching && !companyIds.length;
  if (widening) {
    const setDenial = await authorizeFilterSets(createAdminClient(), parsedFilters, userId, "company", clientId,
      peopleScope ? [{ entityType: "prospect", clientScope: clientId, filters: peopleScope.filters }] : []);
    if (setDenial) return { error: setDenial };
  }
  return {
    args: {
      p_company_ids: companyIds.length ? companyIds : null,
      // Empty unless this is an all-matching request, so an explicit selection
      // can never be widened by a filter left in the payload.
      p_search: widening ? String(body.search ?? "").trim().slice(0, 300) : "",
      p_filters: widening ? parsedFilters : [],
      p_people_scope: widening ? peopleScope : null,
      p_excluded_ids: widening && excludedIds.length ? excludedIds : null,
    },
  };
}

// Every chosen model judges the same companies: the selection is resolved once.
async function startSelection(clientId: string, body: Record<string, unknown>, userId: string, actor: string) {
  const icpId = String(body.icpId ?? "").trim();
  if (!icpId) return bad("Which ICP?");
  const chosen = await readModels(body.models);
  if (chosen.error) return chosen.error;
  const effort = REASONING_EFFORTS.includes(String(body.effort)) ? String(body.effort) : "low";
  const selection = await readSelection(clientId, body, userId, "validate");
  if (selection.error) return selection.error;
  const { data, error } = await createAdminClient().rpc("start_icp_validation_selection_v1", {
    p_client_id: clientId,
    p_icp_profile_id: icpId,
    p_models: chosen.models,
    p_reasoning_effort: effort,
    ...selection.args,
    p_reuse: body.reuse !== false,
    p_created_by: actor,
  });
  if (error) return failure(error);
  return Response.json(data);
}

// Takes the ICP check labels off a selection (every ICP, or just icpId), and
// skips checks still queued for those companies so the labels stay off.
async function clearSelection(clientId: string, body: Record<string, unknown>, userId: string) {
  const icpId = String(body.icpId ?? "").trim();
  const selection = await readSelection(clientId, body, userId, "clear");
  if (selection.error) return selection.error;
  const { data, error } = await createAdminClient().rpc("clear_icp_verdicts_selection_v1", {
    p_client_id: clientId,
    ...selection.args,
    p_icp_profile_id: icpId || null,
  });
  if (error) return failure(error);
  return Response.json({ result: data });
}

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { id } = await context.params;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const body = (decoded.value ?? {}) as Record<string, unknown>;
  const action = String(body.action ?? "");
  const user = await getAuthorizedUser();
  const actor = user?.email ?? "";
  const supabase = createAdminClient();

  if (action === "start") return startRuns(id, body, actor);
  if (action === "start_selection") return startSelection(id, body, user?.id ?? "", actor);
  if (action === "clear_selection") return clearSelection(id, body, user?.id ?? "");

  // Team-wide: the models every new check starts with, for every client.
  if (action === "set_default_models") {
    const chosen = await readModels(body.models);
    if (chosen.error) return chosen.error;
    const { error } = await supabase.from("icp_validator_settings").upsert(
      { id: true, default_models: chosen.models, updated_by: actor, updated_at: new Date().toISOString() },
      { onConflict: "id" },
    );
    if (error) return failure(error);
    return Response.json({ defaults: chosen.models });
  }

  if (action === "pause" || action === "resume" || action === "cancel" || action === "retry_failed") {
    const runId = String(body.runId ?? "").trim();
    if (!/^[0-9a-f-]{36}$/i.test(runId)) return bad("Which run?");
    const { data, error } = await supabase.rpc("set_icp_validation_run_state_v1", {
      p_client_id: id, p_run_id: runId, p_action: action, p_actor: actor,
    });
    if (error) return failure(error);
    return Response.json({ run: data });
  }

  if (action === "delete_source") {
    const icpId = String(body.icpId ?? "").trim();
    const source = String(body.source ?? "").trim();
    if (!icpId || !source) return bad("Which ICP and source?");
    const { data, error } = await supabase.rpc("delete_icp_verdict_source_v1", {
      p_client_id: id, p_icp_profile_id: icpId, p_source: source,
    });
    if (error) return failure(error);
    return Response.json({ deleted: data });
  }

  return bad("Unknown action.");
}
