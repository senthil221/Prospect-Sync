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
const expected = "20261004004258_inline_client_summary_ctes.sql";
if (migrationNames.at(-1) !== expected) throw new Error(`Expected ${expected} to be the latest migration in this validation chain.`);
const fixture = await readFile(new URL("../supabase/tests/client_summary_inline_parity.sql", import.meta.url), "utf8");

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
    const firstError = output.split(/\r?\n/u).find(line => /\bERROR:/u.test(line))
      ?? result.error?.message ?? `psql exited ${result.status ?? "unknown"}`;
    process.stderr.write(`::error title=Production hardening migration::${safe(label)}: ${safe(firstError)}\n`);
    process.stdout.write(result.stdout ?? "");
    process.stderr.write(result.stderr ?? "");
    throw result.error ?? new Error(`${label} failed.`);
  }
}

psql("disposable baseline preflight", String.raw`
do $$ begin
  if current_database() <> 'cursor_migration_test' then raise exception 'wrong database'; end if;
  if exists(select 1 from public.clients) or exists(select 1 from public.prospects) then
    raise exception 'schema-only baseline unexpectedly contains rows';
  end if;
end $$;`);

for (const name of migrationNames) {
  const sql = await readFile(new URL(name, migrationDir), "utf8");
  const meaningful = sql.split(/\r?\n/u).map(line => line.trim()).filter(line => line && !line.startsWith("--"));
  if (meaningful[0]?.toLowerCase() === "begin;" || meaningful.at(-1)?.toLowerCase() === "commit;") {
    throw new Error(`${name} must not own its transaction.`);
  }
  psql(name, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${sql}\ncommit;`);
}

psql("client-summary SEG, incomplete and transition parity", `begin; set local statement_timeout='2min';\n${fixture}\nrollback;`);
process.stdout.write(`Applied ${migrationNames.length} additive migrations and passed client-summary parity.\n`);
