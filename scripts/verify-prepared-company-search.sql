-- Run inside a transaction AFTER the proposed migration and baseline filter
-- preamble. Finishes with ROLLBACK: no definitions, jobs, or data persist.
CREATE TEMP TABLE prepared_search_measurements(case_name text,terms int,stage text,elapsed_ms numeric,rows bigint);
CREATE TEMP TABLE prepared_search_cases(n int,filters jsonb);
WITH original AS (
  SELECT array(SELECT jsonb_array_elements_text(:'filters'::jsonb->0->'values')) vals
), extra AS (
  SELECT a || ' ' || b value FROM unnest(ARRAY['cloud','enterprise','network','software','infrastructure','data','IT','application','security','digital','platform','business','technology','database','systems']) a
  CROSS JOIN unnest(ARRAY['consulting','services','support','management','integration','migration','engineering','development','automation','solutions']) b
), all_terms AS (
  SELECT vals || ARRAY(SELECT value FROM extra WHERE NOT(value=ANY(vals)) ORDER BY value) vals FROM original
)
INSERT INTO prepared_search_cases SELECT n,jsonb_set(:'filters'::jsonb,'{0,values}',to_jsonb(vals[1:n]))
FROM all_terms CROSS JOIN unnest(ARRAY[51,100,150]) n;

-- Each case is its own bounded statement (psql \gexec below), like worker work.
CREATE FUNCTION pg_temp.verify_case(p_n int) RETURNS void LANGUAGE plpgsql AS $test$
DECLARE
  f jsonb; sc jsonb; prepared jsonb; r record; q record; set_id uuid; other_id uuid;
  t timestamptz; old_digest text; new_digest text; old_n bigint; cached_n bigint; v jsonb;
  client_key text; people_filters jsonb;
BEGIN
  SELECT filters INTO f FROM prepared_search_cases WHERE n=p_n;
  sc:=jsonb_build_object('search','','filters',f,'limit',250000);
  t:=clock_timestamp();
  SELECT count(*),md5(string_agg(company_id,chr(10) ORDER BY company_id)) INTO old_n,old_digest
    FROM prospect_results.uncached_company_scope_ids_v1(NULL,sc);
  INSERT INTO prepared_search_measurements VALUES('reported-and-expanded',p_n,'baseline scope',extract(epoch FROM clock_timestamp()-t)*1000,old_n);

  t:=clock_timestamp();
  SELECT * INTO r FROM public.prepare_company_scope_v1('codex-performance-verification',sc);
  set_id:=r.set_id;
  SELECT x.set_id INTO other_id FROM public.prepare_company_scope_v1('codex-performance-verification',sc) x;
  IF set_id<>other_id THEN RAISE EXCEPTION 'Duplicate preparation did not reuse its job'; END IF;
  INSERT INTO prepared_search_measurements VALUES('reported-and-expanded',p_n,'enqueue and duplicate reuse',extract(epoch FROM clock_timestamp()-t)*1000,0);

  t:=clock_timestamp();
  PERFORM * FROM prospect_results.build_batch_v1(set_id,25000);
  INSERT INTO prepared_search_measurements VALUES('reported-and-expanded',p_n,'prepare once',extract(epoch FROM clock_timestamp()-t)*1000,old_n);
  prepared:=sc||jsonb_build_object('_prepared_set_id',set_id,'_prepared_owner','codex-performance-verification');
  SELECT count(*),md5(string_agg(company_id,chr(10) ORDER BY company_id)) INTO cached_n,new_digest
    FROM public.company_scope_ids_v2(NULL,prepared);
  IF old_n<>cached_n OR old_digest IS DISTINCT FROM new_digest THEN RAISE EXCEPTION 'Company memberships changed for % terms',p_n; END IF;

  t:=clock_timestamp();
  SELECT * INTO r FROM public.search_prospect_workspace_v12(p_company_scope=>prepared,p_with_total=>true);
  INSERT INTO prepared_search_measurements VALUES('reported-and-expanded',p_n,'People page + exact count',extract(epoch FROM clock_timestamp()-t)*1000,r.total_count);
  IF p_n=51 AND r.total_count<>81477 THEN RAISE EXCEPTION 'Reported filter count changed: %',r.total_count; END IF;
  IF p_n=51 THEN
    SELECT * INTO q FROM public.search_prospect_workspace_v12(p_company_scope=>sc,p_with_total=>true);
    IF r.result_rows IS DISTINCT FROM q.result_rows OR r.total_count<>q.total_count THEN
      RAISE EXCEPTION 'People page/order/count changed';
    END IF;
    SELECT id INTO client_key FROM public.clients ORDER BY id LIMIT 1;
    people_filters:='[{"field":"__title","operator":"contains","values":["manager"]}]'::jsonb;
    SELECT * INTO q FROM public.search_prospect_workspace_v12(p_company_scope=>sc,p_filters=>people_filters,p_client_id=>client_key,p_with_total=>true);
    SELECT * INTO r FROM public.search_prospect_workspace_v12(p_company_scope=>prepared,p_filters=>people_filters,p_client_id=>client_key,p_with_total=>true);
    IF r.result_rows IS DISTINCT FROM q.result_rows OR r.total_count<>q.total_count THEN
      RAISE EXCEPTION 'Combined People filters/client scope changed';
    END IF;
    SELECT count(*) INTO cached_n FROM public.company_scope_ids_v2(NULL,prepared||'{"limit":1000}'::jsonb);
    IF cached_n<>least(old_n,1000) THEN RAISE EXCEPTION 'Existing company scope limit changed'; END IF;
    SELECT * INTO r FROM public.search_prospect_workspace_v12(p_company_scope=>prepared,p_with_total=>true);
  END IF;
  v:=r.data_versions;
  t:=clock_timestamp();
  SELECT * INTO r FROM public.search_prospect_workspace_v12(p_company_scope=>prepared,p_offset=>50,p_with_total=>false,p_known_versions=>v);
  INSERT INTO prepared_search_measurements VALUES('reported-and-expanded',p_n,'People second page',extract(epoch FROM clock_timestamp()-t)*1000,jsonb_array_length(r.result_rows));
  IF r.total_count IS NOT NULL THEN RAISE EXCEPTION 'Second page unnecessarily recounted'; END IF;

  t:=clock_timestamp();
  SELECT * INTO r FROM public.prepared_company_listing_v1('codex-performance-verification',set_id,'',f);
  INSERT INTO prepared_search_measurements VALUES('reported-and-expanded',p_n,'Companies page + exact count',extract(epoch FROM clock_timestamp()-t)*1000,r.total_count);
  -- Compare the full company page contract, including order and exact metrics.
  SELECT * INTO q FROM public.filter_companies_v4('',f);
  IF r.result_rows IS DISTINCT FROM q.result_rows OR r.total_count<>q.total_count
    OR r.covered_count<>q.covered_count OR r.prospect_total<>q.prospect_total THEN
    RAISE EXCEPTION 'Prepared company listing changed its page or metrics';
  END IF;

  BEGIN
    PERFORM * FROM public.company_scope_ids_v2(NULL,prepared||jsonb_build_object('_prepared_owner','different-owner'));
    RAISE EXCEPTION 'Owner check did not reject';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL; END;
  BEGIN
    PERFORM * FROM public.company_scope_ids_v2(NULL,prepared||'{"search":"a different search"}'::jsonb);
    RAISE EXCEPTION 'Content check did not reject';
  EXCEPTION WHEN SQLSTATE 'P0002' THEN NULL; END;
  SELECT version_vector INTO v FROM prospect_results.result_sets WHERE id=set_id;
  UPDATE prospect_results.result_sets SET version_vector='{}' WHERE id=set_id;
  BEGIN
    PERFORM * FROM public.company_scope_ids_v2(NULL,prepared);
    RAISE EXCEPTION 'Stale check did not reject';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
  UPDATE prospect_results.result_sets SET version_vector=v WHERE id=set_id;
  RAISE NOTICE 'PASS: % terms; membership, page, count, owner, content, stale checks',p_n;
END;
$test$;
SET LOCAL statement_timeout='120s';
SELECT format('SELECT pg_temp.verify_case(%s)',n) FROM prepared_search_cases ORDER BY n \gexec
SELECT case_name,terms,stage,round(elapsed_ms) ms,rows FROM prepared_search_measurements;
SELECT has_function_privilege('prospect_ops_worker','prospect_results.build_batch_v1(uuid,integer)','execute') worker_can_build,
  NOT has_function_privilege('authenticated','public.prepare_company_scope_v1(text,jsonb)','execute') authenticated_cannot_enqueue,
  NOT has_table_privilege('prospect_ops_worker','prospect_results.result_set_items','select') worker_cannot_read_items;
ROLLBACK;
