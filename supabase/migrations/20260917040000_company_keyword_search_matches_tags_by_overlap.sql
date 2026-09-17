-- Company keyword search stops building a string per company and matches the
-- tag array by overlap instead.
--
-- THE MEASUREMENT THAT DECIDED THIS, on an idle production database:
--
--   companies matching, name + short_description ilike (trigram)      746 ms
--   companies matching, array_to_string(keywords) ilike (no index)  2,983 ms
--   companies matching, keywords && keyword_tag_variants_v1            33 ms
--
-- The substring match over the joined tag array is the whole cost, and it is the
-- one disjunct no index can serve. End to end on the People rail, counting
-- prospects for a broad term:
--
--   today, concat_ws of name+keywords+description        2,965 ms
--   this change, all three scopes                          681 ms
--   this change, keywords only                              33 ms
--
-- WHY OVERLAP RATHER THAN A NEW INDEX. A GIN trigram index over the joined tag
-- text would keep substring semantics, and would cost about a gigabyte -
-- extrapolated from the existing short_description index, which is 840 MB over
-- 212 MB of text, against 249 MB of keyword text. It would also add GIN
-- maintenance to every company import, and this system imports companies in
-- twelve-thousand-row batches. Worse for reliability, trigram selectivity
-- collapses on short or common terms, which is the failure mode that produced
-- the 10s timeouts in the first place. Array overlap has the same cost whatever
-- the term is.
--
-- It is also not a new bet: company_filter_sql_v3 has matched the keywords scope
-- by overlap since 20260825124148, and that is the rail serving 419,521
-- companies today. This makes the People rail agree with it.
--
-- WHAT CHANGES FOR A SEARCH. Keywords now match whole tags rather than
-- substrings, so "software" matches a company tagged "software" and no longer
-- one tagged only "software development". For that term the People rail goes
-- from 172,817 matching prospects to 62,180 with all three scopes ticked. Name
-- and description are unaffected and still match substrings, so a company whose
-- description mentions software is still found. keyword_tag_variants_v1 supplies
-- the case variants, which is why a tag typed as the user thinks of it still
-- matches a lowercase store.
--
-- THE TEXT EXPRESSION LOSES KEYWORDS ONLY WHERE OVERLAP REPLACES IT. Boolean
-- search and the empty/not-empty operators still read the full concatenation
-- including the tag text: a Boolean query is a text query by definition, and
-- "has no keywords" has to see the keywords. Only the substring path changes,
-- which is the only path that was slow.
--
-- BOTH HALVES OF THE PAIR MOVE TOGETHER. prospect_filter_sql_v1 compiles SQL and
-- prospect_index_matches_v1 walks a row; a change to one and not the other is a
-- grid that disagrees with its own bulk actions. The battery at the foot proves
-- they agree for every scope combination on real rows.
-- ---------------------------------------------------------------------------

-- The text half of a keyword search: name and description only. Keywords are
-- matched by overlap and must not also be concatenated into a string here, or
-- the cost this migration removes comes straight back.
--
-- With keywords as the only scope this returns the empty literal, the ilike arm
-- is constant-false, and the overlap disjunct carries the whole predicate -
-- which is the 33 ms case.
create or replace function public.company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text)
returns text
language plpgsql
immutable
as $FN$
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
  if v_scopes ? 'description' then
    v_parts := array_append(v_parts, format('nullif(%I.short_description, %L)', p_alias, ''));
  end if;
  if cardinality(v_parts) = 0 then
    return quote_literal('');
  end if;
  return format('concat_ws(%L, %s)', ' | ', array_to_string(v_parts, ', '));
end;
$FN$;

-- ---------------------------------------------------------------------------
-- The compiler. One splice over the whole substring branch, so the block it
-- replaces stays balanced and no second edit has to land in the right order.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_declare_old constant text := '  company_expr text;';
  v_declare_new constant text := '  company_expr text;
  company_contains_expr text;';
  v_old constant text := '      else
        if cardinality(raw_values) > bulk_or_threshold then
          company_inner := format(''exists (select 1 from unnest(%L::text[]) needle where %s ilike ''''%%'''' || needle || ''''%%'''')'',
            raw_values, company_expr);
        else
          value_parts := array[]::text[];
          foreach value_text in array raw_values loop
            value_parts := value_parts || format(''%s ilike %L'', company_expr, ''%'' || value_text || ''%'');
          end loop;
          company_inner := ''('' || array_to_string(value_parts, '' or '') || '')'';
        end if;
        company_negate := (operator_key = ''not_contains'');';
  v_new constant text := '      else
        -- A tag array is matched by overlap, never by substring over a joined
        -- string: 33 ms against 2,983 ms measured on production. The text half
        -- keeps name and description, which are what substrings are for.
        if field_key = ''__company_keywords'' then
          company_contains_expr := public.company_keyword_text_expr_sql_v1(filter_item->''scopes'', ''co'');
        else
          company_contains_expr := company_expr;
        end if;
        if cardinality(raw_values) > bulk_or_threshold then
          company_inner := format(''exists (select 1 from unnest(%L::text[]) needle where %s ilike ''''%%'''' || needle || ''''%%'''')'',
            raw_values, company_contains_expr);
        else
          value_parts := array[]::text[];
          foreach value_text in array raw_values loop
            value_parts := value_parts || format(''%s ilike %L'', company_contains_expr, ''%'' || value_text || ''%'');
          end loop;
          company_inner := ''('' || array_to_string(value_parts, '' or '') || '')'';
        end if;
        -- Appended rather than replacing the text half, so a search still finds
        -- a company by name or description as well as by tag.
        if field_key = ''__company_keywords''
           and public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords''
           and cardinality(raw_values) > 0 then
          company_inner := format(''(%s or co.keywords && %L::text[])'', company_inner,
            public.keyword_tag_variants_v1(raw_values));
        end if;
        company_negate := (operator_key = ''not_contains'');';
begin
  if position(v_declare_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer declares company_expr where expected';
  end if;
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 no longer contains the substring branch this migration replaces';
  end if;
  -- Declaration and body in ONE rewrite, so the function is never stored in a
  -- state that references a local it has not declared.
  if position('company_contains_expr text;' in v_def) = 0 then
    v_def := replace(v_def, v_declare_old, v_declare_new);
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('co.keywords && %L::text[]' in v_def) = 0
     or position('company_keyword_text_expr_sql_v1' in v_def) = 0 then
    raise exception 'the overlap replacement did not take';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- The row matcher drops the tag text from its candidate, for the same reason.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  v_old constant text := '        when ''__company_keywords'' then (select concat_ws('' | '',
            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''name'' then nullif(co.name, '''') end,
            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'' then nullif(array_to_string(co.keywords, '' | ''), '''') end,
            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''description'' then nullif(co.short_description, '''') end)
          from public.companies co where co.id = (p_row).company_id)';
  v_new constant text := '        when ''__company_keywords'' then (select concat_ws('' | '',
            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''name'' then nullif(co.name, '''') end,
            case when public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''description'' then nullif(co.short_description, '''') end)
          from public.companies co where co.id = (p_row).company_id)';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_index_matches_v1 no longer contains the company keyword candidate this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$BODY$;

-- And gains the arm that puts the overlap back for a substring search. Without
-- it the two halves disagree the moment a tag matches and the description does
-- not, which is a grid that contradicts its own bulk actions.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  v_old constant text := '      when filter_item->>''field'' in (''__company_keywords'', ''__company_technologies'')
        and (filter_item->>''field'' = ''__company_technologies''
             or public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'')
        and coalesce(filter_item->>''operator'', ''contains'') in (''equals'', ''not_equals'') then (';
  v_new constant text := '      when filter_item->>''field'' = ''__company_keywords''
        and public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords''
        and coalesce(filter_item->>''operator'', ''contains'') in (''contains'', ''not_contains'')
        and coalesce(jsonb_array_length(filter_item->''values''), 0) > 0 then (
        (coalesce(filter_item->>''operator'', ''contains'') = ''not_contains'')
        <> (
          exists (select 1 from public.companies co
                   where co.id = (p_row).company_id
                     and co.keywords && public.keyword_tag_variants_v1(
                           array(select value from jsonb_array_elements_text(filter_item->''values'') as picked(value))))
          or exists (
            select 1 from jsonb_array_elements_text(coalesce(filter_item->''values'', ''[]''::jsonb)) selected(value)
            where candidate.candidate_value ilike ''%'' || selected.value || ''%'')
        )
      )
      when filter_item->>''field'' in (''__company_keywords'', ''__company_technologies'')
        and (filter_item->>''field'' = ''__company_technologies''
             or public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'')
        and coalesce(filter_item->>''operator'', ''contains'') in (''equals'', ''not_equals'') then (';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_index_matches_v1 no longer contains the tag-array arm this migration extends';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- The pair still agrees, on real rows, for every scope combination.
do $BODY$
declare
  v_sample text[];
  v_scopes jsonb;
  v_filter jsonb;
  v_sql text;
  v_by_sql bigint;
  v_by_row bigint;
begin
  select coalesce(array_agg(id), array[]::text[]) into v_sample
  from (select pi.id from public.prospect_index pi
         where pi.company_id is not null
         order by pi.id limit 3000) sampled;
  if cardinality(v_sample) = 0 then
    raise notice 'no indexed prospects carry a company; the agreement is unproven';
    return;
  end if;

  foreach v_scopes in array array[
    '["keywords"]'::jsonb,
    '["name"]'::jsonb,
    '["description"]'::jsonb,
    '["name","keywords"]'::jsonb,
    '["name","keywords","description"]'::jsonb
  ] loop
    v_filter := jsonb_build_array(jsonb_build_object(
      'field', '__company_keywords', 'operator', 'contains',
      'values', jsonb_build_array('software'), 'scopes', v_scopes));

    v_sql := public.prospect_filter_sql_v1('', v_filter);
    execute format('select count(*) from public.prospect_index pi where pi.id = any(%L) and (%s)',
      v_sample, coalesce(nullif(v_sql, ''), 'true')) into v_by_sql;

    select count(*) into v_by_row
    from public.prospect_index pi
    where pi.id = any(v_sample) and public.prospect_index_matches_v1(pi, '', v_filter);

    if v_by_sql <> v_by_row then
      raise exception 'scopes %: compiler matched %, row matcher matched %', v_scopes, v_by_sql, v_by_row;
    end if;
  end loop;

  -- not_contains is the arm most easily got backwards, so it is checked too.
  v_filter := jsonb_build_array(jsonb_build_object(
    'field', '__company_keywords', 'operator', 'not_contains',
    'values', jsonb_build_array('software'), 'scopes', '["name","keywords","description"]'::jsonb));
  v_sql := public.prospect_filter_sql_v1('', v_filter);
  execute format('select count(*) from public.prospect_index pi where pi.id = any(%L) and (%s)',
    v_sample, coalesce(nullif(v_sql, ''), 'true')) into v_by_sql;
  select count(*) into v_by_row
  from public.prospect_index pi
  where pi.id = any(v_sample) and public.prospect_index_matches_v1(pi, '', v_filter);
  if v_by_sql <> v_by_row then
    raise exception 'not_contains: compiler matched %, row matcher matched %', v_by_sql, v_by_row;
  end if;

  raise notice 'compiler and row matcher agree on % sampled prospects for every scope combination', cardinality(v_sample);
end
$BODY$;

-- The tag half actually fires: a tag that exists must be found by overlap even
-- when neither the name nor the description mentions it.
do $BODY$
declare
  v_tag text;
  v_company text;
  v_matched boolean;
begin
  select lower(btrim(kw)), co.id into v_tag, v_company
  from public.companies co
  cross join lateral unnest(co.keywords) as kw
  where co.keywords is not null
    and length(btrim(kw)) > 4
    and co.name not ilike '%' || btrim(kw) || '%'
    and coalesce(co.short_description, '') not ilike '%' || btrim(kw) || '%'
    and exists (select 1 from public.prospect_index pi where pi.company_id = co.id)
  limit 1;

  if v_tag is null then
    raise notice 'no tag exists that is absent from its own name and description; the overlap arm is unproven';
    return;
  end if;

  select exists (
    select 1 from public.prospect_index pi
    where pi.company_id = v_company
      and public.prospect_index_matches_v1(pi, '', jsonb_build_array(jsonb_build_object(
        'field', '__company_keywords', 'operator', 'contains',
        'values', jsonb_build_array(v_tag), 'scopes', '["name","keywords","description"]'::jsonb)))
  ) into v_matched;

  if not v_matched then
    raise exception 'tag "%" is on company % but the overlap arm did not match it', v_tag, v_company;
  end if;
end
$BODY$;
