import { expect, test } from "@playwright/test";

const email = process.env.E2E_USER_EMAIL || "";
const password = process.env.E2E_USER_PASSWORD || "";
const mutationAllowed = process.env.E2E_ALLOW_MUTATION === "1";

test.skip(!email || !password || !mutationAllowed, "Set E2E credentials and E2E_ALLOW_MUTATION=1 for the isolated import smoke test.");

test("an authenticated user can upload and complete a prospect CSV import", async ({ page }) => {
  const suffix = `${Date.now()}-${Math.random().toString(16).slice(2, 8)}`;
  const clientName = `Codex E2E ${suffix}`;
  const listName = `Authenticated import ${suffix}`;
  const prospectEmail = `codex-import-${suffix}@example.invalid`;
  const dateAdded = "2026-08-20";
  let clientId = "";

  try {
    await page.goto("/login");
    await page.getByLabel("Email address").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.getByRole("button", { name: "Sign in securely" }).click();
    await expect(page.getByRole("navigation", { name: "Primary navigation" })).toBeVisible();

    await page.getByRole("button", { name: "Import CSV" }).click();
    await page.getByLabel("Data source").selectOption("Apollo");
    await page.getByLabel("New client name").fill(clientName);
    await page.getByLabel("Date added").fill(dateAdded);
    const csv = [
      "Name,Company Name,Email,Personal LinkedIn URL,Job Title,Seniority,Departments,Sub Departments",
      `Codex Import Sentinel,Prospect Sync E2E,${prospectEmail},https://www.linkedin.com/in/codex-import-sentinel,Director of Testing,Director,Engineering,Quality Assurance`,
    ].join("\n");
    await page.locator('input[type="file"][accept=".csv,text/csv"]').setInputFiles({
      name: `authenticated-import-${suffix}.csv`, mimeType: "text/csv", buffer: Buffer.from(csv),
    });
    await page.getByLabel("List name").fill(listName);
    await page.getByRole("button", { name: "Start import & sync" }).click();
    await expect(page.getByRole("heading", { name: "Your list is ready." })).toBeVisible({ timeout: 150_000 });

    const clientsResponse = await page.request.get("/api/clients", { headers: { "cache-control": "no-store" } });
    expect(clientsResponse.ok()).toBeTruthy();
    const clientsBody = await clientsResponse.json() as { clients: Array<{ id: string; name: string }> };
    clientId = clientsBody.clients.find((client) => client.name === clientName)?.id || "";
    expect(clientId).not.toBe("");

    const prospectsResponse = await page.request.get(`/api/prospects?clientId=${encodeURIComponent(clientId)}&search=${encodeURIComponent(prospectEmail)}&page=1&withTotal=1`);
    expect(prospectsResponse.ok()).toBeTruthy();
    const prospectsBody = await prospectsResponse.json() as { prospects: Array<{ id: string; client_date_added?: string }> };
    expect(prospectsBody.prospects).toHaveLength(1);
    expect(prospectsBody.prospects[0].client_date_added).toBe(dateAdded);
  } finally {
    let canDeleteMaster = false;
    if (!clientId) {
      const clients = await page.request.get("/api/clients").catch(() => null);
      if (clients?.ok()) {
        const body = await clients.json() as { clients?: Array<{ id: string; name: string }> };
        clientId = (body.clients ?? []).find((client) => client.name === clientName)?.id || "";
        canDeleteMaster = !clientId;
      }
    }
    if (clientId) canDeleteMaster = (await page.request.delete(`/api/clients/${encodeURIComponent(clientId)}`)).ok();
    if (canDeleteMaster) {
      const master = await page.request.get(`/api/prospects?search=${encodeURIComponent(prospectEmail)}&page=1&withTotal=1`).catch(() => null);
      if (master?.ok()) {
        const body = await master.json() as { prospects?: Array<{ id: string }> };
        const ids = (body.prospects ?? []).map((prospect) => prospect.id);
        if (ids.length) await page.request.delete("/api/prospects", { data: { ids } });
      }
    }
  }
});
