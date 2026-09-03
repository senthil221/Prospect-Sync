import { expect, test } from "@playwright/test";

// The exit gate for DATA-ACCESS-01 and FOUNDATION-01: open a row from the
// keyboard, close it, and land back where you started.
//
// STRICTLY READ-ONLY. It signs in, tabs, opens a drawer, presses Escape and
// takes screenshots. It never imports, pushes, deletes, exports or edits, so
// unlike authenticated-csv-import.spec.ts it needs no E2E_ALLOW_MUTATION and is
// safe against production:
//
//   E2E_BASE_URL=https://app.clearroadco.link \
//   E2E_USER_EMAIL=... E2E_USER_PASSWORD=... \
//   npx playwright test keyboard-data-grid
//
// The screenshots land in test-results/ and are the point as much as the
// assertions are: the redesign is being written against a UI that cannot
// otherwise be seen.

const email = process.env.E2E_USER_EMAIL || "";
const password = process.env.E2E_USER_PASSWORD || "";

test.skip(!email || !password, "Set E2E_USER_EMAIL and E2E_USER_PASSWORD to run the keyboard gate.");

test.beforeEach(async ({ page }) => {
  await page.goto("/login");
  await page.getByLabel("Email address").fill(email);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: "Sign in securely" }).click();
  await expect(page.getByRole("navigation", { name: "Primary navigation" })).toBeVisible();
});

test("a People row opens from the keyboard and gives focus back on close", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });

  // The identity cell is a real button now, so it is reachable and has a name.
  // Before DATA-ACCESS-01 the row carried onClick on a bare <tr>: no tab stop,
  // no Enter, no focus ring - the table was reachable by mouse only.
  const firstRow = page.locator("table.master-data-table tbody tr").first();
  await expect(firstRow).toBeVisible();
  const identity = firstRow.locator("button.row-open");
  await expect(identity).toBeVisible();

  await identity.focus();
  await expect(identity).toBeFocused();
  await page.screenshot({ path: "test-results/people-row-focused.png", fullPage: false });

  // Enter opens. A <tr> with onClick does nothing here.
  await page.keyboard.press("Enter");
  const drawer = page.getByRole("dialog", { name: /.*/ });
  await expect(drawer).toBeVisible();

  // Initial focus is inside the dialog, on the safe control.
  await expect(drawer.locator("button.drawer-close")).toBeFocused();
  await page.screenshot({ path: "test-results/prospect-drawer.png", fullPage: false });

  // Tab is contained: cycling past the last stop returns to the first rather
  // than walking out into the table behind.
  for (let press = 0; press < 25; press += 1) await page.keyboard.press("Tab");
  await expect(drawer.locator(":focus")).toHaveCount(1);

  // Escape closes, and focus returns to the row that opened it - not to <body>,
  // which is where it went before and which restarts Tab at the top of the page.
  await page.keyboard.press("Escape");
  await expect(drawer).toBeHidden();
  await expect(identity).toBeFocused();
});

test("the drawer's tabs are real tabs over real panels", async ({ page }) => {
  const identity = page.locator("table.master-data-table tbody tr").first().locator("button.row-open");
  await identity.click();
  const drawer = page.getByRole("dialog");
  await expect(drawer).toBeVisible();

  // Until FOUNDATION-01 these were two buttons with role="tab", no roving
  // tabindex, no arrow keys, and aria-controls pointing at ids that existed
  // nowhere in the product.
  const tabs = drawer.getByRole("tab");
  await expect(tabs).toHaveCount(2);
  const selected = drawer.getByRole("tab", { selected: true });
  await expect(selected).toHaveCount(1);

  // Every tab must control a panel that exists and is labelled by it.
  for (const handle of await tabs.all()) {
    const controls = await handle.getAttribute("aria-controls");
    expect(controls, "a tab must name the panel it controls").toBeTruthy();
    const panel = page.locator(`#${controls}`);
    await expect(panel).toHaveCount(1);
    await expect(panel).toHaveAttribute("role", "tabpanel");
  }

  // Arrow keys move between tabs; that is the WAI-ARIA pattern and it did not
  // exist here before.
  await selected.focus();
  await page.keyboard.press("ArrowRight");
  await expect(drawer.getByRole("tab", { selected: true })).not.toHaveAttribute("id", await selected.getAttribute("id") ?? "");

  await page.keyboard.press("Escape");
});

test("the background is inert while a dialog is open", async ({ page }) => {
  const identity = page.locator("table.master-data-table tbody tr").first().locator("button.row-open");
  await identity.click();
  await expect(page.getByRole("dialog")).toBeVisible();

  // aria-modal claims this; useDialogFocus is what makes it true. Anything
  // outside the dialog is inert, so a screen reader and Tab both skip it.
  const inertCount = await page.locator("body > [inert]").count();
  expect(inertCount, "the dialog's siblings must be inert while it is open").toBeGreaterThan(0);

  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toBeHidden();
  expect(await page.locator("body > [inert]").count(), "inertness must be released on close").toBe(0);
});
