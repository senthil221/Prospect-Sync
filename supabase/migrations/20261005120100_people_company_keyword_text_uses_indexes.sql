-- Let ordinary, bounded Company Keywords searches reach the existing trigram
-- indexes on company name and description. This version is intentionally later
-- than 20261005120000: the CLI initially generated 20261005115059 after that
-- migration already existed, and additive history must remain monotonic.
--
-- The legacy concat_ws expression remains the fail-safe for long OR lists,
-- short terms, wildcard syntax and separators. Keywords-only remains the exact
-- overlap path introduced by 20260917040000. No index or row matcher changes.
set local lock_timeout = '5s';

do $BODY$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure);
  v_old constant text := '        if cardinality(raw_values) > bulk_or_threshold then
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
        end if;';
  v_new constant text := '        if field_key = ''__company_keywords''
           and operator_key in (''contains'', ''not_contains'')
           and cardinality(raw_values) between 1 and bulk_or_threshold
           and (public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''name''
                or public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''description'')
           and not exists (
             select 1 from unnest(raw_values) ordinary(value)
             where ordinary.value <> btrim(ordinary.value)
                or length(ordinary.value) < 3
                or position(''%'' in ordinary.value) > 0
                or position(''_'' in ordinary.value) > 0
                or position(''|'' in ordinary.value) > 0
                or position(chr(92) in ordinary.value) > 0
           ) then
          -- Each selected text column is exposed directly to its existing
          -- trigram index. Tag matching keeps the exact overlap semantics.
          value_parts := array[]::text[];
          foreach value_text in array raw_values loop
            if public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''name'' then
              value_parts := value_parts || format(''co.name ilike %L'', ''%'' || value_text || ''%'');
            end if;
            if public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''description'' then
              value_parts := value_parts || format(''co.short_description ilike %L'', ''%'' || value_text || ''%'');
            end if;
          end loop;
          if public.company_keyword_scopes_v1(filter_item->''scopes'') ? ''keywords'' then
            value_parts := value_parts || format(''co.keywords && %L::text[]'',
              public.keyword_tag_variants_v1(raw_values));
          end if;
          company_inner := ''('' || array_to_string(value_parts, '' or '') || '')'';
        else
          -- Compatibility path: preserve every previously supported syntax and
          -- the keywords-only expression byte-for-byte.
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
        end if;';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_sql_v1 company-keyword substring branch changed; refusing to patch blindly';
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'prospect_filter_sql_v1 contains the company-keyword patch anchor more than once';
  end if;
  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$BODY$;

revoke execute on function public.prospect_filter_sql_v1(text, jsonb) from public, anon, authenticated;
grant execute on function public.prospect_filter_sql_v1(text, jsonb) to service_role;

-- Fail closed if the optimized and compatibility paths are not selected by the
-- intended inputs. Exact result parity is exercised in the disposable fixture.
do $$
declare
  v_sql text;
begin
  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_keywords","operator":"contains","values":["blockchain"],"scopes":["name","keywords","description"]}]'::jsonb);
  if position('co.name ilike' in v_sql) = 0
     or position('co.short_description ilike' in v_sql) = 0
     or position('co.keywords &&' in v_sql) = 0
     or position('concat_ws' in v_sql) > 0 then
    raise exception 'ordinary company-keyword search did not compile to indexed fields: %', v_sql;
  end if;

  v_sql := public.prospect_filter_sql_v1('',
    '[{"field":"__company_keywords","operator":"contains","values":["blockchain"],"scopes":["keywords"]}]'::jsonb);
  if position('co.keywords &&' in v_sql) = 0 or position('co.name ilike' in v_sql) > 0 then
    raise exception 'keywords-only search changed shape: %', v_sql;
  end if;

  foreach v_sql in array array[
    public.prospect_filter_sql_v1('', '[{"field":"__company_keywords","operator":"contains","values":["ab"],"scopes":["name","keywords"]}]'::jsonb),
    public.prospect_filter_sql_v1('', '[{"field":"__company_keywords","operator":"contains","values":["block%"],"scopes":["name","keywords"]}]'::jsonb),
    public.prospect_filter_sql_v1('', '[{"field":"__company_keywords","operator":"contains","values":["block|chain"],"scopes":["name","keywords"]}]'::jsonb)
  ] loop
    if position('concat_ws' in v_sql) = 0 then
      raise exception 'unsupported company-keyword term escaped compatibility path: %', v_sql;
    end if;
  end loop;
end $$;
