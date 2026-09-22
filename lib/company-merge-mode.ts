// How a company upload resolves a row that matches a company already in the
// Company database. Matching itself is unchanged: normalized website first, then
// normalized name when at least one side has no website.
//
// Keep these labels in sync with the comment block in
// supabase/migrations/20260825020000_company_merge_modes.sql -- the behaviour is
// implemented there, this is only how it is described and chosen.

export const companyMergeModes = ["enrich", "overwrite", "skip"] as const;

export type CompanyMergeMode = (typeof companyMergeModes)[number];

export const defaultCompanyMergeMode: CompanyMergeMode = "enrich";

export const companyMergeModeLabels: Record<CompanyMergeMode, { label: string; description: string }> = {
  enrich: {
    label: "Fill in what's missing",
    description: "Keep every value already stored and only fill the blanks. Nothing you have collected is ever overwritten.",
  },
  overwrite: {
    label: "Let this file win",
    description: "Replace stored values wherever this file supplies one. Fields this file does not have are left alone, so a narrow CSV cannot blank out data you already have.",
  },
  skip: {
    label: "Skip matches entirely",
    description: "Leave matched companies completely untouched and import only companies that are new.",
  },
};

// The same three modes answer the same question for a person already in the
// People database, so the values, the type and the normalizer below are shared
// rather than duplicated - only the wording differs, because what a match
// means differs. Implemented in 20260922060000.
export const prospectMergeModeLabels: Record<CompanyMergeMode, { label: string; description: string }> = {
  enrich: {
    label: "Fill in what's missing",
    description: "Keep every value already stored and only fill the blanks. A job title you have corrected by hand is not replaced by this file's.",
  },
  overwrite: {
    label: "Let this file win",
    description: "Replace stored values wherever this file supplies one - the way to refresh job titles and seniority. Fields this file leaves blank are left alone, so a narrow CSV cannot blank out data you already have.",
  },
  skip: {
    label: "Skip matches entirely",
    description: "Leave matched people exactly as they are. They are still added to this list and still counted, only their record is not rewritten.",
  },
};

export function normalizeCompanyMergeMode(value: unknown): CompanyMergeMode | null {
  const candidate = String(value ?? "").trim().toLowerCase();
  return (companyMergeModes as readonly string[]).includes(candidate) ? candidate as CompanyMergeMode : null;
}
