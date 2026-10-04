import type { ProspectFilter } from "./prospect-filters.ts";

export const incompleteCompanyProfileField = "__incomplete_company_profile";
// The client's SEG emails setting (client_settings.seg_emails). The value is
// the client id; the database reads keep/discard when the query runs, so the
// app never needs to know the setting to apply it (20261003100000).
export const clientSegPolicyField = "__client_seg_policy";
// Identifies the client whose Company DB produced a company question. Unlike
// __company_client_ids this is never a user filter: the server removes any
// caller value and binds it to the route's authorized client. The database
// uses it for both membership and client-relative prospect coverage.
export const clientCompanyScopeField = "__client_company_scope";

export function clientSegPolicyFilter(clientId: string): ProspectFilter & { id: string } {
  return { id: "client-seg:policy", field: clientSegPolicyField, operator: "equals", values: [clientId] };
}

// Server-owned filters a client workspace adds; never shown as chips.
export const internalClientFilterFields: ReadonlySet<string> = new Set([
  incompleteCompanyProfileField,
  clientSegPolicyField,
  clientCompanyScopeField,
]);

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
  const existingSeg = filters.filter((filter) => filter.field === clientSegPolicyField);
  const profilePresent = filters.some((filter) => filter.field === incompleteCompanyProfileField);
  if (profilePresent && existingSeg.length === 1 && existingSeg[0].operator === "equals"
    && existingSeg[0].values.length === 1 && existingSeg[0].values[0] === clientId) return filters;
  // The SEG predicate is server-owned. A caller may omit it, duplicate it, or
  // submit another client's id; none of those inputs may influence the scope.
  const withoutCallerSeg = filters.filter((filter) => filter.field !== clientSegPolicyField);
  const additions: ProspectFilter[] = [];
  if (!profilePresent) additions.push(completeClientCompanyProfileFilter);
  return [...withoutCallerSeg, ...additions, clientSegPolicyFilter(clientId)];
}

export function clientCompanyScopeFilter(clientId: string): ProspectFilter & { id: string } {
  return {
    id: "client-company:scope",
    field: clientCompanyScopeField,
    operator: "equals",
    values: [clientId],
  };
}

export function rejectClientCompanyScope(filters: ProspectFilter[]) {
  if (filters.some((filter) => filter.field === clientCompanyScopeField)) {
    throw new Error("Client company scope is only valid for company filters.");
  }
}

export function filtersHaveCallerIntent(filters: ProspectFilter[]) {
  return filters.some((filter) => filter.field !== clientCompanyScopeField && filter.field !== clientSegPolicyField);
}

export function validateClientCompanyScopeFilters(filters: ProspectFilter[]) {
  const internal = filters.filter((filter) => filter.field === clientCompanyScopeField);
  if (!internal.length) return;
  if (internal.length !== 1
    || internal[0].operator !== "equals"
    || internal[0].values.length !== 1
    || !internal[0].values[0]?.trim()) {
    throw new Error("Invalid server-owned client company scope.");
  }
}

// Canonical company questions carry their client origin as a server-owned
// predicate. It is added after parsing and before authorization, preparation,
// hashing or persistence, so every execution path sees the same scope.
//
// A caller can still add an ordinary __company_client_ids predicate. It is a
// real product filter and intersects with this origin (for example, companies
// shared by clients A and B). Only the internal origin is rebound.
export function withClientCompanyScope(
  filters: ProspectFilter[],
  clientId: string | null | undefined,
): ProspectFilter[] {
  const internal = filters.filter((filter) => filter.field === clientCompanyScopeField);
  validateClientCompanyScopeFilters(filters);
  if (!clientId) {
    if (internal.length) {
      throw new Error("Client company scope is server-managed.");
    }
    // __client_seg_policy predates the origin predicate and is present in
    // requests from tabs opened before this release. Preserve that established
    // Master/filter behavior; it does not establish company membership.
    return filters;
  }

  const complete = withClientWorkspaceCompleteness(filters, clientId);
  if (internal.length === 1
    && internal[0].operator === "equals"
    && internal[0].values.length === 1
    && internal[0].values[0] === clientId
    && complete === filters) return filters;

  return [
    ...complete.filter((filter) => filter.field !== clientCompanyScopeField),
    clientCompanyScopeFilter(clientId),
  ];
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
