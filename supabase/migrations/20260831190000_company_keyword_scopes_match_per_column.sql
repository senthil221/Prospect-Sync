-- Match each company keyword scope against its own column, not a concatenation.
--
-- company_prefilter_sql emits per-column predicates (c.name ilike …,
-- c.short_description ilike …) so the trigram indexes apply. company_filter_sql_v2
-- emitted concat_ws(' | ', c.name, c.short_description) ilike … for the same
-- scopes. company_effective_filter_sql_v1 ANDs the two, so they have to agree --
-- and they did not: a row matching only ACROSS the ' | ' join satisfied the
-- complete predicate and was then dropped by the narrowing one. Rows disappear
-- silently, which is the worst way for a filter to be wrong.
--
-- It is also simply what the filter means. "Description contains X" should be
-- about the description, not about a string that happens to span the end of the
-- company name and the start of its description.
--
-- Blast radius is small by construction. On the include path the prefilter is
-- always present and already per-column, so `per-column AND concat` becomes
-- `per-column AND per-column` -- provably the same rows. Only a keyword exclude
-- or Boolean-only filter reaches v2 with the prefilter at 'true', and there the
-- change removes a spurious cross-boundary match rather than adding one.
--
-- empty / not_empty / Boolean still read the concatenation deliberately: those
-- operators treat the selected scopes as one blob, and the prefilter never
-- narrows them, so there is nothing to disagree with.
--
-- I could not reach the database to test this beforehand, so the migration
-- verifies itself against real data at apply time and refuses to commit if the
-- rewrite disagrees with the reference implementation. A failure here fails
-- migrate.sh, and update.sh keeps the previous slot serving.

begin;

create or replace function public.company_filter_sql_v2(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $fn$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  selected_scopes jsonb;
  candidate_expr text;
  boolean_expr text;
  keyword_hit text;
  match_cols text[];
  scope_parts text[];
  value_parts text[];
  raw_values text[];
  value_text text;
  lowered text[];
  minimum text;
  maximum text;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('(c.name ilike %1$L or c.domain ilike %1$L)', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    field_key := filter_item->>'field';

    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;

    -- Mirrors the row function: with no values only the emptiness tests mean
    -- anything, and every other operator is a no-op rather than a rejection.
    if cardinality(raw_values) = 0 and operator_key not in ('empty', 'not_empty') then
      continue;
    end if;

    keyword_hit := 'false';

    if field_key = '__company_keywords' then
      selected_scopes := case
        when jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end;

      -- Substring scopes only; keywords are matched exactly, below.
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      candidate_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      -- Match each substring scope against its OWN column rather than against a
      -- concatenation of them. Two reasons. It agrees with company_prefilter_sql,
      -- which emits per-column predicates so the trigram indexes apply -- and the
      -- two are ANDed, so a row matching only across the ' | ' join was accepted
      -- here and then dropped there. And it is what the filter means: "description
      -- contains X" should be about the description, not about a string that
      -- happens to span the end of the name and the start of it.
      match_cols := scope_parts;

      -- Boolean search keeps spanning keywords as text.
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'keywords' then scope_parts := array_append(scope_parts, 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      boolean_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      if selected_scopes ? 'keywords' and cardinality(raw_values) > 0 then
        keyword_hit := format('c.keywords && %L::text[]', raw_values);
      end if;
    else
      candidate_expr := case field_key
        when '__company' then 'c.name'
        when '__website' then 'c.domain'
        when '__industry' then 'c.industry'
        when '__company_city' then 'c.city'
        when '__company_state' then 'c.state'
        when '__company_country' then 'c.country'
        when '__company_location' then 'coalesce(nullif(c.location, ' || quote_literal('') || '), concat_ws(' || quote_literal(', ') || ', nullif(c.city, ' || quote_literal('') || '), nullif(c.state, ' || quote_literal('') || '), nullif(c.country, ' || quote_literal('') || ')))'
        when '__keywords' then 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'
        when '__short_description' then 'c.short_description'
        when '__founded_year' then 'c.founded_year::text'
        when '__technologies' then 'array_to_string(c.technologies, ' || quote_literal(' | ') || ')'
        when '__total_funding' then 'c.total_funding'
        when '__employee_count' then quote_literal('')
        else null
      end;
      -- An unknown field makes the row function compare against '', so nothing
      -- matches. Rather than encode that, refuse and let the caller fall back:
      -- a silently empty listing is a worse failure than a slow one.
      if candidate_expr is null then return null; end if;
      boolean_expr := candidate_expr;
      match_cols := array[candidate_expr];
    end if;

    candidate_expr := 'coalesce(' || candidate_expr || ', ' || quote_literal('') || ')';
    match_cols := array(select 'coalesce(' || col || ', ' || quote_literal('') || ')' from unnest(match_cols) col);
    if cardinality(match_cols) = 0 then match_cols := array[candidate_expr]; end if;
    boolean_expr := 'coalesce(' || boolean_expr || ', ' || quote_literal('') || ')';

    if operator_key = 'equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      if field_key = '__keywords' then
        value_parts := value_parts || format('c.keywords && %L::text[]', raw_values);
      elsif field_key = '__technologies' then
        value_parts := value_parts || format('c.technologies && %L::text[]', raw_values);
      end if;
      if keyword_hit <> 'false' then value_parts := value_parts || keyword_hit; end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'not_equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));

    elsif operator_key = 'not_contains' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(match_cols) col);
      end loop;
      conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));

    elsif operator_key = 'boolean' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)', 'simple', boolean_expr, 'simple', value_text);
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'empty' then
      conjuncts := conjuncts || format('(btrim(%s) = %L)', candidate_expr, '');

    elsif operator_key = 'not_empty' then
      conjuncts := conjuncts || format('(btrim(%s) <> %L)', candidate_expr, '');

    elsif operator_key = 'number_ranges' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        if value_text = 'unknown' then
          if field_key = '__employee_count' then
            value_parts := array_append(value_parts, '(c.employee_count_min is null and c.employee_count_max is null)');
          elsif field_key = '__founded_year' then
            value_parts := array_append(value_parts, '(c.founded_year is null)');
          end if;
          continue;
        end if;
        if value_text !~ '^[0-9]+:[0-9]*$' then continue; end if;
        minimum := split_part(value_text, ':', 1);
        maximum := case when value_text ~ '^[0-9]+:[0-9]+$' then split_part(value_text, ':', 2) else null end;
        if field_key = '__employee_count' then
          value_parts := value_parts || format(
            '(c.employee_count_min is not null and (%s) and (c.employee_count_max is null or c.employee_count_max >= %s))',
            case when maximum is null then 'true' else format('c.employee_count_min <= %s', maximum) end, minimum);
        elsif field_key = '__founded_year' then
          value_parts := value_parts || format('(c.founded_year is not null and c.founded_year >= %s and (%s))',
            minimum, case when maximum is null then 'true' else format('c.founded_year <= %s', maximum) end);
        end if;
      end loop;
      if cardinality(value_parts) = 0 then
        conjuncts := array_append(conjuncts, 'false');
      else
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;

    else
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(match_cols) col);
      end loop;
      if keyword_hit <> 'false' then value_parts := value_parts || keyword_hit; end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$fn$;

-- Verify the rewritten predicate against the reference implementation on this
-- database's own data, at apply time. Any disagreement aborts the transaction,
-- which fails migrate.sh, which leaves update.sh serving the previous slot. The
-- change is therefore never half-applied to a live system.
--
-- The reference is company_prefilter_sql + company_matches_filters_v1: the row
-- function is untouched by this migration and is what the listings used before
-- the complete predicate existed. A 20,000-company sample keeps the slow
-- reference path affordable inside the migration's timeout while being far more
-- than enough to catch a logic error.
do $smoke$
declare
  cases jsonb := $j$[
    {"n":"kw contains, keywords",      "s":"", "f":[{"field":"__company_keywords","operator":"contains","values":["hr consulting"],"scopes":["keywords"]}]},
    {"n":"kw contains, name+keywords", "s":"", "f":[{"field":"__company_keywords","operator":"contains","values":["hr consulting"]}]},
    {"n":"kw contains, +description",  "s":"", "f":[{"field":"__company_keywords","operator":"contains","values":["consulting"],"scopes":["name","keywords","description"]}]},
    {"n":"kw contains, description",   "s":"", "f":[{"field":"__company_keywords","operator":"contains","values":["consulting"],"scopes":["description"]}]},
    {"n":"kw contains, name only",     "s":"", "f":[{"field":"__company_keywords","operator":"contains","values":["tech"],"scopes":["name"]}]},
    {"n":"kw exclude, keywords",       "s":"", "f":[{"field":"__company_keywords","operator":"not_contains","values":["hr consulting"],"scopes":["keywords"]}]},
    {"n":"kw exclude, +description",   "s":"", "f":[{"field":"__company_keywords","operator":"not_contains","values":["consulting"],"scopes":["name","keywords","description"]}]},
    {"n":"kw boolean",                 "s":"", "f":[{"field":"__company_keywords","operator":"boolean","values":["consulting"]}]},
    {"n":"kw equals",                  "s":"", "f":[{"field":"__company_keywords","operator":"equals","values":["hr consulting"],"scopes":["keywords"]}]},
    {"n":"industry contains",          "s":"", "f":[{"field":"__industry","operator":"contains","values":["software"]}]},
    {"n":"industry exclude",           "s":"", "f":[{"field":"__industry","operator":"not_contains","values":["software"]}]},
    {"n":"description not_empty",      "s":"", "f":[{"field":"__short_description","operator":"not_empty","values":[]}]},
    {"n":"employees range",            "s":"", "f":[{"field":"__employee_count","operator":"number_ranges","values":["11:20"]}]},
    {"n":"search + filter",            "s":"tech", "f":[{"field":"__industry","operator":"contains","values":["software"]}]},
    {"n":"include + exclude",          "s":"", "f":[{"field":"__company_keywords","operator":"contains","values":["consulting"],"scopes":["keywords"]},{"field":"__industry","operator":"not_contains","values":["software"]}]}
  ]$j$;
  c jsonb;
  v_search text;
  v_filters jsonb;
  v_effective text;
  v_prefilter text;
  v_old bigint;
  v_new bigint;
  v_fail integer := 0;
begin
  for c in select value from jsonb_array_elements(cases) loop
    v_search := c->>'s';
    v_filters := c->'f';
    v_effective := public.company_effective_filter_sql_v1(v_search, v_filters);
    v_prefilter := public.company_prefilter_sql(v_search, v_filters);
    if v_effective is null then continue; end if;

    execute format(
      'select count(*) from (select * from public.companies order by id limit 20000) c where (%s) and public.company_matches_filters_v1(c, %L, %L::jsonb)',
      v_prefilter, v_search, v_filters::text) into v_old;

    execute format(
      'select count(*) from (select * from public.companies order by id limit 20000) c where (%s)', v_effective) into v_new;

    if v_old is distinct from v_new then
      v_fail := v_fail + 1;
      raise warning 'company filter mismatch on "%": reference=% rewritten=%', c->>'n', v_old, v_new;
    end if;
  end loop;

  if v_fail > 0 then
    raise exception 'company_filter_sql_v2 rewrite disagrees with the reference on % case(s); refusing to apply', v_fail;
  end if;
  raise notice 'company filter predicate verified against the reference on every case';
end
$smoke$;

revoke execute on function public.company_filter_sql_v2(text, jsonb) from public, anon, authenticated;
grant execute on function public.company_filter_sql_v2(text, jsonb) to service_role;

commit;
