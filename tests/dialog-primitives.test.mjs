import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// FOUNDATION-01: the shared dialog/drawer focus lifecycle, real tabpanels, and
// announced status and progress.
//
// These are source assertions. The behavioural half - Tab actually wrapping,
// Escape actually closing, focus actually returning - belongs in the
// dialog-focus Playwright spec the plan asks for, which needs an authenticated
// session. What is asserted here is that every dialog is wired to the one
// lifecycle rather than hand-rolling a third of it, which is the condition that
// kept regressing.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("the dialog lifecycle implements all four parts of the contract", async () => {
  const hook = await read("../app/components/use-dialog.ts");

  // 1. store the launcher, focus the safest control
  assert.match(hook, /launcher\.current = document\.activeElement/);
  assert.match(hook, /querySelector<HTMLElement>\("\[data-autofocus\]"\)/);
  // 2. Tab containment, and an inert background
  assert.match(hook, /event\.key !== "Tab"/);
  assert.match(hook, /sibling\.inert = true/);
  assert.match(hook, /for \(const sibling of inerted\) sibling\.inert = false/);
  // 3. Escape, unless something committed is running
  assert.match(hook, /if \(event\.key === "Escape"\)/);
  assert.match(hook, /if \(busyRef\.current\) return;/);
  // 4. focus returns to the launcher
  assert.match(hook, /if \(target\?\.isConnected\) target\.focus\(\)/);

  // The listener is capturing, so a dialog's Escape is handled before any
  // background handler can also act on it.
  assert.match(hook, /addEventListener\("keydown", onKeyDown, true\)/);
  assert.match(hook, /removeEventListener\("keydown", onKeyDown, true\)/);
});

test("every dialog and drawer uses the shared lifecycle, not its own", async () => {
  const ui = await read("../app/components/DashboardUi.tsx");

  // Every surface that claims aria-modal must implement it. Asserted as a
  // relationship rather than a count, so adding a dialog cannot quietly add one
  // that only claims the contract - which is the exact bug this test exists for.
  const modals = ui.match(/aria-modal="true"/g)?.length ?? 0;
  const lifecycles = ui.match(/useDialogFocus\(panel/g)?.length ?? 0;
  assert.ok(modals >= 2, "the drawer and the delete confirmation are both dialogs");
  assert.equal(lifecycles, modals,
    `${modals} surfaces claim aria-modal but only ${lifecycles} implement the focus lifecycle`);

  // The old private Escape handler must not come back alongside the shared one.
  assert.doesNotMatch(ui, /closeOnEscape/);

  // Initial focus goes to the safe control. A delete dialog opening with Delete
  // focused turns the Enter that opened it into a confirmed deletion.
  assert.match(ui, /className="secondary" data-autofocus disabled=\{busy\}/);
  assert.match(ui, /className="drawer-close" data-autofocus/);

  // A committed delete is not interruptible by Escape.
  assert.match(ui, /useDialogFocus\(panel, \{ onClose: onCancel, busy \}\)/);

  // The confirmation's explanation is the dialog's description, not loose text.
  assert.match(ui, /aria-describedby="delete-explanation"/);
  assert.match(ui, /id="delete-explanation"/);
});

test("tabs point at panels that exist", async () => {
  const tabs = await read("../app/components/Tabs.tsx");
  const ui = await read("../app/components/DashboardUi.tsx");

  // Tabs has always emitted this reference; nothing in the product answered it,
  // so every tab announced a relationship to an element that did not exist.
  assert.match(tabs, /aria-controls=\{`tabpanel-\$\{item\.id\}`\}/);
  assert.match(tabs, /id=\{`tab-\$\{item\.id\}`\}/);
  assert.match(ui, /id=\{`tabpanel-\$\{id\}`\}/);
  assert.match(ui, /role="tabpanel"/);
  assert.match(ui, /aria-labelledby=\{`tab-\$\{id\}`\}/);

  // The drawer's hand-rolled strip - two buttons with role="tab", no arrow
  // keys, no roving tabindex, no panels - is replaced by the real control.
  assert.match(ui, /<Tabs label="Prospect details"/);
  assert.doesNotMatch(ui, /className="drawer-tabs" role="tablist"/);
  assert.equal(ui.match(/<TabPanel id="/g)?.length, 2);
});

test("asynchronous change is announced, and progress carries its numbers", async () => {
  const ui = await read("../app/components/DashboardUi.tsx");

  // A skeleton with no accessible name is a surface that has silently stopped
  // responding.
  assert.match(ui, /className="loading-state" role="status" aria-live="polite" aria-busy="true"/);
  assert.match(ui, /<span className="sr-only">\{label\}<\/span>/);

  // Polite by default, assertive only for a blocking failure.
  assert.match(ui, /role=\{tone === "alert" \? "alert" : "status"\}/);
  assert.match(ui, /aria-live=\{tone === "alert" \? "assertive" : "polite"\}/);

  // A known total reports valuenow; an unknown one omits it, which is what
  // marks the bar indeterminate rather than stuck at zero.
  assert.match(ui, /role="progressbar"/);
  assert.match(ui, /aria-valuenow=\{known \? value : undefined\}/);
  assert.match(ui, /aria-valuemax=\{known \? total : undefined\}/);
  assert.match(ui, /aria-valuetext=/);

  const styles = await read("../app/components.css");
  assert.match(styles, /\.sr-only \{/);
  assert.match(styles, /\[role="tabpanel"\]:focus-visible/);
});

test("row identity is a control, not a click handler on a table row", async () => {
  // A11Y-02. All three tables carried onClick on a bare <tr>: not a tab stop,
  // no response to Enter, no focus ring. The entire grid was pointer-only.
  for (const path of ["../app/components/ProspectTableRow.tsx", "../app/components/ListsPanel.tsx"]) {
    const source = await read(path);
    assert.match(source, /<button type="button" className="row-open"/, `${path} must open its row from a real control`);
    // Opening must not also toggle the row's own click handler.
    assert.match(source, /className="row-open" onClick=\{\(event\) => \{ event\.stopPropagation\(\);/, `${path} must not double-fire the row click`);
  }
  // Companies already had this shape; it is the pattern the other two now follow.
  const company = await read("../app/components/CompanyTableRow.tsx");
  assert.match(company, /className="company-open" aria-label=/);

  // Selection must never navigate - the checkbox cell stops the row click.
  const prospectRow = await read("../app/components/ProspectTableRow.tsx");
  assert.match(prospectRow, /className="select-column" onClick=\{\(event\) => event\.stopPropagation\(\)\}/);

  const styles = await read("../app/components.css");
  assert.match(styles, /\.compact-person \.row-open \{/);
});
