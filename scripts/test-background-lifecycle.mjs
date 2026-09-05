// Isolated PostgreSQL contract using the actual table/function definitions,
// not a production data copy. Everything is rolled back, including test roles.
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
if (process.env.ATOMIC_UNIT_TEST_ALLOW !== '1') throw new Error('Only an explicitly enabled disposable database may run this test.');
const url = new URL(process.env.DATABASE_URL ?? '');
if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new Error('Only a local disposable PostgreSQL target is supported.');
const read = async name => (await readFile(new URL(name,import.meta.url),'utf8')).replaceAll('\r\n','\n');
const results = await read('../supabase/migrations/20260902000120_durable_result_sets.sql');
const filters = await read('../supabase/migrations/20260902000100_durable_filter_sets.sql');
const operations = await read('../supabase/migrations/20260902000140_idempotent_frozen_operations.sql');
const exports = await read('../supabase/migrations/20260902000170_export_without_holding_it_all.sql');
function table(source,name) {
  const pattern = new RegExp(`create (?:unlogged )?table (?:if not exists )?${name.replaceAll('.','\\.')} \\(`,'i');
  const start=source.search(pattern),end=source.indexOf('\n);',start);
  if(start<0 || end<0) throw new Error(`Missing table fixture: ${name}`);
  return source.slice(start,end+4);
}
function fn(source,name) {
  const start=source.indexOf(`create or replace function ${name}(`),end=source.indexOf('$function$;',start);
  if(start<0 || end<0) throw new Error(`Missing function fixture: ${name}`);
  return source.slice(start,end+'$function$;'.length);
}
const fixture = `
DO $$ BEGIN
 IF to_regclass('public.prospects') IS NOT NULL OR to_regnamespace('prospect_results') IS NOT NULL THEN
   RAISE EXCEPTION 'Refusing lifecycle fixture on an application database';
 END IF;
END $$;
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE ROLE prospect_operator; CREATE ROLE prospect_ops_worker;
GRANT prospect_operator TO prospect_ops_worker;
CREATE SCHEMA prospect_results; CREATE SCHEMA prospect_filters;
CREATE SCHEMA prospect_operations; CREATE SCHEMA prospect_exports;
${table(results,'prospect_results.result_sets')}
ALTER TABLE prospect_results.result_sets ADD COLUMN company_scope jsonb NOT NULL DEFAULT '{}';
${table(results,'prospect_results.result_set_items')}
${table(filters,'prospect_filters.filter_sets')}
${table(filters,'prospect_filters.filter_set_values')}
${table(operations,'prospect_operations.operation_jobs')}
${table(operations,'prospect_operations.operation_job_items')}
${table(exports,'prospect_exports.jobs')}
${table(exports,'prospect_exports.job_parts')}
${fn(filters,'prospect_filters.create_set_v1')}
${fn(exports,'prospect_exports.request_v1')}
`;
const migration=await read('../supabase/migrations/20260905230936_bounded_background_lifecycle.sql');
const checks=await read('./check-background-lifecycle.sql');
const result=spawnSync('psql',['-X','-v','ON_ERROR_STOP=1'],{
  input:`BEGIN; SET LOCAL statement_timeout='10s';\n${fixture}\n${migration}\n${checks}\nROLLBACK;`,encoding:'utf8',timeout:30000,
  env:{...process.env,PGHOST:url.hostname,PGPORT:url.port||'5432',PGUSER:decodeURIComponent(url.username),PGPASSWORD:decodeURIComponent(url.password),PGDATABASE:url.pathname.slice(1)},
});
if(result.error) throw result.error;
process.stdout.write(result.stdout); process.stderr.write(result.stderr);
process.exitCode=result.status??1;
