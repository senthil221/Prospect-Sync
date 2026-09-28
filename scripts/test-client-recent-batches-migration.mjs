import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

if (process.env.RECENT_BATCHES_MIGRATION_TEST_ALLOW !== '1') {
  throw new Error('Set RECENT_BATCHES_MIGRATION_TEST_ALLOW=1 only for the disposable cursor_migration_test database.');
}

const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
  || decodeURIComponent(url.pathname.slice(1)) !== 'cursor_migration_test'
  || decodeURIComponent(url.username) !== 'postgres'
  || decodeURIComponent(url.password) !== 'disposable-ci-only') {
  throw new Error('Recent-batches migration validation requires postgres@loopback/cursor_migration_test with the disposable password.');
}

const migrationName = '20260928202444_client_recent_batches_v2.sql';
const [migration, contract] = await Promise.all([
  readFile(new URL(`../supabase/migrations/${migrationName}`, import.meta.url), 'utf8'),
  readFile(new URL('../supabase/tests/client_recent_batches_v2.sql', import.meta.url), 'utf8'),
]);
const meaningful = migration.split(/\r?\n/u)
  .map(line => line.trim())
  .filter(line => line && !line.startsWith('--'));
if (meaningful[0]?.toLowerCase() === 'begin;' || meaningful.at(-1)?.toLowerCase() === 'commit;') {
  throw new Error(`${migrationName} must not own its transaction.`);
}

const env = {
  PATH: process.env.PATH,
  LC_ALL: 'C',
  PGHOST: url.hostname === '[::1]' ? '::1' : url.hostname,
  PGPORT: url.port || '5432',
  PGUSER: decodeURIComponent(url.username),
  PGPASSWORD: decodeURIComponent(url.password),
  PGDATABASE: 'cursor_migration_test',
};

function escape(value) {
  return String(value)
    .replaceAll('disposable-ci-only', '[redacted]')
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, 'postgresql://[redacted]@')
    .replaceAll('%', '%25')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A')
    .slice(0, 900);
}

function diagnostic(result) {
  const lines = `${result.stderr ?? ''}\n${result.stdout ?? ''}`.split(/\r?\n/u);
  const first = lines.findIndex(line => /\bERROR:/u.test(line));
  if (first >= 0) return lines.slice(first, first + 7).map(line => line.trim()).filter(Boolean).join(' | ');
  return result.error?.message ?? `psql exited ${result.status ?? 'unknown'}`;
}

function psql(label, sql) {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {
    input: sql,
    encoding: 'utf8',
    env,
    timeout: 330_000,
    maxBuffer: 100 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    process.stderr.write(`::error title=Recent batches schema contract::${escape(label)}: ${escape(diagnostic(result))}\n`);
    process.stdout.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw result.error ?? new Error(`${label} failed.`);
  }
}

psql(migrationName, `begin; set local lock_timeout='5s'; set local statement_timeout='5min';\n${migration}\ncommit;`);
psql('source-first recent-batches behavior', contract);
process.stdout.write('Recent batches source, 48-hour window, pagination, and grants contracts passed.\n');
