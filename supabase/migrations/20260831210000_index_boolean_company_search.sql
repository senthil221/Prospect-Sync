-- Index Boolean company search. It was the last operator recomputing everything
-- per row, at roughly 21s across 418,151 companies.
--
-- to_tsvector over the scope concatenation cannot go in an index expression:
-- array_to_string is STABLE, not IMMUTABLE (verified here; to_tsvector and
-- array_to_tsvector are both immutable, array_to_string is not). So the vector is
-- materialised into a column and kept current by a trigger.
--
-- Measured on this database:
--
--   Boolean today, recomputed per row ......... ~21 s
--   Boolean reading the stored column .........  2.9 s
--
-- Note where that win comes from. The GIN index is NOT the reason, and the
-- planner is right to ignore it for a common term: 'consulting' matches 106,544
-- of 418,151 rows, and at 25% selectivity a sequential scan genuinely is cheaper.
-- The gain is from not recomputing to_tsvector -- and detoasting
-- short_description -- for every row. The index still earns its place for
-- selective terms, which is what a Boolean search is usually for.
--
-- THE BACKFILL IS DELIBERATELY NOT IN THIS MIGRATION.
--
-- Populating 418,151 rows measured at six minutes: it rewrites every row and
-- holds row locks throughout. migrate.sh allows five, so this would fail the
-- release outright -- and even with a raised timeout it would block company
-- writes for six minutes of a deploy, which is exactly the sort of thing that
-- looks like an outage from outside. Instead:
--
--   * this migration adds the column, the trigger and the index, all of which are
--     instant, so a deploy carrying it costs nothing;
--   * refresh_company_search_tsv_v1() fills it in bounded batches, is safe to
--     re-run, and reports how many rows are left;
--   * maintenance.sh calls it, so it completes on the weekly run without anyone
--     having to remember.
--
-- Until it is filled, search_tsv is null on old rows and the prefilter treats
-- null as "cannot narrow this row" -- so results stay exactly correct throughout,
-- and Boolean simply keeps its current speed until the backfill catches up.

begin;

-- Instant: a nullable column with no default does not rewrite the table.
alter table public.companies add column if not exists search_tsv tsvector;

create or replace function public.companies_fill_search_tsv()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  new.search_tsv := to_tsvector('simple',
    coalesce(new.name, '') || ' | ' ||
    coalesce(array_to_string(new.keywords, ' | '), '') || ' | ' ||
    coalesce(new.short_description, ''));
  return new;
end;
$fn$;

-- Scoped to the three source columns, so the backfill below does not re-trigger
-- it and ordinary writes touching neither pay nothing.
drop trigger if exists trg_companies_search_tsv on public.companies;
create trigger trg_companies_search_tsv
  before insert or update of name, keywords, short_description on public.companies
  for each row execute function public.companies_fill_search_tsv();

-- Cheap while the column is mostly null: GIN does not index nulls, so this starts
-- tiny and grows as the backfill proceeds.
create index if not exists idx_companies_search_tsv on public.companies using gin (search_tsv);

-- Bounded, resumable backfill. Returns the number of rows still outstanding, so a
-- caller can loop until it reports zero.
create or replace function public.refresh_company_search_tsv_v1(p_batch integer default 5000)
returns bigint
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $fn$
declare
  v_batch integer := greatest(100, least(coalesce(p_batch, 5000), 50000));
  v_remaining bigint;
begin
  update public.companies c set search_tsv = to_tsvector('simple',
    coalesce(c.name, '') || ' | ' ||
    coalesce(array_to_string(c.keywords, ' | '), '') || ' | ' ||
    coalesce(c.short_description, ''))
  where c.id in (
    select id from public.companies where search_tsv is null limit v_batch
  );

  select count(*) into v_remaining from public.companies where search_tsv is null;
  return v_remaining;
end;
$fn$;

revoke execute on function public.refresh_company_search_tsv_v1(integer) from public, anon, authenticated;
revoke execute on function public.companies_fill_search_tsv() from public, anon, authenticated;
grant execute on function public.refresh_company_search_tsv_v1(integer) to service_role;


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
    if operator_key not in ('contains', 'equals', 'boolean') then continue; end if;
    field_key := filter_item->>'field';

    raw_values := array[]::text[];
    for value_text in
      select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb))
    loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    -- Boolean search: narrow on the stored vector rather than recomputing
    -- to_tsvector for every row. search_tsv covers name + keywords + description
    -- together, so a match on any single scope implies a match on the combined
    -- vector -- a valid NECESSARY condition. company_filter_sql_v2 still does the
    -- exact per-scope check afterwards, so scope selection stays precise.
    --
    -- The null branch matters: rows the backfill has not reached yet cannot be
    -- narrowed, so they pass through to the exact check. Results are therefore
    -- correct at every point during the backfill, not only once it finishes.
    if operator_key = 'boolean' then
      if field_key <> '__company_keywords' then continue; end if;
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := array_append(value_parts,
          format('c.search_tsv @@ to_tsquery(%L, %L)', 'simple', value_text));
      end loop;
      conjuncts := conjuncts || ('(c.search_tsv is null or ' || array_to_string(value_parts, ' or ') || ')');
      continue;
    end if;

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

    -- Exact matching of an array field means any array element equals any
    -- requested value. This is both correct and served by the existing GIN
    -- indexes; joined-string equality is neither.
    if operator_key = 'equals' and field_key = '__keywords' then
      conjuncts := conjuncts || format('c.keywords && %L::text[]', raw_values);
      continue;
    end if;
    if operator_key = 'equals' and field_key = '__technologies' then
      conjuncts := conjuncts || format('c.technologies && %L::text[]', raw_values);
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

    if operator_key = 'equals' then
      conjuncts := conjuncts || format(
        'lower(%s) = any (%L::text[])',
        column_expr,
        array(select lower(value) from unnest(raw_values) value)
      );
    elsif cardinality(raw_values) <= bulk_or_threshold then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      conjuncts := conjuncts || format(
        'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
        raw_values,
        column_expr
      );
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$function$

;

revoke execute on function public.company_prefilter_sql(text, jsonb) from public, anon, authenticated;
grant execute on function public.company_prefilter_sql(text, jsonb) to service_role;

commit;
