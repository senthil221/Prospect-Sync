import { normalizeDomain, normalizeText } from "../db/normalize.ts";
import { splitPastedValues } from "./bulk-values.ts";

export const MAX_BULK_COMPANY_VALUES = 20_000;
export const MAX_BULK_COMPANY_MATCHES = 50_000;

export function parseCompanyBulkSelection(raw: string, limit = MAX_BULK_COMPANY_VALUES) {
  const allValues = splitPastedValues(raw);
  const values = allValues.slice(0, limit);
  const domains = new Set<string>();
  const names = new Set<string>();

  for (const value of values) {
    const looksLikeWebsite = /^(?:https?:\/\/)?(?:www\.)?[^\s/]+\.[a-z]{2,}(?:[/?#]|$)/i.test(value);
    if (looksLikeWebsite) {
      const domain = normalizeDomain(value);
      if (domain) domains.add(domain);
    } else {
      const name = normalizeText(value);
      if (name) names.add(name);
    }
  }

  return {
    domains: [...domains],
    names: [...names],
    submitted: values.length,
    truncated: allValues.length > values.length,
  };
}
