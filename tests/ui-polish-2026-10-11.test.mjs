import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// 2026-10-11: the blocklist filters and the ICP picker are styled listboxes,
// never native <select>s, and say what they filter once chosen.
test("the blocklist filters and the ICP picker use ListboxPicker", async () => {
  const blocklist = await read("../app/components/BlocklistPanel.tsx");
  assert.match(blocklist, /<ListboxPicker label="Filter blocklist type"/);
  assert.doesNotMatch(blocklist, /<select aria-label="Filter blocklist/);
  const clients = await read("../app/components/ClientsPanel.tsx");
  assert.match(clients, /placeholder="Filter by ICP"\s+prefix="ICP"/);
  assert.match(clients, /label: "No ICP tag"/);
  // Clearing the picker shows the whole People DB, never an empty panel.
  assert.match(clients, /setTab\(next \? "by_icp" : tab === "by_icp" \? "prospects" : tab\)/);
});

// "No domain not fit" companies are blocked by their people's email domain.
test("a domain-less NON_FIT company is blocklisted by its people's email domain", async () => {
  const sql = await read("../supabase/migrations/20261011090000_no_domain_not_fit_blocks_the_email_domain.sql");
  assert.match(sql, /create or replace function public\.company_block_domain_v1\(p_company_id text\)/);
  // Free mail never counts, and two business domains are ambiguous.
  assert.match(sql, /not public\.is_free_email_domain_v1\(e\.domain\)\s+having count\(\*\) = 1/);
  assert.match(sql, /revoke execute on function public\.company_block_domain_v1\(text\) from public, anon, authenticated;/);
  assert.match(sql, /'domain', public\.company_block_domain_v1\(c\.id\)\)/);
  // A domain a verified company holds is never blocked.
  assert.match(sql, /where vc\.normalized_domain = r->>'domain'/);
  // The tab keeps only companies with nothing to block, in all four paths.
  assert.equal(sql.match(/company_block_domain_v1\((?:pi\.company_id|\(p_row\)\.company_id|c\.id|\(p_row\)\.id)\) = ''/g).length, 4);
  assert.match(sql, /No domain proof passed/);
});

// The app-wide audit of 2026-10-11.
test("no native <select> is left in the signed-in app", async () => {
  const { readdir } = await import("node:fs/promises");
  const files = [];
  async function walk(dir) {
    for (const entry of await readdir(new URL(dir, import.meta.url), { withFileTypes: true })) {
      const path = `${dir}/${entry.name}`;
      if (entry.isDirectory()) { if (!["e2e-fixtures", "blocklist"].includes(entry.name)) await walk(path); }
      else if (path.endsWith(".tsx")) files.push(path);
    }
  }
  await walk("../app");
  // Attributes, not prose: comments still talk about "a native <select>".
  for (const file of files) assert.doesNotMatch(await read(file), /<select\s+(?:aria-|value|id|className|defaultValue|onChange|disabled|required)/, file);
  // The drop-in keeps the native handler shape, so callers did not change.
  assert.match(await read("../app/components/ListboxPicker.tsx"), /onChange\?\.\(\{ target: \{ value: next \} \}\)/);
});

test("the table pages lead with data: no marketing headings, one bar of controls", async () => {
  const [people, companies, clients, overview, css] = await Promise.all([
    read("../app/components/ProspectTable.tsx"), read("../app/components/CompaniesWorkspace.tsx"),
    read("../app/components/ClientsPanel.tsx"), read("../app/components/OverviewWorkspace.tsx"), read("../app/workspace.css"),
  ]);
  assert.doesNotMatch(people, /<h2>Find people<\/h2>/);
  assert.doesNotMatch(companies, /Companies already in your database/);
  assert.doesNotMatch(clients, /CLIENT MASTER DB|CLIENT COMPANY DB|Keep every ICP list organized/);
  assert.doesNotMatch(overview, /All your prospects, organized in one place/);
  assert.match(people, /<ProspectTable|toolbarExtra \? <div className="view-bar-extra">\{toolbarExtra\}<\/div>/);
  assert.match(clients, /<ProspectTable toolbarExtra=\{</);
  assert.match(clients, /<CompanyTable toolbarExtra=\{</);
  // No width cap on the data pages.
  assert.match(css, /^\.content \{ width: 100%; max-width: none;/m);
});
