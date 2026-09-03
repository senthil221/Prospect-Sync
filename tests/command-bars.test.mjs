import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// COMMANDS-01, and its acceptance criteria PEOPLE-01 and COMP-01: one primary
// action per screen, related utilities grouped, destructive actions separated.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const codeOnly = (source) => source.split("\n").filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("*") && !line.trimStart().startsWith("/*")).join("\n");

test("the command menu is a disclosure, and returns focus like one", async () => {
  const menu = await read("../app/components/MenuButton.tsx");

  // Deliberately not role="menu": half the contents are checkboxes, selects and
  // a cycling control, and a menu whose children are form controls tells a
  // screen reader something false about how to operate it.
  assert.doesNotMatch(codeOnly(menu), /role="menu"|role="menuitem"/);
  assert.match(menu, /aria-haspopup="true"/);
  assert.match(menu, /aria-expanded=\{open\}/);
  assert.match(menu, /aria-controls=\{open \? panelId : undefined\}/);

  // useDismiss handles Escape and outside clicks but leaves focus on <body>
  // when the panel it was inside disappears. This is the missing half.
  assert.match(menu, /trigger\.current\?\.focus\(\)/);
  assert.match(menu, /panel\.current\?\.contains\(document\.activeElement\)/);

  // Keyboard: open onto the first control, then move between them.
  assert.match(menu, /event\.key !== "ArrowDown" && event\.key !== "ArrowUp"/);
  // A select owns Up/Down for changing its value, so the roving keys must not
  // take them.
  assert.match(menu, /if \(active instanceof HTMLSelectElement\) return;/);
});

test("People has one primary action and the rest are grouped", async () => {
  const table = await read("../app/components/ProspectTable.tsx");
  const bar = table.slice(table.indexOf('<div className="workspace-actions">'), table.indexOf('{notice ?'));

  // PEOPLE-01: Saved views, Save view, Density and Columns under View; Detect
  // ESPs under Actions; Export keeps its own weight; Sort and Filters stay out.
  assert.match(bar, /<MenuButton label="View"/);
  assert.match(bar, /<MenuButton label="Actions"/);
  assert.match(bar, /Save this view/);
  assert.match(bar, /Detect ESPs/);
  assert.match(bar, /Export CSV/);
  assert.match(bar, /Sort prospects/);
  assert.match(bar, /Filters /);

  // Eight equal-weight controls became four. The count is the acceptance
  // criterion behind "no command overflow at 1024px".
  const topLevel = (bar.match(/className="outline-button/g) ?? []).length;
  assert.ok(topLevel <= 2, `the People bar should expose at most two plain buttons beside its menus, found ${topLevel}`);

  // The hand-rolled column popover it replaces must be gone, not merely unused.
  assert.doesNotMatch(table, /columnMenu|column-control/);
});

test("Companies keeps Add from CSV primary and groups the rest", async () => {
  const workspace = await read("../app/components/CompaniesWorkspace.tsx");
  const bar = workspace.slice(workspace.indexOf('<div className="company-intro-actions">'), workspace.indexOf('{peopleScope ?'));

  // COMP-01: Add from CSV stays primary, Bulk domains and Export move under
  // Actions, See People becomes contextual navigation rather than a peer.
  assert.equal((bar.match(/className="primary"/g) ?? []).length, 1, "exactly one dominant action");
  assert.match(bar, /Add from CSV/);
  assert.match(bar, /<MenuButton label="Actions"/);
  assert.match(bar, /Bulk domains/);
  assert.match(bar, /See these people/);

  // It used to carry five `secondary` buttons competing with the primary.
  assert.doesNotMatch(bar, /className="secondary/);

  // The menu opens inward at the end of a bar rather than off the viewport.
  assert.match(bar, /align="end"/);
});

test("the popover CSS that lost its component was removed, not left behind", async () => {
  const workspace = await read("../app/workspace.css");
  for (const dead of [".column-control", ".column-menu", ".company-export-control", ".company-export-button"]) {
    assert.ok(!workspace.split("\n").some((line) => line.startsWith(`${dead} `) || line.startsWith(`${dead}{`)),
      `${dead} has no component left and should not still be styled`);
  }
  // And the replacement is on the shared elevation and control tokens.
  const components = await read("../app/components.css");
  assert.match(components, /\.ds-menu-panel \{[\s\S]*box-shadow: var\(--elevation-3\)/);
  assert.match(components, /\.ds-menu-item \{[\s\S]*min-height: var\(--control-dense\)/);
});
