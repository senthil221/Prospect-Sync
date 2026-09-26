import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

const allow = process.env.CURSOR_MIGRATION_TEST_ALLOW;
if (allow !== '1') {
  throw new Error('Set CURSOR_MIGRATION_TEST_ALLOW=1 for the empty disposable cursor_migration_test database only.');
}

const url = new URL(process.env.DATABASE_URL ?? '');
const database = decodeURIComponent(url.pathname.slice(1));
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) {
  throw new Error('Cursor migration replay only supports a loopback PostgreSQL target.');
}
if (database !== 'cursor_migration_test' || decodeURIComponent(url.username) !== 'postgres') {
  throw new Error('Cursor migration replay requires postgres@.../cursor_migration_test.');
}
if (decodeURIComponent(url.password) !== 'disposable-ci-only') {
  throw new Error('Cursor migration replay requires the disposable CI password.');
}

const migrationsUrl = new URL('../supabase/migrations/', import.meta.url);
const candidate = '20260926083856_prospect_people_cursor_v1.sql';
const seedBefore = '20260902000260_count_people_exactly.sql';
const migrationFiles = (await readdir(migrationsUrl))
  .filter((name) => /^\d{14}_.+\.sql$/.test(name))
  .sort();

if (!migrationFiles.includes(candidate) || !migrationFiles.includes(seedBefore)) {
  throw new Error('Required cursor or historical seed-point migration is missing.');
}
if (migrationFiles.indexOf(seedBefore) >= migrationFiles.indexOf(candidate)) {
  throw new Error(`Historical fixture seed point ${seedBefore} must precede ${candidate}.`);
}

const candidateSql = await readFile(new URL(candidate, migrationsUrl), 'utf8');
const candidateBoundaryLines = candidateSql
  .split(/\r?\n/u)
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith('--'));
if (candidateBoundaryLines[0]?.toLowerCase() === 'begin;'
    || candidateBoundaryLines.at(-1)?.toLowerCase() === 'commit;') {
  throw new Error(`${candidate} must not own BEGIN/COMMIT; deploy/scripts/migrate.sh owns migration atomicity.`);
}

const psqlEnv = {
  PATH: process.env.PATH,
  LC_ALL: 'C',
  PGHOST: url.hostname === '[::1]' ? '::1' : url.hostname,
  PGPORT: url.port || '5432',
  PGUSER: decodeURIComponent(url.username),
  PGPASSWORD: decodeURIComponent(url.password),
  PGDATABASE: database,
};

function actionEscape(value) {
  return String(value)
    .replaceAll('disposable-ci-only', '[redacted]')
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, 'postgresql://[redacted]@')
    .replaceAll('::', ': :')
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A')
    .slice(0, 700);
}

function firstPsqlError(result) {
  const output = `${result.stderr ?? ''}\n${result.stdout ?? ''}`;
  const errorLine = output.split(/\r?\n/u).find((line) => /\bERROR:/u.test(line));
  if (errorLine) return errorLine.trim();
  if (result.error) return result.error.message;
  return `psql exited with code ${result.status ?? 'unknown'}`;
}

function psql(label, sql, timeout = 330_000) {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {
    input: sql,
    encoding: 'utf8',
    env: psqlEnv,
    timeout,
    maxBuffer: 50 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    process.stderr.write(
      `::error title=Cursor migration replay::${actionEscape(label)}: ${actionEscape(firstPsqlError(result))}\n`,
    );
    process.stdout.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw result.error ?? new Error(`${label} failed with psql exit code ${result.status}.`);
  }
}

const preflight = String.raw`
do $$
begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'refusing database %', current_database();
  end if;
  if exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname not in ('pg_catalog', 'information_schema')
      and n.nspname not like 'pg_toast%'
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
  ) then
    raise exception 'disposable cursor migration database is not empty';
  end if;
  if exists (select 1 from pg_roles where rolname in (
    'anon', 'authenticated', 'service_role', 'authenticator',
    'prospect_importer', 'prospect_import_worker',
    'prospect_operator', 'prospect_ops_worker',
    'prospect_integrator', 'prospect_integration_worker'
  )) then
    raise exception 'synthetic test roles already exist; use a fresh PostgreSQL service';
  end if;
end $$;
`;

psql('disposable database preflight', preflight);
psql(
  'synthetic Supabase role fixture',
  await readFile(new URL('./prospect-cursor-ci-roles.sql', import.meta.url), 'utf8'),
);

const seedSql = await readFile(new URL('./prospect-cursor-history-fixture.sql', import.meta.url), 'utf8');
let seeded = false;
let candidateApplied = false;
for (const file of migrationFiles) {
  if (file === seedBefore) {
    psql('historical cursor data fixture', `begin;\nset local statement_timeout = '60s';\n${seedSql}\ncommit;`);
    seeded = true;
  }
  const sql = await readFile(new URL(file, migrationsUrl), 'utf8');
  process.stdout.write(`${file === candidate ? 'Applying candidate' : 'Replaying'} ${file}\n`);
  psql(file, `begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '5min';\n${sql}\n;\ncommit;`);
  if (file === candidate) candidateApplied = true;
}
if (!seeded) throw new Error(`Historical fixture was not inserted before ${seedBefore}.`);
if (!candidateApplied) throw new Error(`Cursor candidate ${candidate} was not replayed.`);
psql(
  'cursor runtime contract',
  await readFile(new URL('./check-prospect-cursor-migration.sql', import.meta.url), 'utf8'),
);
process.stdout.write('Cursor migration replay and runtime contract passed.\n');
