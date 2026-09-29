import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
if (process.env.ATOMIC_UNIT_TEST_ALLOW !== '1') throw new Error('Disposable test database must be explicitly enabled.');
const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new Error('Only a local disposable database is supported.');
const read = async path => (await readFile(new URL(path, import.meta.url), 'utf8')).replaceAll('\r\n','\n');
const initial = await read('../supabase/migrations/20260807000000_initial_schema.sql');
function table(source,name) {
  const start=source.indexOf(`create table if not exists public.${name} (`);
  if(start<0)throw new Error(`Fixture ${name} changed.`);
  return source.slice(start,source.indexOf('\n);',start)+4);
}
const memberships=await read('../supabase/migrations/20260825040000_client_prospects.sql');
const clients = ['clients','companies','prospects'].map(name=>table(initial,name)).join('\n')
  + '\n' + ['client_prospects','client_blocklist'].map(name=>table(memberships,name)).join('\n');
const fixture = `DO $$ BEGIN IF to_regclass('public.clients') IS NOT NULL THEN RAISE EXCEPTION 'Refusing application database'; END IF; END $$;
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
${clients}
CREATE OR REPLACE FUNCTION public.add_client_blocklist_batch_v2(p_client_id text,p_domains text[] default null,p_emails text[] default null,p_reason text default '',p_actor text default '',p_request_id text default '',p_match_limit integer default 5000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE added integer;
BEGIN
  WITH incoming AS (SELECT 'domain'::text kind,x value FROM unnest(coalesce(p_domains,array[]::text[]))x UNION ALL SELECT 'email',x FROM unnest(coalesce(p_emails,array[]::text[]))x),
  inserted AS (INSERT INTO public.client_blocklist(client_id,kind,value,reason,source) SELECT p_client_id,kind,value,p_reason,'paste' FROM incoming ON CONFLICT(client_id,kind,value) DO NOTHING RETURNING 1)
  SELECT count(*)::integer INTO added FROM inserted;
  RETURN jsonb_build_object('added',added,'suppressed',0,'remaining',false,'reindexed',0,'queued',0);
END $$;
CREATE OR REPLACE FUNCTION public.remove_client_blocklist_v1(p_client_id text,p_ids text[],p_actor text default '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE removed integer;
BEGIN
  DELETE FROM public.client_blocklist
    WHERE client_id=p_client_id AND id=ANY(coalesce(p_ids,array[]::text[]));
  GET DIAGNOSTICS removed=ROW_COUNT;
  RETURN jsonb_build_object('removed',removed,'restored',0,'companiesRestored',0);
END $$;`;
const input = ['BEGIN; SET LOCAL statement_timeout=\'5s\';', fixture,
  await read('../supabase/migrations/20260906001221_integration_connections.sql'),
  await read('../supabase/migrations/20260906002853_integration_delivery_ledger.sql'),
  await read('../supabase/migrations/20260906005421_integration_client_campaigns.sql'),
  await read('../supabase/migrations/20260906005651_integration_selection_preview.sql'),
  await read('../supabase/migrations/20260906012316_smartlead_durable_dispatch.sql'),
  await read('../supabase/migrations/20260928212351_smartlead_inbox_blocklist_sync.sql'),
  await read('../supabase/migrations/20260929173000_smartlead_account_scoped_inbox.sql'),
  await read('./fixture-smartlead-stale-inbox-telemetry.sql'),
  await read('../supabase/migrations/20260929180000_smartlead_inbox_validation_telemetry_reset.sql'),
  await read('./check-integration-connections.sql'), await read('./check-integration-ledger.sql'),
  await read('./check-integration-destinations.sql'), await read('./check-integration-preview.sql'),
  await read('./check-smartlead-dispatch.sql'), await read('./check-smartlead-inbox.sql'), 'ROLLBACK;'].join('\n');
const result = spawnSync('psql', ['-X','-v','ON_ERROR_STOP=1'], { input, encoding:'utf8', timeout:30000,
  env: { ...process.env, PGHOST:url.hostname, PGPORT:url.port || '5432', PGUSER:decodeURIComponent(url.username), PGPASSWORD:decodeURIComponent(url.password), PGDATABASE:url.pathname.slice(1) } });
if (result.error) throw result.error;
process.stdout.write(result.stdout); process.stderr.write(result.stderr); process.exitCode=result.status ?? 1;
