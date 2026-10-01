-- Filter a client's People by Date Contacted.
--
-- Date Contacted (the per-client cooldown clock) is client_prospects.date_added
-- - the same field Contactable reads and the People grid shows. It could be
-- seen and set, but not filtered. New People filter field
-- __client_date_contacted, values '<client id>' then calendar dates:
--
--   never     [client]                  no contact date for this client
--   before    [client, d]               date_added <  d
--   on        [client, d]               date_added =  d
--   after     [client, d]               date_added >= d   ("on or after")
--   between   [client, from, through]   from <= date_added <= through
--
-- Dates are plain calendar dates because date_added is a date - no time zone
-- arithmetic, unlike Last Verified's timestamps. lib/prospect-filters.ts
-- validates the shape before anything reaches here.
--
-- Spliced into the SQL builder and the row matcher the same way Lead and
-- Contactable were (20260915110000): read the deployed body, replace an anchor
-- that occurs exactly once, raise if it is missing. The proof below checks the
-- two select the same rows for every operator.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

do $patch_date_contacted$
declare
  v_definition text;
  v_rewritten text;
begin
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('__client_date_contacted' in v_definition) = 0 then
    v_rewritten := replace(v_definition,
      $old$    if field_key in ('__lead', '__contactable') then$old$,
      $new$    -- Date Contacted for one client: values are the client id, then dates.
    if field_key = '__client_date_contacted' then
      if cardinality(raw_values) < 1 then continue; end if;
      candidate_expr := case operator_key
        when 'never' then 'cp.date_added is null'
        when 'before' then case when cardinality(raw_values) >= 2 then format('cp.date_added < %L::date', raw_values[2]) end
        when 'on' then case when cardinality(raw_values) >= 2 then format('cp.date_added = %L::date', raw_values[2]) end
        when 'after' then case when cardinality(raw_values) >= 2 then format('cp.date_added >= %L::date', raw_values[2]) end
        when 'between' then case when cardinality(raw_values) >= 3
          then format('cp.date_added between %L::date and %L::date', raw_values[2], raw_values[3]) end
      end;
      if candidate_expr is null then
        conjuncts := array_append(conjuncts, 'false');
        continue;
      end if;
      conjuncts := conjuncts || format($dc$(exists (select 1 from public.client_prospects cp
        where cp.prospect_id = pi.id and cp.client_id = %L and %s))$dc$, raw_values[1], candidate_expr);
      continue;
    end if;

    if field_key in ('__lead', '__contactable') then$new$);
    if v_rewritten = v_definition then raise exception 'Could not patch prospect_filter_sql_v1 for Date Contacted'; end if;
    execute v_rewritten;
  end if;

  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if position('__client_date_contacted' in v_definition) = 0 then
    v_rewritten := replace(v_definition,
      $old$      when filter_item->>'field' = '__lead' then ($old$,
      $new$      when filter_item->>'field' = '__client_date_contacted' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or exists (select 1 from public.client_prospects cp
                    where cp.prospect_id = (p_row).id and cp.client_id = filter_item->'values'->>0
                      and coalesce(case coalesce(filter_item->>'operator', 'on')
                        when 'never' then cp.date_added is null
                        when 'before' then cp.date_added < (filter_item->'values'->>1)::date
                        when 'on' then cp.date_added = (filter_item->'values'->>1)::date
                        when 'after' then cp.date_added >= (filter_item->'values'->>1)::date
                        when 'between' then cp.date_added between (filter_item->'values'->>1)::date
                                                              and (filter_item->'values'->>2)::date
                        else false end, false))
      )
      when filter_item->>'field' = '__lead' then ($new$);
    if v_rewritten = v_definition then raise exception 'Could not patch prospect_index_matches_v1 for Date Contacted'; end if;
    execute v_rewritten;
  end if;
end;
$patch_date_contacted$;

-- ---------------------------------------------------------------------------
-- Proof, read-only: on 2,000 of a real client's people, the builder and the row
-- matcher select the same rows for every operator, and both agree with
-- client_prospects directly. (Bounded: the row matcher is slow by design.)
do $$
declare
  v_client text;
  v_day date;
  v_ids text[];
  v_filter jsonb;
  v_compiled integer;
  v_matched integer;
  v_direct integer;
  v_case jsonb;
begin
  select cp.client_id into v_client
    from public.client_prospects cp
   where cp.date_added is not null
   limit 1;
  if v_client is null then
    raise notice 'Date Contacted proof skipped: no client with contact dates.';
    return;
  end if;
  -- A sample with both dated and undated people when the client has them.
  select array_agg(prospect_id) into v_ids from (
    (select prospect_id from public.client_prospects where client_id = v_client and date_added is not null limit 1500)
    union all
    (select prospect_id from public.client_prospects where client_id = v_client and date_added is null limit 500)) sample;
  select min(date_added) into v_day from public.client_prospects where client_id = v_client and prospect_id = any(v_ids);

  foreach v_case in array array[
    jsonb_build_object('op', 'never', 'values', jsonb_build_array(v_client)),
    jsonb_build_object('op', 'before', 'values', jsonb_build_array(v_client, (v_day + 1)::text)),
    jsonb_build_object('op', 'on', 'values', jsonb_build_array(v_client, v_day::text)),
    jsonb_build_object('op', 'after', 'values', jsonb_build_array(v_client, v_day::text)),
    jsonb_build_object('op', 'between', 'values', jsonb_build_array(v_client, v_day::text, (v_day + 30)::text))] loop
    v_filter := jsonb_build_array(jsonb_build_object('field', '__client_date_contacted',
      'operator', v_case->>'op', 'values', v_case->'values'));
    execute format('select count(*) from public.prospect_index pi where pi.id = any($1) and %s',
      public.prospect_filter_sql_v1('', v_filter)) into v_compiled using v_ids;
    select count(*) into v_matched from public.prospect_index pi
     where pi.id = any(v_ids) and public.prospect_index_matches_v1(pi, '', v_filter);
    select count(*) into v_direct
      from public.client_prospects cp join public.prospect_index pi on pi.id = cp.prospect_id
     where cp.client_id = v_client and cp.prospect_id = any(v_ids)
       and case v_case->>'op'
             when 'never' then cp.date_added is null
             when 'before' then cp.date_added < v_day + 1
             when 'on' then cp.date_added = v_day
             when 'after' then cp.date_added >= v_day
             else cp.date_added between v_day and v_day + 30 end;
    if v_compiled <> v_matched or v_compiled <> v_direct then
      raise exception 'Date Contacted proof: % compiled %, matched %, direct %', v_case->>'op', v_compiled, v_matched, v_direct;
    end if;
  end loop;
  -- A date operator without its date restricts to nothing.
  v_filter := '[{"field":"__client_date_contacted","operator":"before","values":["x"]}]'::jsonb;
  if public.prospect_filter_sql_v1('', v_filter) not like '%false%' then
    raise exception 'Date Contacted proof: a date operator without a date did not compile to false';
  end if;
  raise notice 'Date Contacted proof passed on % people.', cardinality(v_ids);
end $$;
