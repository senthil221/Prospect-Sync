-- Run only inside the caller's ROLLBACK transaction after the candidate migration.
-- Synthetic private cache/job rows only; never insert or update customer records.
DO $test$
DECLARE
  v_set uuid := gen_random_uuid(); v_pin uuid := gen_random_uuid(); v_export uuid := gen_random_uuid();
  v_operation uuid := gen_random_uuid(); v_metric uuid := gen_random_uuid();
  v_filter uuid; v_result record; v_values text[]; v_count bigint;
BEGIN
  INSERT INTO prospect_results.result_sets(id,owner_id,entity_type,content_hash,version_vector,status,row_count,expires_at)
    VALUES(v_set,'lifecycle-fixture','company',v_set::text,'{}','ready',7,'-infinity'),
          (v_pin,'lifecycle-fixture','company',v_pin::text,'{}','ready',1,'-infinity'),
          (v_metric,'lifecycle-fixture','company',v_metric::text,'{}','pending',0,now()+interval '1 day');
  INSERT INTO prospect_results.result_set_items(result_set_id,ordinal,entity_id)
    SELECT v_set,i,'fixture-'||i FROM generate_series(1,7) i;
  INSERT INTO prospect_results.result_set_items VALUES(v_pin,1,'fixture-pin');
  INSERT INTO prospect_exports.jobs(id,owner_id,request_id,entity_type,result_set_id,download_token,expires_at)
    VALUES(v_export,'lifecycle-fixture',v_export::text,'company',v_pin,'fixture-token',now()+interval '1 day');

  SELECT * INTO v_result FROM prospect_operations.reclaim_unit_v1('search',3);
  IF v_result.items_removed<>3 OR v_result.parents_removed<>0
    OR (SELECT count(*) FROM prospect_results.result_set_items WHERE result_set_id=v_set)<>4 THEN
    RAISE EXCEPTION 'Cleanup did not respect its item budget';
  END IF;
  PERFORM prospect_operations.reclaim_unit_v1('search',3);
  SELECT * INTO v_result FROM prospect_operations.reclaim_unit_v1('search',3);
  IF v_result.items_removed<>1 OR v_result.parents_removed<>1
    OR EXISTS(SELECT 1 FROM prospect_results.result_sets WHERE id=v_set) THEN RAISE EXCEPTION 'Cleanup did not finish parent last'; END IF;
  IF NOT EXISTS(SELECT 1 FROM prospect_results.result_set_items WHERE result_set_id=v_pin) THEN RAISE EXCEPTION 'Cleanup removed an export dependency'; END IF;

  INSERT INTO prospect_operations.operation_jobs(id,actor,action,request_id,entity_type,content_hash,version_vector,status,expires_at)
    VALUES(v_operation,'lifecycle-fixture','fixture',v_operation,'company',v_operation::text,'{}','frozen','-infinity');
  PERFORM prospect_operations.reclaim_unit_v1('operation',3);
  IF NOT EXISTS(SELECT 1 FROM prospect_operations.operation_jobs WHERE id=v_operation) THEN RAISE EXCEPTION 'Cleanup removed an acknowledged unfinished operation'; END IF;

  -- Partly deleted filter values must be restored before extending the TTL.
  SELECT array_agg('lifecycle-fixture-'||i) INTO v_values FROM generate_series(1,8) i;
  SELECT set_id INTO v_filter FROM prospect_filters.create_set_v1('lifecycle-fixture','company','','__website',v_values);
  UPDATE prospect_filters.filter_sets SET expires_at='-infinity' WHERE id=v_filter;
  SELECT * INTO v_result FROM prospect_operations.reclaim_unit_v1('filter',3);
  IF v_result.items_removed<>3 THEN RAISE EXCEPTION 'Filter cleanup budget failed'; END IF;
  PERFORM prospect_filters.create_set_v1('lifecycle-fixture','company','','__website',v_values);
  IF (SELECT count(*) FROM prospect_filters.filter_set_values WHERE filter_set_id=v_filter)<>8 THEN RAISE EXCEPTION 'Filter reuse revived an incomplete set'; END IF;

  UPDATE prospect_results.result_sets SET status='ready',completed_at=clock_timestamp() WHERE id=v_metric;
  UPDATE prospect_results.result_sets SET status='ready' WHERE id=v_metric;
  SELECT sum(jobs) INTO v_count FROM prospect_operations.job_metrics WHERE kind='search' AND outcome='ready';
  IF v_count<>1 THEN RAISE EXCEPTION 'Terminal job was counted more than once'; END IF;
  IF public.background_health_v1()->>'schemaVersion'<>'1' THEN RAISE EXCEPTION 'Background health unavailable'; END IF;
  BEGIN
    PERFORM prospect_operations.reclaim_unit_v1('search',5001);
    RAISE EXCEPTION 'Oversized cleanup was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'PASS: bounded reclamation, export pin, unfinished-operation retention, filter rehydration, terminal metrics and privileges';
END;
$test$;
