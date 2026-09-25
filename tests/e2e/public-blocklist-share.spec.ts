import { expect, test } from "@playwright/test";

const token = "public_share_test_token_123456789012345678901234567890";

test("a client link submits with an explicit reason without exposing the token in the URL path", async ({ page }) => {
  const calls: Array<{ url: string; body: Record<string, unknown> }> = [];
  await page.route("**/api/blocklist-share", async (route) => {
    const body = route.request().postDataJSON() as Record<string, unknown>;
    calls.push({ url: route.request().url(), body });
    if (body.action === "info") {
      await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ clientName: "Acme Client", label: "Acme exclusions", reasons: ["Client Provided", "ICP Invalid", "Campaign Reply"] }) });
      return;
    }
    await route.fulfill({ status: 202, contentType: "application/json", body: JSON.stringify({ accepted: true }) });
  });

  await page.goto(`/blocklist#token=${token}`);
  await expect(page).toHaveURL(/\/blocklist$/);
  await expect(page.getByRole("heading", { name: "Submit for Acme Client" })).toBeVisible();
  const submit = page.getByRole("button", { name: "Add to blocklist" });
  await page.getByLabel("Domains and email addresses").fill("example.com\nno-contact@example.com");
  await expect(submit).toBeDisabled();
  await page.getByLabel("Reason").selectOption("Client Provided");
  await submit.click();
  await expect(page.getByRole("status")).toHaveText("Your entries were accepted and will be applied securely.");
  await expect(page.getByLabel("Reason")).toHaveValue("");

  expect(calls).toHaveLength(2);
  expect(calls.every((call) => !call.url.includes(token))).toBe(true);
  expect(calls[1].body).toMatchObject({ action: "submit", token, reason: "Client Provided" });
});

test("an invalid or revoked link shows only the generic public error", async ({ page }) => {
  await page.route("**/api/blocklist-share", (route) => route.fulfill({
    status: 404,
    contentType: "application/json",
    body: JSON.stringify({ error: "This submission link is invalid, expired, or revoked." }),
  }));
  await page.goto(`/blocklist#token=${token}`);
  await expect(page.locator(".login-error")).toHaveText("This submission link is invalid, expired, or revoked.");
  await expect(page).toHaveURL(/\/blocklist$/);
});
