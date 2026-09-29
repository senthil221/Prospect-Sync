// How the ICP validator's verdicts read on one Company DB row.
//
// A company can carry verdicts from several models (and, per ICP, several
// ICPs). The row shows one summary per ICP: FIT or NON_FIT when every model
// agrees, MIXED when they do not, with the per-model detail in the tooltip.
// Verdicts judged against an older version of the brief are counted
// separately as stale rather than silently mixed in.

export type IcpLabel = {
  company_id: string;
  icp_profile_id: string;
  icp_name: string;
  source: string;
  verdict: "FIT" | "NON_FIT";
  reason: string;
  current: boolean;
};

export type IcpLabelSummary = {
  icpId: string;
  icpName: string;
  verdict: "FIT" | "NON_FIT" | "MIXED" | "STALE";
  fit: number;
  nonFit: number;
  stale: number;
  labels: IcpLabel[];
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
    const fit = current.filter((label) => label.verdict === "FIT").length;
    const nonFit = current.length - fit;
    return {
      icpId,
      icpName: list[0]?.icp_name.trim() || "Untitled ICP",
      verdict: !current.length ? "STALE" : !nonFit ? "FIT" : !fit ? "NON_FIT" : "MIXED",
      fit,
      nonFit,
      stale: list.length - current.length,
      labels: list,
    };
  });
}
