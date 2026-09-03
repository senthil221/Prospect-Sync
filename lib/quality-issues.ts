// Six numbers, ranked by what they cost you.
//
// QUALITY-01. The quality centre rendered its metrics as six identical tiles in
// source order - Missing email beside Missing LinkedIn beside Stale 180+ days,
// same size, same weight, no statement of what any of them does to the product.
// A tile reading "412,883" is a fact; it is not a task. Nothing on the screen
// said which of the six to work on first, or what working on one would even
// mean.
//
// So each check now carries three things a tile cannot: how badly it hurts, what
// it breaks, and the one action that fixes it. Severity is a property of the
// field rather than of the count - an email gap is worse than a LinkedIn gap at
// any scale - and the count only orders checks that are already equally severe.

import type { QualitySummary } from "./types.ts";

export type QualitySeverity = "high" | "medium" | "low" | "clear";

export type QualityIssue = {
  id: string;
  label: string;
  count: number;
  total: number;
  share: number;
  shareText: string;
  severity: QualitySeverity;
  /** What this gap does to the product, in the user's terms. */
  impact: string;
  /** The one next action. */
  action: string;
};

/**
 * QUALITY-03: a non-zero count never reads as 0%.
 *
 * Math.round((412 / 681_085) * 100) is 0, so 412 real records with no email
 * were reported as "0% of database" - a number that says there is nothing to
 * do. The mirror of the same bug is 100% on a value that is not everything, so
 * both ends are clamped.
 */
export function formatShare(count: number, total: number) {
  if (!total || count <= 0) return "0%";
  if (count >= total) return "100%";
  const percent = (count / total) * 100;
  if (percent < 1) return "<1%";
  if (percent > 99) return ">99%";
  return `${Math.round(percent)}%`;
}

const checks: Array<{ id: string; label: string; severity: Exclude<QualitySeverity, "clear">; read: (summary: QualitySummary) => number; impact: string; action: string }> = [
  {
    id: "email", label: "Missing work email", severity: "high",
    read: (summary) => summary.missingEmail,
    impact: "These people cannot be contacted at all, and they still take up room in every list you push to a client.",
    action: "Re-import the source list with an email column, or exclude them from client pushes until it has one.",
  },
  {
    id: "domain", label: "Missing company website", severity: "high",
    read: (summary) => summary.missingDomain,
    impact: "The website is what companies are matched on. Without it these records duplicate against every future import, and the coverage checker cannot see them.",
    action: "Fill gaps from company records above, which recovers the website from other people at the same company.",
  },
  {
    id: "company", label: "Missing company", severity: "high",
    read: (summary) => summary.missingCompany,
    impact: "With no company these people cannot be filtered by industry, size or location, and they never appear in the Company database.",
    action: "Re-import with a company column. If you have the website, filling gaps recovers the name from it.",
  },
  {
    id: "stale", label: "Not touched in 180 days", severity: "medium",
    read: (summary) => summary.staleRecords,
    impact: "Titles and emails decay faster than anything else on a record. A stale list is where bounce rates come from.",
    action: "Re-scrape these people and re-import before the next campaign; the import updates in place.",
  },
  {
    id: "title", label: "Missing title", severity: "medium",
    read: (summary) => summary.missingTitle,
    impact: "Seniority and department are derived from the title, so every filter built on either skips these records entirely.",
    action: "Re-import with a title column - it is a person-level field, so filling gaps from company records cannot supply it.",
  },
  {
    id: "linkedin", label: "Missing LinkedIn", severity: "low",
    read: (summary) => summary.missingLinkedin,
    impact: "LinkedIn is the fallback identifier when name and email both fail to match, so gaps make future de-duplication less certain.",
    action: "No action needed now. A later import that carries the profile fills it in place.",
  },
];

const rank: Record<QualitySeverity, number> = { high: 0, medium: 1, low: 2, clear: 3 };

/**
 * The queue, worst first. A check with no affected records is not dropped - it
 * becomes "clear", because knowing a check ran and found nothing is different
 * from the check not being on the list.
 */
export function qualityIssues(summary: QualitySummary): QualityIssue[] {
  const total = Number(summary.total ?? 0);
  return checks
    .map((check) => {
      const count = Math.max(0, Number(check.read(summary) ?? 0));
      return {
        id: check.id,
        label: check.label,
        count,
        total,
        share: total ? count / total : 0,
        shareText: formatShare(count, total),
        severity: count ? check.severity : ("clear" as QualitySeverity),
        impact: check.impact,
        action: check.action,
      };
    })
    .sort((left, right) => rank[left.severity] - rank[right.severity] || right.count - left.count);
}

export function severityLabel(severity: QualitySeverity) {
  if (severity === "high") return "Blocks outreach";
  if (severity === "medium") return "Degrades targeting";
  if (severity === "low") return "Worth knowing";
  return "Clear";
}
