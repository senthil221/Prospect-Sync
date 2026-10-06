import { expect, test } from "@playwright/test";

test.skip(process.env.E2E_FIXTURE_SUITE !== "1", "local deterministic fixture only");

test("Company DB keeps one clear verification selector and exposes removable legacy verdicts", async ({ page }) => {
  await page.goto("/e2e-fixtures/company-workspace");

  const verification = page.getByRole("group", { name: "Filter companies by ICP verification" });
  await expect(verification.getByRole("button")).toHaveText(["All", "ICP Verified", "ICP Unverified", "No domain unverified"]);
  await expect(page.getByRole("button", { name: "Any ICP check" })).toHaveCount(0);

  const legacy = page.getByRole("button", { name: /Exclude saved ICP results/ });
  await expect(legacy).toContainText("ICP check FIT, ICP check NON_FIT");

  const company = page.getByRole("checkbox", { name: "Select Fixture Systems" });
  await company.check();
  await expect(company).toBeChecked();
  await expect(page.getByText("1 selected across pages")).toBeVisible();

  await legacy.click();
  await expect(page.getByRole("button", { name: /saved ICP results/i })).toHaveCount(0);
  await expect(company).not.toBeChecked();
  await expect(page.getByText("1 selected across pages")).toHaveCount(0);
});

test("capped 100-row company pages keep honest forward and backward navigation", async ({ page }) => {
  await page.goto("/e2e-fixtures/company-workspace");
  await page.getByRole("button", { name: "Show capped 100-row page" }).click();

  const pagination = page.locator(".company-pagination");
  await expect(pagination).toContainText("Page 500 · 50,000+ matches");
  await expect(pagination.getByRole("button", { name: "Next" })).toBeEnabled();
  await pagination.getByRole("button", { name: "Next" }).click();

  await expect(pagination).toContainText("Page 501 · 50,051+ matches");
  await expect(pagination.getByRole("button", { name: "Next" })).toBeDisabled();
  await pagination.getByRole("button", { name: "Previous" }).click();
  await expect(pagination).toContainText("Page 500 · 50,000+ matches");

  await page.getByRole("button", { name: "Show empty page after cap" }).click();
  await expect(pagination).toContainText("Page 502 · 50,000+ matches");
  await expect(pagination.getByRole("button", { name: "Previous" })).toBeEnabled();
  await expect(pagination.getByRole("button", { name: "Next" })).toBeDisabled();
});
