import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { defaultWorkspaceState, filtersFitInUrl, maxFilterUrlChars, readWorkspaceUrl, writeWorkspaceUrl } from "../lib/workspace-url.ts";

// SHELL-STATE-01: the workspace has to survive a refresh, a Back button and a
// link sent to someone else.

// writeWorkspaceUrl falls back to the current path when nothing needs encoding,
// which is the one place it touches the DOM.
globalThis.window ??= { location: { pathname: "/" } };

const base = {
  ...defaultWorkspaceState,
  section: "prospects",
  search: "  acme  ",
  clientId: "client-1",
  prospectPage: 3,
  sort: "full_name",
  direction: "asc",
  prospectFilters: [{ id: "a", field: "__title", operator: "contains", values: ["manager"] }],
  companyPeopleScope: { search: "hdfc", filters: [], limit: 250000 },
};

const roundTrip = (state) => {
  const url = new URL(writeWorkspaceUrl(state), 'https://example.test/');
  return readWorkspaceUrl(url.searchParams, url.hash);
};

test("the whole workspace survives a round trip through the URL", () => {
  const back = roundTrip(base);
  assert.equal(back.section, "prospects");
  assert.equal(back.search, "acme", "search is trimmed on the way out");
  assert.equal(back.clientId, "client-1");
  assert.equal(back.prospectPage, 3);
  assert.equal(back.sort, "full_name");
  assert.equal(back.direction, "asc");
  assert.equal(back.companyPeopleScope?.search, "hdfc");
  assert.deepEqual(
    back.prospectFilters.map((filter) => [filter.field, filter.operator, filter.values]),
    [["__title", "contains", ["manager"]]],
  );
});

test("an untouched workspace leaves a clean URL", () => {
  // Only what differs from the default is written, so the address bar is not
  // full of parameters nobody set.
  assert.equal(writeWorkspaceUrl(defaultWorkspaceState), "/");
  assert.equal(writeWorkspaceUrl({ ...defaultWorkspaceState, section: "companies" }), "?s=companies");
});

test("a hand-edited or truncated URL cannot break the workspace", () => {
  // A link is user input: pasted into a chat client that clipped it, edited by
  // hand, or produced by an older build. None of that may throw during render.
  const junk = readWorkspaceUrl(new URLSearchParams(
    "s=nonsense&pp=-4&cp=99999999999&sort=" + "x".repeat(500) + "&dir=sideways&pf=not-json&cf=[{]&cscope={{{&pscope=null",
  ));
  assert.equal(junk.section, "overview");
  assert.equal(junk.prospectPage, 1);
  assert.equal(junk.companyPage, 1);
  assert.equal(junk.direction, "desc");
  assert.equal(junk.sort.length, 60, "an overlong sort is clamped, not trusted");
  assert.deepEqual(junk.prospectFilters, []);
  assert.deepEqual(junk.companyFilters, []);
  assert.equal(junk.companyPeopleScope, null);
});

test("large filters survive in the fragment without expanding the HTTP request", () => {
  // 400 pasted domains is a 12.9 KB request line and works; 600 is 19.3 KB and
  // Node answers 431 before any handler runs. So a big list stays out of the
  // URL - and it leaves whole, because half a filter list is a different
  // question and restoring the wrong narrowing is worse than restoring none.
  const many = {
    ...base,
    prospectFilters: [{
      id: "b", field: "__website", operator: "equals",
      values: Array.from({ length: 400 }, (_, index) => `company-${index}.example.com`),
    }],
  };
  const url = writeWorkspaceUrl(many);
  assert.ok(!new URL(url, 'https://example.test').searchParams.has('pf'));
  assert.ok(url.includes('#workspace-v1?pf='));
  assert.deepEqual(roundTrip(many).prospectFilters[0].values, many.prospectFilters[0].values);
  assert.ok(url.includes("s=prospects"), "everything else still restores");
  assert.ok(url.includes("pp=3"));
  assert.equal(filtersFitInUrl(many.prospectFilters), false);
  assert.equal(filtersFitInUrl(base.prospectFilters), true);

  // The boundary is honoured rather than approximate.
  const justUnder = [{ id: "c", field: "__title", operator: "contains", values: ["x".repeat(maxFilterUrlChars - 80)] }];
  assert.equal(filtersFitInUrl(justUnder), true);
});

test('large nested pivots and Unicode survive reload with a bounded HTTP query', () => {
  const filters = [{ id: 'large', field: '__company_keywords', operator: 'contains', values: Array.from({length: 150}, (_, i) => `技術 consulting ${i}`), scopes: ['name', 'description'] }];
  const state = { ...base, companyFilters: filters, companyPeopleScope: { search: '', filters, limit: 250000 } };
  const url = new URL(writeWorkspaceUrl(state), 'https://example.test');
  assert.ok(url.search.length < 6001);
  assert.deepEqual(roundTrip(state).companyFilters[0].values, filters[0].values);
  assert.deepEqual(roundTrip(state).companyPeopleScope.filters[0].values, filters[0].values);
});

test("the app reads the URL once and writes it with the documented history API", async () => {
  const app = await readFile(new URL("../app/DashboardApp.tsx", import.meta.url), "utf8");

  // Read once at mount. Re-reading on every render would fight the writer.
  assert.match(app, /const initial = useMemo\(\(\) => readWorkspaceUrl\(/);
  // Next documents native pushState/replaceState for shallow client routing;
  // it updates the stack without a navigation and stays in sync with
  // useSearchParams.
  assert.match(app, /window\.history\.pushState\(null, "", target\)/);
  assert.match(app, /window\.history\.replaceState\(null, "", target\)/);
  // A section change pushes so Back works; everything else replaces, or the
  // Back button becomes a way to retype what you just typed.
  assert.match(app, /if \(urlState\.section !== lastSection\.current\)/);
  // Back and Forward feed the URL back into state.
  assert.match(app, /addEventListener\("popstate", onPopState\)/);
  assert.match(app, /removeEventListener\("popstate", onPopState\)/);
  // And the writer must not immediately overwrite the entry the browser just
  // restored, which would strand the user on it.
  assert.match(app, /if \(restoring\.current\) \{ restoring\.current = false; return; \}/);

  // The page belongs to each workspace controller, so it is passed as an
  // initial value rather than set from an effect after mount.
  assert.match(app, /initialPage: initial\.prospectPage/);
  assert.match(app, /initialPage: initial\.companyPage/);
});
