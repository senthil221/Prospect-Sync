import { authorizeApi, getAuthorizedUser } from "../../../lib/auth.ts";
import { readBoundedJson } from "../../../lib/bounded-json.ts";
import { attachmentDisposition, csvCell } from "../../../lib/csv.ts";
import { readIcpSelection } from "../../../lib/icp-selection.ts";
import { observed } from "../../../lib/observability.ts";
import { createAdminClient } from "../../../lib/supabase/admin";
import { PROVIDER_MODES, icpStrategy, sourceLabel } from "../../../worker/icp-validator-core.mjs";

// ICP checks by strategy (Strict / Balanced / Lenient). Each check is two or
// three model passes run by the ICP worker; the database turns their votes
// into one FIT / NON_FIT per company (20260930210000_icp_strategy_checks.sql).
//
// GET  ?view=checks[&client=<id>]                         recent checks, with passes and outcome
// GET  ?view=results&client=&check=&filter=&search=&page= one page of a check's companies and votes
// GET  ?view=csv&client=&check=&filter=&search=           the same as a CSV download
// GET  ?view=scope&client=&icp=                           how many companies each scope would check,
//                                                         and the observed cost per company per model
// POST {action:"start", clientId, icpId, strategy, providerMode, force,
//       scope:"unverified"|"all"|"selection", companyIds[] | allMatching + search + filters + …}
//       Companies with a current ICP check result for this ICP are skipped unless force.
// POST {action:"pause"|"resume"|"cancel"|"retry_failed", clientId, checkId}

const missingCodes = new Set(["PGRST202", "PGRST205", "42883", "42P01"]);
const pageSize = 100;
const csvLimit = 100_000;
const filters = new Set(["all", "fit", "non_fit", "pending", "split"]);
const scopes = new Set(["all", "unverified", "selection"]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function failure(error: { code?: string; message: string }) {
  const missing = Boolean(error.code && missingCodes.has(error.code));
  return Response.json(
    { error: missing ? "Apply the latest database migration to enable ICP checks." : error.message },
    { status: missing ? 503 : error.code === "P0002" ? 404 : error.code === "22023" ? 400 : error.code === "57014" ? 504 : 500 },
  );
}

const bad = (error: string, status = 400) => Response.json({ error }, { status });
const noStore = { "Cache-Control": "no-store" };

type Vote = { pass_no: number; model: string; reasoning_effort: string; state: string; verdict: "FIT" | "NON_FIT" | null; reason: string };
type ResultRow = {
  company_id: string; name: string; domain: string; industry: string; short_description: string;
  verdict: "FIT" | "NON_FIT" | null; reason: string; fit_votes: number; non_fit_votes: number; votes: Vote[];
};

function resultsArgs(url: URL, clientId: string, checkId: string, limit: number, offset: number) {
  const filter = url.searchParams.get("filter") ?? "all";
  return {
    p_client_id: clientId,
    p_check_id: checkId,
    p_filter: filters.has(filter) ? filter : "all",
    p_search: (url.searchParams.get("search") ?? "").trim().slice(0, 200),
    p_limit: limit,
    p_offset: offset,
  };
}

async function workerState() {
  const { data } = await createAdminClient().from("icp_worker_heartbeat").select("configured, seen_at").eq("id", true).maybeSingle();
  if (!data) return { configured: false, seen_at: null, alive: false };
  const seen = new Date(String(data.seen_at)).getTime();
  return { configured: Boolean(data.configured), seen_at: data.seen_at, alive: Number.isFinite(seen) && Date.now() - seen < 120_000 };
}

// What a company has actually cost per model and effort, from the last 30
// days of finished runs (OpenRouter-reported cost over companies it judged).
// List prices overstate DeepSeek at high effort ~4x, so the estimate a check
// shows comes from this when there is history.
async function costPerCompany() {
  const since = new Date(Date.now() - 30 * 86_400_000).toISOString();
  const { data } = await createAdminClient().from("icp_validation_runs")
    .select("model, reasoning_effort, cost_usd, done_items, cached_items")
    .eq("status", "completed").gte("created_at", since).order("created_at", { ascending: false }).limit(300);
  const totals = new Map<string, { cost: number; companies: number }>();
  for (const run of data ?? []) {
    const companies = Number(run.done_items ?? 0) - Number(run.cached_items ?? 0);
    const cost = Number(run.cost_usd ?? 0);
    if (!(companies > 0) || !(cost > 0)) continue;
    const key = `${run.model}|${run.reasoning_effort}`;
    const total = totals.get(key) ?? { cost: 0, companies: 0 };
    total.cost += cost; total.companies += companies;
    totals.set(key, total);
  }
  return Object.fromEntries([...totals].map(([key, total]) => [key, total.cost / total.companies]));
}

const filterNames: Record<string, string> = { fit: "FIT", non_fit: "NON_FIT", split: "Split votes", pending: "Pending" };

// "ICP check - Balanced - Testing ICP - Krishify - FIT - 2026-09-30.csv":
// the method first, then whose and which ICP, the view if it is not
// everything, and the day the check ran (so downloading it again gives the
// same name).
async function csvFileName(clientId: string, checkId: string, url: URL) {
  const supabase = createAdminClient();
  const [{ data: check }, { data: client }] = await Promise.all([
    supabase.from("icp_strategy_checks").select("strategy, icp_name, created_at").eq("id", checkId).eq("client_id", clientId).maybeSingle(),
    supabase.from("clients").select("name").eq("id", clientId).maybeSingle(),
  ]);
  const method = icpStrategy(String(check?.strategy ?? ""))?.label ?? "Check";
  const day = String(check?.created_at ?? new Date().toISOString()).slice(0, 10);
  const view = filterNames[url.searchParams.get("filter") ?? ""];
  const search = (url.searchParams.get("search") ?? "").trim();
  return [
    "ICP check", method, client?.name, check?.icp_name, view, search ? `search ${search.slice(0, 40)}` : "", day,
  ].map((part) => String(part ?? "").trim()).filter(Boolean).join(" - ") + ".csv";
}

async function handleGET(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const url = new URL(request.url);
  const view = url.searchParams.get("view") ?? "checks";
  const clientId = (url.searchParams.get("client") ?? "").trim();
  const supabase = createAdminClient();

  if (view === "checks") {
    const [{ data, error }, worker] = await Promise.all([
      supabase.rpc("icp_strategy_checks_v1", { p_client_id: clientId || null, p_limit: 30 }),
      workerState(),
    ]);
    if (error) return failure(error);
    return Response.json({ checks: data ?? [], worker }, { headers: noStore });
  }

  if (!clientId) return bad("Which client?");

  if (view === "scope") {
    const icpId = (url.searchParams.get("icp") ?? "").trim();
    if (!icpId) return bad("Which ICP?");
    const [{ data, error }, perCompany] = await Promise.all([
      supabase.rpc("icp_strategy_scope_counts_v2", { p_client_id: clientId, p_icp_profile_id: icpId }),
      costPerCompany(),
    ]);
    if (error) return failure(error);
    return Response.json({ counts: data, costPerCompany: perCompany }, { headers: noStore });
  }

  const checkId = (url.searchParams.get("check") ?? "").trim();
  if (!uuid.test(checkId)) return bad("Which check?");

  if (view === "results") {
    const page = Math.max(1, Math.min(Number(url.searchParams.get("page") ?? 1) || 1, 10_000));
    const { data, error } = await supabase.rpc("icp_strategy_results_v1", resultsArgs(url, clientId, checkId, pageSize, (page - 1) * pageSize));
    if (error) return failure(error);
    return Response.json({ ...(data as object), page, pageSize }, { headers: noStore });
  }

  if (view === "csv") {
    const header = ["Company", "Domain", "Industry", "Final verdict", "FIT votes", "NON_FIT votes", "Reason", "Votes", "Short description"];
    const lines = [header.map(csvCell).join(",")];
    for (let offset = 0; offset < csvLimit; offset += 1000) {
      const { data, error } = await supabase.rpc("icp_strategy_results_v1", resultsArgs(url, clientId, checkId, 1000, offset));
      if (error) return failure(error);
      const rows = (data as { rows?: ResultRow[] })?.rows ?? [];
      for (const row of rows) {
        const votes = row.votes.map((vote) => `#${vote.pass_no} ${sourceLabel(vote.model)} (${vote.reasoning_effort}): ${vote.verdict ?? vote.state}`).join("; ");
        lines.push([row.name, row.domain, row.industry, row.verdict ?? "Pending", row.fit_votes, row.non_fit_votes, row.reason, votes, row.short_description]
          .map(csvCell).join(","));
      }
      if (rows.length < 1000) break;
    }
    return new Response(String.fromCharCode(0xfeff) + `${lines.join("\r\n")}\r\n`, {
      headers: {
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": attachmentDisposition(await csvFileName(clientId, checkId, url)),
        "Cache-Control": "no-store",
      },
    });
  }

  return bad("Unknown view.");
}

async function handlePOST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const decoded = await readBoundedJson(request);
  if (decoded.response) return decoded.response;
  const body = (decoded.value ?? {}) as Record<string, unknown>;
  const action = String(body.action ?? "");
  const clientId = String(body.clientId ?? "").trim();
  if (!clientId) return bad("Which client?");
  const user = await getAuthorizedUser();
  const actor = user?.email ?? "";
  const supabase = createAdminClient();

  if (action === "start") {
    const icpId = String(body.icpId ?? "").trim();
    if (!icpId) return bad("Which ICP?");
    const strategy = icpStrategy(String(body.strategy ?? ""));
    if (!strategy) return bad("Choose Strict, Balanced or Lenient.");
    const scope = String(body.scope ?? "unverified");
    if (!scopes.has(scope)) return bad("Unknown scope.");
    const providerMode = PROVIDER_MODES.includes(String(body.providerMode)) ? String(body.providerMode) : "cheapest";
    let selection = { p_company_ids: null as string[] | null, p_search: "", p_filters: [] as unknown, p_people_scope: null as unknown, p_excluded_ids: null as string[] | null };
    if (scope === "selection") {
      const read = await readIcpSelection(clientId, body, user?.id ?? "", "check");
      if (read.error) return read.error;
      selection = read.args;
    }
    const { data, error } = await supabase.rpc("start_icp_strategy_check_v2", {
      p_client_id: clientId,
      p_icp_profile_id: icpId,
      p_strategy: strategy.id,
      p_scope: scope,
      ...selection,
      p_force: body.force === true,
      p_provider_mode: providerMode,
      p_created_by: actor,
    });
    if (error) return failure(error);
    return Response.json({ check: data });
  }

  if (action === "pause" || action === "resume" || action === "cancel" || action === "retry_failed") {
    const checkId = String(body.checkId ?? "").trim();
    if (!uuid.test(checkId)) return bad("Which check?");
    const { data, error } = await supabase.rpc("set_icp_strategy_check_state_v1", {
      p_client_id: clientId, p_check_id: checkId, p_action: action, p_actor: actor,
    });
    if (error) return failure(error);
    return Response.json({ result: data });
  }

  return bad("Unknown action.");
}

export const GET = observed("/api/icp-checks", handleGET);
export const POST = observed("/api/icp-checks", handlePOST);
