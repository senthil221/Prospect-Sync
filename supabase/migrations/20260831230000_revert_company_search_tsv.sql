-- Revert companies.search_tsv. It bought Boolean search at the cost of every
-- other company query, which is a trade I should not have made.
--
-- 20260831210000 materialised the Boolean search vector onto companies. It did
-- what it claimed for Boolean, but measured against the live table afterwards:
--
--   search_tsv column data ....... 583 MB
--   its GIN index ................ 177 MB
--   added to a ~1.3 GB table ..... ~760 MB, about +58%
--
-- companies is scanned by every filter, and the box has 2 GB of shared_buffers
-- for a working set that also includes prospect_index. Inflating the table by
-- more than half pushed the rest out of cache. Warm, before and after:
--
--   keyword + description (the reported failure) .... 2.4 s -> 15.5 s
--   unfiltered master .............................. 0.5 s ->  1.0 s
--   Boolean, common term ........................... 21 s  -> 13.9 s
--   Boolean, selective term ........................ 21 s  ->  2.1 s
--
-- Boolean got better and everything else got worse, including the exact query
-- that was reported. That is a net loss: Boolean is the advanced mode, while
-- keyword and description filtering is the everyday path.
--
-- Dropping the column returns the space. The 583 MB is almost entirely TOAST, so
-- VACUUM reclaims it without the ACCESS EXCLUSIVE table rewrite that dropping an
-- inline column would need; only a few bytes per row of dropped-column header
-- remain until the table is next rewritten naturally.
--
-- The right shape for this is a side table -- company_id plus tsvector, joined
-- only when a Boolean filter is present -- so the vector never sits in the heap
-- that every other query has to scan. That is a separate piece of work, done
-- deliberately, rather than left half-applied here.
--
-- Boolean therefore returns to roughly 21s: slow, bounded by the statement
-- timeout, and no longer degrading anything else.

begin;

drop trigger if exists trg_companies_search_tsv on public.companies;
drop index if exists public.idx_companies_search_tsv;
alter table public.companies drop column if exists search_tsv;
drop function if exists public.refresh_company_search_tsv_v1(integer);
drop function if exists public.companies_fill_search_tsv();

-- company_prefilter_sql referenced search_tsv for the Boolean branch. Restore the
-- version from 20260831130211, which skips Boolean entirely: with no vector to
-- narrow on, the complete predicate handles it exactly as it did before.
create or replace function public.company_prefilter_sql(p_search text, p_filters jsonb)
returns text
language plpgsql
stable
security invoker
set search_path = public
as $function$
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

revoke execute on function public.company_prefilter_sql(text, jsonb) from public, anon, authenticated;
grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;

commit;
