import { expect, test } from "@playwright/test";

// Screenshots of the authenticated workspaces, light and dark, at the widths
// the redesign plan's viewport gate names.
//
// This exists because section B of the plan records the audit's own limitation:
// the authenticated screens were never seen. Everything since has been written
// against source rather than against pixels, which is the wrong way round for a
// design project. Running this produces the evidence.
//
// STRICTLY READ-ONLY - navigate and capture, nothing else. Safe against
// production:
//
//   E2E_BASE_URL=https://app.clearroadco.link \
//   E2E_USER_EMAIL=... E2E_USER_PASSWORD=... \
//   npx playwright test visual-workspaces
//
// Images land in test-results/.

const email = process.env.E2E_USER_EMAIL || "";
const password = process.env.E2E_USER_PASSWORD || "";

test.skip(!email || !password, "Set E2E_USER_EMAIL and E2E_USER_PASSWORD to capture the workspaces.");

const widths = [1440, 1280, 1024];
const sections = [
  { name: "people", nav: "Master DB" },
  { name: "companies", nav: "Company DB" },
  { name: "clients", nav: "Clients" },
];

for (const theme of ["light", "dark"] as const) {
  test(`workspaces render in ${theme}`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: theme });
    await page.goto("/login");
    await page.getByLabel("Email address").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.getByRole("button", { name: "Sign in securely" }).click();
    await expect(page.getByRole("navigation", { name: "Primary navigation" })).toBeVisible();

    for (const width of widths) {
      await page.setViewportSize({ width, height: 900 });
      for (const section of sections) {
        const link = page.getByRole("button", { name: section.nav });
        if (await link.count() === 0) continue;
        await link.first().click();
        // Settle rather than race the listing request.
        await page.waitForLoadState("networkidle").catch(() => undefined);
        await page.screenshot({ path: `test-results/${theme}-${width}-${section.name}.png`, fullPage: false });
      }
    }
  });
}
