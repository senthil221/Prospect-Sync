import { expect, test } from "@playwright/test";

test.skip(process.env.E2E_FIXTURE_SUITE !== "1", "local deterministic fixture only");

test("Company DB keeps one clear verification selector and exposes removable legacy verdicts", async ({ page }) => {
  await page.goto("/e2e-fixtures/company-workspace");

  const verification = page.getByRole("group", { name: "Filter companies by ICP verification" });
  await expect(verification.getByRole("button")).toHaveText(["All", "ICP Verified", "ICP Unverified"]);
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
