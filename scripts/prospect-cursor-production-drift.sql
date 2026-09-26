set default_transaction_read_only = on;
set statement_timeout = '15s';

select 'count_min_max' || chr(9) || count(*)::text || chr(9)
  || min(version) || chr(9) || max(version)
from supabase_migrations.schema_migrations;

select 'versions_pipe_md5' || chr(9)
  || md5(string_agg(version, '|' order by version))
from supabase_migrations.schema_migrations;

select 'version_colon_name_lf_md5' || chr(9) || md5(string_agg(
  version || ':' || coalesce(name, ''), chr(10) order by version
))
from supabase_migrations.schema_migrations;

select 'active_schema_sessions' || chr(9) || count(*)::text
from pg_catalog.pg_stat_activity
where pid <> pg_catalog.pg_backend_pid()
  and state <> 'idle'
  and query ~* '\m(create|alter|drop|truncate|reindex|vacuum)\M';
