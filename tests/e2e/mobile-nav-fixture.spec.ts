import { expect, test } from "@playwright/test";

test.skip(process.env.E2E_FIXTURE_SUITE !== "1", "local deterministic fixture only");

test("mobile More owns focus, Escape and background inertness", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/e2e-fixtures/mobile-nav");
  const more = page.getByRole("button", { name: "More" });
  await more.focus();
  await more.click();

  const dialog = page.getByRole("dialog", { name: "More" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Close" })).toBeFocused();
  expect(await page.locator("main > button", { hasText: "Background action" }).evaluate(node => Boolean(node.closest("[inert]")))).toBe(true);
  for (let step = 0; step < 12; step += 1) {
    await page.keyboard.press("Tab");
    expect(await page.locator(":focus").evaluate(node => Boolean(node.closest('[role="dialog"]')))).toBe(true);
  }

  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  await expect(more).toBeFocused();
  expect(await page.locator("body > [inert]").count()).toBe(0);
});

test("theme choice changes the actual document theme", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/e2e-fixtures/mobile-nav");
  await page.getByRole("button", { name: "More" }).click();
  await page.getByRole("button", { name: "Dark theme" }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
});
