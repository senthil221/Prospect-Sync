import { readdir, readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

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
const candidateSignature = 'public.search_prospect_workspace_cursor_v1(text,jsonb,integer,text,timestamp with time zone,text,boolean,jsonb)';
const seedBefore = '20260902000260_count_people_exactly.sql';
const compatibilityTarget = '20260825070000_company_location_filter.sql';
const compatibilityForwardFix = '20260825103139_fix_company_location_import_drift.sql';
const reviewedHistoryHashes = new Map([
  ['20260816013930_resumable_import_cursors.sql', '2c1edbfdfa6eb204338c4922041fdfcd4de12d14b85f17d94e37a6d2ab38fdc6'],
  [compatibilityTarget, '5d1a6aecfb189f95fd5987d9e31b142fdc3559fc57a09fc312a772a071766c96'],
  [compatibilityForwardFix, '564d2cd92ab53e07a9e7b4effb7d7f1b2b3d9bb2ea1caca2addca35d1abce3f4'],
]);
const migrationFiles = (await readdir(migrationsUrl))
  .filter((name) => /^\d{14}_.+\.sql$/.test(name))
  .sort();

if (!migrationFiles.includes(candidate) || !migrationFiles.includes(seedBefore)) {
  throw new Error('Required cursor or historical seed-point migration is missing.');
}
if (migrationFiles.indexOf(seedBefore) >= migrationFiles.indexOf(candidate)) {
  throw new Error(`Historical fixture seed point ${seedBefore} must precede ${candidate}.`);
}
if (migrationFiles.indexOf(compatibilityTarget) >= migrationFiles.indexOf(compatibilityForwardFix)) {
  throw new Error('Reviewed company-import compatibility migrations are missing or out of order.');
}

for (const [file, expectedHash] of reviewedHistoryHashes) {
  const sql = await readFile(new URL(file, migrationsUrl), 'utf8');
  const normalizedSql = sql.replaceAll('\r\n', '\n');
  const actualHash = createHash('sha256').update(normalizedSql, 'utf8').digest('hex');
  if (actualHash !== expectedHash) {
    throw new Error(`${file} changed after the CI compatibility exception was reviewed.`);
  }
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

function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

function candidateAbsentContract(label) {
  return String.raw`
do $candidate_absent$
begin
  if pg_catalog.to_regprocedure(${sqlLiteral(candidateSignature)}) is not null then
    raise exception '${label}: cursor RPC exists';
  end if;
  if exists (
    select 1 from supabase_migrations.schema_migrations
    where version = ${sqlLiteral(candidate.slice(0, 14))}
  ) then
    raise exception '${label}: cursor migration ledger entry exists';
  end if;
end
$candidate_absent$;
`;
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
psql('synthetic migration ledger', String.raw`
create schema supabase_migrations;
create table supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
`);

const seedSql = await readFile(new URL('./prospect-cursor-history-fixture.sql', import.meta.url), 'utf8');
const compatibilitySql = await readFile(new URL('./prospect-cursor-history-compat.sql', import.meta.url), 'utf8');
let seeded = false;
let candidateApplied = false;
let compatibilityExceptionCount = 0;
for (const file of migrationFiles) {
  if (file === seedBefore) {
    psql('historical cursor data fixture', `begin;\nset local statement_timeout = '60s';\n${seedSql}\ncommit;`);
    seeded = true;
  }
  if (file === compatibilityTarget) {
    process.stdout.write(`Applying one reviewed CI-only compatibility exception before ${file}\n`);
    psql(
      'reviewed company import compatibility precondition',
      `begin;\n${compatibilitySql.replaceAll('__COMPAT_PHASE__', 'pre')}\ncommit;`,
    );
    compatibilityExceptionCount += 1;
  }
  const sql = await readFile(new URL(file, migrationsUrl), 'utf8');
  const version = file.slice(0, 14);
  const name = file.slice(15, -4);
  if (file === candidate) {
    psql('candidate rollback precondition', candidateAbsentContract('before rollback probe'));
    process.stdout.write(`Proving candidate RPC and ledger rollback before applying ${file}\n`);
    psql(
      'forced cursor candidate rollback',
      `begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '5min';\n${sql}\n;\ninsert into supabase_migrations.schema_migrations (version, name) values (${sqlLiteral(version)}, ${sqlLiteral(name)});\nrollback;`,
    );
    psql('candidate rollback postcondition', candidateAbsentContract('after rollback probe'));
  }
  process.stdout.write(`${file === candidate ? 'Applying candidate' : 'Replaying'} ${file}\n`);
  psql(file, `begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '5min';\n${sql}\n;\ninsert into supabase_migrations.schema_migrations (version, name) values (${sqlLiteral(version)}, ${sqlLiteral(name)});\ncommit;`);
  if (file === compatibilityForwardFix) {
    psql(
      'reviewed company import compatibility postcondition',
      `begin;\n${compatibilitySql.replaceAll('__COMPAT_PHASE__', 'post')}\ncommit;`,
    );
  }
  if (file === candidate) candidateApplied = true;
}
if (!seeded) throw new Error(`Historical fixture was not inserted before ${seedBefore}.`);
if (!candidateApplied) throw new Error(`Cursor candidate ${candidate} was not replayed.`);
if (compatibilityExceptionCount !== 1) {
  throw new Error(`Expected exactly one reviewed compatibility exception, applied ${compatibilityExceptionCount}.`);
}
psql('synthetic migration ledger contract', String.raw`
do $ledger$
begin
  if (select count(*) from supabase_migrations.schema_migrations) <> ${migrationFiles.length} then
    raise exception 'synthetic migration ledger does not contain every replayed migration';
  end if;
  if (select count(*) from supabase_migrations.schema_migrations where version = ${sqlLiteral(candidate.slice(0, 14))}) <> 1 then
    raise exception 'cursor candidate is not recorded exactly once in the synthetic migration ledger';
  end if;
end
$ledger$;
`);
psql(
  'cursor runtime contract',
  await readFile(new URL('./check-prospect-cursor-migration.sql', import.meta.url), 'utf8'),
);
process.stdout.write('Cursor migration replay and runtime contract passed.\n');
