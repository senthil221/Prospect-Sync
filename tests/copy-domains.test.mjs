import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

// Copy Domains needs no migration: resolve_company_action_selection_v1 already
// resolves a selection (explicit ids, capped to 50,000; or search/filters,
// full-scan, capped to 250,000) for push/tag/remove, with p_client_id null
// already meaning "the master database" - verified against production before
// this was written. This test pins that the route actually reuses it rather
// than re-deriving the same selection a second way.
test("Copy Domains resolves through the same selection resolver as push/tag/remove, not a new one", async () => {
  const route = await read("../app/api/companies/domains/route.ts");

  assert.match(route, /resolve_company_action_selection_v1/);
  // p_client_id null is what makes the resolver answer for the master database
  // too - it is not a client-only function.
  assert.match(route, /p_client_id: clientId,/);
  assert.match(route, /p_company_ids: ids\.length \? ids : null,/);

  // Deduplicated and blank-free: two companies sharing a domain should not
  // paste twice, and a company with no recorded website contributes nothing.
  assert.match(route, /const domainSet = new Set<string>\(\);/);
  assert.match(route, /if \(domain\) domainSet\.add\(domain\);/);

  // Batched the same way prospects/route.ts already batches its `.in("id", ...)`
  // deletes: an unbatched `.in()` with up to 20,000 ids builds a GET request
  // that blows the proxy's URL/header size limit and fails with a raw
  // "TypeError: fetch failed" instead of a clean response.
  assert.match(route, /for \(let index = 0; index < companyIds\.length; index \+= 500\)/);
  assert.match(route, /const batch = companyIds\.slice\(index, index \+ 500\);/);

  // A cap exists and is honest about being hit, rather than silently returning
  // fewer domains than the selection actually contains.
  assert.match(route, /const maxCopyDomains = 20_000;/);
  assert.match(route, /truncated: companyIds\.length >= maxCopyDomains/);

  // A set id is not authorization: the same guard every other filtered company
  // action makes, run only when the selection is filter-based rather than an
  // explicit id list (an explicit list never touches the filter sets table).
  assert.match(route, /authorizeFilterSets\(supabase, filters, user\?\.id \?\? "", "company"/);
});

test("Copy Domains is available in both the master and a client's Company DB", async () => {
  const source = await read("../app/components/CompaniesWorkspace.tsx");

  // Placed in the bulk-action-group next to See People, outside the
  // canDelete-only branch that Push to Client and the master Delete button
  // live in - so it renders for both scopes, not just the unscoped one.
  const bulkBarStart = source.indexOf('<div className="bulk-bar company-bulk-bar">');
  const canDeleteBranchStart = source.indexOf("{canDelete ? <>", bulkBarStart);
  const copyButton = source.indexOf("Copy Domains", bulkBarStart);
  assert.ok(bulkBarStart > -1 && canDeleteBranchStart > -1 && copyButton > -1, "expected markers not found");
  assert.ok(copyButton < canDeleteBranchStart, "Copy Domains must render before the canDelete-only branch, not inside it");

  // Resolved server-side rather than from whatever rows happen to be loaded on
  // screen, so a selection spanning several pages, or "select all matching",
  // copies every domain it claims to - not just the current page's fifty.
  assert.match(source, /await navigator\.clipboard\.writeText\(result\.domains\.join\("\\n"\)\)/);
  assert.match(source, /\/api\/companies\/domains/);

  // Clipboard access can be blocked by the browser; the failure is caught and
  // surfaces as a message rather than an unhandled rejection.
  const fnStart = source.indexOf("async function copyDomains()");
  const fnBody = source.slice(fnStart, source.indexOf("function requestDeleteSelected", fnStart));
  assert.match(fnBody, /catch \(caught\)/);
  assert.match(fnBody, /Unable to copy domains/);
});
