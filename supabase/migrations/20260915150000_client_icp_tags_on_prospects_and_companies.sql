-- Client ICP tags, on prospects and on companies.
--
-- MOST OF THIS ALREADY EXISTED. 20260825040000 made prospect_tags
-- client-scoped: it added client_id, dropped prospect_tags_name_key, and
-- replaced it with two partial unique indexes - (client_id, lower(name)) for a
-- client's tags and lower(name) for agency-wide ones. Confirmed against
-- production before writing this. So there is no constraint to drop, no
-- backfill, and no question about which client the existing rows belong to:
-- client_id null means agency-wide and stays supported.
--
-- What was missing is the company half, the filters, and the write paths.
--
-- ONE VOCABULARY, TWO LINK TABLES. public.prospect_tags stays the single tag
-- table for both entities, so the same ICP means the same thing on a company
-- and on its people and the Company-to-People pivot stays coherent. Companies
-- get their own narrow link table rather than a polymorphic
-- (entity_type, entity_id) one: a polymorphic table cannot carry a foreign key
-- to two different parents, so both cascades would become triggers somebody has
-- to remember to write, and every query would carry an entity_type predicate
-- the planner has to filter inside a shared index.
--
-- FILTERS TAKE TAG IDS, NOT NAMES, AND NOT A CLIENT-QUALIFIED FIELD NAME. A tag
-- row already carries its client_id, so an id is unambiguous on its own: there
-- is nothing to parse out of the field name and no join to prospect_tags in the
-- predicate at all. Names would also reintroduce the bug 20260915130000 fixed
-- for clients - a renamed tag silently changing what a saved view returns.
--
--   people      exists (... prospect_tag_links where prospect_id = pi.id and tag_id = any(...))
--   companies   exists (... company_tag_links  where company_id  = c.id  and tag_id = any(...))
--
-- served by idx_tag_links_tag (tag_id, prospect_id) and the company index below,
-- both of which are already the direction these read.
--
-- PROSPECT TAGS REINDEX; COMPANY TAGS DO NOT. reindex_prospects builds
-- prospect_index.tags and .tag_text from prospect_tag_links, and tag_text feeds
-- search_text - so tagging a prospect changes the index and must queue a
-- re-index. Nothing in prospect_index carries a company's tags, so tagging a
-- company changes nothing there. That asymmetry is why there are two write
-- functions rather than one.
--
-- THE VALUE-PICKER LEAK, FIXED HERE. prospect_filter_values_v3's __tags arm
-- joins prospect_tag_links to prospect_tags with no client predicate, so once
-- client tags exist, client B's filter panel would list client A's tag names
-- wherever the two share a prospect. __tags is narrowed to the agency-wide tags
-- it was always about, and __client_tags gets its own arm scoped by client.
-- ---------------------------------------------------------------------------

create table if not exists public.company_tag_links (
  company_id text not null references public.companies(id) on delete cascade,
  tag_id text not null references public.prospect_tags(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (company_id, tag_id)
);

comment on table public.company_tag_links is
  'Applies a prospect_tags row to a company. Same vocabulary as prospect_tag_links, so one ICP tag means the same thing on both sides.';

-- The PK covers "this company's tags" for the drawer; this covers "companies
-- with this tag", which is what the filter reads.
create index if not exists idx_company_tag_links_tag
  on public.company_tag_links (tag_id, company_id);

alter table public.company_tag_links enable row level security;
revoke all on public.company_tag_links from public, anon, authenticated;
grant select, insert, update, delete on public.company_tag_links to service_role;

-- ---------------------------------------------------------------------------
do $patch_tags$
declare
  v_definition text;
  v_rewritten text;
begin
  -- People: the SQL builder.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    lowered := array(select lower(value) from unnest(raw_values) value);$old$,
    $new$    lowered := array(select lower(value) from unnest(raw_values) value);

    -- Client ICP tags. Values are tag ids: a tag knows its own client, so the
    -- predicate needs no join and no client argument.
    if field_key = '__client_tags' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format($t$(not exists (select 1 from public.prospect_tag_links ptl
          where ptl.prospect_id = pi.id and ptl.tag_id = any (%L::text[])))$t$, raw_values);
      else
        conjuncts := conjuncts || format($t$(exists (select 1 from public.prospect_tag_links ptl
          where ptl.prospect_id = pi.id and ptl.tag_id = any (%L::text[])))$t$, raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_filter_sql_v1 for __client_tags'; end if;
  execute v_rewritten;

  -- People: the row matcher. Anchored on the arm 20260915130000 added.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      when filter_item->>'field' = '__client_ids' then ($old$,
    $new$      when filter_item->>'field' = '__client_tags' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.prospect_tag_links ptl
                  where ptl.prospect_id = (p_row).id
                    and ptl.tag_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__client_ids' then ($new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_index_matches_v1 for __client_tags'; end if;
  execute v_rewritten;

  -- People: the pre-filter takes the include half only.
  select pg_get_functiondef('public.prospect_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    field_key := filter_item->>'field';$old$,
    $new$    field_key := filter_item->>'field';
    if field_key = '__client_tags' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format($t$(exists (select 1 from public.prospect_tag_links ptl
          where ptl.prospect_id = pi.id and ptl.tag_id = any (%L::text[])))$t$, raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch prospect_prefilter_sql for __client_tags'; end if;
  execute v_rewritten;

  -- Companies: the SQL builder.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      candidate_expr := case field_key$old$,
    $new$      if field_key = '__company_tags' then
        if cardinality(raw_values) = 0 then continue; end if;
        if operator_key in ('not_contains', 'not_equals') then
          conjuncts := conjuncts || format($t$(not exists (select 1 from public.company_tag_links ctl
            where ctl.company_id = c.id and ctl.tag_id = any (%L::text[])))$t$, raw_values);
        else
          conjuncts := conjuncts || format($t$(exists (select 1 from public.company_tag_links ctl
            where ctl.company_id = c.id and ctl.tag_id = any (%L::text[])))$t$, raw_values);
        end if;
        continue;
      end if;
      candidate_expr := case field_key$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 for __company_tags'; end if;
  execute v_rewritten;

  -- Companies: the row matcher. Anchored on the arm 20260915140000 added.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      when filter_item->>'field' = '__company_client_ids' then ($old$,
    $new$      when filter_item->>'field' = '__company_tags' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.company_tag_links ctl
                  where ctl.company_id = (p_row).id
                    and ctl.tag_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__company_client_ids' then ($new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 for __company_tags'; end if;
  execute v_rewritten;

  -- Companies: the pre-filter takes the include half only. It matters here:
  -- the Master Company DB has no client scope to narrow it first.
  select pg_get_functiondef('public.company_prefilter_sql(text,jsonb)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$    field_key := filter_item->>'field';$old$,
    $new$    field_key := filter_item->>'field';
    if field_key = '__company_tags' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format($t$(exists (select 1 from public.company_tag_links ctl
          where ctl.company_id = c.id and ctl.tag_id = any (%L::text[])))$t$, raw_values);
      end if;
      continue;
    end if;
$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_prefilter_sql for __company_tags'; end if;
  execute v_rewritten;
end $patch_tags$;

-- ---------------------------------------------------------------------------
-- The value picker stops showing one client's tags to another.
do $patch_values$
declare
  v_definition text;
  v_rewritten text;
begin
  select pg_get_functiondef('public.prospect_filter_values_v3(text,text,text,integer)'::regprocedure) into v_definition;
  v_rewritten := replace(v_definition,
    $old$      || ' join public.prospect_tags pt on pt.id = ptl.tag_id';$old$,
    $new$      || ' join public.prospect_tags pt on pt.id = ptl.tag_id'
      || ' and pt.client_id is null';$new$);
  if v_rewritten = v_definition then raise exception 'Could not scope prospect_filter_values_v3 __tags to agency-wide tags'; end if;
  execute v_rewritten;
end $patch_values$;

-- ---------------------------------------------------------------------------
-- Applying a tag to a selection, per entity.
--
-- Prospects reindex and companies do not: prospect_index carries tags and
-- tag_text, and nothing in it carries a company's tags.
create or replace function public.set_client_prospect_tag_v1(
  p_client_id text,
  p_tag_id text,
  p_apply boolean,
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
  v_changed integer := 0;
  v_reindex record;
begin
  -- The tag must belong to this client (or be agency-wide). Without this a
  -- client workspace could apply another client's ICP tag.
  if not exists (select 1 from public.prospect_tags t
                  where t.id = p_tag_id and (t.client_id = p_client_id or t.client_id is null)) then
    raise exception 'That tag does not belong to this client' using errcode = 'P0002';
  end if;

  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  if p_apply then
    insert into public.prospect_tag_links (prospect_id, tag_id)
    select id, p_tag_id from unnest(v_ids) as id
    on conflict (prospect_id, tag_id) do nothing;
    get diagnostics v_changed = row_count;
  else
    delete from public.prospect_tag_links
     where tag_id = p_tag_id and prospect_id = any(v_ids);
    get diagnostics v_changed = row_count;
  end if;

  -- tag_text feeds search_text, so this is not optional.
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    case when p_apply then 'tag_apply' else 'tag_remove' end,
    p_client_id, p_actor,
    format('%s tag on %s prospects', case when p_apply then 'Applied' else 'Removed' end, v_changed),
    v_changed, v_ids);

  return jsonb_build_object('updated', v_changed, 'queued', v_reindex.queued);
end;
$$;

create or replace function public.set_client_company_tag_v1(
  p_client_id text,
  p_tag_id text,
  p_apply boolean,
  p_company_ids text[],
  p_actor text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_changed integer := 0;
begin
  if not exists (select 1 from public.prospect_tags t
                  where t.id = p_tag_id and (t.client_id = p_client_id or t.client_id is null)) then
    raise exception 'That tag does not belong to this client' using errcode = 'P0002';
  end if;
  if p_company_ids is null or cardinality(p_company_ids) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  if p_apply then
    insert into public.company_tag_links (company_id, tag_id)
    select id, p_tag_id from unnest(p_company_ids) as id
    on conflict (company_id, tag_id) do nothing;
    get diagnostics v_changed = row_count;
  else
    delete from public.company_tag_links
     where tag_id = p_tag_id and company_id = any(p_company_ids);
    get diagnostics v_changed = row_count;
  end if;

  -- Deliberately no re-index: prospect_index carries no company tags, so
  -- tagging a company changes nothing it holds.
  return jsonb_build_object('updated', v_changed, 'queued', 0);
end;
$$;

revoke execute on function public.set_client_prospect_tag_v1(text, text, boolean, text, jsonb, text[], text[], text) from public, anon, authenticated;
grant execute on function public.set_client_prospect_tag_v1(text, text, boolean, text, jsonb, text[], text[], text) to service_role;
revoke execute on function public.set_client_company_tag_v1(text, text, boolean, text[], text) from public, anon, authenticated;
grant execute on function public.set_client_company_tag_v1(text, text, boolean, text[], text) to service_role;

-- ---------------------------------------------------------------------------
do $$
declare
  v_sql text;
  v_builder bigint;
  v_matcher bigint;
begin
  if to_regclass('public.company_tag_links') is null then
    raise exception 'company_tag_links was not created';
  end if;
  if has_table_privilege('anon', 'public.company_tag_links', 'SELECT')
     or has_table_privilege('authenticated', 'public.company_tag_links', 'SELECT') then
    raise exception 'company_tag_links must not be readable by anon or authenticated';
  end if;

  -- Both compile, both directions, and an empty value list never returns null.
  foreach v_sql in array array['contains', 'not_contains'] loop
    if public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
         'field', '__client_tags', 'operator', v_sql, 'values', jsonb_build_array('tag-1')))) is null then
      raise exception '__client_tags did not compile for %', v_sql;
    end if;
    if public.company_filter_sql_v3('', jsonb_build_array(jsonb_build_object(
         'field', '__company_tags', 'operator', v_sql, 'values', jsonb_build_array('tag-1')))) is null then
      raise exception '__company_tags did not compile for %', v_sql;
    end if;
  end loop;
  if public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
       'field', '__client_tags', 'operator', 'contains', 'values', jsonb_build_array()))) is null then
    raise exception '__client_tags did not compile for an empty value list';
  end if;

  -- Builder and row matcher must agree. With no tags applied yet both are 0,
  -- which is still the check that catches an inverted negation.
  execute format('select count(*) from public.prospect_index pi where %s',
    public.prospect_filter_sql_v1('', jsonb_build_array(jsonb_build_object(
      'field', '__client_tags', 'operator', 'not_contains', 'values', jsonb_build_array('no-such-tag')))))
    into v_builder;
  execute format($q$select count(*) from public.prospect_index pi
                   where public.prospect_index_matches_v1(pi, '', %L::jsonb)$q$,
    jsonb_build_array(jsonb_build_object('field', '__client_tags', 'operator', 'not_contains',
      'values', jsonb_build_array('no-such-tag')))) into v_matcher;
  if v_builder is distinct from v_matcher then
    raise exception '__client_tags disagrees: builder %, matcher %', v_builder, v_matcher;
  end if;
  -- Excluding a tag nobody has must keep everybody.
  if v_builder <> (select count(*) from public.prospect_index) then
    raise exception 'excluding an unused tag dropped rows: % of %', v_builder, (select count(*) from public.prospect_index);
  end if;

  -- The picker no longer offers one client's tags to another.
  if pg_get_functiondef('public.prospect_filter_values_v3(text,text,text,integer)'::regprocedure)
       not like '%pt.client_id is null%' then
    raise exception 'prospect_filter_values_v3 still lists client tags under __tags';
  end if;

  raise notice 'client ICP tags: filters compile both ways on both entities, matcher agrees on % rows', v_builder;
end $$;
