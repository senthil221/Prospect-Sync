import { expect, test } from "@playwright/test";

test.skip(process.env.E2E_VERIFICATION_FIXTURE !== "1", "local isolated fixture only");
const fixturePath = process.env.E2E_VERIFICATION_FIXTURE_PATH || "/";

test("verification confirmation keeps one request id across preparation and controls the same paused run", async ({ page }) => {
  await page.goto(fixturePath);
  await expect(page.getByRole("heading", { name: "Work email verification" })).toBeVisible();
  await expect(page.getByRole("button", { name: /Current search & filters/ })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByRole("button", { name: "10,000" })).toHaveAttribute("aria-pressed", "true");
  await page.screenshot({ path: "test-results/email-verification-setup-desktop.png", fullPage: true });
  await page.getByRole("button", { name: "Custom" }).click();
  await page.getByRole("spinbutton", { name: "Maximum unique work emails" }).fill("10000");
  await page.locator(".verification-advanced summary").click();
  await page.getByLabel("Reverify completed unchanged emails").check();
  await page.getByRole("button", { name: /Review verification/ }).click();
  await expect(page.getByRole("heading", { name: "Review verification run" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Back to setup" })).toBeFocused();
  await page.screenshot({ path: "test-results/email-verification-limit-confirmation.png", fullPage: true });
  await page.getByRole("button", { name: "Create run" }).click();
  await expect(page.getByText("23,850").first()).toBeVisible({ timeout: 10_000 });
  const requests = await page.evaluate(() => (globalThis as typeof globalThis & { __verificationRequests?: Array<Record<string, unknown>> }).__verificationRequests ?? []);
  expect(requests).toHaveLength(2);
  expect(requests[0].requestId).toBe(requests[1].requestId);
  expect(requests[0].forceReverify).toBe(true);
  expect(requests[0].maxEmails).toBe(10_000);
  await expect(page.getByText(/10,000 emails selected/)).toBeVisible();
  await expect(page.getByText(/40,000 emails eligible/)).toBeVisible();
  await expect(page.getByText(/10,000 requested limit/)).toBeVisible();
  await page.getByRole("button", { name: "Continue same run" }).click();
  await expect(page.getByText("Running").first()).toBeVisible();
  await page.locator(".verification-run-list").evaluate(element => { element.scrollTop = 0; });
  await page.screenshot({ path: "test-results/email-verification-desktop.png", fullPage: true });
});

test("confirmation traps focus and Escape returns through the panel to its launcher", async ({ page }) => {
  await page.goto(fixturePath);
  await page.getByRole("button", { name: "Close verification" }).click();
  await page.getByRole("button", { name: "Open email verification" }).click();
  const review = page.getByRole("button", { name: /Review verification/ });
  await review.click();
  await expect(page.getByRole("button", { name: "Back to setup" })).toBeFocused();
  for (let step = 0; step < 5; step += 1) {
    await page.keyboard.press("Tab");
    expect(await page.locator(":focus").evaluate(element => Boolean(element.closest('[role="dialog"]')))).toBe(true);
  }
  await page.keyboard.press("Escape");
  await expect(review).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("button", { name: "Open email verification" })).toBeFocused();
});

test("verification modal remains usable without horizontal overflow on mobile", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(fixturePath);
  const dialog = page.getByRole("dialog", { name: "Work email verification" });
  await expect(dialog).toBeVisible();
  const overflow = await dialog.evaluate(element => element.scrollWidth - element.clientWidth);
  expect(overflow).toBeLessThanOrEqual(1);
  const review = page.getByRole("button", { name: /Review verification/ });
  await expect(review).toBeVisible();
  await review.scrollIntoViewIfNeeded();
  await page.screenshot({ path: "test-results/email-verification-mobile.png", fullPage: true });
  await review.click();
  await expect(page.getByRole("button", { name: "Create run" })).toBeVisible();
  expect(await page.getByRole("dialog", { name: "Review verification run" }).evaluate(element => element.scrollWidth - element.clientWidth)).toBeLessThanOrEqual(1);
});

test("All eligible is explicit and omits a cap", async ({ page }) => {
  await page.goto(fixturePath);
  await page.getByRole("button", { name: "All eligible", exact: true }).click();
  await page.getByRole("button", { name: /Review verification/ }).click();
  await expect(page.getByRole("dialog")).toContainText("All eligible work emails");
  await page.getByRole("button", { name: "Create run" }).click();
  await expect(page.getByText("23,850").first()).toBeVisible({ timeout: 10_000 });
  const requests = await page.evaluate(() => (globalThis as typeof globalThis & { __verificationRequests?: Array<Record<string, unknown>> }).__verificationRequests ?? []);
  expect(requests[0].maxEmails).toBeUndefined();
});

test("Last Verified restores saved dates and preserves Never Verified in the matching request", async ({ page }) => {
  await page.goto(fixturePath);
  await page.getByRole("button", { name: "Close verification" }).click();
  const dateFilter = page.locator("#verification-date-fixture");
  await expect(dateFilter.getByLabel("From")).toHaveValue("2026-09-02");
  await expect(dateFilter.getByLabel("Through")).toHaveValue("2026-09-04");
  // A styled listbox, not a native select: open it, then choose the option.
  await dateFilter.getByRole("button", { name: /^Condition|currently/ }).first().click();
  await page.getByRole("option", { name: "Never verified" }).click();
  await dateFilter.getByRole("button", { name: "Apply date" }).click();
  const selected = await page.evaluate(() => (globalThis as typeof globalThis & { __verificationDateFilters?: Array<Record<string, unknown>> }).__verificationDateFilters ?? []);
  expect(selected).toEqual([expect.objectContaining({ field: "__work_email_verified_at", operator: "never", values: [] })]);
  await page.getByRole("button", { name: "Open email verification" }).click();
  await page.getByRole("button", { name: /Review verification/ }).click();
  await page.getByRole("button", { name: "Create run" }).click();
  await expect(page.getByText("23,850").first()).toBeVisible({ timeout: 10_000 });
  const requests = await page.evaluate(() => (globalThis as typeof globalThis & { __verificationRequests?: Array<Record<string, unknown>> }).__verificationRequests ?? []);
  expect(requests[0].filters).toEqual(expect.arrayContaining([expect.objectContaining({ field: "__work_email_verified_at", operator: "never", values: [] })]));
  expect(requests[0].maxEmails).toBe(10_000);
});
