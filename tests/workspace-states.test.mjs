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
  assert.match(panel, /disabled=\{!dirty \|\| over \|\| busyId === profile\.id\}/);
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
  assert.match(companyRoute, /set_client_company_tag_v1/);
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

  // Apply/remove on both entities. The two halves differ on "all matching", and
  // the difference is real rather than an oversight: 20260916120000 taught
  // prospect_operations.apply_batch_v1 the add_tag/remove_tag verbs, so People
  // tagging freezes a result set and runs in the background - but apply_batch_v1
  // refuses any job whose entity_type is not 'prospect', and there is no company
  // batch applier, so company tagging is still explicit-selection only.
  assert.match(peopleTable, /async function clientTagAction/);
  assert.match(companyTable, /async function companyTagAction/);
  assert.match(peopleTable, /runAllMatching\(action, clientId, requestId, null, bulkTagId\)/);
  assert.doesNotMatch(peopleTable, /Tagging needs an explicit selection/);
  assert.match(companyTable, /Tagging needs an explicit selection/);

  // And the ICP panel says the two are one thing, which is the only place that
  // relationship is visible.
  assert.match(icpPanel, /Taggable as/);
});
