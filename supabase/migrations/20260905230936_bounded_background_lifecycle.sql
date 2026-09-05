-- Bounded lifecycle for derived work; no customer-table writes.
SET LOCAL lock_timeout = '5s';

CREATE OR REPLACE FUNCTION prospect_operations.reclaim_unit_v1(p_kind text, p_limit integer DEFAULT 5000)
RETURNS TABLE(items_removed integer, parents_removed integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations, prospect_results, prospect_exports, prospect_filters
AS $function$
DECLARE
  v_schema text; v_parent text; v_child text; v_fk text; v_guard text;
  v_id uuid; v_removed integer := 0; v_parents integer := 0; v_remaining boolean;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 5000 THEN
    RAISE EXCEPTION 'Cleanup limit must be 1–5000' USING ERRCODE='22023';
  END IF;
  CASE p_kind
    WHEN 'search' THEN
      v_schema := 'prospect_results'; v_parent := 'result_sets'; v_child := 'result_set_items'; v_fk := 'result_set_id';
      -- Export metadata is a durable dependency pin until that export is terminal.
      v_guard := 'coalesce(s.lease_expires_at,now()) <= now()
        AND NOT EXISTS (SELECT 1 FROM prospect_exports.jobs j WHERE j.result_set_id=s.id AND j.status IN (''queued'',''building''))';
    WHEN 'operation' THEN
      v_schema := 'prospect_operations'; v_parent := 'operation_jobs'; v_child := 'operation_job_items'; v_fk := 'job_id';
      -- Never age out an acknowledged mutation that still needs to run.
      v_guard := 's.status IN (''completed'',''failed'') AND coalesce(s.lease_expires_at,now()) <= now()';
    WHEN 'export' THEN
      v_schema := 'prospect_exports'; v_parent := 'jobs'; v_child := 'job_parts'; v_fk := 'job_id';
      v_guard := 'coalesce(s.lease_expires_at,now()) <= now()';
      p_limit := least(p_limit,2); -- Parts can hold thousands of wide rows.
    WHEN 'filter' THEN
      v_schema := 'prospect_filters'; v_parent := 'filter_sets'; v_child := 'filter_set_values'; v_fk := 'filter_set_id';
      v_guard := 'NOT EXISTS (SELECT 1 FROM prospect_results.result_sets r
        WHERE r.status IN (''pending'',''building'')
          AND (strpos(r.filters::text,s.id::text)>0 OR strpos(r.company_scope::text,s.id::text)>0))';
    ELSE RAISE EXCEPTION 'Unknown cleanup class' USING ERRCODE='22023';
  END CASE;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('prospect-background-unit-v1',0)) THEN
    RETURN QUERY SELECT 0,0; RETURN;
  END IF;
  -- Lock the parent before any child deletion. Builders and dependency creators
  -- use this same row lock; no cleanup can race an export attaching its input.
  EXECUTE format('SELECT s.id FROM %I.%I s WHERE s.expires_at<=now() AND %s
    ORDER BY s.expires_at,s.id LIMIT 1 FOR UPDATE OF s SKIP LOCKED',v_schema,v_parent,v_guard) INTO v_id;
  IF v_id IS NULL THEN RETURN QUERY SELECT 0,0; RETURN; END IF;
  EXECUTE format('DELETE FROM %I.%I WHERE ctid IN
    (SELECT ctid FROM %I.%I WHERE %I=$1 LIMIT $2)',v_schema,v_child,v_schema,v_child,v_fk)
    USING v_id,p_limit;
  GET DIAGNOSTICS v_removed=ROW_COUNT;
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE %I=$1)',v_schema,v_child,v_fk)
    INTO v_remaining USING v_id;
  IF NOT v_remaining THEN
    EXECUTE format('DELETE FROM %I.%I WHERE id=$1',v_schema,v_parent) USING v_id;
    GET DIAGNOSTICS v_parents=ROW_COUNT;
  END IF;
  RETURN QUERY SELECT v_removed,v_parents;
END;
$function$;
REVOKE EXECUTE ON FUNCTION prospect_operations.reclaim_unit_v1(text,integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION prospect_operations.reclaim_unit_v1(text,integer) TO prospect_operator;

-- Existing entry points remain safe for a rollback worker too.
CREATE OR REPLACE FUNCTION prospect_results.expire_sets_v1()
RETURNS integer LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations
AS $function$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('search',5000); $function$;
REVOKE EXECUTE ON FUNCTION prospect_results.expire_sets_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION prospect_results.expire_sets_v1() TO prospect_operator;
CREATE OR REPLACE FUNCTION prospect_filters.expire_sets_v1()
RETURNS integer LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations
AS $function$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('filter',5000); $function$;
REVOKE EXECUTE ON FUNCTION prospect_filters.expire_sets_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION prospect_filters.expire_sets_v1() TO prospect_operator;
CREATE OR REPLACE FUNCTION prospect_operations.expire_jobs_v1()
RETURNS integer LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations
AS $function$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('operation',5000); $function$;
REVOKE EXECUTE ON FUNCTION prospect_operations.expire_jobs_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION prospect_operations.expire_jobs_v1() TO prospect_operator;
CREATE OR REPLACE FUNCTION prospect_exports.expire_jobs_v1()
RETURNS integer LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations
AS $function$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('export',5000); $function$;
REVOKE EXECUTE ON FUNCTION prospect_exports.expire_jobs_v1() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION prospect_exports.expire_jobs_v1() TO prospect_operator;

-- Close the dependency/cleanup race and reject already-expired export inputs.
-- Fail loudly on source drift instead of silently missing a critical splice.
DO $patch$
DECLARE v_source text; v_anchor text;
BEGIN
  v_source := pg_get_functiondef('prospect_exports.request_v1(text,text,text,text,uuid,text[],text[],text[],text,interval)'::regprocedure);
  v_anchor := 'where rs.id = p_result_set_id;';
  IF (length(v_source)-length(replace(v_source,v_anchor,'')))/length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'Export dependency lock anchor drifted';
  END IF;
  EXECUTE replace(v_source,v_anchor,'where rs.id = p_result_set_id and rs.expires_at > now() for update;');

  v_source := pg_get_functiondef('prospect_filters.create_set_v1(text,text,text,text,text[],interval)'::regprocedure);
  v_anchor := 'and fs.content_hash = v_hash;';
  IF (length(v_source)-length(replace(v_source,v_anchor,'')))/length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'Filter reuse lock anchor drifted';
  END IF;
  v_source := replace(v_source,v_anchor,'and fs.content_hash = v_hash for update;');
  v_anchor := 'if v_existing is not null then';
  IF (length(v_source)-length(replace(v_source,v_anchor,'')))/length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'Filter restoration anchor drifted';
  END IF;
  -- A partly reclaimed, expired value set may be reused only after all values
  -- supplied by the caller have been restored in this same locked transaction.
  EXECUTE replace(v_source,v_anchor,v_anchor || E'\n'
    || '    insert into prospect_filters.filter_set_values(filter_set_id,normalized_value)'
    || ' select v_existing,value from unnest(v_values) value on conflict do nothing;');
END;
$patch$;

CREATE TABLE prospect_operations.job_metrics (
  hour timestamptz NOT NULL,
  kind text NOT NULL CHECK(kind IN ('search','operation','export')),
  outcome text NOT NULL CHECK(outcome IN ('ready','completed','failed')),
  duration_bucket_ms integer NOT NULL,
  jobs bigint NOT NULL DEFAULT 0,
  total_ms double precision NOT NULL DEFAULT 0,
  max_ms double precision NOT NULL DEFAULT 0,
  PRIMARY KEY(hour,kind,outcome,duration_bucket_ms)
);
ALTER TABLE prospect_operations.job_metrics ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON prospect_operations.job_metrics FROM PUBLIC,anon,authenticated,service_role,prospect_operator;

CREATE OR REPLACE FUNCTION prospect_operations.record_job_metric_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations
AS $function$
DECLARE v_kind text; v_ms double precision; v_bucket integer;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('ready','completed','failed') THEN RETURN NEW; END IF;
  v_kind := CASE TG_TABLE_SCHEMA WHEN 'prospect_results' THEN 'search' WHEN 'prospect_exports' THEN 'export' ELSE 'operation' END;
  v_ms := greatest(0,extract(epoch FROM (clock_timestamp()-NEW.created_at))*1000);
  v_bucket := CASE WHEN v_ms<=2000 THEN 2000 WHEN v_ms<=5000 THEN 5000 WHEN v_ms<=15000 THEN 15000
    WHEN v_ms<=30000 THEN 30000 WHEN v_ms<=60000 THEN 60000 WHEN v_ms<=120000 THEN 120000 ELSE 2147483647 END;
  INSERT INTO prospect_operations.job_metrics(hour,kind,outcome,duration_bucket_ms,jobs,total_ms,max_ms)
    VALUES(date_trunc('hour',clock_timestamp()),v_kind,NEW.status,v_bucket,1,v_ms,v_ms)
    ON CONFLICT(hour,kind,outcome,duration_bucket_ms) DO UPDATE
      SET jobs=job_metrics.jobs+1,total_ms=job_metrics.total_ms+excluded.total_ms,max_ms=greatest(job_metrics.max_ms,excluded.max_ms);
  RETURN NEW;
END;
$function$;
REVOKE EXECUTE ON FUNCTION prospect_operations.record_job_metric_v1() FROM PUBLIC,anon,authenticated,service_role,prospect_operator;
CREATE TRIGGER result_job_metric AFTER UPDATE OF status ON prospect_results.result_sets
FOR EACH ROW EXECUTE FUNCTION prospect_operations.record_job_metric_v1();
CREATE TRIGGER operation_job_metric AFTER UPDATE OF status ON prospect_operations.operation_jobs
FOR EACH ROW EXECUTE FUNCTION prospect_operations.record_job_metric_v1();
CREATE TRIGGER export_job_metric AFTER UPDATE OF status ON prospect_exports.jobs
FOR EACH ROW EXECUTE FUNCTION prospect_operations.record_job_metric_v1();

CREATE OR REPLACE FUNCTION prospect_operations.prune_metrics_v1()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations
AS $function$
DECLARE v_count integer;
BEGIN
  DELETE FROM prospect_operations.job_metrics WHERE ctid IN
    (SELECT ctid FROM prospect_operations.job_metrics WHERE hour<now()-interval '30 days' ORDER BY hour LIMIT 1000);
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN v_count;
END;
$function$;
REVOKE EXECUTE ON FUNCTION prospect_operations.prune_metrics_v1() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION prospect_operations.prune_metrics_v1() TO prospect_operator;

CREATE OR REPLACE FUNCTION public.background_health_v1()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations, prospect_results, prospect_exports
AS $function$
  WITH queues AS (
    SELECT 'search'::text kind,count(*) pending,
      coalesce(max(extract(epoch FROM (now()-created_at))),0) oldest_seconds
      FROM prospect_results.result_sets WHERE status IN ('pending','building') AND expires_at>now()
    UNION ALL SELECT 'operation',count(*),coalesce(max(extract(epoch FROM (now()-created_at))),0)
      FROM prospect_operations.operation_jobs WHERE status IN ('pending','frozen','running')
    UNION ALL SELECT 'export',count(*),coalesce(max(extract(epoch FROM (now()-created_at))),0)
      FROM prospect_exports.jobs WHERE status IN ('queued','building') AND expires_at>now()
  ), metrics AS (
    SELECT kind,outcome,duration_bucket_ms,sum(jobs) jobs,sum(total_ms) total_ms,max(max_ms) max_ms
      FROM prospect_operations.job_metrics WHERE hour>=date_trunc('hour',now())-interval '1 hour'
      GROUP BY kind,outcome,duration_bucket_ms
  )
  SELECT jsonb_build_object(
    'measuredAt',now(),'schemaVersion',1,
    'queues',(SELECT jsonb_agg(to_jsonb(queues)) FROM queues),
    'recentJobs',coalesce((SELECT jsonb_agg(to_jsonb(metrics)) FROM metrics),'[]'::jsonb),
    'recentWindow','current and previous UTC hour',
    'searchBytes',pg_total_relation_size('prospect_results.result_sets')+pg_total_relation_size('prospect_results.result_set_items'),
    'exportBytes',pg_total_relation_size('prospect_exports.jobs')+pg_total_relation_size('prospect_exports.job_parts'),
    'operationBytes',pg_total_relation_size('prospect_operations.operation_jobs')+pg_total_relation_size('prospect_operations.operation_job_items'),
    'metricBytes',pg_total_relation_size('prospect_operations.job_metrics')
  );
$function$;
REVOKE EXECUTE ON FUNCTION public.background_health_v1() FROM PUBLIC,anon,authenticated,prospect_operator;
GRANT EXECUTE ON FUNCTION public.background_health_v1() TO service_role;

DO $assert$
BEGIN
  IF has_function_privilege('anon','public.background_health_v1()','execute')
    OR has_function_privilege('authenticated','prospect_operations.reclaim_unit_v1(text,integer)','execute')
    OR has_table_privilege('prospect_ops_worker','prospect_operations.job_metrics','select')
    OR NOT has_function_privilege('prospect_ops_worker','prospect_operations.reclaim_unit_v1(text,integer)','execute') THEN
    RAISE EXCEPTION 'Background lifecycle privileges failed';
  END IF;
END;
$assert$;
