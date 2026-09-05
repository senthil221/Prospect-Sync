DO $test$
DECLARE v record; v_kind text; v_table text; v_pending text; v_finished text;
  v_id uuid := '00000000-0000-0000-0000-000000000001';
  v_status text; v_count bigint; v_worker text;
BEGIN
  FOREACH v_kind IN ARRAY ARRAY['search','operation','export'] LOOP
    v_table := CASE v_kind WHEN 'search' THEN 'unit_results.result_sets' WHEN 'operation' THEN 'unit_operations.operation_jobs' ELSE 'unit_exports.jobs' END;
    v_pending := CASE v_kind WHEN 'search' THEN 'pending' WHEN 'operation' THEN 'frozen' ELSE 'queued' END;
    v_finished := CASE v_kind WHEN 'operation' THEN 'completed' ELSE 'ready' END;
    EXECUTE format('INSERT INTO %s(id,status) VALUES($1,$2)',v_table) USING v_id,v_pending;
    SELECT * INTO v FROM unit_operations.run_queue_unit_v1(v_kind,'fixture-worker',1000);
    IF v.total<>1 OR v.done OR v.outcome<>'progress' THEN RAISE EXCEPTION 'first unit failed %',v_kind; END IF;
    EXECUTE format('SELECT status,row_count,worker_id FROM %s WHERE id=$1',v_table) INTO v_status,v_count,v_worker USING v_id;
    IF v_status<>v_pending OR v_count<>1 OR v_worker IS NOT NULL THEN RAISE EXCEPTION 'checkpoint/release failed %',v_kind; END IF;
    SELECT * INTO v FROM unit_operations.run_queue_unit_v1(v_kind,'successor-worker',1000);
    IF v.total<>2 OR NOT v.done THEN RAISE EXCEPTION 'resume failed %',v_kind; END IF;
    EXECUTE format('SELECT status FROM %s WHERE id=$1',v_table) INTO v_status USING v_id;
    IF v_status<>v_finished THEN RAISE EXCEPTION 'terminal status failed %',v_kind; END IF;
    IF (SELECT count(*) FROM public.unit_effects WHERE kind=v_kind)<>2 THEN RAISE EXCEPTION 'duplicate or missing effects'; END IF;
    IF EXISTS(SELECT 1 FROM unit_operations.run_queue_unit_v1(v_kind,'worker',1000)) THEN RAISE EXCEPTION 'completed job reclaimed'; END IF;
    EXECUTE format('UPDATE %s SET status=$2,should_fail=true WHERE id=$1',v_table) USING v_id,v_pending;
    SELECT * INTO v FROM unit_operations.run_queue_unit_v1(v_kind,'failed-worker',1000);
    IF v.outcome<>'failed' THEN RAISE EXCEPTION 'failure not recorded'; END IF;
    IF (SELECT count(*) FROM public.unit_effects WHERE kind=v_kind)<>2 THEN RAISE EXCEPTION 'failed unit leaked effects'; END IF;
    EXECUTE format('SELECT status,row_count FROM %s WHERE id=$1',v_table) INTO v_status,v_count USING v_id;
    IF v_status<>'failed' OR v_count<>2 THEN RAISE EXCEPTION 'failure destroyed prior checkpoint'; END IF;
  END LOOP;
  BEGIN
    PERFORM unit_operations.run_queue_unit_v1('invalid','worker',1000);
    RAISE EXCEPTION 'invalid kind accepted';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  RAISE NOTICE 'PASS: all three queues checkpoint, resume, finish, and roll back failed effects';
END;
$test$;
