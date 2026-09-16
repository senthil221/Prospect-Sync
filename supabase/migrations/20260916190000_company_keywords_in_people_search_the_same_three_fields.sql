-- Company Keywords in the People database searches name, keywords and
-- description together - the same control the Company database has.
--
-- WHAT WAS WRONG WITH IT. The People rail offered Company Keywords and Company
-- Description as two separate filters, so "find me companies that do X" was two
-- filters that could not be OR-ed, while the Companies rail has had a single
-- Company keywords control with Name / Keywords / Description tick boxes since
-- 20260825124148. Two rails, two answers to the same question.
--
-- ONE RESOLUTION FUNCTION, BECAUSE THE DANGER HERE IS DISAGREEMENT.
-- prospect_filter_sql_v1 compiles SQL text and prospect_index_matches_v1
-- evaluates a row in PL/pgSQL; they are the pair that must agree, and this
-- change gives both a new way to be wrong - the scope list. So the normalising
-- of that list is a single function, company_keyword_scopes_v1, which both
-- sides call. Neither can decide for itself what an absent or empty scopes
-- array means.
--
-- THE DEFAULT IS TODAY'S BEHAVIOUR, NOT THE COMPANIES RAIL'S. A filter with no
-- scopes key resolves to keywords only, which is exactly what __company_keywords
-- has always meant here. Saved views, result sets and background exports created
-- before this migration carry no scopes key, and widening them to three fields
-- would silently change what a saved search returns - the same bug
-- 20260915130000 fixed for clients. The UI always sends its scopes explicitly,
-- so anything created from now on says what it means.
--
-- __company_description IS NOT REMOVED. It still compiles and still matches, so
-- an existing saved view keeps working. It simply stops being offered in the
-- picker, which is the same treatment the retired export columns got.
--
-- BUILT AS INLINE SQL TEXT, NOT AS A FUNCTION CALL OVER THE ROW. A helper
-- taking a companies row would be tidier and would also make the predicate
-- opaque to the planner, so co.short_description ilike '%x%' could no longer
-- reach the trigram index on 418,000 companies. The Companies rail builds
-- concat_ws inline for that reason and so does this.
-- ---------------------------------------------------------------------------

-- Absent, empty, or a list. One answer, used by both sides of the pair.
create or replace function public.company_keyword_scopes_v1(p_scopes jsonb)
returns jsonb
language sql
immutable
as $$
  select case
    when jsonb_typeof(p_scopes) = 'array' and jsonb_array_length(p_scopes) > 0 then p_scopes
    else '["keywords"]'::jsonb
  end;
$$;

-- The SQL text for those scopes, against a companies alias. nullif keeps an
-- empty column from contributing a bare separator, which would otherwise make
-- "a | " match a search for "|".
create or replace function public.company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text)
returns text
language plpgsql
immutable
as $$
declare
  v_scopes jsonb := public.company_keyword_scopes_v1(p_scopes);
  v_parts text[] := array[]::text[];
begin
  if p_alias !~ '^[a-z_][a-z0-9_]*$' then
    raise exception 'unsafe company alias %', p_alias;
  end if;
  if v_scopes ? 'name' then
    v_parts := array_append(v_parts, format('nullif(%I.name, %L)', p_alias, ''));
  end if;
  if v_scopes ? 'keywords' then
    v_parts := array_append(v_parts, format('nullif(array_to_string(%I.keywords, %L), %L)', p_alias, ' | ', ''));
  end if;
  if v_scopes ? 'description' then
    v_parts := array_append(v_parts, format('nullif(%I.short_description, %L)', p_alias, ''));
  end if;
  if cardinality(v_parts) = 0 then
    return quote_literal('');
  end if;
  return format('concat_ws(%L, %s)', ' | ', array_to_string(v_parts, ', '));
end;
$$;

-- ---------------------------------------------------------------------------
-- The compiler learns the scopes.
do $$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text := E'        when ''__company_keywords'' then ''array_to_string(co.keywords, '''' | '''')''';
  v_new constant text := E'        when ''__company_keywords'' then public.company_keyword_expr_sql_v1(filter_item->''scopes'', ''co'')';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer contains the company keyword expression this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('company_keyword_expr_sql_v1' in v_def) = 0 then
    raise exception 'the compiler replacement did not take';
  end if;
  execute v_def;
end $$;

-- The keyword tag shortcut only fires when keywords are actually in scope.
-- Without this, unticking Keywords would still match through the array overlap
-- and the box would do nothing.
do $$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text := E'        if field_key = ''__company_keywords'' then';
  v_new constant text := E'        if field_key = ''__company_keywords''\n'
    || E'           and public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'' then';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer contains the keyword tag branch this migration guards';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- The row matcher learns exactly the same thing.
do $$
declare
  v_def text := pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  v_old constant text := E'        when ''__company_keywords'' then (select array_to_string(co.keywords, '' | '') from public.companies co where co.id = (p_row).company_id)';
  v_new constant text := E'        when ''__company_keywords'' then (select concat_ws('' | '',\n'
    || E'            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''name'' then nullif(co.name, '''') end,\n'
    || E'            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'' then nullif(array_to_string(co.keywords, '' | ''), '''') end,\n'
    || E'            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''description'' then nullif(co.short_description, '''') end)\n'
    || E'          from public.companies co where co.id = (p_row).company_id)';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_index_matches_v1 no longer contains the company keyword arm this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

-- And its tag-array arm respects the same tick box.
do $$
declare
  v_def text := pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  v_old constant text := E'      when filter_item->>''field'' in (''__company_keywords'', ''__company_technologies'')\n        and coalesce(filter_item->>''operator'', ''contains'') in (''equals'', ''not_equals'') then (';
  v_new constant text := E'      when filter_item->>''field'' in (''__company_keywords'', ''__company_technologies'')\n'
    || E'        and (filter_item->>''field'' = ''__company_technologies''\n'
    || E'             or public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'')\n'
    || E'        and coalesce(filter_item->>''operator'', ''contains'') in (''equals'', ''not_equals'') then (';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_index_matches_v1 no longer contains the tag-array arm this migration guards';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- The pair agrees, on real rows, for every scope combination.
--
-- This is the assertion that matters. The compiler produces SQL and the matcher
-- evaluates a row; a scope handled differently by the two would show up as a
-- grid that disagrees with its own bulk actions - which is exactly the class of
-- bug 20260916090000 was written to catch, and did.
do $$
declare
  v_sample text[];
  v_scopes jsonb;
  v_filter jsonb;
  v_sql text;
  v_by_sql bigint;
  v_by_row bigint;
  v_term text;
begin
  -- A sample with companies behind it, so the arms have something to read.
  select coalesce(array_agg(id), array[]::text[]) into v_sample
  from (select pi.id from public.prospect_index pi
         where pi.company_id is not null
         order by pi.id limit 3000) sampled;
  if cardinality(v_sample) = 0 then
    raise notice 'no indexed prospects carry a company; the scope agreement is unproven';
    return;
  end if;

  -- A term that actually occurs, so the comparison is not 0 = 0.
  select lower(split_part(btrim(co.short_description), ' ', 1)) into v_term
  from public.companies co
  join public.prospect_index pi on pi.company_id = co.id
  where pi.id = any(v_sample) and length(btrim(coalesce(co.short_description, ''))) > 20
  limit 1;
  v_term := coalesce(nullif(v_term, ''), 'the');

  foreach v_scopes in array array[
    '["keywords"]'::jsonb,
    '["name"]'::jsonb,
    '["description"]'::jsonb,
    '["name","keywords"]'::jsonb,
    '["name","keywords","description"]'::jsonb,
    'null'::jsonb
  ] loop
    v_filter := jsonb_build_array(jsonb_build_object(
      'field', '__company_keywords', 'operator', 'contains',
      'values', jsonb_build_array(v_term))
      || case when v_scopes = 'null'::jsonb then '{}'::jsonb else jsonb_build_object('scopes', v_scopes) end);

    v_sql := public.prospect_filter_sql_v1('', v_filter);
    execute format('select count(*) from public.prospect_index pi where pi.id = any(%L) and (%s)',
      v_sample, coalesce(nullif(v_sql, ''), 'true')) into v_by_sql;

    select count(*) into v_by_row
    from public.prospect_index pi
    where pi.id = any(v_sample) and public.prospect_index_matches_v1(pi, '', v_filter);

    if v_by_sql <> v_by_row then
      raise exception 'scopes %: the compiler matched % rows and the row matcher matched %',
        v_scopes, v_by_sql, v_by_row;
    end if;
  end loop;

  raise notice 'company keyword scopes agree across the pair for every combination, on % sampled prospects', cardinality(v_sample);
end $$;


-- Unticking Keywords has to change the answer, or the tick box is decoration.
-- Asserted separately because an equivalence battery is happy when both sides
-- are equally wrong.
--
-- BOUNDED TO A SAMPLE, DELIBERATELY. prospect_index_matches_v1 is PL/pgSQL with
-- a correlated subquery per row, so running it across all 683,784 prospects is
-- minutes of work inside a migration that holds a transaction open - the same
-- trap 20260916090000 fell into and had to be cut back from 3m33s. The sample
-- and the tag are drawn from the same set, so the comparison cannot be 0 = 0.
do $$
declare
  v_sample text[];
  v_tag text;
  v_keywords_only bigint;
  v_name_only bigint;
begin
  select coalesce(array_agg(pi.id), array[]::text[]) into v_sample
  from (select pi.id from public.prospect_index pi
         join public.companies co on co.id = pi.company_id
        where co.keywords is not null and cardinality(co.keywords) > 0
        order by pi.id limit 2000) pi;

  if cardinality(v_sample) = 0 then
    raise notice 'no sampled prospect has a company with keywords; the tick box is unproven';
    return;
  end if;

  -- A tag that a company IN THE SAMPLE actually carries.
  select lower(btrim(kw)) into v_tag
  from public.prospect_index pi
  join public.companies co on co.id = pi.company_id
  cross join lateral unnest(co.keywords) as kw
  where pi.id = any(v_sample) and length(btrim(kw)) > 3
  limit 1;

  if v_tag is null then
    raise notice 'no usable company keyword tag in the sample; the tick box is unproven';
    return;
  end if;

  select count(*) into v_keywords_only
  from public.prospect_index pi
  where pi.id = any(v_sample)
    and public.prospect_index_matches_v1(pi, '', jsonb_build_array(jsonb_build_object(
      'field', '__company_keywords', 'operator', 'contains',
      'values', jsonb_build_array(v_tag), 'scopes', '["keywords"]'::jsonb)));

  select count(*) into v_name_only
  from public.prospect_index pi
  where pi.id = any(v_sample)
    and public.prospect_index_matches_v1(pi, '', jsonb_build_array(jsonb_build_object(
      'field', '__company_keywords', 'operator', 'contains',
      'values', jsonb_build_array(v_tag), 'scopes', '["name"]'::jsonb)));

  if v_keywords_only = 0 then
    raise exception 'the keywords scope matched nothing for tag "%" taken from the sample itself', v_tag;
  end if;
  if v_keywords_only = v_name_only then
    raise exception 'unticking Keywords changed nothing for tag "%" (% both ways); the scope is not being applied',
      v_tag, v_keywords_only;
  end if;

  raise notice 'the Keywords tick box changes the answer: % with it, % without', v_keywords_only, v_name_only;
end $$;
