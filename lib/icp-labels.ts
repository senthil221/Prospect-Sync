// How the ICP validator's verdicts read on one Company DB row.
//
// A company can carry verdicts from several models (and, per ICP, several
// ICPs). The row shows one summary per ICP: FIT or NON_FIT when every model
// agrees, MIXED when they do not, with the per-model detail in the tooltip.
// Verdicts judged against an older version of the brief are counted
// separately as stale rather than silently mixed in.
//
// A strategy check (Strict / Balanced / Lenient, source 'strategy:<name>') is
// already the votes of several models reduced to one answer, so when one is
// current it is the row's verdict - the latest one if several strategies ran -
// and the individual model labels stay in the tooltip.

export type IcpLabel = {
  company_id: string;
  icp_profile_id: string;
  icp_name: string;
  source: string;
  verdict: "FIT" | "NON_FIT";
  reason: string;
  current: boolean;
  decided_at?: string | null;
};

export type IcpLabelSummary = {
  icpId: string;
  icpName: string;
  verdict: "FIT" | "NON_FIT" | "MIXED" | "STALE";
  fit: number;
  nonFit: number;
  stale: number;
  // "Strict", "Balanced" or "Lenient" when the verdict is a strategy's.
  method: string | null;
  labels: IcpLabel[];
};

const strategyPrefix = "strategy:";
const methodName = (source: string) => {
  const name = source.slice(strategyPrefix.length);
  return name.charAt(0).toUpperCase() + name.slice(1);
};

export function summarizeIcpLabels(labels: IcpLabel[]): IcpLabelSummary[] {
  const byIcp = new Map<string, IcpLabel[]>();
  for (const label of labels) {
    const list = byIcp.get(label.icp_profile_id) ?? [];
    list.push(label);
    byIcp.set(label.icp_profile_id, list);
  }
  return [...byIcp.entries()].map(([icpId, list]) => {
    const current = list.filter((label) => label.current);
    const strategy = current
      .filter((label) => label.source.startsWith(strategyPrefix))
      .sort((a, b) => String(b.decided_at ?? "").localeCompare(String(a.decided_at ?? "")))[0];
    const models = current.filter((label) => !label.source.startsWith(strategyPrefix));
    const fit = models.filter((label) => label.verdict === "FIT").length;
    const nonFit = models.length - fit;
    return {
      icpId,
      icpName: list[0]?.icp_name.trim() || "Untitled ICP",
      verdict: strategy ? strategy.verdict : !current.length ? "STALE" : !nonFit ? "FIT" : !fit ? "NON_FIT" : "MIXED",
      fit,
      nonFit,
      stale: list.length - current.length,
      method: strategy ? methodName(strategy.source) : null,
      labels: list,
    };
  });
}
