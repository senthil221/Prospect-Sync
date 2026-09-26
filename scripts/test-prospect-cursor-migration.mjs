import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';

const allow = process.env.CURSOR_MIGRATION_TEST_ALLOW;
if (allow !== '1') {
  throw new Error('Set CURSOR_MIGRATION_TEST_ALLOW=1 for the empty disposable cursor_migration_test database only.');
}

const url = new URL(process.env.DATABASE_URL ?? '');
const database = decodeURIComponent(url.pathname.slice(1));
if (!['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) {
  throw new Error('Cursor migration validation only supports a loopback PostgreSQL target.');
}
if (database !== 'cursor_migration_test' || decodeURIComponent(url.username) !== 'postgres') {
  throw new Error('Cursor migration validation requires postgres@.../cursor_migration_test.');
}
if (decodeURIComponent(url.password) !== 'disposable-ci-only') {
  throw new Error('Cursor migration validation requires the disposable CI password.');
}

const candidate = '20260926083856_prospect_people_cursor_v1.sql';
const candidateVersion = candidate.slice(0, 14);
const candidateSignature = 'public.search_prospect_workspace_cursor_v1(text,jsonb,integer,text,timestamp with time zone,text,boolean,jsonb)';
const normalized = (value) => value.replaceAll('\r\n', '\n');
const [baselineRaw, manifestRaw, candidateSql, rolesSql, fixtureSql, contractSql] = await Promise.all([
  readFile(new URL('./prospect-cursor-schema-baseline.sql', import.meta.url), 'utf8'),
  readFile(new URL('./prospect-cursor-schema-baseline.json', import.meta.url), 'utf8'),
  readFile(new URL(`../supabase/migrations/${candidate}`, import.meta.url), 'utf8'),
  readFile(new URL('./prospect-cursor-ci-roles.sql', import.meta.url), 'utf8'),
  readFile(new URL('./prospect-cursor-fixture.sql', import.meta.url), 'utf8'),
  readFile(new URL('./check-prospect-cursor-migration.sql', import.meta.url), 'utf8'),
]);
const baseline = normalized(baselineRaw);
const manifest = JSON.parse(manifestRaw);
const baselineHash = createHash('sha256').update(baseline, 'utf8').digest('hex');
if (manifest.formatVersion !== 1 || baselineHash !== manifest.normalizedSha256) {
  throw new Error('Reviewed cursor schema baseline hash does not match its manifest.');
}

const dumpSchemas = [...baseline.matchAll(/^CREATE SCHEMA ([a-z_][a-z0-9_]*);$/gmu)]
  .map((match) => match[1])
  .sort();
const manifestSchemas = [...manifest.schemas].sort();
if (JSON.stringify(dumpSchemas) !== JSON.stringify(manifestSchemas)) {
  throw new Error('Cursor schema baseline contains schemas outside its reviewed manifest.');
}
const dumpDefaultAclOwners = [...new Set(
  [...baseline.matchAll(/^ALTER DEFAULT PRIVILEGES FOR ROLE ([a-z_][a-z0-9_]*)\b/gmu)]
    .map((match) => match[1]),
)].sort();
if (JSON.stringify(dumpDefaultAclOwners) !== JSON.stringify([...manifest.defaultPrivileges.owners].sort())) {
  throw new Error('Cursor schema baseline default-privilege owners differ from its reviewed manifest.');
}
for (const [label, pattern] of [
  ['data rows', /^COPY .+ FROM stdin;$/mu],
  ['role definitions', /^(?:CREATE|ALTER) ROLE\b/mu],
  ['extension definitions', /^CREATE EXTENSION\b/mu],
  ['comments', /^COMMENT ON\b/mu],
  ['security labels', /^SECURITY LABEL\b/mu],
  ['foreign connections', /^CREATE (?:SERVER|USER MAPPING|FOREIGN TABLE|SUBSCRIPTION|PUBLICATION)\b/mu],
  ['database URLs', /(?:postgres(?:ql)?|https?|smtp):\/\//iu],
  ['private keys', /-----BEGIN [A-Z ]*PRIVATE KEY-----/u],
]) {
  if (pattern.test(baseline)) throw new Error(`Cursor schema baseline unexpectedly contains ${label}.`);
}

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

function sqlArrayLiteral(values) {
  return `array[${values.map(sqlLiteral).join(',')}]::text[]`;
}

function psql(label, sql, timeout = 330_000) {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {
    input: sql,
    encoding: 'utf8',
    env: psqlEnv,
    timeout,
    maxBuffer: 100 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    process.stderr.write(
      `::error title=Cursor schema upgrade::${actionEscape(label)}: ${actionEscape(firstPsqlError(result))}\n`,
    );
    process.stdout.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw result.error ?? new Error(`${label} failed with psql exit code ${result.status}.`);
  }
}

function psqlExpectedFailure(label, sql, expected, timeout = 30_000) {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], {
    input: sql,
    encoding: 'utf8',
    env: psqlEnv,
    timeout,
    maxBuffer: 1024 * 1024,
  });
  const failure = firstPsqlError(result);
  if (!result.error && result.status !== 0 && expected.test(failure)) return;
  process.stderr.write(
    `::error title=Cursor schema upgrade::${actionEscape(label)}: ${actionEscape(failure)}\n`,
  );
  throw result.error ?? new Error(`${label} did not fail with the expected permission denial.`);
}

function replaceExactlyOnce(source, needle, replacement, label) {
  const count = source.split(needle).length - 1;
  if (count !== 1) throw new Error(`${label} anchor occurs ${count} times; expected exactly once.`);
  return source.replace(needle, replacement);
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
    where version = ${sqlLiteral(candidateVersion)}
  ) then
    raise exception '${label}: cursor migration ledger entry exists';
  end if;
end
$candidate_absent$;
`;
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
  if exists (
    select 1 from pg_namespace
    where nspname not in ('pg_catalog', 'information_schema', 'public')
      and nspname not like 'pg_toast%'
      and nspname not like 'pg_temp_%'
  ) or exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  ) or exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
  ) or exists (
    select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
    where n.nspname = 'public'
  ) then
    raise exception 'disposable cursor migration database is not a fresh stock database';
  end if;
  if exists (select 1 from pg_roles where rolname in (
    'supabase_admin', 'anon', 'authenticated', 'service_role', 'authenticator',
    'prospect_importer', 'prospect_import_worker',
    'prospect_operator', 'prospect_ops_worker',
    'prospect_integrator', 'prospect_integration_worker'
  )) then
    raise exception 'synthetic test roles already exist; use a fresh PostgreSQL service';
  end if;
end $$;
`;

psql('disposable database preflight', preflight);
psql('synthetic Supabase role fixture', rolesSql);

let restoreSql = baseline;
restoreSql = replaceExactlyOnce(
  restoreSql,
  'SET statement_timeout = 0;',
  "SET statement_timeout = '5min';",
  'statement timeout',
);
restoreSql = replaceExactlyOnce(
  restoreSql,
  'SET lock_timeout = 0;',
  "SET lock_timeout = '5s';",
  'lock timeout',
);
restoreSql = replaceExactlyOnce(
  restoreSql,
  'ALTER SCHEMA public OWNER TO pg_database_owner;',
  String.raw`ALTER SCHEMA public OWNER TO pg_database_owner;

CREATE EXTENSION pg_trgm WITH SCHEMA public;
CREATE EXTENSION unaccent WITH SCHEMA public;`,
  'public extension injection',
);
psql(
  'reviewed schema-only baseline restore',
  `begin;\ndrop schema public restrict;\n${restoreSql}\ncommit;`,
);

psql('restored baseline contract', String.raw`
do $baseline_contract$
declare
  v_default_acl_grantees text[];
  v_unexpected_owners text[];
begin
  if pg_catalog.to_regprocedure(
       'public.search_prospect_workspace_v13(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'
     ) is null
     or pg_catalog.to_regprocedure(
       'public.search_prospect_workspace_v12(text,jsonb,text,text,integer,integer,text,jsonb,boolean,jsonb)'
     ) is null then
    raise exception 'reviewed workspace readers are missing from the restored baseline';
  end if;
  if pg_catalog.to_regprocedure('public.import_company_batch_v2(text,jsonb)') is not null
     or pg_catalog.to_regprocedure('public.import_company_batch_v2(text,jsonb,integer)') is null then
    raise exception 'restored baseline has the wrong company import contract';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'list_memberships'
      and column_name = 'raw_data'
  ) then
    raise exception 'restored baseline unexpectedly has retired list_memberships.raw_data';
  end if;
  if (select count(*) from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where c.relkind in ('r', 'p') and c.relrowsecurity
        and n.nspname = any(${sqlArrayLiteral(manifest.schemas)})) <> ${manifest.objectCounts.rlsEnabledTables} then
    raise exception 'restored baseline RLS table count differs from the reviewed manifest';
  end if;
  select array_agg(distinct r.rolname order by r.rolname) into v_unexpected_owners
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_roles r on r.oid = c.relowner
  where n.nspname = any(${sqlArrayLiteral(manifest.schemas)})
    and r.rolname not in ('postgres', 'pg_database_owner');
  if v_unexpected_owners is not null then
    raise exception 'restored baseline has unexpected object owners: %', v_unexpected_owners;
  end if;
  if (select count(*) from pg_catalog.pg_default_acl) <> ${manifest.defaultPrivileges.entryCount}
     or exists (
       select 1
       from pg_catalog.pg_default_acl d
       join pg_catalog.pg_roles owner_role on owner_role.oid = d.defaclrole
       where owner_role.rolname <> all(${sqlArrayLiteral(manifest.defaultPrivileges.owners)})
          or d.defaclobjtype::text <> all(${sqlArrayLiteral(manifest.defaultPrivileges.objectTypes)})
     )
     or exists (
       select 1
       from (values ('postgres'), ('supabase_admin')) expected(owner_name)
       cross join (values ('S'::"char"), ('f'::"char"), ('r'::"char")) kinds(object_type)
       where not exists (
         select 1
         from pg_catalog.pg_default_acl d
         join pg_catalog.pg_roles owner_role on owner_role.oid = d.defaclrole
         where owner_role.rolname = expected.owner_name
           and d.defaclobjtype = kinds.object_type
       )
     ) then
    raise exception 'restored baseline default-privilege owners or object types differ from the reviewed manifest';
  end if;
  select array_agg(distinct grantee_role.rolname order by grantee_role.rolname)
  into v_default_acl_grantees
  from pg_catalog.pg_default_acl d
  cross join lateral pg_catalog.aclexplode(d.defaclacl) acl_entry
  join pg_catalog.pg_roles grantee_role on grantee_role.oid = acl_entry.grantee;
  if v_default_acl_grantees is distinct from ${sqlArrayLiteral(manifest.defaultPrivileges.grantees)} then
    raise exception 'restored baseline default-privilege grantees differ: %', v_default_acl_grantees;
  end if;
  if not exists (select 1 from pg_catalog.pg_extension where extname = 'pg_trgm')
     or not exists (select 1 from pg_catalog.pg_extension where extname = 'unaccent') then
    raise exception 'required public text-search extensions are missing';
  end if;
  if exists (select 1 from supabase_migrations.schema_migrations) then
    raise exception 'schema-only baseline unexpectedly restored migration rows';
  end if;
  if exists (select 1 from public.prospects) then
    raise exception 'schema-only baseline unexpectedly restored customer rows';
  end if;
end
$baseline_contract$;
`);
psql('candidate baseline precondition', candidateAbsentContract('before fixture'));
psql('current-schema cursor fixture', `begin;\nset local statement_timeout = '60s';\n${fixtureSql}\ncommit;`);
psql('candidate rollback precondition', candidateAbsentContract('before rollback probe'));
psql(
  'forced cursor candidate rollback',
  `begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '5min';\n${candidateSql}\n;\ninsert into supabase_migrations.schema_migrations (version, name) values (${sqlLiteral(candidateVersion)}, ${sqlLiteral(candidate.slice(15, -4))});\nrollback;`,
);
psql('candidate rollback postcondition', candidateAbsentContract('after rollback probe'));
psql(
  candidate,
  `begin;\nset local lock_timeout = '5s';\nset local statement_timeout = '5min';\n${candidateSql}\n;\ninsert into supabase_migrations.schema_migrations (version, name) values (${sqlLiteral(candidateVersion)}, ${sqlLiteral(candidate.slice(15, -4))});\ncommit;`,
);
psql('candidate migration ledger contract', String.raw`
do $ledger$
begin
  if (select count(*) from supabase_migrations.schema_migrations) <> 1
     or (select count(*) from supabase_migrations.schema_migrations
         where version = ${sqlLiteral(candidateVersion)}) <> 1 then
    raise exception 'cursor candidate is not the single recorded synthetic upgrade';
  end if;
end
$ledger$;
`);
const roleProbe = String.raw`
select count(*) from public.search_prospect_workspace_cursor_v1(
  '', '[]'::jsonb, 1, null, null, null, false, null
);
`;
psql(
  'service-role cursor execution probe',
  `begin;\nset local role service_role;\n${roleProbe}\nrollback;`,
  30_000,
);
for (const browserRole of ['anon', 'authenticated']) {
  psqlExpectedFailure(
    `${browserRole} cursor execution denial`,
    `begin;\nset local role ${browserRole};\n${roleProbe}\nrollback;`,
    /permission denied for function search_prospect_workspace_cursor_v1/iu,
  );
}
psql('cursor runtime contract', contractSql);
process.stdout.write('Reviewed schema baseline, cursor upgrade, rollback, and runtime contracts passed.\n');
