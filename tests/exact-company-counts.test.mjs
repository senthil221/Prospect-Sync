import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (relative) => readFile(new URL(relative, import.meta.url), "utf8");
const statementsOnly = (sql) => sql.replace(/^\s*--.*$/gm, "");

const exactCounts = () => read("../supabase/migrations/20260902000200_count_companies_exactly.sql");
const route = () => read("../app/api/companies/route.ts");
const workspace = () => read("../app/components/CompaniesWorkspace.tsx");
const api = () => read("../lib/dashboard-api.ts");

// `limit 50001` is what made a broad filter cheap -- it stopped as soon as it had
// found 50,001 matches. Removing it is the whole point, and it is what makes the
// numbers exact.
test("the counting scan is uncapped, so the totals are exact", async () => {
  const statements = statementsOnly(await exactCounts());

  assert.doesNotMatch(statements, /limit 50001/, "the count cap is what produced \"50,000+\"");
  assert.doesNotMatch(statements, /least\(count\(\*\), 50000\)/);
  // total_capped survives as a column so existing readers keep working, but it
  // can no longer be true.
  assert.match(statements, /false,\s*\n\s*%10\$L::jsonb/);
});

// covered_count and prospect_total were computed over an unordered `limit 50001`,
// so above the cap they described an arbitrary sample. Two identical production
// calls returned covered=24874/prospects=58020 then covered=13365/prospects=34815.
test("covered and prospect_total are counted over the whole match set", async () => {
  const statements = statementsOnly(await exactCounts());

  const counted = statements.slice(statements.indexOf("), counted as ("), statements.indexOf(")\n    select coalesce(("));
  assert.match(counted, /count\(\*\)::integer as total_count/);
  assert.match(counted, /count\(\*\) filter \(where %2\$s > 0\)::integer as covered_count/);
  assert.match(counted, /coalesce\(sum\(%2\$s\), 0\)::integer as prospect_total/);
  assert.doesNotMatch(counted, /limit/, "a LIMIT here is what made these two numbers unstable");
});

// Postgres short-circuits an OR left to right, and the array overlap is the only
// indexed disjunct. It was emitted last, after every ILIKE.
test("the indexed keyword test is the first disjunct, not the last", async () => {
  const statements = statementsOnly(await exactCounts());

  const seeded = statements.match(
    /value_parts := case when keyword_hit <> 'false' then array\[keyword_hit\] else array\[\]::text\[\] end;/g) ?? [];
  assert.equal(seeded.length, 2, "both equals and contains must lead with the indexed test");
  // And it must no longer be appended after the substring chain.
  assert.doesNotMatch(statements, /value_parts := value_parts \|\| keyword_hit;/,
    "appending it last is the ordering this migration removes");
});

// 20260902000190 chooses a shape for a CAPPED count, where the chain exits early
// and wins from 40% of the table up. Counting exactly there is no early exit, so
// the crossover moves: at 65.1% the probe won 32.2s to 37.3s, at 79.9% the chain
// won 6.9s to 12.7s.
test("exact counting uses its own threshold, not the capped one", async () => {
  const statements = statementsOnly(await exactCounts());

  assert.match(statements, /v_broad_fraction constant numeric := 0\.72;/);
  assert.match(statements, /if v_fraction < v_broad_fraction then\s*\n\s*v_counting_clause := v_probe;/);
  // The page never changes shape: it walks the ranking index and stops at fifty.
  assert.match(statements, /v_where := format\('\(%s\)', v_match_clause\) \|\| v_scope_suffix;/);
  assert.match(statements, /v_where_counting := format\('\(%s\)', v_counting_clause\) \|\| v_scope_suffix;/);
});

// An exact count of a quarter-million matches costs real seconds, so it is paid
// once per version vector rather than per request.
test("the count is cached against the version vector, and skipped on a hit", async () => {
  const statements = statementsOnly(await exactCounts());

  // companies.prospect_count is maintained by a trigger on prospect_index, so a
  // prospect import moves covered_count and prospect_total without touching a
  // company row. Keying on company alone would serve stale numbers.
  assert.match(statements, /data_versions_v1\(array\['company', 'prospect'\]\)/);
  assert.match(statements, /v_want_total := p_known_versions is null or p_known_versions <> v_versions;/);
  // On a hit the three numbers come back null and the page is still served.
  assert.match(statements, /case when %9\$s then counted\.total_count end/);
  assert.match(statements, /case when %9\$s then counted\.covered_count end/);
  assert.match(statements, /case when %9\$s then counted\.prospect_total end/);
});

test("the version vector travels end to end", async () => {
  assert.match(await api(), /if \(knownVersions\) params\.set\("knownVersions", JSON\.stringify\(knownVersions\)\);/);
  assert.match(await route(), /p_known_versions: knownVersions,/);
  assert.match(await route(), /versions: summary\?\.data_versions \?\? null,/);
  // Null total means "you already have this one", not "zero companies".
  assert.match(await route(), /total: counted \? Number\(summary\?\.total_count\) : null,/);
});

test("the client caches the count per question, not per page", async () => {
  const source = await workspace();

  assert.match(source, /const countCache = useRef\(new BoundedCache</);
  assert.match(source, /knownVersions: cached\?\.versions \?\? null/);
  // Paging does not change how many rows match, so page 4 reuses page 1's count.
  const key = source.slice(source.indexOf("const countKey = useMemo("), source.indexOf("useEffect(() => {"));
  assert.ok(!/\bpage\b/.test(key), "including page in the key would re-count on every page click");
  assert.match(source, /debouncedSearch\.trim\(\), encodedFilters, peopleScope, refresh/);
});

// The tile said "Counting stopped at 50,000 to keep this fast" and rendered the
// total with a "+". Neither is true any more.
test("the summary tiles stop advertising a cap", async () => {
  const source = await workspace();

  assert.doesNotMatch(source, /Counting stopped at 50,000/);
  assert.doesNotMatch(source, /of the first 50,000/);
  // Coverage is now a real percentage of a real total in every case.
  assert.match(source, /total \? `\$\{Math\.round\(\(covered \/ total\) \* 100\)\}% of companies`/);
});
