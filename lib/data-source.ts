export const commonDataSources = ["Scraper", "Apollo", "Prospeo", "SalesQL", "BetterContact"] as const;

export function normalizeDataSource(value: unknown) {
  return String(value ?? "").trim().replace(/\s+/g, " ").slice(0, 80);
}
