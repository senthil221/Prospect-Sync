import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

if (process.env.HISTORY_MIGRATION_DIAGNOSTIC_ALLOW !== '1') {
  throw new Error('Set HISTORY_MIGRATION_DIAGNOSTIC_ALLOW=1 only for the disposable history_migration_diagnostic database.');
}
const url = new URL(process.env.DATABASE_URL ?? '');
const database = decodeURIComponent(url.pathname.slice(1));
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
    || database !== 'history_migration_diagnostic'
    || decodeURIComponent(url.username) !== 'postgres'
    || decodeURIComponent(url.password) !== 'disposable-ci-only') {
  throw new Error('Historical diagnostic requires the exact loopback disposable PostgreSQL target.');
}

const env = {
  PATH: process.env.PATH,
  LC_ALL: 'C',
  PGHOST: url.hostname === '[::1]' ? '::1' : url.hostname,
  PGPORT: url.port || '5432',
  PGUSER: 'postgres',
  PGPASSWORD: 'disposable-ci-only',
  PGDATABASE: database,
};
const migrationsUrl = new URL('../supabase/migrations/', import.meta.url);
const files = (await readdir(migrationsUrl))
  .filter((name) => /^\d{14}_.+\.sql$/u.test(name))
  .sort();

function sanitize(value) {
  return String(value)
    .replaceAll('disposable-ci-only', '[redacted]')
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, 'postgresql://[redacted]@')
    .replaceAll('::', ': :')
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A')
    .slice(0, 700);
}

function run(label, sql) {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {
    input: sql,
    encoding: 'utf8',
    env,
    timeout: 330_000,
    maxBuffer: 50 * 1024 * 1024,
  });
  if (!result.error && result.status === 0) return;
  const output = `${result.stderr ?? ''}\n${result.stdout ?? ''}`;
  const firstError = output.split(/\r?\n/u).find((line) => /\bERROR:/u.test(line))
    ?? result.error?.message
    ?? `psql exited with code ${result.status ?? 'unknown'}`;
  process.stderr.write(`::error title=Historical migration diagnostic::${sanitize(label)}: ${sanitize(firstError)}\n`);
  throw result.error ?? new Error(`${label} failed.`);
}

run('disposable database preflight', String.raw`
do $$
begin
  if current_database() <> 'history_migration_diagnostic' then
    raise exception 'refusing database %', current_database();
  end if;
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname not in ('pg_catalog', 'information_schema')
      and n.nspname not like 'pg_toast%'
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
  ) or exists (select 1 from pg_roles where rolname in (
    'anon', 'authenticated', 'service_role', 'authenticator',
    'prospect_importer', 'prospect_import_worker',
    'prospect_operator', 'prospect_ops_worker',
    'prospect_integrator', 'prospect_integration_worker'
  )) then
    raise exception 'historical diagnostic requires a fresh disposable database';
  end if;
end $$;
`);
run('synthetic role fixture', await readFile(new URL('./prospect-cursor-ci-roles.sql', import.meta.url), 'utf8'));
run('synthetic migration ledger', String.raw`
create schema supabase_migrations;
create table supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
`);
for (const file of files) {
  const sql = await readFile(new URL(file, migrationsUrl), 'utf8');
  const version = file.slice(0, 14);
  const name = file.slice(15, -4);
  process.stdout.write(`Replaying unchanged ${file}\n`);
  run(file, `begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '5min';\n${sql}\n;\ninsert into supabase_migrations.schema_migrations (version, name) values ('${version}', '${name.replaceAll("'", "''")}');\ncommit;`);
}
process.stdout.write(`All ${files.length} historical migrations replayed unchanged.\n`);
