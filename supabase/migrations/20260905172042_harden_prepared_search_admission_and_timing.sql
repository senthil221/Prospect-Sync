-- Backward-compatible: v1 remains available to the previous app image.
-- No customer records or historical timestamps are rewritten.
SET LOCAL lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.prepare_company_scope_v2(p_owner_id text, p_scope jsonb, p_allow_enqueue boolean DEFAULT true)
RETURNS TABLE(set_id uuid, status text, row_count bigint, error text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, prospect_results
SET statement_timeout = '5s'
AS $function$
DECLARE
  v_search text := coalesce(p_scope->>'search','');
  v_filters jsonb := coalesce(p_scope->'filters','[]'::jsonb);
  v_versions jsonb := public.data_versions_v1(array['company']);
  v_hash text;
  v_row prospect_results.result_sets%rowtype;
BEGIN
  IF coalesce(btrim(p_owner_id),'') = '' OR (btrim(v_search)='' AND v_filters='[]'::jsonb) THEN
    RAISE EXCEPTION 'An owner and company search are required' USING errcode='22023';
  END IF;
  -- Versions are in the identity, not merely an after-the-fact stale flag.
  -- The creation bucket keeps expired rows from conflicting with replacements.
  -- Reuse below is by full content and version for the entire 24-hour TTL,
  -- including builds that straddle an hour boundary.
  v_hash := 'company-pivot-v1:' || md5(jsonb_build_array(v_search,v_filters,v_versions,date_trunc('hour',now()))::text);
  -- Concurrent browser polls share one job. The lock is held only while
  -- enqueueing, never while the text search runs.
  PERFORM pg_advisory_xact_lock(hashtextextended('company-pivot-queue-v1',0));
  SELECT * INTO v_row FROM prospect_results.result_sets s
    WHERE s.owner_id=p_owner_id AND s.entity_type='company' AND s.client_scope=''
      AND s.content_hash LIKE 'company-pivot-v1:%' AND s.expires_at>now()
      AND s.search=v_search AND s.filters=v_filters AND s.version_vector=v_versions
    ORDER BY s.created_at DESC LIMIT 1;
  IF FOUND AND NOT (v_row.status='failed' AND v_row.completed_at < now()-interval '30 seconds') THEN
    RETURN QUERY SELECT v_row.id,v_row.status,v_row.row_count,v_row.error;
    RETURN;
  END IF;
  IF NOT coalesce(p_allow_enqueue,false) THEN
    RETURN QUERY SELECT NULL::uuid,'unavailable'::text,0::bigint,NULL::text;
    RETURN;
  END IF;
  IF (SELECT count(*) FROM prospect_results.result_sets s WHERE s.owner_id=p_owner_id
        AND s.content_hash LIKE 'company-pivot-v1:%' AND s.status IN ('pending','building') AND s.expires_at>now()) >= 4
    OR (SELECT count(*) FROM prospect_results.result_sets s WHERE s.content_hash LIKE 'company-pivot-v1:%'
        AND s.status IN ('pending','building') AND s.expires_at>now()) >= 12 THEN
    RAISE EXCEPTION 'Several company searches are already being prepared. Please try again shortly.' USING errcode='53300';
  END IF;
  INSERT INTO prospect_results.result_sets
    (owner_id,entity_type,client_scope,content_hash,version_vector,search,filters,expires_at)
  VALUES(p_owner_id,'company','',v_hash,v_versions,v_search,v_filters,now()+interval '24 hours')
  RETURNING * INTO v_row;
  RETURN QUERY SELECT v_row.id,v_row.status,v_row.row_count,v_row.error;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.prepare_company_scope_v2(text,jsonb,boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_company_scope_v2(text,jsonb,boolean) TO service_role;


-- now() is transaction start, not the instant the expensive query finishes.
-- Restrict the replacement to the known wrapper and fail if its shape drifted.
DO $timing$
DECLARE v_source text;
BEGIN
  v_source := pg_get_functiondef('prospect_results.build_batch_v1(uuid,integer)'::regprocedure);
  IF position('completed_at=now()' in v_source)=0
    OR position('company-pivot-v1:' in v_source)=0 THEN
    RAISE EXCEPTION 'Prepared builder changed; review timing migration before applying';
  END IF;
  EXECUTE replace(v_source,'completed_at=now()','completed_at=clock_timestamp()');
END;
$timing$;

-- Readiness probes must never require any table grants.
DO $grants$
BEGIN
  IF has_function_privilege('anon','public.prepare_company_scope_v2(text,jsonb,boolean)','EXECUTE')
    OR has_function_privilege('authenticated','public.prepare_company_scope_v2(text,jsonb,boolean)','EXECUTE') THEN
    RAISE EXCEPTION 'Prepared enqueue must remain service-role only';
  END IF;
END;
$grants$;
