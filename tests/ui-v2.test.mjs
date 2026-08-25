import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("ships the readable Prospect Sync UI v2 system", async () => {
  const [dashboard, filterPanel, styles, tokens, companiesRoute, companyProspectsRoute] = await Promise.all([
    readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/ApolloFilterPanel.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/workspace.css", import.meta.url), "utf8"),
    readFile(new URL("../app/design-system.css", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/api/companies/[id]/prospects/route.ts", import.meta.url), "utf8"),
  ]);

  assert.match(dashboard, /All your prospects, organized in one place/);
  assert.match(dashboard, /function AppIcon/);
  assert.match(dashboard, /company-table/);
  assert.match(dashboard, /company-prospect-list/);
  assert.match(dashboard, /function CompanyDrawer/);
  assert.match(dashboard, /company-drawer/);
  assert.match(dashboard, /const navGroups/);
  assert.match(dashboard, /Data tools/);
  assert.doesNotMatch(dashboard, /className="sync-visual"/);
  assert.doesNotMatch(dashboard, /className="sidebar-note"/);
  assert.match(dashboard, /Load \$\{Math\.min\(50, total - prospects\.length\)\} more prospects/);
  assert.match(dashboard, /company-pagination/);
  assert.match(dashboard, /All companies/);
  assert.match(dashboard, /Only with websites/);
  assert.match(dashboard, /Export CSV/);
  assert.match(dashboard, /X-Exported-Rows/);
  assert.doesNotMatch(dashboard, /company-prospect-row/);
  assert.match(dashboard, /filtersOpen/);
  assert.match(filterPanel, /aria-multiselectable/);
  assert.match(dashboard, /View all fields/);
  assert.doesNotMatch(dashboard, /Know what you already own, reuse clean data across clients/);
  assert.doesNotMatch(dashboard, /Reuse eligibility/);
  assert.match(companiesRoute, /\.range\(from, from \+ pageSize - 1\)/);
  assert.match(companiesRoute, /prospectTotal/);
  assert.match(companiesRoute, /exportCompanies\(search, websitesOnly,/);
  assert.match(companiesRoute, /website.*required/);
  assert.match(companiesRoute, /\.neq\("domain", ""\)/);
  assert.match(companiesRoute, /\.range\(offset, offset \+ exportBatchSize - 1\)/);
  assert.match(companiesRoute, /Content-Disposition/);
  assert.match(companiesRoute, /X-Exported-Rows/);
  assert.doesNotMatch(companiesRoute, /\.limit\(100\)/);
  assert.match(companyProspectsRoute, /prospect_summaries/);
  assert.match(companyProspectsRoute, /\.range\(from, from \+ pageSize - 1\)/);
  // Sizes now come from the design-system scale rather than literals, so the
  // contract is checked in two halves: the component references the token, and
  // the token resolves to the size the product is specified at.
  assert.match(styles, /html, body[\s\S]*font-size: var\(--text-base\)/);
  assert.match(tokens, /--text-base:\s*14px/);
  assert.match(styles, /\.master-data-table td[\s\S]*font-size: var\(--text-sm\)/);
  assert.match(tokens, /--text-sm:\s*13px/);
  // No raw colour, size, weight or radius may re-enter the component sheet.
  assert.doesNotMatch(styles, /#[0-9a-fA-F]{3,8}\b/);
  assert.doesNotMatch(styles, /font-size:\s*[0-9.]+px/);
  assert.match(styles, /\.company-table/);
  assert.match(styles, /\.company-drawer/);
  assert.match(styles, /\.summary-violet/);
  assert.match(styles, /\.nav-group-label/);
  assert.match(styles, /\.nav-group \{ display: contents; \}/);
  assert.match(styles, /\.login-logo \{ display: flex; \}/);
  assert.match(styles, /@media \(max-width: 760px\)/);
  assert.match(styles, /prefers-reduced-motion/);
  assert.doesNotMatch(styles, /font-size: 6(?:\.5)?px/);
});
