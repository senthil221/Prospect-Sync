-- Leads and Contactable: two client-scoped views of a shared prospect.
--
-- WHY NEITHER ADDS A COLUMN TO prospect_index. Both are client-scoped state,
-- and the client workspace already emits `pi.client_ids @> array[<client>]` as
-- its first conjunct, served by idx_prospect_index_client_ids. Every candidate
-- row is narrowed to one client's membership before either predicate runs, and
-- each predicate is then a semi-join against public.client_prospects - 688,356
-- rows across 3 clients, already indexed by prospect_id.
--
-- The alternative was denormalising both onto prospect_index: widening
-- reindex_prospects, backfilling 674,804 rows, and draining that through
-- reindex_backlog. All of it to replace a hash semi-join over one client's
-- membership. Rejected. Nothing in this file touches prospect_index, so nothing
-- in this file needs re-indexing.
--
-- WHY LEAD IS A COLUMN AND NOT A RESERVED TAG. A tag is a name, and names are
-- editable: renaming "Lead" to "Leads" would silently empty the tab. A lead
-- also wants a timestamp and an actor, which client_prospects gives as columns.
-- client_prospects is explicitly the table for this - its own header says it
-- exists so there is somewhere to store an ICP-verified flag or a client-scoped
-- decision, and is_lead is the same shape as icp_verified.
--
-- WHICH CLOCK "CONTACTABLE" READS. client_prospects.date_added, the field the
-- UI calls Client Date Contacted - NOT contact_events. 20260908141654 moved the
-- cooldown there deliberately, because imported contact dates lived in
-- date_added and the old contact_events reading showed them as never contacted.
-- lib/client-idle-age.ts computes the badge from the same field, and
-- 20260908181225 computes next_eligible_at from it. A tab built on
-- contact_events would disagree with the badge on the very same row.
--
-- The expression is (now() at time zone 'UTC')::date for the same reason: it
-- has to be character-for-character what list_workspace and clientIdleAge use,
-- or the tab and the badge differ by a day for anyone west of UTC.
--
-- BLOCKED PROSPECTS ARE NOT CONTACTABLE. status = 'blocked' is
-- suppressed-not-deleted; such a row still appears in the workspace with a
-- badge, and offering it as contactable would be offering a suppression to be
-- ignored.
--
-- THE TWO IMPLEMENTATIONS MUST AGREE. prospect_filter_sql_v1 builds set-based
-- SQL and prospect_index_matches_v1 tests one row; a listing uses the first and
-- a frozen bulk operation the second. They cannot share code - one has to be
-- indexable and the other per-row - so the assertion block at the bottom
-- compares their answers on real rows rather than trusting that they match.
-- ---------------------------------------------------------------------------

-- add column ... default false is metadata-only in PG11+, so this does not
-- rewrite 688,356 rows or hold a lock while it runs.
alter table public.client_prospects
  add column if not exists is_lead boolean not null default false,
  add column if not exists lead_marked_at timestamptz,
  add column if not exists lead_marked_by text not null default '';

comment on column public.client_prospects.is_lead is
  'Client-scoped lead mark. Deliberately a column, not a tag: a tag name can be renamed and would silently empty the Leads tab.';

-- Partial: the index holds only marked rows, which is a small fraction of the
-- table. A non-partial index here would be the size of the whole membership.
create index if not exists idx_client_prospects_lead
  on public.client_prospects (client_id, prospect_id) where is_lead;

-- ---------------------------------------------------------------------------
-- Teach the two People filter paths about __lead and __contactable.
--
-- Spliced rather than rewritten, using the technique from 20260908141654: read
-- the deployed body, replace a known anchor, RAISE if the anchor is missing.
-- Every anchor below was confirmed to occur exactly once in the live database
-- before this was written. A silently skipped splice is the failure mode that
-- matters here - it leaves the builder and the matcher disagreeing, which
-- returns wrong rows rather than an error.
do $patch_client_state$
declare
  v_definition text;
  v_rewritten text;
begin
  -- 1. The SQL builder. Handled before the candidate_expr CASE, because these
  --    are exists() shapes rather than a column to compare against - the same
  --    reason __lists, __clients and __employee_count are special-cased.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    lowered := array(select lower(value) from unnest(raw_values) value);$old$,
    $new$    lowered := array(select lower(value) from unnest(raw_values) value);

    -- Client-scoped state. Values are client ids. contains/equals asks for the
    -- state, not_contains/not_equals for its complement.
    if field_key in ('__lead', '__contactable') then
      -- No values restricts nothing, which is what the row matcher does too.
      -- Returning null here would push every surface onto the row matcher for
      -- the whole query.
      if cardinality(raw_values) = 0 then continue; end if;
      if field_key = '__lead' then
        candidate_expr := format($lead$exists (select 1 from public.client_prospects cp
          where cp.prospect_id = pi.id and cp.is_lead and cp.client_id = any (%L::text[]))$lead$, raw_values);
      else
        candidate_expr := format($contact$exists (select 1 from public.client_prospects cp
          where cp.prospect_id = pi.id and cp.status = 'active' and cp.client_id = any (%L::text[])
            and (cp.date_added is null or cp.date_added <= ((now() at time zone 'UTC')::date
              - coalesce((select s.cooldown_days from public.client_settings s where s.client_id = cp.client_id), 90))))$contact$, raw_values);
      end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || ('(not ' || candidate_expr || ')');
      else
        conjuncts := conjuncts || ('(' || candidate_expr || ')');
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_filter_sql_v1 for client state'; end if;
  execute v_rewritten;

  -- 2. The row matcher. The operator CASE is wrapped in a field CASE so these
  --    two fields are answered before the operator dispatch ever sees them.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    where not case coalesce(filter_item->>'operator', 'contains')$old$,
    $new$    where not case
      when filter_item->>'field' = '__lead' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.client_prospects cp
                  where cp.prospect_id = (p_row).id and cp.is_lead
                    and cp.client_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__contactable' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.client_prospects cp
                  where cp.prospect_id = (p_row).id and cp.status = 'active'
                    and cp.client_id = any (select value from jsonb_array_elements_text(filter_item->'values'))
                    and (cp.date_added is null or cp.date_added <= ((now() at time zone 'UTC')::date
                      - coalesce((select s.cooldown_days from public.client_settings s where s.client_id = cp.client_id), 90))))))
      )
      else case coalesce(filter_item->>'operator', 'contains')$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_index_matches_v1 for client state'; end if;
  v_definition := v_rewritten;

  -- Close the field CASE that now wraps the operator CASE.
  v_rewritten := replace(v_definition,
    $old$    end
  );
$old$,
    $new$    end end
  );
$new$);
  if v_rewritten = v_definition then raise exception 'Could not close the wrapped CASE in prospect_index_matches_v1'; end if;
  execute v_rewritten;
end $patch_client_state$;

-- ---------------------------------------------------------------------------
-- Marking leads, in the shape set_icp_verified_v1 already runs in.
--
-- The one deliberate difference: no reindex_scope_v1 call. A lead mark changes
-- nothing that prospect_index carries, so re-indexing would be pure cost. The
-- return shape keeps 'queued' so callers that merge results do not have to care.
create or replace function public.set_client_lead_v1(
  p_client_id text,
  p_is_lead boolean,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_prospect_ids text[] default null::text[],
  p_excluded_ids text[] default null::text[],
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_ids text[];
  v_updated integer := 0;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  update public.client_prospects cp set
    is_lead = p_is_lead,
    lead_marked_at = case when p_is_lead then now() else null end,
    lead_marked_by = case when p_is_lead then left(coalesce(p_actor, ''), 200) else '' end
  where cp.client_id = p_client_id
    and cp.prospect_id = any(v_ids)
    and cp.is_lead is distinct from p_is_lead;
  get diagnostics v_updated = row_count;

  perform public.record_operation(
    case when p_is_lead then 'lead_mark' else 'lead_unmark' end,
    p_client_id, p_actor,
    format('Marked %s prospects %s', v_updated, case when p_is_lead then 'as leads' else 'not leads' end),
    v_updated, v_ids);

  return jsonb_build_object('updated', v_updated, 'queued', 0);
end;
$$;

revoke execute on function public.set_client_lead_v1(text, boolean, text, jsonb, text[], text[], text) from public, anon, authenticated;
grant execute on function public.set_client_lead_v1(text, boolean, text, jsonb, text[], text[], text) to service_role;

-- ---------------------------------------------------------------------------
-- Assertions. These run against real rows, not against DDL having compiled.
do $$
declare
  v_client text;
  v_sql text;
  v_compiler bigint;
  v_matcher bigint;
  v_yes bigint;
  v_no bigint;
  v_active bigint;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'client_prospects' and column_name = 'is_lead') then
    raise exception 'client_prospects.is_lead was not added';
  end if;
  if not exists (select 1 from pg_indexes
                  where indexname = 'idx_client_prospects_lead' and indexdef ilike '%where is_lead%') then
    raise exception 'idx_client_prospects_lead must be partial, or it is the size of the whole membership';
  end if;

  -- The BIGGEST client, not the first by id. Picking arbitrarily landed on one
  -- with no membership at all, and "the two implementations agree on 0 rows"
  -- is not evidence of anything.
  select cp.client_id into v_client
    from public.client_prospects cp
   group by cp.client_id
   order by count(*) desc
   limit 1;
  if v_client is null then
    raise notice 'no client has any membership; skipping the behavioural checks';
    return;
  end if;

  foreach v_sql in array array['__lead', '__contactable'] loop
    -- The builder emits something for every operator, including an empty value
    -- list. A null here silently demotes every surface to the row matcher.
    if public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
         'field', v_sql, 'operator', 'contains', 'values', jsonb_build_array(v_client)))) is null then
      raise exception '% did not compile for contains', v_sql;
    end if;
    if public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
         'field', v_sql, 'operator', 'not_contains', 'values', jsonb_build_array()))) is null then
      raise exception '% did not compile for an empty value list', v_sql;
    end if;
  end loop;

  -- The builder and the row matcher must select the same set. This is the
  -- check that catches a wrong negation or a missed status predicate.
  foreach v_sql in array array['__lead', '__contactable'] loop
    execute format('select count(*) from public.prospect_index pi where %s',
      public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
        'field', v_sql, 'operator', 'contains', 'values', jsonb_build_array(v_client)))))
      into v_compiler;
    execute format($q$select count(*) from public.prospect_index pi
                    where public.prospect_index_matches_v1(pi, '', %L::jsonb)$q$,
      jsonb_build_array(jsonb_build_object('field', v_sql, 'operator', 'contains',
        'values', jsonb_build_array(v_client))))
      into v_matcher;
    if v_compiler is distinct from v_matcher then
      raise exception '% disagrees: builder % rows, row matcher % rows', v_sql, v_compiler, v_matcher;
    end if;
    raise notice '% agrees on % rows', v_sql, v_compiler;
  end loop;

  -- Contactable and its complement must partition the client's active
  -- membership. Catches an off-by-one on the cooldown boundary and a dropped
  -- "never contacted" branch, neither of which the agreement check above sees.
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__contactable', 'operator', 'contains', 'values', jsonb_build_array(v_client))))) into v_yes;
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__contactable', 'operator', 'not_contains', 'values', jsonb_build_array(v_client))))) into v_no;
  select count(*) into v_active
    from public.prospect_index pi
   where exists (select 1 from public.client_prospects cp
                  where cp.prospect_id = pi.id and cp.client_id = v_client and cp.status = 'active');
  if v_yes + v_no <> (select count(*) from public.prospect_index) then
    raise exception 'contactable and its complement do not partition the index: % + % of %',
      v_yes, v_no, (select count(*) from public.prospect_index);
  end if;
  if v_yes > v_active then
    raise exception 'more contactable (%) than active membership (%)', v_yes, v_active;
  end if;
  raise notice 'contactable % of % active for client %', v_yes, v_active, v_client;
end $$;
