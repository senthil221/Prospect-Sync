import type { ProspectFilter } from "./prospect-filters.ts";

export const incompleteCompanyProfileField = "__incomplete_company_profile";
// The client's SEG emails setting (client_settings.seg_emails). The value is
// the client id; the database reads keep/discard when the query runs, so the
// app never needs to know the setting to apply it (20261003100000).
export const clientSegPolicyField = "__client_seg_policy";

export function clientSegPolicyFilter(clientId: string): ProspectFilter & { id: string } {
  return { id: "client-seg:policy", field: clientSegPolicyField, operator: "equals", values: [clientId] };
}

// Server-owned filters a client workspace adds; never shown as chips.
export const internalClientFilterFields: ReadonlySet<string> = new Set([incompleteCompanyProfileField, clientSegPolicyField]);

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
//
// Every client-scoped call, Incomplete Info included, also carries the SEG
// policy: a client that discards SEG emails does not see people or companies
// behind a secure email gateway anywhere in its workspace.
export function withClientWorkspaceCompleteness(
  filters: ProspectFilter[],
  clientId: string | null | undefined,
): ProspectFilter[] {
  if (!clientId) return filters;
  const additions: ProspectFilter[] = [];
  if (!filters.some((filter) => filter.field === incompleteCompanyProfileField)) additions.push(completeClientCompanyProfileFilter);
  if (!filters.some((filter) => filter.field === clientSegPolicyField)) additions.push(clientSegPolicyFilter(clientId));
  return additions.length ? [...filters, ...additions] : filters;
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
