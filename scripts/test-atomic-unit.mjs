import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
if (process.env.ATOMIC_UNIT_TEST_ALLOW !== '1') throw new Error('Set ATOMIC_UNIT_TEST_ALLOW=1 for an empty disposable test database only.');
const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new Error('Only a local disposable PostgreSQL target is supported.');
const read = path => readFile(new URL(path, import.meta.url), 'utf8');
const fixture = await read('./atomic-unit-fixture.sql');
const migration = (await read('../supabase/migrations/20260905220328_fair_atomic_background_units.sql'))
  .replaceAll('prospect_results.', 'unit_results.').replaceAll('prospect_operations.', 'unit_operations.').replaceAll('prospect_exports.', 'unit_exports.');
const checks = await read('./check-atomic-unit.sql');
const result = spawnSync('psql', ['-X','-v','ON_ERROR_STOP=1'], {
  input: `BEGIN; SET LOCAL statement_timeout='10s';\n${fixture}\n${migration}\n${checks}\nROLLBACK;`, encoding: 'utf8',
  env: { ...process.env, PGHOST: url.hostname, PGPORT: url.port || '5432', PGUSER: decodeURIComponent(url.username),
    PGPASSWORD: decodeURIComponent(url.password), PGDATABASE: url.pathname.slice(1) },
  timeout: 30000,
});
if (result.error) throw result.error;
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exitCode = result.status ?? 1;
