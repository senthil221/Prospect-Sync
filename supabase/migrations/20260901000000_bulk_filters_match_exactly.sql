-- Make a pasted list of websites an indexed equality test.
--
-- The Bulk domains box and the People "Paste list" tab both emitted
-- operator="contains" for every value, at up to maxFilterValues (1000) per
-- filter. Above bulk_or_threshold (40) company_prefilter_sql stops emitting an
-- OR-chain and emits a correlated EXISTS instead:
--
--   exists (select 1 from unnest('{…781 domains…}'::text[]) needle
--           where c.domain ilike '%' || needle || '%')
--
-- The pattern is built per row, so no index can serve it - not the trigram GIN,
-- nothing. Measured on the live database with 781 pasted domains:
--
--   the predicate alone ............ 83,443 ms, 161,376,893 rows removed
--   filter_companies_v4 end to end .. 127,358 ms  (PostgREST cancels at 120s)
--
-- Substring matching was also returning the wrong answer. 781 pasted domains
-- matched 5,904 companies, because acme.com is a substring of notacme.com.au and
-- acme.com.br. For a cold-email database that is worse than the timeout: it
-- silently widens every list anyone pastes.
--
-- lib/bulk-values.ts has carried exactMatchThreshold = 25 and a comment saying
-- "above this size the picker switches operators" since it was written. The
-- constant was never imported anywhere. The companion change to this migration
-- wires it into both paste paths; this half makes the equals branch indexable.
--
-- companies.normalized_domain is lower(domain) with a leading www. removed, and
-- it is indexed by idx_companies_normalized_domain. lower(c.domain) is not
-- indexed. Verified against the live table before writing this:
--
--   select count(*) filter (where lower(domain) is distinct from normalized_domain)
--     from companies;   ->  0 of 418,151
--
-- So the two are the same predicate on this data, and the prefilter stays
-- implied by the row predicate company_matches_filters_v1 applies
-- (lower((p_row).domain) = lower(selected.value)). Pasted values arrive already
-- normalized through normalizeDomain(), so they compare equal to the stored
-- form. With 781 domains this goes from 83,443 ms to 179 ms on an Index Scan.
--
-- Only the __website equals branch is added; the rest of the function is the
-- definition currently live in production, unchanged.

begin;

CREATE OR REPLACE FUNCTION public.company_prefilter_sql(p_search text, p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  selected_scopes jsonb;
  scope_parts text[];
  value_parts text[];
  raw_values text[];
  value_text text;
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format(
      '(c.name ilike %1$L or c.domain ilike %1$L)',
      '%' || btrim(p_search) || '%'
    );
  end if;

  for filter_item in
    select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
  loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';

    raw_values := array[]::text[];
    for value_text in
      select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb))
    loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    if field_key = '__company_keywords' then
      selected_scopes := case
        when jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end;
      scope_parts := array[]::text[];

      if selected_scopes ? 'keywords' then
        scope_parts := array_append(scope_parts, format('c.keywords && %L::text[]', raw_values));
      end if;
      foreach value_text in array raw_values loop
        if selected_scopes ? 'name' then
          scope_parts := array_append(scope_parts, format('c.name ilike %L', '%' || value_text || '%'));
        end if;
        if selected_scopes ? 'description' then
          scope_parts := array_append(scope_parts, format('c.short_description ilike %L', '%' || value_text || '%'));
        end if;
      end loop;

      if cardinality(scope_parts) > 0 then
        conjuncts := conjuncts || ('(' || array_to_string(scope_parts, ' or ') || ')');
      end if;
      continue;
    end if;

    column_expr := case field_key
      when '__company' then 'c.name'
      when '__website' then 'c.domain'
      when '__industry' then 'c.industry'
      when '__company_city' then 'c.city'
      when '__company_state' then 'c.state'
      when '__company_country' then 'c.country'
      when '__company_location' then 'c.location'
      when '__short_description' then 'c.short_description'
      when '__total_funding' then 'c.total_funding'
      when '__keywords' then 'array_to_string(c.keywords, '' | '')'
      when '__technologies' then 'array_to_string(c.technologies, '' | '')'
      else null
    end;
    if column_expr is null then continue; end if;

    if operator_key = 'equals' and field_key = '__keywords' then
      conjuncts := conjuncts || format('c.keywords && %L::text[]', raw_values);
      continue;
    end if;
    if operator_key = 'equals' and field_key = '__technologies' then
      conjuncts := conjuncts || format('c.technologies && %L::text[]', raw_values);
      continue;
    end if;

    -- A pasted list of websites. normalized_domain is indexed and equals
    -- lower(domain) on every row, so this is the same test the row predicate
    -- makes, served by idx_companies_normalized_domain instead of a scan.
    if operator_key = 'equals' and field_key = '__website' then
      conjuncts := conjuncts || format('c.normalized_domain = any (%L::text[])',
        array(select lower(value) from unnest(raw_values) value));
      continue;
    end if;

    if operator_key = 'equals' then
      conjuncts := conjuncts || format('lower(%s) = any (%L::text[])',
        column_expr, array(select lower(value) from unnest(raw_values) value));
    elsif cardinality(raw_values) <= bulk_or_threshold then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      conjuncts := conjuncts || format(
        'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
        raw_values, column_expr);
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$;

grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;

commit;
