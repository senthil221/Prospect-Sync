import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { isEmptySelection, parseBulkSelection, selectionArgs } from "../lib/client-operations.ts";

test("a bulk selection accepts explicit ids or the live filter payload", () => {
  const byIds = parseBulkSelection({ prospectIds: ["a", "b", "a", " ", "c"] });
  assert.deepEqual(byIds.prospectIds, ["a", "b", "c"], "ids are de-duplicated and blanks dropped");
  assert.equal(byIds.search, "");

  const byFilter = parseBulkSelection({
    search: "  director  ",
    filters: [{ field: "__title", operator: "contains", values: ["vp"] }],
    excludedIds: ["skip-me"],
  });
  assert.equal(byFilter.search, "director");
  assert.equal(byFilter.filters.length, 1);
  assert.deepEqual(byFilter.excludedIds, ["skip-me"]);
  assert.equal(byFilter.prospectIds, null);
});

// Without this guard a request carrying neither ids nor filters would mean
// "every prospect in the database" - which for push or ICP marking is a
// catastrophe rather than a no-op.
test("a selection with neither ids nor filters is rejected, not treated as everything", () => {
  assert.equal(isEmptySelection(parseBulkSelection({})), true);
  assert.equal(isEmptySelection(parseBulkSelection({ prospectIds: [] })), true);
  assert.equal(isEmptySelection(parseBulkSelection({ excludedIds: ["x"] })), true, "exclusions alone are not a selection");
  assert.equal(isEmptySelection(parseBulkSelection({ prospectIds: ["a"] })), false);
  assert.equal(isEmptySelection(parseBulkSelection({ search: "acme" })), false);
  assert.equal(isEmptySelection(parseBulkSelection({ filters: [{ field: "__title", operator: "contains", values: ["vp"] }] })), false);
});

test("selection arguments map onto the RPC parameter names", () => {
  const args = selectionArgs(parseBulkSelection({ search: "acme", prospectIds: ["a"] }));
  assert.deepEqual(Object.keys(args).sort(), ["p_excluded_ids", "p_filters", "p_prospect_ids", "p_search"]);
  assert.deepEqual(args.p_prospect_ids, ["a"]);
  assert.equal(args.p_search, "acme");
});

test("a malformed Boolean filter is rejected rather than silently dropped", () => {
  assert.throws(() => parseBulkSelection({
    filters: [{ field: "__title", operator: "boolean", values: ["AND OR ((("] }],
  }));
});

test("client isolation is enforced in SQL, not only in the UI", async () => {
  const [membership, operations] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260825040000_client_prospects.sql", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260825050000_client_operations.sql", import.meta.url), "utf8"),
  ]);

  // Per-client state has a home, and it is keyed by client.
  assert.match(membership, /create table if not exists public\.client_prospects/);
  assert.match(membership, /primary key \(client_id, prospect_id\)/);
  assert.match(membership, /icp_verified boolean not null default false/);
  assert.match(membership, /status text not null default 'active' check \(status in \('active', 'blocked'\)\)/);

  // Tags are no longer globally unique by name.
  assert.match(membership, /alter table public\.prospect_tags add column if not exists client_id/);
  assert.match(membership, /idx_prospect_tags_client_name/);

  // Blocklisting suppresses; nothing in the blocklist path deletes a prospect.
  const blocklistSection = operations.slice(
    operations.indexOf("add_client_blocklist_v1"),
    operations.indexOf("remove_prospects_from_client_v2"),
  );
  assert.doesNotMatch(blocklistSection, /delete from public\.prospects/);

  // Removing from a client must never reach the master record either.
  const removalSection = operations.slice(operations.indexOf("remove_prospects_from_client_v2"));
  assert.doesNotMatch(removalSection.slice(0, removalSection.indexOf("$$;")), /delete from public\.prospects\b/);
  assert.match(operations, /masterProspectPreserved/);

  // A blocked record must not be re-added by a later push.
  assert.match(operations, /not exists \(\s*select 1 from public\.client_blocklist b/);
});

test("client blocklists remove current matches and guard future imports without deleting master data", async () => {
  const migration = await readFile(new URL("../supabase/migrations/20260829090337_enforce_client_blocklist_exclusion.sql", import.meta.url), "utf8");

  assert.match(migration, /client_block_reason_v1/);
  assert.match(migration, /sync_client_prospects_from_lists/);
  assert.match(migration, /case when block\.reason is null then 'active' else 'blocked' end/);
  assert.match(migration, /cp\.status = 'active'/);
  assert.match(migration, /pi\.client_ids @> array\[p_client_id\]/);
  assert.match(migration, /client_company_prospects/);
  assert.match(migration, /membership\.added_by not in \('membership-backfill', 'prospect-membership', 'prospect-company-change'\)/);
  assert.doesNotMatch(migration, /delete from public\.prospects\b/);
  assert.doesNotMatch(migration, /delete from public\.companies\b/);
});

test("large client blocklists are bounded, resumable, and paginated without truncation", async () => {
  const [migration, route, panel] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260829124348_batch_client_blocklist_safely.sql", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/blocklist/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/components/BlocklistPanel.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(migration, /add_client_blocklist_batch_v2/);
  assert.match(migration, /create table if not exists public\.client_blocklist_batch_results/);
  assert.match(migration, /request_id text primary key/);
  assert.match(migration, /if found then[\s\S]*return v_result/);
  assert.match(migration, /limit v_limit/);
  assert.match(migration, /'remaining', v_remaining/);
  assert.match(migration, /p_batch => 1000/);
  assert.match(migration, /queued safely|v_queued/);
  assert.match(migration, /revoke execute on function public\.add_client_blocklist_batch_v2/);
  assert.match(migration, /grant execute on function public\.add_client_blocklist_batch_v2[\s\S]*to service_role/);
  assert.doesNotMatch(migration, /delete from public\.(prospects|companies)\b/);

  assert.match(route, /partitionBlocklistValues/);
  assert.match(route, /BLOCKLIST_REQUEST_VALUES/);
  assert.match(route, /add_client_blocklist_batch_v2/);
  assert.match(route, /p_request_id: requestId/);
  assert.match(route, /\.range\(offset, offset \+ pageSize - 1\)/);
  assert.doesNotMatch(route, /domainSource = emails\.invalid/);

  assert.match(panel, /MAX_BLOCKLIST_PASTE_VALUES/);
  assert.match(panel, /offset \+= BLOCKLIST_REQUEST_VALUES/);
  assert.match(panel, /while \(remaining\)/);
  assert.match(panel, /attempt <= 3/);
  assert.match(panel, /crypto\.randomUUID\(\)/);
  assert.match(panel, /Progress was saved/);
});

test("clients can be created before any list is imported", async () => {
  const [panel, route] = await Promise.all([
    readFile(new URL("../app/components/ClientsPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(panel, /> New client</);
  assert.match(panel, /\/api\/clients/);
  assert.match(panel, /add the blocklist before importing any prospects/i);
  assert.match(route, /export async function POST/);
  assert.match(route, /from\("clients"\)\.insert\(client\)/);
});

test("bulk actions are grouped into consistent toolbars", async () => {
  const [people, companies, css] = await Promise.all([
    readFile(new URL("../app/components/ProspectTable.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/components/CompaniesWorkspace.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/workspace.css", import.meta.url), "utf8"),
  ]);

  assert.match(people, /bulk-selection-summary/);
  assert.match(people, /bulk-action-group-primary/);
  assert.match(companies, /bulk-selection-summary/);
  assert.match(companies, /bulk-action-group-danger/);
  assert.match(css, /\.bulk-action-group \{/);
  assert.match(css, /\.bulk-bar \.bulk-clear/);
});

test("bulk client operations resolve their own ids server-side", async () => {
  const operations = await readFile(new URL("../supabase/migrations/20260825050000_client_operations.sql", import.meta.url), "utf8");
  // Each one accepts a filter payload so a whole segment is one request rather
  // than tens of thousands of ids crossing the wire.
  for (const fn of ["push_prospects_to_client_v1", "set_icp_verified_v1", "remove_prospects_from_client_v2"]) {
    const body = operations.slice(operations.indexOf(`function public.${fn}`));
    assert.match(body.slice(0, body.indexOf("$$;")), /prospect_ids_matching_v1/, `${fn} must resolve filters server-side`);
  }
  // Every one of them is recorded, because each can change tens of thousands of
  // rows from a single click.
  assert.match(operations, /create table if not exists public\.operation_log/);
  for (const action of ["push_to_client", "icp_verify", "blocklist_add", "remove_from_client"]) {
    assert.match(operations, new RegExp(`'${action}'`), `${action} must be recorded in the operation log`);
  }
});

test("enrichment fills blanks only, and never copies person-level fields", async () => {
  const enrichment = await readFile(new URL("../supabase/migrations/20260825060000_company_enrichment.sql", import.meta.url), "utf8");
  const apply = enrichment.slice(enrichment.indexOf("function public.enrich_from_company_v1"));
  const body = apply.slice(0, apply.indexOf("$$;"));

  // Blanks only: every assignment is guarded on the current value being empty.
  for (const column of ["city", "state", "country", "location"]) {
    assert.match(body, new RegExp(`${column} = case when c\\.${column} = '' then`), `${column} must only be filled when empty`);
  }
  // Two people at one company legitimately differ; copying these would corrupt
  // the database rather than enrich it.
  for (const personField of ["title", "seniority", "work_email", "linkedin_url"]) {
    assert.doesNotMatch(body, new RegExp(`\\b${personField}\\s*=`), `${personField} is person-level and must never propagate`);
  }
  // The website is the anchor, as asked.
  assert.match(body, /normalized_domain <> ''/);
  // Filled values stay distinguishable from uploaded ones.
  assert.match(body, /_enriched_from/);
});

test("the re-index backlog makes a failed index update recoverable", async () => {
  const [migration, reindex] = await Promise.all([
    readFile(new URL("../supabase/migrations/20260825020000_reindex_reliability.sql", import.meta.url), "utf8"),
    readFile(new URL("../lib/reindex.ts", import.meta.url), "utf8"),
  ]);
  assert.match(migration, /create table if not exists public\.reindex_backlog/);
  assert.match(migration, /function public\.drain_reindex_backlog/);
  assert.match(migration, /function public\.prospect_index_drift/);
  // The bug this fixes: the outcome used to be discarded at every call site.
  assert.match(reindex, /ReindexOutcome/);
  assert.match(reindex, /enqueue\(supabase, batch, error\.message\)/);
  // And the timeout that made failure likely is avoided by batching.
  assert.match(reindex, /const batchSize = \d+/);
});
