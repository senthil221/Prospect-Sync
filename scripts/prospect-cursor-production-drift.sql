set default_transaction_read_only = on;
set statement_timeout = '15s';

select count(*)::text || chr(9)
  || min(version) || chr(9)
  || max(version) || chr(9)
  || md5(string_agg(version, '|' order by version))
from supabase_migrations.schema_migrations;

select count(*)
from pg_catalog.pg_stat_activity
where pid <> pg_catalog.pg_backend_pid()
  and state <> 'idle'
  and query ~* '\m(create|alter|drop|truncate|reindex|vacuum)\M';
