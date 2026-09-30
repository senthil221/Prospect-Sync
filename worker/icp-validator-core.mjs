// The ICP validator's model contract: the prompt, how a company becomes a row,
// how an answer is read back, and how OpenRouter is called. Plain JS so the
// ICP worker imports it directly; the app imports the catalog and estimator.
//
// Nothing in here touches the database.

export const OPENROUTER_URL = 'https://openrouter.ai/api/v1/chat/completions';

// Prices are OpenRouter's list prices per million tokens on 2026-09-29, used
// only for the estimate shown before a run starts. The cost recorded on a run
// is the one OpenRouter reports for each call.
export const ICP_MODELS = [
  { id: 'openai/gpt-6-luna', label: 'GPT-6 Luna', inputPerM: 0.10, outputPerM: 0.50 },
  { id: 'deepseek/deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash', inputPerM: 0.30, outputPerM: 1.20 },
  { id: 'xiaomi/mimo-v2.6-flash', label: 'MiMo V2.6 Flash', inputPerM: 0.14, outputPerM: 0.28 },
];

export const REASONING_EFFORTS = ['minimal', 'low', 'medium', 'high'];

export function icpModel(id) {
  return ICP_MODELS.find((model) => model.id === id) ?? null;
}

export function sourceLabel(source) {
  if (source.startsWith('reference:')) return `${source.slice('reference:'.length)} (reference)`;
  if (source.startsWith('strategy:')) return icpStrategy(source.slice('strategy:'.length))?.label ?? source;
  return icpModel(source)?.label ?? source;
}

// Rough, and labelled as such: ~1,100 tokens of instructions and brief per
// call spread over the batch, ~300 tokens per company in, ~60 out plus
// reasoning that grows with effort.
const reasoningTokensPerRow = { minimal: 20, low: 120, medium: 300, high: 700 };
// One check runs at most this many models side by side.
export const MAX_MODELS_PER_CHECK = 3;

// The production strategies: fixed model passes over the same companies, and
// the rule that turns their votes into one label. The database's
// icp_strategy_passes_v1 / icp_strategy_rule_v1 are what actually run; this is
// what the app shows, and a unit test keeps the two identical.
export const ICP_STRATEGIES = [
  {
    id: 'strict', label: 'Strict', needFit: 2,
    rule: 'FIT only if both runs say FIT. Either says NON_FIT → NON_FIT.',
    summary: 'Fewest FITs. For a tight list where a wrong FIT costs more than a missed one.',
    passes: [
      { model: 'deepseek/deepseek-v4.1-flash', effort: 'high' },
      { model: 'openai/gpt-6-luna', effort: 'low' },
    ],
  },
  {
    id: 'balanced', label: 'Balanced', needFit: 2,
    rule: 'FIT if at least two of three runs say FIT. Two NON_FITs → NON_FIT.',
    summary: 'Majority vote. The middle ground.',
    passes: [
      { model: 'deepseek/deepseek-v4.1-flash', effort: 'high' },
      { model: 'deepseek/deepseek-v4.1-flash', effort: 'high' },
      { model: 'openai/gpt-6-luna', effort: 'low' },
    ],
  },
  {
    id: 'lenient', label: 'Lenient', needFit: 1,
    rule: 'FIT if either run says FIT. Only both NON_FIT → NON_FIT.',
    summary: 'Most FITs. Keeps borderline companies - fewest false NON_FITs.',
    passes: [
      { model: 'deepseek/deepseek-v4.1-flash', effort: 'high' },
      { model: 'deepseek/deepseek-v4.1-flash', effort: 'high' },
    ],
  },
];

export function icpStrategy(id) {
  return ICP_STRATEGIES.find((strategy) => strategy.id === id) ?? null;
}

// A strategy's final verdict from its votes, or null while the remaining
// votes could still change it. The same rule settle_icp_strategy_companies_v1
// applies.
export function strategyVerdict(strategy, fitVotes, nonFitVotes) {
  const rule = typeof strategy === 'string' ? icpStrategy(strategy) : strategy;
  if (!rule) return null;
  if (fitVotes >= rule.needFit) return 'FIT';
  if (nonFitVotes > rule.passes.length - rule.needFit) return 'NON_FIT';
  return null;
}

// Provider routing. 'cheapest' asks OpenRouter for the lowest-priced provider
// that still honours JSON mode and reasoning, leaving out 4-bit quantized
// hosts (fp4/int4 and their variants), whose answers can drift. Fallbacks stay
// on, so a cheap provider that fails hands over to the next one.
export const PROVIDER_MODES = ['cheapest', 'default'];
export const CHEAPEST_QUANTIZATIONS = ['int8', 'fp6', 'fp8', 'mxfp8', 'fp16', 'bf16', 'fp32', 'unknown'];

// modelOrId: a catalog entry ({inputPerM, outputPerM}) for any OpenRouter
// model, or the id of one of the defaults.
export function estimateRunCost(modelOrId, companies, { effort = 'low', batchSize = 20, briefLength = 800 } = {}) {
  const model = typeof modelOrId === 'string' ? icpModel(modelOrId) : modelOrId;
  if (!model || !companies) return null;
  const perCallInput = 900 + Math.ceil(briefLength / 4);
  const input = companies * 300 + Math.ceil(companies / batchSize) * perCallInput;
  const output = companies * (60 + (reasoningTokensPerRow[effort] ?? 120));
  return (input * model.inputPerM + output * model.outputPerM) / 1_000_000;
}

// ---------------------------------------------------------------------------
// The prompt. The operator's brief, adapted to a batch contract: every row
// carries an id and every result must return it, because company names repeat
// and get mangled, and a result matched by name can silently land on the
// wrong company.
export function buildSystemPrompt(icpText) {
  return `You are filtering cold-outreach company lists against a client ICP.

ICP source: use only the ICP supplied in this request. If the request has no ICP, return exactly {"error":"NO_ICP"} and nothing else. Do not invent an ICP. If the ICP depends on fields you will not receive (headcount, geography, revenue, tech stack), return {"error":"ICP_UNANSWERABLE","missing":[...]} and nothing else.

Output space is two verdicts only:
FIT - the row is a clear match, or the text is insufficient / mixed / ambiguous. When unsure, FIT.
NON_FIT - the text establishes that this company itself does not do or possess what the ICP requires.
NON_FIT is the only high-bar label. Empty text, industry-only rows, mixed roles, and "can't tell" are FIT. Do not force NON_FIT to look decisive.

What you have to evaluate
Each row: id, company_name, industry, short_description, and keywords only when short_description is missing or under ~300 characters. You will never see Website. Ignore any URL if one appears inside the text.
Trust order: short_description first, keywords second, industry last-resort hint. Industry alone must never produce NON_FIT. A row with empty/near-empty short_description and keywords is FIT.

How to judge (do this in thinking; do not skip)
Quote the phrases that describe what this company itself does or owns.
Apply the ICP to those quotes only. No outside knowledge. Unknown is not NON_FIT.
Run the vendor test on every row: lists were keyword-pulled. A company that only serves, advises, staffs, finances, sells software to, or publishes about the ICP audience is NON_FIT. The test is: does this company itself do or possess what the ICP requires - not "does it talk about people who do."
Intermediaries (distributor, dealer, importer, broker, agency, marketplace, franchisee): NON_FIT only if the text clearly shows an intermediary-only role. A clear blend with the qualifying operating role is FIT. An unclear mix is FIT.
If name/text looks like the row describes a different entity than the company name, FIT (do not NON_FIT).

Output
Return one JSON object, no markdown, no extra keys:
{"results":[{"id":"<id from input>","company_name":"<exact name from input>","verdict":"FIT" | "NON_FIT","reason":"<one sentence; must include a short quote from the row, or state that the text was insufficient>"}]}
One result per input row, same order as input. Every input row appears exactly once, with its id. reason is for operator logs; it is not a third category.

Hard rules
Never classify by industry label, keyword presence, or pattern-matching in place of reading the description.
Never fabricate facts about the company.
NON_FIT only when the row's own text establishes a disqualifying operating model or a clear miss vs the ICP.
When evidence cuts both ways, or there is no evidence: FIT.

ICP:
<<<
${String(icpText ?? '').trim()}
>>>`;
}

const urlPattern = /\b(?:https?:\/\/|www\.)\S+/gi;
const clip = (value, max) => (value.length > max ? `${value.slice(0, max - 1).trimEnd()}…` : value);
const tidy = (value) => String(value ?? '').replace(urlPattern, ' ').replace(/\s+/g, ' ').trim();

export const DESCRIPTION_LIMIT = 1500;
export const KEYWORDS_LIMIT = 600;
export const KEYWORDS_WHEN_DESCRIPTION_UNDER = 300;

// A claimed company as the model sees it. Keywords ride along only when the
// description is missing or short - decided here, not left to the model.
export function companyRow(company, id) {
  const description = tidy(company.short_description);
  const row = {
    id,
    company_name: String(company.name ?? '').trim(),
    industry: tidy(company.industry),
    short_description: clip(description, DESCRIPTION_LIMIT),
  };
  if (description.length < KEYWORDS_WHEN_DESCRIPTION_UNDER) {
    const keywords = Array.isArray(company.keywords) ? company.keywords : [];
    const text = tidy(keywords.filter(Boolean).join(', '));
    if (text) row.keywords = clip(text, KEYWORDS_LIMIT);
  }
  return row;
}

export function buildBatch(companies) {
  const rows = companies.map((company, index) => companyRow(company, `r${index + 1}`));
  const idToCompany = new Map(rows.map((row, index) => [row.id, companies[index].company_id]));
  const user = `Evaluate these ${rows.length} rows. Return one result per row, with its id.\n${rows.map((row) => JSON.stringify(row)).join('\n')}`;
  return { rows, idToCompany, user };
}

// ---------------------------------------------------------------------------
export class IcpOutputError extends Error {
  constructor(kind, message, extra = {}) {
    super(message);
    this.kind = kind; // 'invalid_output' | 'unanswerable'
    Object.assign(this, extra);
  }
}

function normalizeVerdict(value) {
  const verdict = String(value ?? '').trim().toUpperCase().replace(/[\s-]+/g, '_');
  if (verdict === 'FIT') return 'FIT';
  if (verdict === 'NON_FIT' || verdict === 'NONFIT' || verdict === 'NOT_FIT') return 'NON_FIT';
  return null;
}

function extractJson(text) {
  let body = String(text ?? '');
  body = body.replace(/<think>[\s\S]*?<\/think>/gi, '');
  body = body.replace(/```(?:json)?/gi, '');
  const start = body.indexOf('{');
  const end = body.lastIndexOf('}');
  if (start === -1 || end <= start) throw new IcpOutputError('invalid_output', 'The model did not return a JSON object.');
  try {
    return JSON.parse(body.slice(start, end + 1));
  } catch {
    throw new IcpOutputError('invalid_output', 'The model returned malformed JSON.');
  }
}

// Reads an answer back onto the batch. Rows the model skipped are reported,
// not guessed; the database puts them back in line.
export function parseModelOutput(text, batch) {
  const parsed = extractJson(text);
  if (parsed && typeof parsed === 'object' && typeof parsed.error === 'string' && parsed.error) {
    const missing = Array.isArray(parsed.missing) ? parsed.missing.map(String).slice(0, 10) : [];
    throw new IcpOutputError('unanswerable', parsed.error, { code: parsed.error, missing });
  }
  if (!parsed || !Array.isArray(parsed.results)) {
    throw new IcpOutputError('invalid_output', 'The model answer has no results array.');
  }

  const byName = new Map();
  for (const row of batch.rows) {
    const key = row.company_name.toLowerCase();
    byName.set(key, byName.has(key) ? null : row.id);
  }

  const results = [];
  const seen = new Set();
  for (const item of parsed.results) {
    if (!item || typeof item !== 'object') continue;
    let id = typeof item.id === 'string' || typeof item.id === 'number' ? String(item.id).trim() : '';
    if (!batch.idToCompany.has(id)) {
      // An id-less answer is accepted only when its name is unique in the batch.
      id = byName.get(String(item.company_name ?? '').trim().toLowerCase()) ?? '';
    }
    const verdict = normalizeVerdict(item.verdict);
    if (!id || !verdict || seen.has(id)) continue;
    seen.add(id);
    results.push({
      company_id: batch.idToCompany.get(id),
      verdict,
      reason: String(item.reason ?? '').replace(/\s+/g, ' ').trim().slice(0, 1000),
    });
  }

  if (!results.length && batch.rows.length) {
    throw new IcpOutputError('invalid_output', 'The model answer had no usable verdicts.');
  }
  const missing = batch.rows.filter((row) => !seen.has(row.id)).map((row) => batch.idToCompany.get(row.id));
  return { results, missing };
}

// ---------------------------------------------------------------------------
export class OpenRouterError extends Error {
  constructor(kind, message, extra = {}) {
    super(message);
    // auth | credits | rate_limited | transient | bad_request | model_unavailable
    this.kind = kind;
    Object.assign(this, extra);
  }
}

function retryAfterMs(response) {
  const header = Number(response.headers?.get?.('retry-after'));
  return Number.isFinite(header) && header > 0 ? Math.min(header * 1000, 120_000) : 0;
}

function errorFromStatus(status, message, response) {
  const detail = message ? `: ${String(message).slice(0, 300)}` : '';
  if (status === 401 || status === 403) return new OpenRouterError('auth', `OpenRouter rejected the API key (${status})${detail}`);
  if (status === 402) return new OpenRouterError('credits', `OpenRouter says the account is out of credits (402)${detail}`);
  if (status === 429) return new OpenRouterError('rate_limited', `OpenRouter rate limit (429)${detail}`, { retryAfterMs: response ? retryAfterMs(response) : 0 });
  if (status === 404) return new OpenRouterError('model_unavailable', `OpenRouter has no provider for this model and these settings (404)${detail}`);
  if (status === 400 || status === 413 || status === 422) return new OpenRouterError('bad_request', `OpenRouter refused the request (${status})${detail}`);
  return new OpenRouterError('transient', `OpenRouter or the model provider failed (${status})${detail}`);
}

export function openRouterBody({ model, effort, system, user, providerMode = 'default' }) {
  return {
    model,
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: user },
    ],
    response_format: { type: 'json_object' },
    reasoning: { effort: REASONING_EFFORTS.includes(effort) ? effort : 'low', exclude: true },
    max_tokens: 16000,
    usage: { include: true },
    // Only route to providers that honour JSON mode and reasoning settings, so
    // three models are compared on the same terms.
    provider: providerMode === 'cheapest'
      ? { require_parameters: true, sort: 'price', quantizations: CHEAPEST_QUANTIZATIONS }
      : { require_parameters: true },
  };
}

export async function callOpenRouter({ apiKey, model, effort, system, user, providerMode = 'default', timeoutMs = 150_000, fetchImpl = fetch, referer = '' }) {
  const started = Date.now();
  let response;
  try {
    response = await fetchImpl(OPENROUTER_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'X-Title': 'Prospect-Sync ICP validator',
        ...(referer ? { 'HTTP-Referer': referer } : {}),
      },
      body: JSON.stringify(openRouterBody({ model, effort, system, user, providerMode })),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    const timedOut = error?.name === 'TimeoutError' || error?.name === 'AbortError';
    throw new OpenRouterError('transient', timedOut ? `No answer from OpenRouter within ${Math.round(timeoutMs / 1000)}s` : 'Could not reach OpenRouter');
  }

  let data = null;
  try { data = await response.json(); } catch { data = null; }
  const ms = Date.now() - started;
  const usage = usageFrom(data?.usage, ms);

  if (!response.ok) {
    const error = errorFromStatus(response.status, data?.error?.message, response);
    error.usage = usage;
    throw error;
  }
  if (data?.error) {
    const error = errorFromStatus(Number(data.error.code) || 502, data.error.message, response);
    error.usage = usage;
    throw error;
  }
  const choice = data?.choices?.[0];
  if (choice?.error) {
    const error = errorFromStatus(Number(choice.error.code) || 502, choice.error.message, response);
    error.usage = usage;
    throw error;
  }
  const content = typeof choice?.message?.content === 'string' ? choice.message.content : '';
  return { content, finishReason: choice?.finish_reason ?? '', usage, provider: data?.provider ?? '' };
}

export function usageFrom(usage, ms = 0) {
  return {
    prompt_tokens: Number(usage?.prompt_tokens ?? 0) || 0,
    completion_tokens: Number(usage?.completion_tokens ?? 0) || 0,
    cached_tokens: Number(usage?.prompt_tokens_details?.cached_tokens ?? 0) || 0,
    reasoning_tokens: Number(usage?.completion_tokens_details?.reasoning_tokens ?? 0) || 0,
    cost: Number(usage?.cost ?? 0) || 0,
    ms,
  };
}

// What the worker should do about a failed call. pauseScope 'all' stops every
// run (the key or the account is the problem); 'run' stops just this one (the
// model can't do this ICP, or this model isn't routable); '' retries the rows.
export function failurePlan(error) {
  if (error instanceof IcpOutputError && error.kind === 'unanswerable') {
    const missing = error.missing?.length ? `: ${error.missing.join(', ')}` : '';
    return {
      retry: false, pauseScope: 'run',
      message: error.code === 'NO_ICP'
        ? 'The model says it received no ICP. Check the brief on the ICPs tab, then start a new check.'
        : `The model says this ICP depends on information it is not given${missing}. Keep the brief to what a company's description, keywords and industry can show (filter size and location with the Company DB filters), then start a new check.`,
    };
  }
  if (error instanceof OpenRouterError) {
    if (error.kind === 'auth' || error.kind === 'credits') return { retry: false, pauseScope: 'all', message: `${error.message}. Fix it, then resume.` };
    if (error.kind === 'model_unavailable' || error.kind === 'bad_request') return { retry: false, pauseScope: 'run', message: `${error.message}. Resume to try again, or start this check with another model.` };
  }
  return { retry: true, pauseScope: '', message: '' };
}
