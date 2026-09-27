import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

if (process.env.VERIFICATION_MIGRATION_TEST_ALLOW !== '1') {
  throw new Error('Set VERIFICATION_MIGRATION_TEST_ALLOW=1 only for the disposable cursor_migration_test database.');
}
const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  || decodeURIComponent(url.pathname.slice(1)) !== 'cursor_migration_test'
  || decodeURIComponent(url.username) !== 'postgres'
  || decodeURIComponent(url.password) !== 'disposable-ci-only') {
  throw new Error('Verification migration validation requires postgres@loopback/cursor_migration_test with the disposable password.');
}

const migrations = [
  '20260926150000_indexes_are_reachable_and_background_work_waits.sql',
  '20260926160000_membership_tables_stay_all_visible.sql',
  '20260926170000_a_bulk_action_reindexes_a_bounded_slice_inline.sql',
  '20260926180000_interactive_reads_get_limits_sized_to_their_real_cost.sql',
  '20260926190000_company_blank_filters_read_an_index.sql',
  '20260928100000_master_email_verification.sql',
];
const sqlFiles = await Promise.all(migrations.map(name => readFile(new URL(`../supabase/migrations/${name}`, import.meta.url), 'utf8')));
const contract = await readFile(new URL('./check-email-verification-migration.sql', import.meta.url), 'utf8');
const env = {
  PATH: process.env.PATH, LC_ALL: 'C',
  PGHOST: url.hostname === '[::1]' ? '::1' : url.hostname,
  PGPORT: url.port || '5432', PGUSER: decodeURIComponent(url.username),
  PGPASSWORD: decodeURIComponent(url.password), PGDATABASE: 'cursor_migration_test',
};

function escape(value) {
  return String(value).replaceAll('disposable-ci-only', '[redacted]').replaceAll('%', '%25')
    .replaceAll('\r', '%0D').replaceAll('\n', '%0A').slice(0, 900);
}
function diagnostic(result) {
  const lines = `${result.stderr ?? ''}\n${result.stdout ?? ''}`.split(/\r?\n/u);
  const first = lines.findIndex(line => /\bERROR:/u.test(line));
  if (first >= 0) {
    const context = lines.slice(first + 1).find(line => /^(CONTEXT|LINE|DETAIL|HINT):/u.test(line));
    return `${lines[first].trim()}${context ? ` | ${context.trim()}` : ''}`;
  }
  return result.error?.message ?? `psql exited ${result.status ?? 'unknown'}`;
}
function psql(label, sql, timeout = 330_000) {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {
    input: sql, encoding: 'utf8', env, timeout, maxBuffer: 100 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    process.stderr.write(`::error title=Email verification schema contract::${escape(label)}: ${escape(diagnostic(result))}\n`);
    process.stdout.write(result.stdout ?? ''); process.stderr.write(result.stderr ?? '');
    throw result.error ?? new Error(`${label} failed.`);
  }
  return result.stdout ?? '';
}

psql('verification capability roles', `
do $$ begin
  if not exists(select 1 from pg_roles where rolname='prospect_verifier') then create role prospect_verifier nologin noinherit; end if;
  if not exists(select 1 from pg_roles where rolname='prospect_verification_worker') then create role prospect_verification_worker login inherit; end if;
end $$;
grant prospect_verifier to prospect_verification_worker;
`);

for (let index = 0; index < migrations.length; index += 1) {
  const name = migrations[index];
  const body = sqlFiles[index];
  const meaningful = body.split(/\r?\n/u).map(line => line.trim()).filter(line => line && !line.startsWith('--'));
  if (meaningful[0]?.toLowerCase() === 'begin;' || meaningful.at(-1)?.toLowerCase() === 'commit;') {
    throw new Error(`${name} must not own its transaction.`);
  }
  psql(name, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${body}\ncommit;`);
}
psql('verification runtime behavior', contract);
process.stdout.write('Email verification schema, concurrency fences, filters, lifecycle, quota, imports, and grants passed.\n');
