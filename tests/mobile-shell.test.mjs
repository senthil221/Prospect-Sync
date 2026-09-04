import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Package 13, MOBILE-01..04. These are source assertions: the device gate
// (MOBILE-05 - real 390x844 and 360x800 hardware, rotation, software keyboard)
// needs a browser session this project cannot reach, and is reported UNVERIFIED
// rather than approximated here. What IS checkable without a device is that the
// three structural defects the audit found are actually gone, and cannot come
// back quietly.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

/** The body of the <=760px block, which is where the mobile shell is defined. */
async function mobileBlock() {
  const styles = await read("../app/workspace.css");
  const start = styles.indexOf("@media (max-width: 760px) {");
  assert.notEqual(start, -1, "the mobile breakpoint must exist");
  return styles.slice(start);
}

test("navigation no longer scrolls sideways to hide half of itself", async () => {
  const styles = await read("../app/workspace.css");
  // The defect: seven destinations at a 76px minimum inside a horizontally
  // scrolling strip. 7 x 76 = 532px of navigation in a 390px viewport, so three
  // destinations sat off-screen with nothing to indicate they existed.
  assert.doesNotMatch(styles, /\.sidebar \{ position: fixed;[^}]*overflow-x: auto/);
  const block = await mobileBlock();
  assert.match(block, /\.sidebar \{ display: none; \}/, "the desktop rail is replaced on mobile, not folded up small");

  // Four fixed destinations, laid out in a grid so they cannot overflow.
  assert.match(block, /\.mobile-nav \{[^}]*grid-template-columns: repeat\(4, 1fr\)/);
  assert.doesNotMatch(block.slice(block.indexOf(".mobile-nav {"), block.indexOf(".mobile-nav button")), /overflow-x/);

  const nav = await read("../app/components/MobileNav.tsx");
  assert.match(nav, /const pinned = \["overview", "prospects", "companies"\]/);
  // The fourth slot is More, and it reports itself current when the screen you
  // are on lives inside it - otherwise four of seven screens show no active
  // destination at all.
  assert.match(nav, /aria-current=\{inSheet \? "page" : undefined\}/);
});

test("sign out is reachable from a phone", async () => {
  // The old rule hid .profile outright below 760px. That is the only sign-out
  // in the product, so a phone could sign in and never sign out.
  const styles = await read("../app/workspace.css");
  assert.doesNotMatch(styles, /\.brand, \.workspace, \.profile, \.nav-group-label \{ display: none; \}/);
  const nav = await read("../app/components/MobileNav.tsx");
  assert.match(nav, /href="\/auth\/signout"/);
  assert.match(nav, /<small>Sign out<\/small>/);
  // Theme and account are settings, not destinations, so they live in the sheet.
  assert.match(nav, /<ThemeToggle\/>/);
});

test("search survives on the two screens that exist to search", async () => {
  const block = await mobileBlock();
  assert.doesNotMatch(block, /\.search \{ display: none; \}/);
  // It moves to its own full-width row rather than competing with the title.
  assert.match(block, /\.search \{ order: 3; flex: 1 0 100%/);
});

test("the More sheet is a real dialog", async () => {
  const nav = await read("../app/components/MobileNav.tsx");
  // Same lifecycle as every other dialog: focus trapped, Escape closes, focus
  // returns to the launcher. The mobile gate asks for exactly this.
  assert.match(nav, /useDialogFocus\(sheet, \{ onClose: \(\) => setOpen\(false\) \}\)/);
  assert.match(nav, /role="dialog"/);
  assert.match(nav, /aria-modal="true"/);
  assert.match(nav, /aria-labelledby="mobile-sheet-title"/);
  assert.match(nav, /data-autofocus/);
  assert.match(nav, /aria-haspopup="dialog"/);
  // Choosing a destination closes it - leaving it open would cover the screen
  // the user just asked for. Done on the click, not in an effect watching
  // `section`: that set state during render on every navigation, including the
  // ones that never opened the sheet.
  assert.match(nav, /const go = \(id: string\) => \{ setOpen\(false\); onNavigate\(id\); \}/);
  assert.doesNotMatch(nav, /useEffect/);
  // No dismiss-on-backdrop, matching every other dialog in the product: a
  // non-interactive div with a click handler is unreachable by keyboard, and
  // Escape plus an explicit Close is the contract the others already keep.
  assert.doesNotMatch(nav, /mobile-sheet-backdrop" role="presentation" onClick/);
});

test("selection and identity never scroll out of reach", async () => {
  const block = await mobileBlock();
  // MOBILE-02's gate is that no PRIMARY workflow needs horizontal scrolling.
  // Selecting a row and opening it are primary; reading the ninth column is
  // not. So those two columns are pinned and the rest scroll under them.
  assert.match(block, /\.master-data-table td\.select-column,\s*\n\s*\.master-data-table th:first-child \{ position: sticky; left: 0/);
  assert.match(block, /\.master-data-table td:nth-child\(2\),\s*\n\s*\.master-data-table th:nth-child\(2\) \{ position: sticky; left: 44px/);
  // A sticky cell needs its own background or the rows scroll through it, and
  // a selected row has to keep its selected colour while pinned.
  assert.match(block, /tbody tr\.selected td\.select-column \{ background: var\(--surface-selected\)/);
});

test("fixed and sticky surfaces respect the device's own reserved space", async () => {
  const block = await mobileBlock();
  // A bottom bar drawn under the home indicator is a bar you cannot press.
  const insets = [...block.matchAll(/env\(safe-area-inset-bottom, 0px\)/g)].length;
  assert.ok(insets >= 6, `only ${insets} surfaces account for the safe area`);
  // And the page itself has to clear the bar, or the last row is unreachable.
  assert.match(block, /\.content \{ padding:[^}]*env\(safe-area-inset-bottom/);
});

test("every mobile target reaches 44px", async () => {
  const block = await mobileBlock();
  for (const rule of [".mobile-sheet-close", ".modal-actions button", ".duplicate-actions button", ".import-step-actions button", ".coverage-replace"]) {
    const at = block.indexOf(`${rule} {`);
    assert.notEqual(at, -1, `${rule} needs a mobile size`);
    const body = block.slice(at, block.indexOf("}", at));
    assert.match(body, /(min-height|height): 44px/, `${rule} is below the 44px touch target`);
  }
  // The bar's own buttons carry their padding on top of the target.
  assert.match(block, /\.mobile-nav button \{[\s\S]*?min-height: 52px/);
});

test("long surfaces become sheets rather than floating boxes", async () => {
  const block = await mobileBlock();
  // MOBILE-03. A dialog at 90% of a small screen is a sheet whether or not it
  // calls itself one.
  assert.match(block, /\.modal-backdrop \{ align-items: flex-end/);
  assert.match(block, /\.confirm-modal, \.export-modal \{[\s\S]*?border-radius: var\(--radius-xl\) var\(--radius-xl\) 0 0/);
  // Confirming button under the thumb, cancel above it - reversed from desktop
  // on purpose.
  assert.match(block, /\.modal-actions \{ flex-direction: column-reverse/);
  // Filters get their own scroll so Show results stays reachable with the
  // software keyboard open instead of being pushed off the bottom.
  assert.match(block, /\.apollo-filter-panel, \.company-filter-panel \{[\s\S]*?position: fixed/);
  assert.match(block, /\.filter-panel-foot, \.company-filter-actions \{[\s\S]*?position: sticky/);
});

test("POLISH-01: an inert card does not wear an actionable card's elevation", async () => {
  const styles = await read("../app/workspace.css");
  // VIS-01 / OV-AC-01. Metric tiles and the welcome hero do nothing when you
  // click them, and elevation-2 is this product's "you can act on this" signal.
  assert.match(styles, /\.metric-card, \.welcome \{ box-shadow: none; \}/);
  assert.doesNotMatch(styles, /\.panel, \.metric-card, \.client-hero/);

  // Colour glows are gone from the chrome: a 40%-opacity blue shadow under the
  // loudest control on screen, and a 26% one under the logo.
  assert.doesNotMatch(styles, /\.primary \{ box-shadow: 0 1px 2px rgba\(var\(--accent-rgb\)/);
  assert.doesNotMatch(styles, /\.brand-mark \{ box-shadow: 0 6px 16px/);
  // Shadows below the threshold of perception were costing a paint and saying
  // nothing: an inset at 1.5% opacity and an accent glow at 6%.
  assert.doesNotMatch(styles, /rgba\(var\(--shadow-rgb\), \.015\)/);
  assert.doesNotMatch(styles, /rgba\(var\(--accent-rgb\), \.06\)/);

  // Four metric classes whose bodies were already identical and neutral - a
  // dead colour vocabulary inviting someone to "restore" it.
  for (const dead of [".metric-card.violet", ".metric-card.blue", ".metric-card.amber", ".metric-card.green"]) {
    assert.ok(!styles.includes(dead), `${dead} is a colour that no longer exists`);
  }
  const overview = await read("../app/components/OverviewWorkspace.tsx");
  assert.doesNotMatch(overview, /color: "(violet|blue|amber|green)"/);
  assert.match(overview, /<article className="metric-card" key=\{card\.label\}/);
});
