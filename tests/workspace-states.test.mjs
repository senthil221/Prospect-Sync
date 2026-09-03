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
  assert.equal(panel.match(/<TabPanel id="/g)?.length, 4);
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
