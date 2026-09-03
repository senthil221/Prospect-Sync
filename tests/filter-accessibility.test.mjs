import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// FILTERS-01, covering PEOPLE-03 (the token picker becomes a real combobox) and
// COMP-04 (the accordion controls something).

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("the value picker is a combobox, not a list nobody can reach", async () => {
  const panel = await read("../app/ApolloFilterPanel.tsx");

  // It already had role="listbox" - a list is what it looked like - with no way
  // to reach it: no arrows, no Enter to take a suggestion, no Escape, and
  // nothing telling assistive technology which option was current. A sighted
  // mouse user could pick a value; nobody else could.
  assert.match(panel, /role="combobox"/);
  assert.match(panel, /aria-expanded=\{open\}/);
  assert.match(panel, /aria-controls=\{listId\}/);
  assert.match(panel, /aria-autocomplete="list"/);
  assert.match(panel, /aria-activedescendant=\{activeIndex >= 0 \? `\$\{listId\}-option-\$\{activeIndex\}` : undefined\}/);
  assert.match(panel, /aria-label=\{placeholder\}/);

  // Arrow keys move the active option; past either end it returns to "none" so
  // the typed text is reachable again instead of trapping the caret in the list.
  assert.match(panel, /if \(event\.key === "ArrowDown" \|\| event\.key === "ArrowUp"\)/);
  assert.match(panel, /if \(next < 0 \|\| next >= visibleOptions\.length\) return -1;/);
  // Enter takes the active option, or adds what was typed when there is none.
  assert.match(panel, /const chosen = activeIndex >= 0 \? visibleOptions\[activeIndex\] : null;/);
  assert.match(panel, /if \(event\.key === "Escape" && open\)/);

  // Options are options, not buttons. A button inside a listbox is its own tab
  // stop and fights the combobox for focus.
  assert.match(panel, /id=\{`\$\{listId\}-option-\$\{index\}`\}/);
  assert.match(panel, /aria-selected=\{index === activeIndex\}/);
  assert.doesNotMatch(panel, /<button type="button" role="option"/);

  // Loading and no-options both announce rather than appearing silently.
  assert.match(panel, /aria-busy=\{loading\}/);
  assert.match(panel, /<p role="status">Searching all prospects…<\/p>/);
  assert.match(panel, /<p role="status">\{query\.trim\(\)/);
});

test("the active option is visible, since focus never moves to it", async () => {
  // aria-activedescendant keeps focus on the input, so the option gets no focus
  // ring from the browser. Without a style the arrow keys move something
  // invisible.
  const styles = await read("../app/components.css");
  assert.match(styles, /\.token-options \[role="option"\]\.active/);
  assert.match(styles, /\[role="option"\]\[aria-selected="true"\]/);
});

test("both filter accordions control something", async () => {
  for (const [path, prefix] of [
    ["../app/ApolloFilterPanel.tsx", "filter"],
    ["../app/CompanyFilterPanel.tsx", "company-filter"],
  ]) {
    const source = await read(path);
    // aria-expanded announced a state while naming nothing, so a screen reader
    // could not tell what had expanded or navigate to it.
    assert.match(source, new RegExp(`aria-controls=\\{\`${prefix}-panel-`), `${path} trigger must name its panel`);
    assert.match(source, new RegExp(`id=\\{\`${prefix}-panel-`), `${path} panel must have the id its trigger names`);
    assert.match(source, new RegExp(`aria-labelledby=\\{\`${prefix}-trigger-`), `${path} panel must point back at its trigger`);
    assert.match(source, /role="region"/, `${path} panel must be a region`);
  }
});
