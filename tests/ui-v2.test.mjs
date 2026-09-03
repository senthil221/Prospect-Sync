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
  assert.match(dashboard, /downloadCsvStream/);
  assert.doesNotMatch(dashboard, /company-prospect-row/);
  assert.match(dashboard, /filtersOpen/);
  assert.match(filterPanel, /aria-multiselectable/);
  assert.match(dashboard, /View all fields/);
  assert.doesNotMatch(dashboard, /Know what you already own, reuse clean data across clients/);
  assert.doesNotMatch(dashboard, /Reuse eligibility/);
  assert.match(companiesRoute, /\.range\(from, from \+ pageSize - 1\)/);
  assert.match(companiesRoute, /prospectTotal/);
  assert.match(companiesRoute, /streamCompanyExport\(search, websitesOnly,/);
  assert.match(companiesRoute, /website.*required/);
  // The export is a keyset walk now, not a growing OFFSET, and it is rendered a
  // page at a time instead of accumulated into one string. The row count moves
  // with it: a streamed response cannot carry a total in its headers, because
  // the total is not known when the headers are sent.
  assert.match(companiesRoute, /search_company_export_v1/);
  assert.match(companiesRoute, /p_after_name: cursor\?\.name \?\? null/);
  assert.doesNotMatch(companiesRoute, /\.range\(offset, offset \+ exportBatchSize - 1\)/);
  assert.match(companiesRoute, /Content-Disposition/);
  assert.doesNotMatch(companiesRoute, /X-Exported-Rows/);
  assert.doesNotMatch(companiesRoute, /\.limit\(100\)/);
  assert.match(companyProspectsRoute, /prospect_summaries/);
  assert.match(companyProspectsRoute, /\.range\(from, from \+ pageSize - 1\)/);
  // Sizes now come from the design-system scale rather than literals, so the
  // contract is checked in two halves: the component references the token, and
  // the token resolves to the size the product is specified at.
  assert.match(styles, /html, body[\s\S]*font-size: var\(--text-base\)/);
  assert.match(tokens, /--text-base:\s*\.875rem/);
  assert.match(styles, /\.master-data-table td[\s\S]*font-size: var\(--text-sm\)/);
  assert.match(tokens, /--text-sm:\s*\.875rem/);
  // No raw colour, size, weight or radius may re-enter the component sheet.
  assert.doesNotMatch(styles, /#[0-9a-fA-F]{3,8}\b/);
  assert.doesNotMatch(styles, /font-size:\s*[0-9.]+px/);

  // Every themed token must be redefined in BOTH dark blocks. A token defined
  // in only one of them keeps its light value in the other, which is how a
  // white topbar ends up floating over a dark page.
  const tokenNames = (source) => new Set(
    [...source.matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)].map((match) => match[1]),
  );
  const section = (pattern) => (tokens.match(pattern)?.[1] ?? "");
  const lightPalette = tokenNames(
    tokens.slice(tokens.indexOf(":root {"), tokens.indexOf("@media (prefers-color-scheme: dark)")),
  );
  const systemDark = tokenNames(section(
    /@media \(prefers-color-scheme: dark\) \{\s*:root:not\(\[data-theme="light"\]\) \{([\s\S]*?)\n {2}\}\n\}/,
  ));
  const explicitDark = tokenNames(section(/:root\[data-theme="dark"\] \{([\s\S]*?)\n\}/));
  // The --ds-* ramps are raw scales and are deliberately theme-independent.
  const themed = [...lightPalette].filter((name) => !name.startsWith("--ds-")
    && /(canvas|surface|text-(primary|secondary|tertiary|disabled|inverse)|border-|accent|overlay|scrollbar-thumb|elevation|rgb|veil)/.test(name));
  assert.ok(themed.length > 20, "expected the light palette to define the themed tokens");
  for (const name of themed) {
    assert.ok(systemDark.has(name), `${name} is missing from the prefers-color-scheme dark block`);
    assert.ok(explicitDark.has(name), `${name} is missing from the [data-theme="dark"] block`);
  }

  // The sticky chrome sits over scrolling content and must take its translucent
  // fill from a token, or dark mode shows a white bar over dark content. (The
  // login brand panel is a deliberately dark surface in both themes, so its
  // white-alpha highlights are correct and are not covered here.)
  for (const rule of styles.split("\n").filter((line) => /^\.(topbar|workspace-progress|modal-backdrop|drawer-backdrop)\b/.test(line))) {
    assert.doesNotMatch(rule, /rgba\(\s*255,\s*255,\s*255/, `sticky chrome must not hardcode white: ${rule.slice(0, 80)}`);
  }
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
