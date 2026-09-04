import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// 20260902000260: the People count stops being bounded, and the number it
// produces is animated on its way onto the screen. The pair belongs in one file
// because they are one change to the person reading it - the figure in the
// header is now worth watching arrive, because it is now true.

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migration = () => read("../supabase/migrations/20260902000260_count_people_exactly.sql");
// The header explains the old shape by naming it, so "is it gone" has to be
// asked of the executable SQL rather than of the whole file.
const executable = (sql) => sql.split("\n").filter((line) => !line.trimStart().startsWith("--")).join("\n");

test("the counting scan has no ceiling left in it", async () => {
  const sql = executable(await migration());

  // The three things that made a total a floor rather than a number.
  assert.doesNotMatch(sql, /v_count_cap/);
  assert.doesNotMatch(sql, /\) capped/);
  assert.doesNotMatch(sql, /least\(counted\.matched_rows/);

  // What replaced them: one unbounded count over the same predicate.
  assert.match(sql, /select count\(\*\)::bigint as matched_rows\s*\n\s*from public\.prospect_index pi%s/);
  assert.match(sql, /v_total_expr := '\(select counted\.matched_rows from counted\)';/);

  // The whole-database total is counted rather than read off the planner's
  // estimate, which was 219 rows wrong on the day this was measured.
  assert.doesNotMatch(sql, /pg_class\.reltuples/);
  assert.match(sql, /v_total_expr := '\(select count\(\*\)::bigint from public\.prospect_index\)';/);

  // total_capped survives in the result type and is permanently false, so the
  // wire shape is unchanged and a future cap has somewhere to be reported.
  assert.match(sql, /RETURNS TABLE\(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean, data_versions jsonb\)/);
  assert.equal(sql.match(/v_total_capped_expr := 'false';/g)?.length, 3);
});

test("the migration keeps its grants, its measurements and its assertions", async () => {
  const sql = await migration();

  // CREATE OR REPLACE preserves grants, but the SECURITY DEFINER check in CI
  // wants them stated, and stating them costs nothing.
  assert.match(sql, /revoke execute on function public\.search_prospect_workspace_v12\(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb\) from public, anon, authenticated;/);
  assert.match(sql, /grant execute on function public\.search_prospect_workspace_v12\(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb\) to service_role;/);

  // Why this was affordable here when the company side needed a plan chooser to
  // earn it: measured, per shape, in the header rather than argued in prose.
  assert.match(sql, /681,085/);
  assert.match(sql, /527,248/);
  assert.match(sql, /5\.96 s is company_scope_ids_v2/);

  // And the numbers are checked against real rows at deploy time rather than
  // only compiled. A count rewrite that emptied the page would pass a dry run.
  assert.match(sql, /do \$assert\$/);
  assert.match(sql, /unscoped total %s <> actual %s/);
  assert.match(sql, /the page returned no rows alongside a non-zero total/);
  // array_cat, not array_append, is the trap that makes the safety net report a
  // parse error instead of the problem it found.
  assert.match(sql, /array_append\(v_problems/);
  assert.doesNotMatch(sql, /v_problems := v_problems \|\| '/);
});

test("no surface still describes a People total as bounded or approximate", async () => {
  const [route, table] = await Promise.all([
    read("../app/api/prospects/route.ts"),
    read("../app/components/ProspectTable.tsx"),
  ]);

  // The API stops computing an estimate flag it can no longer earn.
  assert.match(route, /totalEstimated: false,/);
  assert.doesNotMatch(route, /const totalEstimated = withTotal/);
  // The capped flag still comes through, because the column still exists.
  assert.match(route, /totalCapped: summary\.total_capped === true/);

  // The grid no longer offers to explain an estimate that cannot happen.
  assert.doesNotMatch(table, /Approximate: the whole-database total/);
  assert.match(table, /Exact count of the records matching this search and these filters\./);
  // A "+" can still be rendered, and still comes only from total_capped.
  assert.match(table, /const totalSuffix = countedExactly === null && totalCapped \? "\+" : "";/);
});

test("counts arrive by counting, without being announced", async () => {
  const [countUp, overview] = await Promise.all([
    read("../app/components/CountUp.tsx"),
    read("../app/components/OverviewWorkspace.tsx"),
  ]);

  // Reduced motion is honoured by not animating at all rather than by animating
  // quickly: a CSS duration override cannot reach a requestAnimationFrame loop.
  assert.match(countUp, /prefers-reduced-motion: reduce/);
  assert.match(countUp, /if \(from === target \|\| !enabled \|\| prefersReducedMotion\(\)\)/);

  // The server renders the settled number, so a no-JS render and the first
  // paint are both correct; the rewind happens before the browser paints.
  assert.match(countUp, /useState\(target\)/);
  assert.match(countUp, /typeof window === "undefined" \? useEffect : useLayoutEffect/);

  // Never a live region: these are static spans, and a screen reader must not
  // be read every frame between 0 and 681,085.
  assert.doesNotMatch(countUp, /aria-live/);
  assert.doesNotMatch(countUp, /role="status"/);

  // The frame loop is cancelled, so a total that changes twice does not leave
  // two loops fighting over the same number.
  assert.match(countUp, /return \(\) => cancelAnimationFrame\(frameRef\.current\);/);

  // Wired to the Overview figures, and every one of them takes the same
  // decision about whether this particular render is animating.
  assert.match(overview, /<strong><CountUp value=\{card\.value\} enabled=\{countUp\}\/><\/strong>/);
  assert.equal(overview.match(/<CountUp value=\{[^}]+\} enabled=\{countUp\}\/>/g)?.length, 5);
});

test("the Overview counts up once per run, and nowhere else counts at all", async () => {
  const [overview, styles, table, companies, tabs] = await Promise.all([
    read("../app/components/OverviewWorkspace.tsx"),
    read("../app/workspace.css"),
    read("../app/components/ProspectTable.tsx"),
    read("../app/components/CompaniesWorkspace.tsx"),
    read("../app/components/Tabs.tsx"),
  ]);

  // Module scope, not component state. Navigating to People and back UNMOUNTS
  // this page, so state would be gone by the time the question is asked and
  // every visit would re-run the animation.
  assert.match(overview, /^let countsHavePlayed = false;$/m);
  assert.match(overview, /const \[countUp\] = useState\(\(\) => !countsHavePlayed\);/);
  // A screen of zeroes does not count as having played: stats arrive after the
  // first paint, and marking it done then would spend the animation on nothing.
  assert.match(overview, /const hasNumbers = stats\.prospects > 0 \|\| stats\.companies > 0 \|\| stats\.rowsImported > 0;/);
  assert.match(overview, /useEffect\(\(\) => \{ if \(hasNumbers\) countsHavePlayed = true; \}, \[hasNumbers\]\);/);

  // The staggered entrance and the filling bar answer to the same flag, so the
  // page does not re-choreograph itself every time you glance at it.
  assert.match(overview, /metric-grid\$\{countUp \? " counts-arriving" : ""\}/);
  assert.match(overview, /panel coverage\$\{countUp \? " counts-arriving" : ""\}/);
  assert.match(styles, /\.metric-grid\.counts-arriving \.metric-card \{ animation: ph-rise/);
  assert.match(styles, /\.coverage\.counts-arriving \.coverage-track i \{ animation: ph-fill/);

  // Overview only. Everywhere else the number is something you work against -
  // re-read after every filter change, checked against a selection, compared to
  // an export - and one that has to finish moving before it can be read is an
  // obstacle rather than a flourish.
  assert.doesNotMatch(table, /CountUp/);
  assert.doesNotMatch(companies, /CountUp/);
  assert.doesNotMatch(styles, /\.company-summary > div \{ animation/);
  assert.match(table, /<strong title=\{totalHint\}>\{displayedTotal\} people<\/strong>/);
  assert.match(companies, /<strong>\{totalLabel\}<\/strong>/);
  // And the tab badge goes back to accepting only what it needs.
  assert.match(tabs, /count\?: number \| string;/);
});

test("a filter can be cleared one at a time, or all at once", async () => {
  const [panel, styles, dashboard] = await Promise.all([
    read("../app/ApolloFilterPanel.tsx"),
    read("../app/workspace.css"),
    read("../app/DashboardApp.tsx"),
  ]);

  // Clearing one field no longer requires expanding it first. The control is a
  // sibling of the disclosure button, because a button inside a button is
  // markup the browser is entitled to resolve however it likes.
  assert.match(panel, /className="apollo-filter-head"/);
  assert.match(panel, /className="apollo-filter-clear"/);
  assert.match(panel, /aria-label=\{`Clear the \$\{definition\.label\} filter`\}/);
  assert.match(styles, /\.apollo-filter-head \{ display: flex;/);

  // And the panel head says how many there are to clear, so "clear all" is a
  // decision rather than a guess.
  assert.match(panel, /Clear all \{fieldsInUse\}/);
  assert.match(panel, /\$\{fieldsInUse\} filter\$\{fieldsInUse === 1 \? "" : "s"\} applied/);

  // A query that failed carries its own way out, in the message that reports it.
  assert.match(dashboard, /className="alert-reset"/);
  assert.match(dashboard, /Clear filters and start over/);
  assert.match(dashboard, /const canResetQuery = Boolean\(narrowedQuery\.filters\.length \|\| narrowedQuery\.scope \|\| search\.trim\(\)\)/);
  // Clearing the filters alone would leave a 250,000-company pivot in place,
  // which is usually the expensive half of the query that just failed.
  assert.match(dashboard, /setCompanyPeopleScope\(null\); setProspectPage\(1\);/);
});
