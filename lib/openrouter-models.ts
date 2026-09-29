import { ICP_MODELS } from "../worker/icp-validator-core.mjs";

// Which OpenRouter models the ICP validator may run.
//
// The three defaults are always offered. Any other model on OpenRouter can be
// chosen too, as long as OpenRouter says it honours the two settings every ICP
// call sends - JSON output (response_format) and reasoning - because the worker
// asks OpenRouter to route only to providers that support them
// (provider.require_parameters); a model without them would fail every call.
//
// The catalog is OpenRouter's public model list (no key needed), cached for an
// hour. If it cannot be fetched, the defaults still work.

export type IcpModelOption = {
  id: string;
  label: string;
  inputPerM: number;
  outputPerM: number;
  contextLength: number | null;
  recommended: boolean;
};

type OpenRouterModel = {
  id?: unknown;
  name?: unknown;
  context_length?: unknown;
  pricing?: { prompt?: unknown; completion?: unknown };
  supported_parameters?: unknown;
};

const catalogUrl = "https://openrouter.ai/api/v1/models";
const cacheMs = 60 * 60 * 1000;
let cached: { at: number; models: IcpModelOption[] } | null = null;
let inflight: Promise<IcpModelOption[]> | null = null;

const defaults = (): IcpModelOption[] => ICP_MODELS.map((model) => ({
  id: model.id, label: model.label, inputPerM: model.inputPerM, outputPerM: model.outputPerM, contextLength: null, recommended: true,
}));

const perMillion = (value: unknown) => {
  const price = Number(value);
  return Number.isFinite(price) && price >= 0 ? Math.round(price * 1_000_000 * 10_000) / 10_000 : null;
};

// Exported for tests: the filter from OpenRouter's catalog to what may run.
export function icpModelsFromCatalog(data: unknown): IcpModelOption[] {
  const rows = Array.isArray((data as { data?: unknown })?.data) ? (data as { data: OpenRouterModel[] }).data : [];
  const recommended = new Set(ICP_MODELS.map((model) => model.id));
  const options = new Map<string, IcpModelOption>(defaults().map((model) => [model.id, model]));
  for (const row of rows) {
    const id = typeof row.id === "string" ? row.id.trim() : "";
    // Same shape start_icp_validation_run_v1 accepts; drops "~vendor/…-latest"
    // aliases, whose model can change under a run, and ":batch" listings,
    // which are OpenRouter's delayed batch pricing, not live calls.
    if (!/^[a-z0-9][a-z0-9._~-]*\/[a-z0-9][a-z0-9._:~-]*$/.test(id) || id.startsWith("~") || id.endsWith(":batch")) continue;
    const parameters = Array.isArray(row.supported_parameters) ? row.supported_parameters.map(String) : [];
    if (!parameters.includes("response_format") || !parameters.includes("reasoning")) continue;
    const inputPerM = perMillion(row.pricing?.prompt);
    const outputPerM = perMillion(row.pricing?.completion);
    if (inputPerM === null || outputPerM === null) continue;
    const label = typeof row.name === "string" && row.name.trim() ? row.name.trim() : id;
    options.set(id, {
      id,
      label: recommended.has(id) ? options.get(id)?.label ?? label : label,
      inputPerM,
      outputPerM,
      contextLength: Number(row.context_length) || null,
      recommended: recommended.has(id),
    });
  }
  return [...options.values()].sort((left, right) =>
    Number(right.recommended) - Number(left.recommended) || left.label.localeCompare(right.label));
}

export async function icpModelCatalog(): Promise<IcpModelOption[]> {
  if (cached && Date.now() - cached.at < cacheMs) return cached.models;
  inflight ??= (async () => {
    try {
      const response = await fetch(catalogUrl, { signal: AbortSignal.timeout(8_000), cache: "no-store" });
      if (!response.ok) throw new Error(`OpenRouter models ${response.status}`);
      const models = icpModelsFromCatalog(await response.json());
      cached = { at: Date.now(), models };
      return models;
    } catch {
      // Keep the last good list; with none yet, offer the defaults.
      return cached?.models ?? defaults();
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

export async function unknownIcpModels(ids: string[]) {
  const catalog = await icpModelCatalog();
  const known = new Set(catalog.map((model) => model.id));
  return ids.filter((id) => !known.has(id));
}
