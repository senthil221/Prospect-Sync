import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships the readable Prospect Sync UI v2 system", async () => {
  const [dashboard, styles, companiesRoute, companyProspectsRoute] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/workspace.css", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/[id]/prospects/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /All your prospects, organized in one place/);
  assert.match(dashboard, /function AppIcon/);
  assert.match(dashboard, /company-table/);
  assert.match(dashboard, /company-prospect-list/);
  assert.match(dashboard, /function CompanyDrawer/);
  assert.match(dashboard, /company-drawer/);
  assert.match(dashboard, /Load \$\{Math\.min\(50, total - prospects\.length\)\} more prospects/);
  assert.match(dashboard, /company-pagination/);
  assert.doesNotMatch(dashboard, /company-prospect-row/);
  assert.match(dashboard, /filtersOpen/);
  assert.match(dashboard, /aria-multiselectable/);
  assert.match(dashboard, /View all fields/);
  assert.doesNotMatch(dashboard, /Know what you already own, reuse clean data across clients/);
  assert.doesNotMatch(dashboard, /Reuse eligibility/);
  assert.match(companiesRoute, /\.range\(from, from \+ pageSize - 1\)/);
  assert.match(companiesRoute, /prospectTotal/);
  assert.doesNotMatch(companiesRoute, /\.limit\(100\)/);
  assert.match(companyProspectsRoute, /prospect_summaries/);
  assert.match(companyProspectsRoute, /\.range\(from, from \+ pageSize - 1\)/);
  assert.match(styles, /html, body[\s\S]*font-size: 14px/);
  assert.match(styles, /\.master-data-table td[\s\S]*font-size: 13px/);
  assert.match(styles, /\.company-table/);
  assert.match(styles, /\.company-drawer/);
  assert.match(styles, /\.summary-violet/);
  assert.match(styles, /@media \(max-width: 760px\)/);
  assert.match(styles, /prefers-reduced-motion/);
  assert.doesNotMatch(styles, /font-size: 6(?:\.5)?px/);
});
