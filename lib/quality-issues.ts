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

import type { ProspectFilter } from "./types.ts";
import type { QualitySummary } from "./types.ts";

export type QualitySeverity = "high" | "medium" | "low" | "clear";

// The filter that selects exactly the records a check counted.
//
// A count is a fact; it is still not a task. "412 people have no email" tells
// you nothing you can act on until you can see which 412, which is why every
// check that can be expressed as a filter now carries one - the button opens
// the People workspace already narrowed to those records, where they can be
// edited, exported or pushed like any other selection.
//
// EXACTNESS IS THE WHOLE POINT. A tile reading 23 that opens onto 113 records
// is worse than no button at all, because it quietly teaches you not to trust
// the number. Each filter below was checked against the count its tile reads
// from data_quality_overview, on production:
//
//   missing work email   23      -> __work_email empty AND __personal_email empty   23
//   missing website      23,568  -> __company_domain empty                          23,568
//   missing title        2,115   -> __title empty                                   2,115
//   missing LinkedIn     82,322  -> __linkedin empty                                82,322
//   missing company      113     -> __company empty                                 113
//
// The website check reads __company_domain rather than the __website it shares a
// name with, because __website is not a working prospect filter: the compiler
// resolves it to an empty literal, so `__website empty` becomes
// btrim(coalesce('', '')) = '' and matches every row in the database. Checked
// rather than assumed - it returned all 681,785 against a tile reading 23,568.
// The People filter panel never offers __website, so nothing else reaches it;
// __company_domain compiles to btrim(coalesce(pi.company_domain, '')) = '' and
// counts exactly the 23,568.
//
// A check with no filter simply gets no button. "Not touched in 180 days" reads
// prospects.updated_at, and there is no updated_at filter to point at - inventing
// an approximate one would break the rule above.
//
// The three company-profile checks added later were held back for exactly this
// rule: two of them had no People filter to point at until 20260916090000 taught
// the compiler to read public.companies. Their counts were re-verified the same
// way, against the tiles, on production:
//
//   missing # employees           78,995  -> __employee_count is "unknown"   78,995
//   missing company keywords      94,089  -> __company_keywords empty        94,089
//   missing company description   94,444  -> __company_description empty     94,444
//
// That equality is asserted inside 20260916100000 rather than only checked once,
// because the tile and the button drift the moment either side is edited alone.
const emptyFilter = (field: string): ProspectFilter => ({ id: `quality:${field}`, field, operator: "empty", values: [] });

// Which database a check's number counts, and which one its button opens.
// PEOPLE-side checks (email, title, LinkedIn, "missing company" itself, and
// staleness) are gaps on the person record with no company row to redirect to
// instead. COMPANY-side checks (website, employees, keywords, description) are
// gaps on the company profile - counting them per person double-counted every
// company with more than one prospect and, worse, silently excluded every
// company with zero prospects. 20260920120000 is what makes that distinction
// possible: it adds the company-counted equivalent of each company-side check
// to data_quality_overview, verified there against the exact filter its button
// applies, over every company - not the people who happen to sit behind one.
export type QualityEntity = "people" | "company";

export type QualityIssue = {
  id: string;
  label: string;
  entity: QualityEntity;
  count: number;
  total: number;
  share: number;
  shareText: string;
  severity: QualitySeverity;
  /** What this gap does to the product, in the user's terms. */
  impact: string;
  /** The one next action. */
  action: string;
  /** Selects exactly the records this check counted, or null when it cannot be expressed. */
  filters: ProspectFilter[] | null;
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

const checks: Array<{ id: string; label: string; entity: QualityEntity; severity: Exclude<QualitySeverity, "clear">; read: (summary: QualitySummary) => number; total: (summary: QualitySummary) => number; impact: string; action: string; filters: ProspectFilter[] | null }> = [
  {
    id: "email", label: "Missing work email", entity: "people", severity: "high",
    read: (summary) => summary.missingEmail, total: (summary) => summary.total,
    impact: "These people cannot be contacted at all, and they still take up room in every list you push to a client.",
    action: "Re-import the source list with an email column, or exclude them from client pushes until it has one.",
    // Both, because the count is people who have neither address.
    filters: [emptyFilter("__work_email"), emptyFilter("__personal_email")],
  },
  {
    id: "company", label: "Missing company", entity: "people", severity: "high",
    read: (summary) => summary.missingCompany, total: (summary) => summary.total,
    impact: "With no company these people cannot be filtered by industry, size or location, and they never appear in the Company database.",
    action: "Re-import with a company column. If you have the website, filling gaps recovers the name from it.",
    // Person-side on purpose: there is no company row to redirect to when the
    // gap IS the missing link. Counted as a blank company name rather than a
    // missing link, so the number and this filter select the same rows -- see
    // 20260916090000.
    filters: [emptyFilter("__company")],
  },
  {
    id: "title", label: "Missing title", entity: "people", severity: "medium",
    read: (summary) => summary.missingTitle, total: (summary) => summary.total,
    impact: "Seniority and department are derived from the title, so every filter built on either skips these records entirely.",
    action: "Re-import with a title column - it is a person-level field, so filling gaps from company records cannot supply it.",
    filters: [emptyFilter("__title")],
  },
  {
    id: "stale", label: "Not touched in 180 days", entity: "people", severity: "medium",
    read: (summary) => summary.staleRecords, total: (summary) => summary.total,
    impact: "Titles and emails decay faster than anything else on a record. A stale list is where bounce rates come from.",
    action: "Re-scrape these people and re-import before the next campaign; the import updates in place.",
    // prospects.updated_at has no filter field, and an approximate one would
    // break the exactness rule above, so this check gets no button.
    filters: null,
  },
  {
    id: "linkedin", label: "Missing LinkedIn", entity: "people", severity: "low",
    read: (summary) => summary.missingLinkedin, total: (summary) => summary.total,
    impact: "LinkedIn is the fallback identifier when name and email both fail to match, so gaps make future de-duplication less certain.",
    action: "No action needed now. A later import that carries the profile fills it in place.",
    filters: [emptyFilter("__linkedin")],
  },
  // The company profile, counted and opened on the COMPANY side: how many
  // companies carry the gap, out of every company, with the button opening the
  // Company database rather than People. Counting people here double-counted
  // any company with several prospects and silently dropped every company with
  // none - measured on production, 100,448 companies have no recorded website
  // against 23,568 people who happened to be at one. 20260920120000 is what
  // makes the company-side number exist to read.
  {
    id: "domain", label: "Missing company website", entity: "company", severity: "high",
    read: (summary) => summary.companiesMissingDomain ?? 0, total: (summary) => summary.companiesTotal ?? 0,
    impact: "The website is what companies are matched on. Without it a company duplicates against every future import, and the coverage checker cannot see it.",
    action: "Fill gaps from company records above, which recovers the website from another import of the same company.",
    filters: [{ id: "quality:__website", field: "__website", operator: "empty", values: [] }],
  },
  {
    id: "employees", label: "Missing # employees", entity: "company", severity: "medium",
    read: (summary) => summary.companiesMissingEmployees ?? 0, total: (summary) => summary.companiesTotal ?? 0,
    impact: "Company size is the first cut in almost every ICP, so these companies are invisible to any search that sets a size band - including a client's own.",
    action: "Import the company list with an employee count column.",
    // Not an empty filter: employee count is two numeric columns, and the range
    // control expresses "no number at all" as the 'unknown' band.
    filters: [{ id: "quality:__employee_count", field: "__employee_count", operator: "number_ranges", values: ["unknown"] }],
  },
  {
    id: "company_keywords", label: "Missing company keywords", entity: "company", severity: "medium",
    read: (summary) => summary.companiesMissingKeywords ?? 0, total: (summary) => summary.companiesTotal ?? 0,
    impact: "Keywords are what a keyword search matches. Without them a company can only be found by name, industry or description.",
    action: "Re-import the company file with a Keywords column.",
    filters: [{ id: "quality:__keywords", field: "__keywords", operator: "empty", values: [] }],
  },
  {
    id: "company_description", label: "Missing company description", entity: "company", severity: "low",
    read: (summary) => summary.companiesMissingDescription ?? 0, total: (summary) => summary.companiesTotal ?? 0,
    impact: "The description is the widest of the keyword scopes - it is what finds a company that does the thing without using the word for it.",
    action: "No action needed now. A later company import carrying descriptions fills them in place, and the narrower scopes still work meanwhile.",
    filters: [{ id: "quality:__short_description", field: "__short_description", operator: "empty", values: [] }],
  },
];

const rank: Record<QualitySeverity, number> = { high: 0, medium: 1, low: 2, clear: 3 };

/**
 * The queue, worst first. A check with no affected records is not dropped - it
 * becomes "clear", because knowing a check ran and found nothing is different
 * from the check not being on the list.
 */
export function qualityIssues(summary: QualitySummary): QualityIssue[] {
  return checks
    .map((check) => {
      const count = Math.max(0, Number(check.read(summary) ?? 0));
      // Each check's own denominator: a company check divided by every person
      // would report a percentage of the wrong population entirely.
      const total = Math.max(0, Number(check.total(summary) ?? 0));
      return {
        id: check.id,
        label: check.label,
        entity: check.entity,
        count,
        total,
        share: total ? count / total : 0,
        shareText: formatShare(count, total),
        severity: count ? check.severity : ("clear" as QualitySeverity),
        impact: check.impact,
        action: check.action,
        filters: check.filters,
      };
    })
    .sort((left, right) => rank[left.severity] - rank[right.severity] || right.count - left.count);
}
