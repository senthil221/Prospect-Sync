-- Run AFTER the candidate migration inside an explicitly ROLLED BACK transaction.
-- Private synthetic cache rows only. No customer record writes or heavy searches.
DO $checks$
DECLARE
  v_scope jsonb := '{"search":"codex-v8-admission-regression-only","filters":[]}';
  v_owner text := 'codex-v8-check-' || gen_random_uuid()::text;
  v_first record;
  v_second record;
BEGIN
  SELECT * INTO v_first FROM public.prepare_company_scope_v2(v_owner,v_scope,false);
  IF v_first.status <> 'unavailable' OR v_first.set_id IS NOT NULL THEN
    RAISE EXCEPTION 'Worker-down check created a job';
  END IF;
  SELECT * INTO v_first FROM public.prepare_company_scope_v2(v_owner,v_scope,true);
  SELECT * INTO v_second FROM public.prepare_company_scope_v2(v_owner,v_scope,true);
  IF v_first.set_id IS DISTINCT FROM v_second.set_id OR v_second.status <> 'pending' THEN
    RAISE EXCEPTION 'Identical polls did not reuse the pending job';
  END IF;
  SELECT * INTO v_second FROM public.prepare_company_scope_v2(v_owner,v_scope,false);
  IF v_first.set_id IS DISTINCT FROM v_second.set_id THEN RAISE EXCEPTION 'Pending job lookup was lost during outage'; END IF;
  UPDATE prospect_results.result_sets SET status='ready',row_count=0,completed_at=clock_timestamp() WHERE id=v_first.set_id;
  SELECT * INTO v_second FROM public.prepare_company_scope_v2(v_owner,v_scope,false);
  IF v_second.status <> 'ready' OR v_first.set_id IS DISTINCT FROM v_second.set_id THEN
    RAISE EXCEPTION 'Ready results require a worker';
  END IF;
  SELECT * INTO v_second FROM public.prepare_company_scope_v2(v_owner || '-different',v_scope,false);
  IF v_second.set_id IS NOT NULL THEN RAISE EXCEPTION 'Prepared owner isolation failed'; END IF;
  IF has_function_privilege('anon','public.prepare_company_scope_v2(text,jsonb,boolean)','EXECUTE')
    OR has_function_privilege('authenticated','public.prepare_company_scope_v2(text,jsonb,boolean)','EXECUTE')
    OR has_table_privilege('prospect_ops_worker','public.prospects','SELECT') THEN
    RAISE EXCEPTION 'Privilege boundary failed';
  END IF;
  IF position('completed_at=clock_timestamp()' in pg_get_functiondef('prospect_results.build_batch_v1(uuid,integer)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'Builder completion still uses transaction-start time';
  END IF;
  RAISE NOTICE 'PASS: no enqueue during outage, pending/ready reuse, owner isolation, grants, completion timestamp';
END;
$checks$;
