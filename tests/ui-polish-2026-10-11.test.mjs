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
