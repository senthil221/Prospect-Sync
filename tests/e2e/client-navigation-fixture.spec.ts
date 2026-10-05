import { expect, test, type Page, type Route } from "@playwright/test";

test.skip(process.env.E2E_FIXTURE_SUITE !== "1", "local deterministic fixture only");

const clients = {
  a: { id: "client-a", name: "Client A", list_count: 2, prospect_count: 8, company_count: 3, cooldown_days: 90, icp_verified_count: 2, blocked_count: 0, folder_id: "folder-a", folder_name: "North", archived_at: null },
  b: { id: "client-b", name: "Client B", list_count: 1, prospect_count: 4, company_count: 2, cooldown_days: 60, icp_verified_count: 1, blocked_count: 0, folder_id: null, folder_name: null, archived_at: null },
  archived: { id: "client-archived", name: "Archived Client", list_count: 0, prospect_count: 0, company_count: 0, cooldown_days: 90, icp_verified_count: 0, blocked_count: 0, folder_id: null, folder_name: null, archived_at: "2026-01-01T00:00:00.000Z" },
  deep: { id: "client-deep", name: "Deep Link Client", list_count: 80, prospect_count: 20, company_count: 7, cooldown_days: 90, icp_verified_count: 3, blocked_count: 0, folder_id: null, folder_name: null, archived_at: null },
};
const lists = {
  a: { id: "list-a", name: "List A", data_source: "CSV", source_file_name: "list-a.csv", uploaded_rows: 8, unique_added: 8, duplicates_linked: 0, prospect_count: 8, created_at: "2026-01-01T00:00:00.000Z", field_count: 4, field_headers: ["name"] },
  a2: { id: "list-a2", name: "List A2", data_source: "CSV", source_file_name: "list-a2.csv", uploaded_rows: 2, unique_added: 2, duplicates_linked: 0, prospect_count: 2, created_at: "2026-01-03T00:00:00.000Z", field_count: 3, field_headers: ["name"] },
  b: { id: "list-b", name: "List B", data_source: "CSV", source_file_name: "list-b.csv", uploaded_rows: 4, unique_added: 4, duplicates_linked: 0, prospect_count: 4, created_at: "2026-01-02T00:00:00.000Z", field_count: 4, field_headers: ["name"] },
  deep: { id: "list-deep", name: "Deep Page List", data_source: "CSV", source_file_name: "deep.csv", uploaded_rows: 20, unique_added: 20, duplicates_linked: 0, prospect_count: 20, created_at: "2025-01-01T00:00:00.000Z", field_count: 5, field_headers: ["name"] },
};

function deferred() {
  let release = () => {};
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

async function installApi(page: Page, held: string[] = [], failOnce: string[] = []) {
  const gates = new Map(held.map((key) => [key, deferred()]));
  const failures = new Set(failOnce);
  const requested: string[] = [];
  const completed = new Set<string>();
  const wait = async (key: string) => { await gates.get(key)?.promise; };
  const json = (route: Route, body: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
  const delayedJson = async (key: string, route: Route, body: unknown, status = 200) => {
    await wait(key);
    try {
      await json(route, body, status);
    } catch (error) {
      if (!gates.has(key)) throw error;
    } finally {
      completed.add(key);
    }
  };
  await page.route("**/api/**", async (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname;
    requested.push(`${path}${url.search}`);
    if (path === "/api/dashboard") return delayedJson("global", route, { stats: { prospects: 12, companies: 5, clients: 3, lists: 3, rowsImported: 12, duplicatesDetected: 0 }, recentImports: [] });
    if (path === "/api/clients") return delayedJson("global", route, { clients: [clients.a, clients.b, clients.archived] });
    if (path === "/api/client-folders") return json(route, { folders: [{ id: "folder-a", name: "North", created_at: "2026-01-01T00:00:00.000Z" }] });
    const clientMatch = path.match(/^\/api\/clients\/([^/]+)$/);
    if (clientMatch) {
      const id = decodeURIComponent(clientMatch[1]);
      const key = `client:${id}`;
      if (failures.delete(key)) return delayedJson(key, route, { error: "Temporary client failure." }, 500);
      const client = Object.values(clients).find((item) => item.id === id);
      return client ? delayedJson(key, route, { client }) : delayedJson(key, route, { error: "Client not found." }, 404);
    }
    if (/^\/api\/clients\/[^/]+\/icp$/.test(path)) return json(route, { profiles: [] });
    if (path === "/api/lists") {
      const clientId = url.searchParams.get("clientId") ?? "";
      const result = clientId === clients.a.id ? [lists.a, lists.a2] : clientId === clients.b.id ? [lists.b] : [];
      return delayedJson(`lists:${clientId}`, route, { lists: result, total: result.length, page: 1, limit: 50 });
    }
    const rowsMatch = path.match(/^\/api\/lists\/([^/]+)\/rows$/);
    if (rowsMatch) return json(route, { rows: [], total: 0 });
    const listMatch = path.match(/^\/api\/lists\/([^/]+)$/);
    if (listMatch) {
      const id = decodeURIComponent(listMatch[1]);
      const clientId = url.searchParams.get("clientId") ?? "";
      const key = `list:${id}`;
      if (failures.delete(key)) return delayedJson(key, route, { error: "Temporary list failure." }, 500);
      const list = id === lists.a.id && clientId === clients.a.id ? lists.a
        : id === lists.a2.id && clientId === clients.a.id ? lists.a2
        : id === lists.b.id && clientId === clients.b.id ? lists.b
        : id === lists.deep.id && clientId === clients.deep.id ? lists.deep : null;
      return list ? delayedJson(key, route, { list }) : delayedJson(key, route, { error: "List not found for this client." }, 404);
    }
    if (path === "/api/imports") return json(route, { imports: [], backgroundImports: [] });
    return json(route, {});
  });
  return { release: (key: string) => gates.get(key)?.release(), completed, requested };
}

async function popTo(page: Page, url: string) {
  await page.evaluate((next) => { window.history.pushState(null, "", next); window.dispatchEvent(new PopStateEvent("popstate")); }, url);
}

test("pending direct list preserves URL scope and renders before the global directory", async ({ page }) => {
  const api = await installApi(page, ["global", "client:client-a", "lists:client-a", "list:list-a"]);
  const values = Array.from({ length: 400 }, (_, index) => `company-${index}.example.test`);
  const fragment = `#workspace-v1?pf=${encodeURIComponent(JSON.stringify([{ field: "__website", operator: "equals", values }]))}`;
  await page.goto(`/e2e-fixtures/client-navigation?s=clients&client=client-a&list=list-a${fragment}`);
  await expect(page).toHaveURL(/client=client-a/);
  await expect(page).toHaveURL(/list=list-a/);
  expect(new URL(page.url()).hash).toContain("workspace-v1");
  await expect(page.getByText("Opening client workspace")).toBeVisible();
  api.release("client:client-a"); api.release("lists:client-a"); api.release("list:list-a");
  await expect(page.getByRole("heading", { name: "List A", level: 2 })).toBeVisible();
  await expect(page.getByText("Loading the client directory in the background…")).toBeVisible();
  api.release("global");
  await expect(page.getByText("Loading the client directory in the background…")).toBeHidden();
  await expect(page.getByRole("heading", { name: "List A", level: 2 })).toBeVisible();
  await page.reload();
  await expect(page.getByRole("heading", { name: "List A", level: 2 })).toBeVisible();
});

test("archived clients restore while same-id retry, unknown clients and wrong-client lists recover explicitly", async ({ page }) => {
  const api = await installApi(page, ["global"], ["client:client-a"]);
  await page.goto("/e2e-fixtures/client-navigation?s=clients&client=client-archived");
  await expect(page.getByRole("heading", { name: "Archived Client", level: 2 })).toBeVisible();
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-a");
  await expect(page.getByRole("heading", { name: "Unable to open this client" })).toBeVisible();
  await page.getByRole("button", { name: "Retry" }).click();
  await expect(page.getByRole("heading", { name: "Client A", level: 2 })).toBeVisible();
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=missing");
  await expect(page.getByRole("heading", { name: "Unable to open this client" })).toBeVisible();
  await expect(page).toHaveURL(/client=missing/);
  await page.getByRole("button", { name: "Back to all clients" }).click();
  await expect(page).not.toHaveURL(/client=/);
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-a&list=list-b");
  await expect(page.getByRole("heading", { name: "Unable to open this list" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Client A", level: 1 })).toBeVisible();
  await page.getByRole("button", { name: /Back to Client A.*lists/ }).click();
  await expect(page.getByRole("heading", { name: "Client A", level: 2 })).toBeVisible();
  await expect(page).not.toHaveURL(/list=/);
  api.release("global");
});

test("slow client A cannot overwrite fast client B and leaving a pending list cannot reopen it", async ({ page }) => {
  const api = await installApi(page, ["global", "client:client-a", "lists:client-a", "list:list-a2"]);
  await page.goto("/e2e-fixtures/client-navigation?s=clients&client=client-a");
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-b");
  await expect(page.getByRole("heading", { name: "Client B", level: 2 })).toBeVisible();
  api.release("client:client-a"); api.release("lists:client-a");
  await expect.poll(() => api.completed.has("client:client-a") && api.completed.has("lists:client-a")).toBe(true);
  await expect(page.getByRole("heading", { name: "Client B", level: 2 })).toBeVisible();
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-a");
  await expect(page.getByRole("heading", { name: "Client A", level: 2 })).toBeVisible();
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-a&list=list-a2");
  await expect(page.getByText("Opening client list")).toBeVisible();
  await page.getByRole("button", { name: "Overview" }).click();
  api.release("list:list-a2");
  api.release("global");
  await expect(page.getByRole("heading", { name: "Overview" }).first()).toBeVisible();
  await expect(page.getByRole("heading", { name: "List A2", level: 2 })).toHaveCount(0);
});

test("a late global directory response preserves the chosen client tab", async ({ page }) => {
  const api = await installApi(page, ["global"]);
  await page.goto("/e2e-fixtures/client-navigation?s=clients&client=client-a");
  await page.getByRole("tab", { name: /ICPs/ }).click();
  await expect(page.getByRole("heading", { name: "Ideal customer profiles" })).toBeVisible();
  await expect(page.getByText("Loading the client directory in the background…")).toBeVisible();
  api.release("global");
  await expect(page.getByText("Loading the client directory in the background…")).toBeHidden();
  await expect(page.getByRole("tab", { name: /ICPs/ })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("heading", { name: "Ideal customer profiles" })).toBeVisible();
});

test("Back and Forward restore a client and list absent from directory pages", async ({ page }) => {
  const api = await installApi(page);
  await page.goto("/e2e-fixtures/client-navigation?s=clients");
  await expect(page.getByRole("heading", { name: "All clients" })).toBeVisible();
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-deep&list=list-deep");
  await expect(page.getByRole("heading", { name: "Deep Page List", level: 2 })).toBeVisible();
  expect(api.requested).toContain("/api/lists/list-deep?clientId=client-deep");
  await page.goBack();
  await expect(page.getByRole("heading", { name: "All clients" })).toBeVisible();
  await expect(page).not.toHaveURL(/client=/);
  await page.goForward();
  await expect(page.getByRole("heading", { name: "Deep Page List", level: 2 })).toBeVisible();
  await popTo(page, "/e2e-fixtures/client-navigation?s=clients&client=client-a&list=list-a2");
  await expect(page.getByRole("heading", { name: "List A2", level: 2 })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Deep Page List", level: 2 })).toHaveCount(0);
  await page.getByRole("button", { name: "Client A lists" }).click();
  await page.getByRole("button", { name: "All clients" }).click();
  await page.getByRole("button", { name: /North/ }).first().click();
  await expect(page.getByRole("heading", { name: "North" })).toBeVisible();
  await page.getByRole("button", { name: "Clients", exact: true }).click();
  await page.getByRole("button", { name: "Import client list" }).click();
  await expect(page.getByRole("heading", { name: "What are you importing?" })).toBeVisible();
});

test("navigating away from a pending direct client does not reopen it and global navigation becomes ready", async ({ page }) => {
  const api = await installApi(page, ["client:client-a", "lists:client-a"]);
  await page.goto("/e2e-fixtures/client-navigation?s=clients&client=client-a");
  await page.getByRole("button", { name: "Overview" }).click();
  await expect(page.getByRole("heading", { name: "Overview" }).first()).toBeVisible();
  api.release("client:client-a"); api.release("lists:client-a");
  await expect(page.getByRole("heading", { name: "Client A", level: 2 })).toHaveCount(0);
});

test("malformed restoration never starts a client or list request", async ({ page }) => {
  const api = await installApi(page);
  await page.goto("/e2e-fixtures/client-navigation?s=clients&client=client-a&list=list-a&pf=%7B");
  await expect(page.getByRole("heading", { name: "This search link needs attention" })).toBeVisible();
  expect(api.requested.some((path) => path === "/api/clients/client-a" || path.startsWith("/api/lists?clientId=client-a") || path.startsWith("/api/lists/list-a"))).toBe(false);
});
