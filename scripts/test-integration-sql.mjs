import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
if (process.env.ATOMIC_UNIT_TEST_ALLOW !== '1') throw new Error('Disposable test database must be explicitly enabled.');
const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new Error('Only a local disposable database is supported.');
const read = async path => (await readFile(new URL(path, import.meta.url), 'utf8')).replaceAll('\r\n','\n');
const initial = await read('../supabase/migrations/20260807000000_initial_schema.sql');
const clients = initial.slice(0, initial.indexOf('\n);') + 4);
if (!clients.startsWith('create table if not exists public.clients')) throw new Error('Client fixture changed.');
const fixture = `DO $$ BEGIN IF to_regclass('public.clients') IS NOT NULL THEN RAISE EXCEPTION 'Refusing application database'; END IF; END $$;
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
${clients}`;
const input = ['BEGIN; SET LOCAL statement_timeout=\'5s\';', fixture,
  await read('../supabase/migrations/20260906001221_integration_connections.sql'),
  await read('../supabase/migrations/20260906002853_integration_delivery_ledger.sql'),
  await read('./check-integration-connections.sql'), await read('./check-integration-ledger.sql'), 'ROLLBACK;'].join('\n');
const result = spawnSync('psql', ['-X','-v','ON_ERROR_STOP=1'], { input, encoding:'utf8', timeout:30000,
  env: { ...process.env, PGHOST:url.hostname, PGPORT:url.port || '5432', PGUSER:decodeURIComponent(url.username), PGPASSWORD:decodeURIComponent(url.password), PGDATABASE:url.pathname.slice(1) } });
if (result.error) throw result.error;
process.stdout.write(result.stdout); process.stderr.write(result.stderr); process.exitCode=result.status ?? 1;
