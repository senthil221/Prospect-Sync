import { readdir, readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

if (process.env.PRODUCTION_HARDENING_MIGRATION_TEST_ALLOW !== "1") {
  throw new Error("Set PRODUCTION_HARDENING_MIGRATION_TEST_ALLOW=1 only for the disposable cursor_migration_test database.");
}
const url = new URL(process.env.DATABASE_URL ?? "");
const database = decodeURIComponent(url.pathname.slice(1));
if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    || database !== "cursor_migration_test"
    || decodeURIComponent(url.username) !== "postgres"
    || decodeURIComponent(url.password) !== "disposable-ci-only") {
  throw new Error("Production-hardening migration validation requires the disposable loopback PostgreSQL fixture.");
}

const migrationDir = new URL("../supabase/migrations/", import.meta.url);
const migrationNames = (await readdir(migrationDir))
  .filter(name => /^\d+_.+\.sql$/u.test(name) && name > "20260926083856_prospect_people_cursor_v1.sql")
  .sort();
const expected = "20261005204655_client_people_page_first.sql";
if (!migrationNames.includes(expected)) throw new Error(`Expected ${expected} in the forward validation chain.`);
const fixture = await readFile(new URL("../supabase/tests/client_summary_inline_parity.sql", import.meta.url), "utf8");
const clientCompanyFixture = await readFile(new URL("../supabase/tests/client_company_scope_parity.sql", import.meta.url), "utf8");
const storedCountAuthorityFixture = await readFile(new URL("../supabase/tests/client_company_stored_count_authority.sql", import.meta.url), "utf8");
const cappedCompanyFixture = await readFile(new URL("../supabase/tests/client_company_capped_pagination.sql", import.meta.url), "utf8");
const scopedClientSummaryFixture = await readFile(new URL("../supabase/tests/client_summary_scoped_cache.sql", import.meta.url), "utf8");
const peopleCompanyKeywordFixture = await readFile(new URL("../supabase/tests/people_company_keyword_index_parity.sql", import.meta.url), "utf8");
const mxRetrySaturationFixture = await readFile(new URL("../supabase/tests/mx_retry_saturated_backlog.sql", import.meta.url), "utf8");
const clientPeopleCursorFixture = await readFile(new URL("../supabase/tests/client_people_cursor_v2.sql", import.meta.url), "utf8");
const clientPeoplePageFixture = await readFile(new URL("../supabase/tests/client_people_page_first.sql", import.meta.url), "utf8");

const psqlEnv = {
  PATH: process.env.PATH,
  LC_ALL: "C",
  PGHOST: url.hostname === "[::1]" ? "::1" : url.hostname,
  PGPORT: url.port || "5432",
  PGUSER: decodeURIComponent(url.username),
  PGPASSWORD: decodeURIComponent(url.password),
  PGDATABASE: database,
};
function safe(value) {
  return String(value).replaceAll("disposable-ci-only", "[redacted]")
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, "postgresql://[redacted]@")
    .replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A").slice(0, 800);
}
function psql(label, sql, timeout = 330_000) {
  const result = spawnSync("psql", ["-X", "-q", "-v", "ON_ERROR_STOP=1"], {
    input: sql, encoding: "utf8", env: psqlEnv, timeout, maxBuffer: 100 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const output = `${result.stderr ?? ""}\n${result.stdout ?? ""}`;
    const lines = output.split(/\r?\n/u);
    const errorIndex = lines.findIndex(line => /\bERROR:/u.test(line));
    const diagnostic = errorIndex >= 0
      ? lines.slice(errorIndex, errorIndex + 12).filter(Boolean).join(" | ")
      : result.error?.message ?? `psql exited ${result.status ?? "unknown"}`;
    process.stderr.write(`::error title=Production hardening migration::${safe(label)}: ${safe(diagnostic)}\n`);
    process.stdout.write(result.stdout ?? "");
    process.stderr.write(result.stderr ?? "");
    throw result.error ?? new Error(`${label} failed.`);
  }
}

psql("disposable baseline preflight", String.raw`
do $$ begin
  if current_database() <> 'cursor_migration_test' then raise exception 'wrong database'; end if;
  -- The cursor contract immediately before this job intentionally commits its
  -- deterministic fixture. Accept that exact state, but fail closed if any
  -- unrelated/customer-shaped row is present. Nothing is deleted here.
  if (select count(*) from public.clients) <> 2
     or exists(select 1 from public.clients where id not in ('cursor-client-a', 'cursor-client-b'))
     or (select count(*) from public.companies) <> 3
     or exists(select 1 from public.companies where id not in ('cursor-company-complete', 'cursor-company-incomplete', 'cursor-company-b'))
     or (select count(*) from public.prospects) <> 151
     or exists(select 1 from public.prospects where id not like 'cursor-fixture-%')
     or (select count(*) from public.prospect_index) <> 151
     or exists(select 1 from public.prospect_index where id not like 'cursor-fixture-%')
     or (select count(*) from public.lists) <> 3
     or exists(select 1 from public.lists where id not in ('cursor-list-a', 'cursor-list-a-secondary', 'cursor-list-b'))
     or (select count(*) from public.imports) <> 3
     or exists(select 1 from public.imports where id not in ('cursor-import-a', 'cursor-import-a-secondary', 'cursor-import-b'))
     or (select count(*) from public.client_prospects) <> 151
     or exists(select 1 from public.client_prospects where client_id not in ('cursor-client-a', 'cursor-client-b') or prospect_id not like 'cursor-fixture-%')
     or (select count(*) from public.list_memberships) <> 132
     or exists(select 1 from public.list_memberships where list_id not in ('cursor-list-a', 'cursor-list-a-secondary', 'cursor-list-b') or prospect_id not like 'cursor-fixture-%') then
    raise exception 'cursor baseline differs from the reviewed deterministic fixture';
  end if;
end $$;`);

psql("bounded synthetic scale fixture", String.raw`
insert into public.prospects(id, full_name, work_email, all_data, created_at, updated_at)
select
  'hardening-scale-' || lpad(n::text, 4, '0'),
  'Hardening Scale ' || n,
  'hardening-scale-' || n || '@example.test',
  jsonb_build_object('fixture', 'production-hardening-ci', 'ordinal', n),
  '2025-01-01 00:00:00+00'::timestamptz + make_interval(secs => n),
  '2025-01-01 00:00:00+00'::timestamptz + make_interval(secs => n)
from generate_series(1, 1049) n;

select public.reindex_prospects(array_agg(id order by id))
from public.prospects
where id like 'hardening-scale-%';

do $$ begin
  if (select count(*) from public.prospects) <> 1200
     or (select count(*) from public.prospect_index) <> 1200
     or (select count(*) from public.prospects where id like 'hardening-scale-%') <> 1049
     or (select count(*) from public.prospect_index where id like 'hardening-scale-%') <> 1049 then
    raise exception 'bounded scale fixture did not produce exactly 1,200 canonical and projected rows';
  end if;
end $$;`);

for (const name of migrationNames) {
  let sql = await readFile(new URL(name, migrationDir), "utf8");
  if (name === "20260926150000_indexes_are_reachable_and_background_work_waits.sql") {
    // This historical migration ends with a live-data smoke at row 200,000.
    // The reviewed disposable cursor fixture deliberately has 151 rows. Adapt
    // only the two smoke offsets; all DDL and function bodies replay verbatim.
    const smokeOffsets = [
      ["offset 200000 limit 1", "offset 100 limit 1"],
      ["offset 200001 limit 50", "offset 101 limit 50"],
    ];
    for (const [anchor, replacement] of smokeOffsets) {
      if (sql.split(anchor).length !== 2) {
        throw new Error(`${name} cursor smoke anchor changed: ${anchor}`);
      }
      sql = sql.replace(anchor, replacement);
    }
  }
  const meaningful = sql.split(/\r?\n/u).map(line => line.trim()).filter(line => line && !line.startsWith("--"));
  if (meaningful[0]?.toLowerCase() === "begin;" || meaningful.at(-1)?.toLowerCase() === "commit;") {
    throw new Error(`${name} must not own its transaction.`);
  }
  psql(name, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${sql}\ncommit;`);
}

psql("client company listing, stream, pivot and selection parity", `begin; set local statement_timeout='2min';\n${clientCompanyFixture}\nrollback;`);
psql("client company stored-count write-path authority", `begin; set local statement_timeout='2min';\n${storedCountAuthorityFixture}\nrollback;`);
psql("client company capped pagination and complete export", `begin; set local statement_timeout='5min';\n${cappedCompanyFixture}\nrollback;`, 330_000);
psql("client-summary SEG, incomplete and transition parity", `begin; set local statement_timeout='2min';\n${fixture}\nrollback;`);
psql("client-summary scoped cache miss and mutation parity", `begin; set local statement_timeout='2min';\n${scopedClientSummaryFixture}\nrollback;`);
psql("People company-keyword indexed predicate full-ID parity", `begin; set local statement_timeout='2min';\n${peopleCompanyKeywordFixture}\nrollback;`);
psql("MX retry selection with a saturated fresh backlog", `begin; set local statement_timeout='2min';\n${mxRetrySaturationFixture}\nrollback;`);
psql("client People cursor v2 ordered IDs and capped-count parity", `begin; set local statement_timeout='5min';\n${clientPeopleCursorFixture}\nrollback;`);
psql("client People page v1 count-free ordered-ID parity", `begin; set local statement_timeout='2min';\n${clientPeoplePageFixture}\nrollback;`);
process.stdout.write(`Applied ${migrationNames.length} additive migrations and passed client company, scoped-summary, company-keyword, MX retry, client People cursor and page-first parity.\n`);
