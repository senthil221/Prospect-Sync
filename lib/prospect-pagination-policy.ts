type FilterField = { field: string };

// These filters read public.companies rather than only prospect_index. The
// effective v12 contract gives them a bounded total, and the incomplete-profile
// filter also depends on the company data-version. Cursor v1 intentionally
// stays on the simpler prospect-only response contract, so every one of these
// shapes remains on v13 until a cursor reader reproduces both behaviours.
const companyLookupFields = new Set([
  "__company_industry",
  "__company_keywords",
  "__company_description",
  "__company_technologies",
  "__company_founded_year",
  "__company_total_funding",
  "__incomplete_company_profile",
]);

export function prospectCursorShapeSupported(input: {
  sort: string;
  direction: string;
  companyScoped: boolean;
  filters: FilterField[];
}) {
  return input.sort === "created_at" && input.direction === "desc" && !input.companyScoped
    && !input.filters.some((filter) => filter.field === "__max_people_per_company"
      || companyLookupFields.has(filter.field));
}
