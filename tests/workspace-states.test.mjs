import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { emptyWorkspaceState } from "../lib/workspace-states.ts";

// STATE-01 and PEOPLE-05: an empty table has six causes and the product named
// one of them.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const people = (over) => emptyWorkspaceState({ entity: "people", search: "", filterCount: 0, ...over });
const companies = (over) => emptyWorkspaceState({ entity: "companies", search: "", filterCount: 0, ...over });

test("a search that matches nothing offers to clear the search, never to import", () => {
  // PEOPLE-AC-02, and the sharpest version of this bug: People checked whether
  // filters were applied and nothing else, so a mistyped name answered "Import
  // a CSV and your unique prospects will appear here" - advice to import the
  // 681,000 rows you already have.
  const state = people({ search: "Ada Lovelace" });
  assert.equal(state.intent, "clear-search");
  assert.match(state.title, /Ada Lovelace/, "the empty state names the term that hid the rows");
  assert.doesNotMatch(state.action, /Import/);
});

test("each constraint gets its own message and its own way out", () => {
  assert.equal(people({ filterCount: 3 }).intent, "clear-filters");
  assert.match(people({ filterCount: 3 }).text, /3 filters are applied/);
  // Singular reads as English, not as a template.
  assert.match(people({ filterCount: 1 }).text, /1 filter is applied/);
  assert.equal(people({ filterCount: 1 }).action, "Clear filter");

  // Both narrowings at once says so, rather than blaming one of them.
  const both = people({ search: "acme", filterCount: 2 });
  assert.equal(both.intent, "clear-both");
  assert.match(both.text, /Both a search term and 2 filters/);

  // A pivot is the narrowing people forget, because it was set on another
  // screen - so it wins over search and filters.
  const scoped = people({ search: "acme", filterCount: 2, scoped: true });
  assert.equal(scoped.intent, "clear-scope");
  assert.match(scoped.text, /last Company DB search/);

  // Inside a client workspace, empty means "nothing pushed here yet", which is
  // a different thing from an empty database.
  assert.equal(people({ clientScoped: true }).intent, "import");
  assert.match(people({ clientScoped: true }).title, /client workspace/);
});

test("Companies stops claiming there are no companies", () => {
  // It always said "No known companies yet" - including while looking at a
  // filtered subset of 418,000 known companies.
  assert.match(companies({ search: "hdfc" }).title, /No companies match “hdfc”/);
  assert.equal(companies({ search: "hdfc" }).intent, "clear-search");
  assert.match(companies({ scoped: true }).text, /last People DB search/);
  // Only the genuinely empty case still offers the import.
  assert.equal(companies({}).intent, "import");
  assert.match(companies({}).title, /No companies yet/);
});

test("the button always undoes the constraint the message names", async () => {
  // A button labelled "Clear search" that clears filters instead is worse than
  // no button. The mapping lives in one place so it cannot drift per screen.
  const ui = await read("../app/components/DashboardUi.tsx");
  assert.match(ui, /"clear-search": onClearSearch/);
  assert.match(ui, /"clear-filters": onClearFilters/);
  assert.match(ui, /"clear-both": \(\) => \{ onClearSearch\?\.\(\); onClearFilters\?\.\(\); \}/);
  assert.match(ui, /"clear-scope": onClearScope/);
  // An action with no handler renders no button rather than a dead one.
  assert.match(ui, /\{onAction \? <button className="primary"/);
  // The empty state is announced, since it replaces a table that had rows.
  assert.match(ui, /<div className="empty" role="status">/);

  // Both workspaces ask the resolver rather than deciding for themselves.
  for (const path of ["../app/components/ProspectTable.tsx", "../app/components/CompaniesWorkspace.tsx"]) {
    const source = await read(path);
    assert.match(source, /<WorkspaceEmpty state=\{emptyWorkspaceState\(/, `${path} must use the shared resolver`);
    assert.match(source, /onClearSearch=/, `${path} must be able to clear the search it blames`);
  }
});

test("the client workspace stops using native dialogs and dangling tabs", async () => {
  const panel = await read("../app/components/ClientsPanel.tsx");
  const styles = await read("../app/workspace.css");

  // CLIENT-04: window.confirm freezes the tab, cannot carry the scope sentence
  // that makes this safe to agree to, and has none of the focus contract every
  // other dialog here keeps.
  assert.doesNotMatch(panel.replace(/^\s*\/\/.*$/gm, ""), /window\.confirm/);
  assert.match(panel, /<ConfirmDialog/);
  assert.match(panel, /The People database record is preserved/);

  // CLIENT-03: the tab strip pointed aria-controls at ids that existed nowhere.
  //
  // Asserted as the relationship rather than as a count. A hardcoded number
  // says nothing about whether the ids line up - it fails on any new tab, and
  // it would pass a strip whose four tabs pointed at four unrelated panels,
  // which is the bug this test exists for.
  const tabIds = [...panel.matchAll(/\{ id: "([a-z]+)" as const, label:/g)].map((match) => match[1]);
  const panelIds = [...panel.matchAll(/<TabPanel id="([a-z]+)"/g)].map((match) => match[1]);
  assert.ok(tabIds.length >= 4, `expected the client tab strip to have tabs, found ${tabIds.length}`);
  assert.deepEqual(panelIds.slice().sort(), tabIds.slice().sort(),
    "every client tab must have a panel with the same id, and vice versa");
  // These panels hold live tables with their own search, filters and page, so
  // they stay mounted while hidden rather than being thrown away per switch.
  assert.match(panel, /keepMounted/);

  // Visibility moved from an .active class to the hidden attribute. An author
  // display rule beats the UA stylesheet on [hidden], so this has to be
  // explicit or every panel stays on screen at once.
  assert.match(styles, /\.client-tab-panel \{ display: block; \}/);
  assert.match(styles, /\.client-tab-panel\[hidden\] \{ display: none; \}/);
  assert.doesNotMatch(styles, /\.client-tab-panel\.active/);

  // CLIENT-01: the directory scales past a handful of clients.
  assert.match(panel, /className="client-directory"/);
  assert.doesNotMatch(panel, /className="clients-grid"/);
  for (const dead of [".clients-grid", ".client-card", ".client-stats"]) {
    assert.ok(!styles.split("\n").some((line) => line.startsWith(`${dead} `)), `${dead} has no component left`);
  }
});

// Client ICP profiles: several named briefs per client, not one text column.
test("a client can hold several named ICP briefs", async () => {
  const [migration, route, panel, clients] = await Promise.all([
    read("../supabase/migrations/20260915100000_client_icp_profiles.sql"),
    read("../app/api/clients/[id]/icp/route.ts"),
    read("../app/components/ClientIcpPanel.tsx"),
    read("../app/components/ClientsPanel.tsx"),
  ]);

  // A table, so a second ICP does not need a migration.
  assert.match(migration, /create table if not exists public\.client_icp_profiles/);
  // The tag link is already here and nullable: an ICP is the thing you describe
  // and the thing you label with, so the profile can own its tag later without
  // another migration. Nothing reads it yet.
  assert.match(migration, /tag_id text references public\.prospect_tags\(id\) on delete set null/);
  // Deleting a client removes its briefs; deleting a tag must not.
  assert.match(migration, /confdeltype = 'c'/);
  assert.match(migration, /confdeltype = 'n'/);
  // Same deny-all posture as every other client-scoped table here.
  assert.match(migration, /enable row level security/);
  assert.match(migration, /must not be readable by anon or authenticated/);
  // "position" is a SQL function name and would need quoting everywhere.
  assert.doesNotMatch(migration, /\bposition integer\b/);

  // The length cap lives in the API so going over it is a refusal with a number
  // in it, never a silent truncation of somebody's brief.
  assert.match(route, /const maxDescription = 20_000;/);
  assert.match(route, /status: 413/);
  // Edits and deletes are scoped by client as well as by id, so an ICP id from
  // another client cannot be reached through this client's route.
  assert.match(route, /\.eq\("id", profileId\)\s*\n\s*\.eq\("client_id", id\)/);

  // Saving is explicit: these are long pasted documents, and autosave would be
  // a request per keystroke with no way to abandon an edit.
  assert.match(panel, /Unsaved changes/);
  assert.match(panel, /disabled=\{!dirty \|\| over \|\| busyId === selected\.id\}/);
  // Deleting a brief must not untag anything it was applied to.
  assert.match(panel, /Nothing that has been tagged with it is untagged/);

  // And it is reachable.
  assert.match(clients, /id: "icp" as const, label: "ICPs"/);
  assert.match(clients, /<ClientIcpPanel client=\{client\}\/>/);
});

// Client ICP tags, on prospects and on companies.
test("client ICP tags share one vocabulary and reindex only where they must", async () => {
  const [migration, icpRoute, peopleRoute, companyRoute] = await Promise.all([
    read("../supabase/migrations/20260915150000_client_icp_tags_on_prospects_and_companies.sql"),
    read("../app/api/clients/[id]/icp/route.ts"),
    read("../app/api/clients/[id]/prospects/route.ts"),
    read("../app/api/clients/[id]/companies/route.ts"),
  ]);

  // One tag table, two narrow link tables. A polymorphic link table cannot
  // carry a foreign key to two parents.
  assert.match(migration, /create table if not exists public\.company_tag_links/);
  assert.match(migration, /references public\.prospect_tags\(id\) on delete cascade/);
  assert.match(migration, /idx_company_tag_links_tag/);
  assert.match(migration, /must not be readable by anon or authenticated/);

  // Filters take tag ids, so there is nothing to parse out of a field name and
  // no join - and a renamed tag cannot change what a saved view returns.
  assert.match(migration, /ptl\.tag_id = any \(%L::text\[\]\)/);
  assert.match(migration, /ctl\.tag_id = any \(%L::text\[\]\)/);

  // Prospect tags feed prospect_index.tag_text and therefore search_text;
  // company tags appear nowhere in it. Hence two write functions.
  assert.match(migration, /select \* into v_reindex from public\.reindex_scope_v1\(p_prospect_ids => v_ids\)/);
  assert.match(migration, /Deliberately no re-index: prospect_index carries no company tags/);

  // A workspace must not be able to apply another client's tag by sending its id.
  assert.equal(migration.match(/That tag does not belong to this client/g)?.length, 2);

  // The value picker stops offering one client's tags to another.
  assert.match(migration, /pt\.client_id is null/);
  assert.match(migration, /still lists client tags under __tags/);

  // Every splice raises rather than silently skipping.
  assert.equal(migration.match(/raise exception 'Could not patch/g)?.length, 6);

  // Naming an ICP creates its tag; renaming renames it rather than orphaning
  // it. The lookup is client-qualified, which is the 44af7a1 bug not repeated.
  assert.match(icpRoute, /async function syncProfileTag/);
  assert.match(icpRoute, /\.eq\("client_id", clientId\)\.ilike\("name", name\)/);
  assert.match(icpRoute, /An unnamed ICP gets no tag/);

  // Both write paths are reachable.
  assert.match(peopleRoute, /action === "add_tag" \|\| action === "remove_tag"/);
  assert.match(peopleRoute, /set_client_prospect_tag_v1/);
  // v2 since 20260916170000: same function, given the argument list its sibling
  // company actions already had so it can reach every matching company.
  assert.match(companyRoute, /set_client_company_tag_v2/);
});

// The ICP tag UI: one list, two entities, four surfaces.
test("client ICPs are the tag vocabulary everywhere they are offered", async () => {
  const [hook, peoplePanel, companyPanel, peopleTable, companyTable, icpPanel] = await Promise.all([
    read("../app/components/use-client-icps.ts"),
    read("../app/ApolloFilterPanel.tsx"),
    read("../app/CompanyFilterPanel.tsx"),
    read("../app/components/ProspectTable.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
    read("../app/components/ClientIcpPanel.tsx"),
  ]);

  // "The client's ICP tags" and "the client's ICPs" are the same list, so
  // nothing fetches tags. Unnamed profiles have no tag and are dropped.
  assert.match(hook, /filter\(\(profile\) => profile\.tag_id && profile\.name\.trim\(\)\)/);
  assert.match(hook, /Returns the ids of TAGS, not of profiles/);
  // Clearing in the effect body would be a cascading render.
  assert.match(hook, /return clientId \? icps : \[\]/);

  // Filter sections on both entities, only inside a client workspace.
  assert.match(peoplePanel, /<ClientMembershipFilter field="__client_tags"/);
  assert.match(companyPanel, /<ClientMembershipFilter field="__company_tags"/);
  assert.match(peoplePanel, /clientId && icps\.length/);
  assert.match(companyPanel, /clientId && icps\.length/);

  // Apply/remove on both entities, and both now reach every matching record -
  // by two different mechanisms, because the two entities genuinely differ.
  //
  // People: 20260916120000 taught prospect_operations.apply_batch_v1 the
  // add_tag/remove_tag verbs, so a People tag freezes a result set and the
  // worker applies it in bounded batches.
  //
  // Companies: 20260916170000 gave set_client_company_tag_v2 the argument list
  // its two sibling company actions already had, so it resolves inline through
  // resolve_company_action_selection_v1. That is NOT a shortcut - it is the
  // same call push_companies_to_client_v1 and set_company_icp_verified_v2 make
  // on every all-matching click, under the same ceiling and the same cap. The
  // background route would have needed a company branch in apply_batch_v1, a
  // company result-set builder and a worker that understands both.
  assert.match(peopleTable, /async function clientTagAction/);
  assert.match(companyTable, /async function companyTagAction/);
  assert.match(peopleTable, /runAllMatching\(action, clientId, requestId, null, bulkTagId\)/);
  assert.doesNotMatch(peopleTable, /Tagging needs an explicit selection/);
  assert.doesNotMatch(companyTable, /Tagging needs an explicit selection/);

  // And the ICP panel says the two are one thing, which is the only place that
  // relationship is visible.
  assert.match(icpPanel, /Applied as/);
  assert.match(icpPanel, /Name this ICP to tag prospects and companies with it/);
});

// The ICPs screen is a rail and one editor, and reports what each ICP claimed.
//
// It used to stack every brief as a card with its own 160px textarea and its
// own Save, so a client running five ICPs got a page metres long with no way to
// see the set, and no way to tell a brief in use from one somebody abandoned.
test("the ICPs screen lists the set and says how much each one has claimed", async () => {
  const [panel, route, migration] = await Promise.all([
    readFile(new URL("../app/components/ClientIcpPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/icp/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260916150000_an_icp_reports_how_much_it_has_claimed.sql", import.meta.url), "utf8"),
  ]);

  // One selection, one editor - not a card per brief.
  assert.match(panel, /icp-workbench/);
  assert.match(panel, /icp-rail/);
  assert.match(panel, /const \[selectedId, setSelectedId\]/);
  assert.doesNotMatch(panel, /client-icp-card/);

  // The counts come from one call, not one per profile, and the route tolerates
  // losing them: a screen that will not open because a count was slow is worse
  // than a screen without counts.
  assert.match(route, /client_icp_tag_counts_v1/);
  assert.match(route, /counts\.get\(profile\.tag_id\)\?\.prospects \?\? null/);

  // Null and zero are different answers and the panel keeps them apart.
  assert.match(panel, /prospect_count == null/);

  // An ICP that has never been applied still appears, with 0 - that is the one
  // the screen most needs to show. The tag table drives; the counts hang off it.
  assert.match(migration, /from public\.prospect_tags t/);
  assert.match(migration, /where t\.client_id = p_client_id/);
  // Bounded like every other app-called function.
  assert.match(migration, /set statement_timeout to '8s'/);
});

// Choosing an ICP beside the client tabs filters that client's People DB, and
// "Unassigned" is the complement of every ICP rather than "has no tags at all".
test("the ICP picker seeds the same filters the panel writes", async () => {
  const panel = await readFile(new URL("../app/components/ClientsPanel.tsx", import.meta.url), "utf8");

  // By tag id, never by name: renaming an ICP must not change what a view
  // returns - the bug 20260915130000 fixed for clients.
  assert.match(panel, /field: "__client_tags", operator: "contains", values: \[choice\]/);
  assert.match(panel, /field: "__client_tags", operator: "not_contains", values: icps\.map\(\(icp\) => icp\.id\)/);

  // The same filter ids the Client ICP filter section writes, so what the
  // picker seeds is editable and clearable there rather than being invisible.
  assert.match(panel, /"__client_tags:include"/);
  assert.match(panel, /"__client_tags:exclude"/);

  // With no ICPs defined, Unassigned is everyone - so it seeds nothing rather
  // than an empty filter that would read as "no filter applied".
  assert.match(panel, /icps\.length \? \[\{ id: "__client_tags:exclude"/);

  // A <select> (or anything else) inside role="tablist" is announced as a tab
  // that does nothing, so the picker is a sibling of the tablist: it appears
  // after the Tabs element closes, inside the row that wraps both. ROW-01's
  // sibling problem: a native <select>'s open list is unstyleable browser
  // chrome, so the picker is a button + role="listbox" popup instead.
  assert.match(panel, /client-tab-row/);
  const tabsBlock = panel.slice(panel.indexOf("<Tabs"), panel.indexOf("<IcpPicker"));
  assert.doesNotMatch(tabsBlock, /<select/);
  // The Tabs element self-closes before the picker is reached.
  assert.match(tabsBlock, /\]\}\s*\/>/);
});

// Company ICP tagging reaches every matching company, through the resolver its
// sibling actions already use.
//
// The gate said "Tagging needs an explicit selection", and the stated reason was
// that resolving an all-matching company scope is the expensive half of this
// product. True - and it is the identical call push and ICP verification make on
// every all-matching click, under the same 120s ceiling and 250,000 cap. Tagging
// was simply the one company action that had never been given the arguments.
test("a company ICP tag can be applied to everything matching, not just a page", async () => {
  const [table, route, migration] = await Promise.all([
    readFile(new URL("../app/components/CompaniesWorkspace.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/api/clients/[id]/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../supabase/migrations/20260916170000_an_icp_tag_reaches_every_matching_company.sql", import.meta.url), "utf8"),
  ]);

  // One resolver for both shapes, so explicit ids and a filter cannot drift.
  assert.match(migration, /resolve_company_action_selection_v1\(\s*\n?\s*p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000\)/);
  // The tag is checked against the client BEFORE anything is resolved, so a
  // workspace cannot reach another client's tag by sending its id. Compared
  // inside the function body, with comment lines stripped: the header explains
  // the resolver at length and would otherwise be found first.
  const sql = migration.split(/\r?\n/).filter((line) => !line.trimStart().startsWith("--")).join("\n");
  const fn = sql.slice(sql.indexOf("create or replace function public.set_client_company_tag_v2"), sql.indexOf("revoke execute"));
  assert.ok(fn.indexOf("does not belong to this client") < fn.indexOf("resolve_company_action_selection_v1"),
    "tag ownership must be checked before the selection is resolved");
  // Bounded like every other app-called function, and not reachable from a
  // browser role.
  assert.match(migration, /set statement_timeout to '120s'/);
  assert.match(migration, /revoke execute on function public\.set_client_company_tag_v2[^\n]*from public, anon, authenticated/);
  // v1 survives, so an in-flight request from the outgoing image cannot 404
  // mid blue/green release.
  assert.match(migration, /set_client_company_tag_v1 is gone/);
  // Company tagging must never claim to have queued a re-index: prospect_index
  // carries a prospect's tags, never a company's.
  assert.match(migration, /company tagging must never queue a re-index/);

  // The route carries the selection, and refuses a bare request that would
  // otherwise tag the client's whole company list.
  assert.match(route, /set_client_company_tag_v2/);
  assert.match(route, /if \(!companyIds\.length && !tagAllMatching\)/);
  // A saved filter set is spendable only by its owner, in its own scope - the
  // same check push and ICP verification make.
  assert.match(route, /authorizeFilterSets\(tagSupabase, tagFilters/);
  // An explicit selection must never be widened by a filter left in the payload.
  assert.match(route, /p_filters: tagAllMatching && !companyIds\.length \? tagFilters : \[\]/);

  // And the buttons are no longer gated on selection mode.
  assert.match(table, /Tag every matching company with this ICP/);
  assert.doesNotMatch(table, /disabled=\{updatingIcp \|\| !bulkTagId \|\| selectionMode === "all_matching"\}/);
});
