-- Claim + one batch + release in ONE transaction. Row locks remain held for
-- the entire unit; a disconnected worker cannot publish a late checkpoint.
-- Existing functions/grants remain available for rollback compatibility.
SET LOCAL lock_timeout = '5s';
CREATE OR REPLACE FUNCTION prospect_operations.run_queue_unit_v1(p_kind text, p_worker text, p_batch integer DEFAULT 5000)
RETURNS TABLE(job_id uuid, total bigint, done boolean, outcome text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, prospect_operations, prospect_results, prospect_exports
AS $function$
DECLARE
  v_id uuid;
  v_result record;
  v_total bigint := 0;
  v_done boolean := false;
  v_error text;
BEGIN
  IF p_kind NOT IN ('search','operation','export') OR p_kind IS NULL
     OR coalesce(btrim(p_worker),'')='' OR length(p_worker)>200
     OR p_batch IS NULL OR p_batch<1 OR p_batch>100000 THEN
    RAISE EXCEPTION 'Invalid background unit' USING ERRCODE='22023';
  END IF;
  -- This permit covers new operations workers, NOT imports/the entire VPS.
  IF NOT pg_try_advisory_xact_lock(hashtextextended('prospect-background-unit-v1',0)) THEN
    RETURN QUERY SELECT NULL::uuid,0::bigint,false,'busy'::text;
    RETURN;
  END IF;
  CASE p_kind
    WHEN 'search' THEN SELECT c.set_id INTO v_id FROM prospect_results.claim_next_v1(p_worker,300) c;
    WHEN 'operation' THEN SELECT c.job_id INTO v_id FROM prospect_operations.claim_next_v1(p_worker,300) c;
    WHEN 'export' THEN SELECT c.job_id INTO v_id FROM prospect_exports.claim_next_v1(p_worker,300) c;
  END CASE;
  IF v_id IS NULL THEN RETURN; END IF;
  -- Claim locks are outside this subtransaction. Failure rolls back only this
  -- unit's changes; prior committed checkpoints remain intact.
  BEGIN
    CASE p_kind
      WHEN 'search' THEN
        SELECT * INTO v_result FROM prospect_results.build_batch_v1(v_id,p_batch);
        v_total := v_result.total; v_done := v_result.done;
        UPDATE prospect_results.result_sets s
          SET status=CASE WHEN v_done THEN s.status ELSE 'pending' END,
              worker_id=NULL,lease_expires_at=NULL,
              completed_at=CASE WHEN v_done THEN clock_timestamp() ELSE s.completed_at END
          WHERE s.id=v_id;
      WHEN 'operation' THEN
        SELECT * INTO v_result FROM prospect_operations.apply_batch_v1(v_id,least(p_batch,5000),300);
        v_total := v_result.applied_items; v_done := v_result.done;
        UPDATE prospect_operations.operation_jobs j
          SET status=CASE WHEN v_done THEN j.status ELSE 'frozen' END,
              worker_id=NULL,lease_expires_at=NULL,
              completed_at=CASE WHEN v_done THEN clock_timestamp() ELSE j.completed_at END
          WHERE j.id=v_id;
      WHEN 'export' THEN
        SELECT * INTO v_result FROM prospect_exports.build_batch_v1(v_id,least(p_batch,25000),300);
        v_total := v_result.total_rows; v_done := v_result.done;
        UPDATE prospect_exports.jobs j
          SET status=CASE WHEN v_done THEN j.status ELSE 'queued' END,
              worker_id=NULL,lease_expires_at=NULL,
              completed_at=CASE WHEN v_done THEN clock_timestamp() ELSE j.completed_at END
          WHERE j.id=v_id;
    END CASE;
  EXCEPTION WHEN OTHERS OR query_canceled THEN
    v_error := 'Background unit failed (SQLSTATE ' || SQLSTATE || ').';
    CASE p_kind
      WHEN 'search' THEN PERFORM prospect_results.fail_set_v1(v_id,v_error);
      WHEN 'operation' THEN PERFORM prospect_operations.fail_v1(v_id,v_error);
      WHEN 'export' THEN PERFORM prospect_exports.fail_v1(v_id,v_error);
    END CASE;
    RETURN QUERY SELECT v_id,0::bigint,true,'failed'::text;
    RETURN;
  END;
  RETURN QUERY SELECT v_id,v_total,v_done,'progress'::text;
END;
$function$;
REVOKE EXECUTE ON FUNCTION prospect_operations.run_queue_unit_v1(text,text,integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION prospect_operations.run_queue_unit_v1(text,text,integer) TO prospect_operator;
DO $assert$
BEGIN
  IF has_function_privilege('anon','prospect_operations.run_queue_unit_v1(text,text,integer)','EXECUTE')
    OR has_function_privilege('authenticated','prospect_operations.run_queue_unit_v1(text,text,integer)','EXECUTE')
    OR has_function_privilege('service_role','prospect_operations.run_queue_unit_v1(text,text,integer)','EXECUTE')
    OR NOT has_function_privilege('prospect_ops_worker','prospect_operations.run_queue_unit_v1(text,text,integer)','EXECUTE')
    OR has_table_privilege('prospect_ops_worker','public.prospect_index','SELECT') THEN
    RAISE EXCEPTION 'Atomic background unit privilege boundary failed';
  END IF;
END;
$assert$;
