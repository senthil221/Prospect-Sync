import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  timeout: 180_000,
  expect: { timeout: 15_000 },
  ...(process.env.E2E_FIXTURE_SUITE === "1" ? {
    webServer: {
      command: "npm run dev",
      url: "http://localhost:3000/e2e-fixtures/mobile-nav",
      reuseExistingServer: false,
      timeout: 120_000,
      env: { ...process.env, E2E_FIXTURES_ENABLED: "1" },
    },
  } : {}),
  use: {
    baseURL: process.env.E2E_BASE_URL || (process.env.E2E_FIXTURE_SUITE === "1" ? "http://localhost:3000" : "http://127.0.0.1:3000"),
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: process.env.E2E_USE_SYSTEM_CHROME === "1" ? "off" : "retain-on-failure",
  },
  projects: [{
    name: "chromium",
    use: {
      ...devices["Desktop Chrome"],
      ...(process.env.E2E_USE_SYSTEM_CHROME === "1" ? { channel: "chrome" as const } : {}),
    },
  }],
});
