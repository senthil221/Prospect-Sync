import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";

if (process.env.INCOMPLETE_INFO_MIGRATION_TEST_ALLOW !== "1") {
  throw new Error("Set INCOMPLETE_INFO_MIGRATION_TEST_ALLOW=1 only for the disposable cursor_migration_test database.");
}
const url = new URL(process.env.DATABASE_URL ?? "");
const database = decodeURIComponent(url.pathname.slice(1));
if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    || database !== "cursor_migration_test"
    || decodeURIComponent(url.username) !== "postgres"
    || decodeURIComponent(url.password) !== "disposable-ci-only") {
  throw new Error("Incomplete-info migration validation requires postgres with the disposable CI password on loopback cursor_migration_test.");
}

const prerequisiteName = "20260926190000_company_blank_filters_read_an_index.sql";
const migrationName = "20260929120000_segregate_incomplete_client_records.sql";
const [prerequisite, migration, fixture] = await Promise.all([
  readFile(new URL(`../supabase/migrations/${prerequisiteName}`, import.meta.url), "utf8"),
  readFile(new URL(`../supabase/migrations/${migrationName}`, import.meta.url), "utf8"),
  readFile(new URL("../supabase/tests/incomplete_info_segregation.sql", import.meta.url), "utf8"),
]);

for (const [name, sql] of [[prerequisiteName, prerequisite], [migrationName, migration]]) {
  const meaningful = sql.split(/\r?\n/u).map((line) => line.trim()).filter((line) => line && !line.startsWith("--"));
  if (meaningful[0]?.toLowerCase() === "begin;" || meaningful.at(-1)?.toLowerCase() === "commit;") {
    throw new Error(`${name} must not own its transaction.`);
  }
}

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
  return String(value)
    .replaceAll("disposable-ci-only", "[redacted]")
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, "postgresql://[redacted]@")
    .replaceAll("::", ": :")
    .replaceAll("%", "%25")
    .replaceAll("\r", "%0D")
    .replaceAll("\n", "%0A")
    .slice(0, 700);
}

function psql(label, sql, timeout = 330_000) {
  const result = spawnSync("psql", ["-X", "-q", "-v", "ON_ERROR_STOP=1"], {
    input: sql,
    encoding: "utf8",
    env: psqlEnv,
    timeout,
    maxBuffer: 100 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    const output = `${result.stderr ?? ""}\n${result.stdout ?? ""}`;
    const firstError = output.split(/\r?\n/u).find((line) => /\bERROR:/u.test(line))
      ?? result.error?.message ?? `psql exited ${result.status ?? "unknown"}`;
    process.stderr.write(`::error title=Incomplete Info migration::${safe(label)}: ${safe(firstError)}\n`);
    process.stdout.write(result.stdout ?? "");
    process.stderr.write(result.stderr ?? "");
    throw result.error ?? new Error(`${label} failed.`);
  }
}

psql("reviewed baseline preflight", String.raw`
do $$
begin
  if current_database() <> 'cursor_migration_test' then raise exception 'wrong database'; end if;
  if to_regprocedure('public.search_prospect_workspace_v13(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)') is null
     or to_regprocedure('public.company_effective_filter_sql_v1(text,jsonb)') is null
     or to_regprocedure('public.push_prospects_to_client_v2(text,text,jsonb,text,text[],text[],text,text)') is null then
    raise exception 'reviewed schema baseline is missing required client workspace functions';
  end if;
  if exists (select 1 from public.clients where id like 'segregation-%') then
    raise exception 'incomplete-info fixture ids already exist';
  end if;
end $$;
`);

// The reviewed schema snapshot predates the immutable keyword wrapper used by
// this migration. Apply that one chronological prerequisite exactly as deploy
// will before testing the candidate itself.
psql(prerequisiteName, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${prerequisite}\ncommit;`);

// First prove the candidate is transaction-safe, then apply it for behavior.
psql(`${migrationName} rollback`, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${migration}\nrollback;`);
psql(migrationName, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${migration}\ncommit;`);

psql("least-privilege and one-pass summary contract", String.raw`
do $$
declare v_view text := pg_get_viewdef('public.client_summaries'::regclass, true);
begin
  if has_function_privilege('anon', 'public.set_icp_verified_v1(text,boolean,text,jsonb,text[],text[],text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.set_company_icp_verified_v2(text,boolean,text[],text,jsonb,jsonb,text[],text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.set_icp_verified_v1(text,boolean,text,jsonb,text[],text[],text)', 'EXECUTE') then
    raise exception 'ICP mutation grants widened or service execution was lost';
  end if;
  if position('people_counts AS' in v_view) = 0 or position('company_counts AS' in v_view) = 0 then
    raise exception 'client_summaries lost its one-pass aggregate plan: %', v_view;
  end if;
end $$;
`);

psql("push, disjoint-union, and enrichment behavior", `begin; set local statement_timeout='5min';\n${fixture}\nrollback;`);
process.stdout.write("Incomplete Info migration rollback, grants, partition, push and enrichment contracts passed.\n");
