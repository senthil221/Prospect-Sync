-- Prepare expensive company-description scopes once on the existing worker.
-- The reported 51-term pivot returns 81,477 people but takes 9.4s each time.
-- No search semantics, timeouts, caps, or customer records change here.
-- New objects remain private; rollback is to restore the two saved functions.
SET LOCAL lock_timeout = '5s';

-- Preserve the existing paths verbatim for ordinary queries and bulk jobs.
DO $copy$
DECLARE v_source text;
BEGIN
  v_source := pg_get_functiondef('public.company_scope_ids_v2(text,jsonb)'::regprocedure);
  EXECUTE replace(v_source, 'FUNCTION public.company_scope_ids_v2(',
    'FUNCTION prospect_results.uncached_company_scope_ids_v1(');
  v_source := pg_get_functiondef('prospect_results.build_batch_v1(uuid,integer)'::regprocedure);
  EXECUTE replace(v_source, 'FUNCTION prospect_results.build_batch_v1(',
    'FUNCTION prospect_results.build_regular_batch_v1(');
END;
$copy$;
REVOKE EXECUTE ON FUNCTION prospect_results.uncached_company_scope_ids_v1(text,jsonb) FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION prospect_results.build_regular_batch_v1(uuid,integer) FROM public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.prepare_company_scope_v1(p_owner_id text, p_scope jsonb)
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
REVOKE EXECUTE ON FUNCTION public.prepare_company_scope_v1(text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_company_scope_v1(text,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION prospect_results.build_batch_v1(p_set_id uuid,p_batch_size integer DEFAULT 25000)
RETURNS TABLE(inserted integer,total bigint,done boolean)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, prospect_results
SET statement_timeout = '120s'
AS $function$
DECLARE v_row prospect_results.result_sets%rowtype; v_count integer; v_predicate text;
BEGIN
  SELECT * INTO v_row FROM prospect_results.result_sets WHERE id=p_set_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Result set does not exist' USING errcode='P0002'; END IF;
  IF v_row.content_hash NOT LIKE 'company-pivot-v1:%' THEN
    RETURN QUERY SELECT * FROM prospect_results.build_regular_batch_v1(p_set_id,p_batch_size);
    RETURN;
  END IF;
  IF v_row.status NOT IN ('pending','building') THEN
    RETURN QUERY SELECT 0,v_row.row_count,true;
    RETURN;
  END IF;
  IF v_row.entity_type<>'company' OR v_row.client_scope<>'' OR v_row.company_scope<>'{}'::jsonb THEN
    RAISE EXCEPTION 'Invalid prepared company search' USING errcode='22023';
  END IF;
  -- One worker statement and snapshot. Keep the full set for Companies; the
  -- People resolver applies its established scope ceiling on read.
  v_predicate := coalesce(public.company_full_scan_filter_sql_v1(v_row.search,v_row.filters),
    format('public.company_matches_filters_v1(c,%L,%L::jsonb)',v_row.search,v_row.filters::text));
  EXECUTE format($query$
    WITH stored AS (
      INSERT INTO prospect_results.result_set_items(result_set_id,ordinal,entity_id)
      SELECT %L::uuid,row_number() OVER(ORDER BY c.id),c.id FROM public.companies c WHERE %s
      ON CONFLICT DO NOTHING RETURNING 1
    ) SELECT count(*)::integer FROM stored
  $query$,p_set_id,v_predicate) INTO v_count;
  UPDATE prospect_results.result_sets
    SET status='ready',row_count=v_count,completed_at=now(),lease_expires_at=NULL,worker_id=NULL
    WHERE id=p_set_id;
  RETURN QUERY SELECT v_count,v_count::bigint,true;
END;
$function$;
REVOKE EXECUTE ON FUNCTION prospect_results.build_batch_v1(uuid,integer) FROM public, anon, authenticated;
-- CREATE OR REPLACE retains the existing worker grants. It gains no table access.

CREATE OR REPLACE FUNCTION public.company_scope_ids_v2(p_client_id text,p_company_scope jsonb)
RETURNS TABLE(company_id text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, prospect_results
AS $function$
DECLARE
  v_row prospect_results.result_sets%rowtype;
  v_limit integer := CASE WHEN coalesce(p_company_scope->>'limit','') ~ '^[0-9]+$'
    THEN greatest(1000,least((p_company_scope->>'limit')::bigint,250000))::integer ELSE 250000 END;
BEGIN
  IF NOT (p_company_scope ? '_prepared_set_id') THEN
    RETURN QUERY SELECT * FROM prospect_results.uncached_company_scope_ids_v1(p_client_id,p_company_scope);
    RETURN;
  END IF;
  -- These two fields are added by the authorized API, never accepted by
  -- parseCompanyScope. Recheck ownership and content inside the database too.
  SELECT * INTO v_row FROM prospect_results.result_sets s
    WHERE s.id=(p_company_scope->>'_prepared_set_id')::uuid
      AND s.owner_id=p_company_scope->>'_prepared_owner'
      AND s.entity_type='company' AND s.client_scope='' AND s.company_scope='{}'::jsonb
      AND s.content_hash LIKE 'company-pivot-v1:%'
      AND s.search=coalesce(p_company_scope->>'search','')
      AND s.filters=coalesce(p_company_scope->'filters','[]'::jsonb)
      AND s.status='ready' AND s.expires_at>now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prepared company search is unavailable' USING errcode='P0002';
  END IF;
  IF v_row.version_vector IS DISTINCT FROM public.data_versions_v1(array['company']) THEN
    RAISE EXCEPTION 'Company data changed while preparing this search' USING errcode='40001';
  END IF;
  RETURN QUERY SELECT i.entity_id FROM prospect_results.result_set_items i
    WHERE i.result_set_id=v_row.id ORDER BY i.entity_id LIMIT v_limit;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.company_scope_ids_v2(text,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.company_scope_ids_v2(text,jsonb) TO service_role;

-- The global Companies page reads the same prepared membership. A People pivot
-- or client-company view keeps its existing resolver; its semantics differ.
CREATE OR REPLACE FUNCTION public.prepared_company_listing_v1(
  p_owner_id text,p_set_id uuid,p_search text,p_filters jsonb,
  p_limit integer DEFAULT 50,p_offset integer DEFAULT 0,p_known_versions jsonb DEFAULT NULL)
RETURNS TABLE(result_rows jsonb,total_count integer,covered_count integer,prospect_total integer,total_capped boolean,data_versions jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public, prospect_results
SET statement_timeout = '10s'
AS $function$
DECLARE v_row prospect_results.result_sets%rowtype; v_versions jsonb; v_count boolean;
BEGIN
  SELECT * INTO v_row FROM prospect_results.result_sets s WHERE s.id=p_set_id AND s.owner_id=p_owner_id
    AND s.entity_type='company' AND s.client_scope='' AND s.company_scope='{}'::jsonb
    AND s.content_hash LIKE 'company-pivot-v1:%' AND s.status='ready' AND s.expires_at>now()
    AND s.search=coalesce(p_search,'') AND s.filters=coalesce(p_filters,'[]'::jsonb);
  IF NOT FOUND THEN RAISE EXCEPTION 'Prepared company search is unavailable' USING errcode='P0002'; END IF;
  IF v_row.version_vector IS DISTINCT FROM public.data_versions_v1(array['company']) THEN
    RAISE EXCEPTION 'Company data changed while preparing this search' USING errcode='40001';
  END IF;
  v_versions := public.data_versions_v1(array['company','prospect']);
  v_count := p_known_versions IS NULL OR p_known_versions<>v_versions;
  RETURN QUERY
    WITH page AS (
      SELECT c.id,c.name,c.domain,c.created_at,c.prospect_count,c.client_count
      FROM public.companies c JOIN prospect_results.result_set_items i ON i.entity_id=c.id AND i.result_set_id=p_set_id
      ORDER BY c.prospect_count DESC,lower(c.name),c.id
      LIMIT greatest(1,least(coalesce(p_limit,50),5000)) OFFSET greatest(0,coalesce(p_offset,0))
    ), counted AS (
      SELECT count(*)::integer n,count(*) FILTER(WHERE c.prospect_count>0)::integer covered,
        coalesce(sum(c.prospect_count),0)::integer prospects
      FROM public.companies c JOIN prospect_results.result_set_items i ON i.entity_id=c.id AND i.result_set_id=p_set_id
      WHERE v_count
    ) SELECT coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY page.prospect_count DESC,lower(page.name),page.id) FROM page),'[]'::jsonb),
      CASE WHEN v_count THEN counted.n END,CASE WHEN v_count THEN counted.covered END,
      CASE WHEN v_count THEN counted.prospects END,false,v_versions FROM counted;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.prepared_company_listing_v1(text,uuid,text,jsonb,integer,integer,jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prepared_company_listing_v1(text,uuid,text,jsonb,integer,integer,jsonb) TO service_role;

-- Cache rows use the existing private schema, grants, and worker retention.
-- No table DDL or customer-data rewrite is needed for this release.
