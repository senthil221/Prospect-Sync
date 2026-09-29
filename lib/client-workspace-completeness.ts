import type { ProspectFilter } from "./prospect-filters.ts";

export const incompleteCompanyProfileField = "__incomplete_company_profile";

export const completeClientCompanyProfileFilter: ProspectFilter & { id: string } = {
  id: "client-profile:complete",
  field: incompleteCompanyProfileField,
  operator: "equals",
  values: ["false"],
};

export const incompleteClientCompanyProfileFilter: ProspectFilter & { id: string } = {
  id: "client-profile:incomplete",
  field: incompleteCompanyProfileField,
  operator: "equals",
  values: ["true"],
};

// Client workspaces are a partition: the ordinary People/Company databases
// show complete company profiles, while Incomplete Info explicitly asks for
// the other half. Master workspaces have no client scope and remain unchanged.
//
// Keep an explicit profile predicate intact. That is how the locked Incomplete
// Info tab requests its half of the partition. Every other client-scoped call
// receives the complete-profile predicate, including exports and bulk actions.
export function withClientWorkspaceCompleteness(
  filters: ProspectFilter[],
  clientId: string | null | undefined,
): ProspectFilter[] {
  if (!clientId || filters.some((filter) => filter.field === incompleteCompanyProfileField)) return filters;
  return [...filters, completeClientCompanyProfileFilter];
}

export function forceClientWorkspaceCompleteness<T extends ProspectFilter>(
  filters: T[],
  profileFilter: T,
): T[] {
  return [
    ...filters.filter((filter) => filter.field !== incompleteCompanyProfileField),
    profileFilter,
  ];
}
