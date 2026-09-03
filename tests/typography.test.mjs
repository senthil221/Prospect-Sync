import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import "./helpers/tsx-loader.mjs";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const tokens = await read("../app/design-system.css");
const typography = await read("../app/typography.css");
const workspace = await read("../app/workspace.css");

test("type is relative, with a 12px caption floor and 14px working text at the default root", () => {
  const sizes = [...tokens.matchAll(/--text-(2xs|xs|sm|base|md|lg|xl|2xl):\s*([\d.]+)rem/g)];
  assert.equal(sizes.length, 8);
  assert.ok(sizes.every((match) => Number(match[2]) >= .75));
  assert.match(tokens, /--text-base:\s*\.875rem/);
  assert.match(tokens, /--text-xs:\s*\.8125rem/);
  const rootRule = workspace.match(/html, body\s*\{([^}]+)\}/)?.[1];
  assert.ok(rootRule);
  assert.doesNotMatch(rootRule, /font-size:/);
});

test("local Inter retains optical sizing and distinguishes I/l without forcing single-storey a", () => {
  assert.match(workspace, /font-optical-sizing: auto/);
  assert.match(workspace, /font-feature-settings: "cv02", "cv03", "cv04", "cv05", "cv08"/);
  assert.doesNotMatch(workspace, /"cv11"/);
  assert.match(workspace, /button, input, select, textarea \{[^}]*font-feature-settings: inherit/);
  assert.doesNotMatch(workspace, /-webkit-font-smoothing:/);
});

test("readability rules load last and compact text is an explicit user preference", async () => {
  const layout = await read("../app/layout.tsx");
  assert.ok(layout.indexOf('import "./typography.css"') > layout.indexOf('import "./components.css"'));
  assert.match(typography, /:root \{ --table-text-size: var\(--text-base\)/);
  assert.match(typography, /\[data-density="compact"\] \{ --table-text-size: var\(--text-xs\)/);
  assert.match(typography, /\.compact-person \.row-open,[\s\S]*font-size: var\(--table-text-size\)/);
});

test("tables use proportional text and opt into aligned digits only for numeric data", () => {
  assert.match(typography, /table td, \.company-table td, \.master-data-table td \{[^}]*font-variant-numeric: normal/);
  assert.match(typography, /\.numeric-cell[^}]*font-variant-numeric: lining-nums tabular-nums;\s*text-align: right/);
});

test("narrow-screen inputs stay at least 16px and filtering labels may wrap", () => {
  assert.match(typography, /@media \(max-width: 700px\)[\s\S]*font-size: var\(--text-md\)/);
  assert.match(typography, /\.apollo-filter-summary strong \{ font-size: var\(--text-base\); white-space: normal/);
  assert.match(typography, /\.outline-button \{ height: auto/);
  assert.match(typography, /\.apollo-mode-tabs \{ height: auto/);
  assert.match(typography, /\.metric-grid \{ grid-template-columns: repeat\(auto-fit, minmax\(min\(100%, 15rem\), 1fr\)\)/);
});

test("real table rows keep full identity text and mark numerical cells and headers consistently", async () => {
  const { renderTypographyPreview } = await import("./fixtures/typography-preview.tsx");
  const html = renderTypographyPreview();
  assert.match(html, /title="Alexandria Krishnamurthy-Wilson"/);
  assert.match(html, /class="email-cell" title="alexandria.krishnamurthy-wilson@example.org"/);
  assert.match(html, /<th class="numeric-cell">Employees<\/th>/);
  assert.match(html, /<td class="numeric-cell"><span title="1,001–5,000"/);
  assert.match(html, /<td class="numeric-cell"><span class="prospect-count-badge">6,81,085<\/span>/);
  const companies = await read("../app/components/CompaniesWorkspace.tsx");
  const prospects = await read("../app/components/ProspectTable.tsx");
  assert.match(companies, /<th className="numeric-cell">Prospects<\/th><th className="numeric-cell">Client coverage/);
  assert.match(prospects, /<th key=\{field.id\} className=\{field.id === "__employee_count" \? "numeric-cell" : undefined\}/);
});
