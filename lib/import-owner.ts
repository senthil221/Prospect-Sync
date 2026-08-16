// Lists always retain a database owner so memberships, filters, and deletion
// semantics stay intact even when the user imports without choosing a client.
export const unassignedClientId = "prospect-sync-no-client";
export const unassignedClientName = "No client";
export const unassignedClientNormalizedName = "__prospect_sync_no_client__";
