-- "Missing keywords" and "missing description" company filters read an index.
--
-- MEASURED on production 2026-09-26, filter_companies_v4 end to end:
--   keywords empty                      92,646 matches   8.3 s
--   description empty                  102,453 matches   4.7 s
--   keywords empty + description empty  63,501 matches   2.0 s
-- These are what the Data Quality "missing info" links open, and the slowest
-- company-page calls in the log since 2026-09-09 (9.4 s and 4.5 s). Each count
-- was a sequential scan of all 446,492 companies; for keywords it also
-- de-TOASTed every keywords array (443,301 buffers for one count) to build
-- array_to_string(keywords, ' | '). The data is simple - an empty keywords is
-- always '{}' and an empty description always '' - but the predicate could not
-- be indexed: array_to_string is STABLE, and index predicates must be
-- IMMUTABLE.
--
-- THE CHANGE.
--   * company_filter_sql_v3 compiles __keywords through public.tag_array_text_v1
--     (array_to_string(p, ' | '), declared IMMUTABLE - true for text[]), and
--     __technologies through company_technologies_text_v1 (20260923120000), so
--     "technologies contains" on the Companies page reaches the trigram index
--     that migration built for the People page.
--   * Two partial indexes hold exactly the blank rows. The compiled "empty"
--     predicate is textually the index predicate, so the planner proves the
--     match and counts from the index instead of the table.
-- Same rows as before: the wrappers return array_to_string's value, NULL for
-- NULL; the migration checks both counts against the old expressions.
--
-- THE LOCK. Each index build holds a SHARE lock on companies (reads continue,
-- company writes wait). Deploy while no import is running; lock_timeout makes
-- the migration step aside rather than queue behind one.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.tag_array_text_v1(p_tags text[])
returns text
language sql
immutable
parallel safe
as $$ select array_to_string(p_tags, ' | ') $$;

comment on function public.tag_array_text_v1(text[]) is
  'array_to_string(tags, '' | '') declared IMMUTABLE so company filters on keywords can be indexed.';

do $BODY$
declare
  v_def text := pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure);
  v_old_kw constant text := E'when ''__keywords'' then ''array_to_string(c.keywords, '' || quote_literal('' | '') || '')''';
  v_new_kw constant text := E'when ''__keywords'' then ''public.tag_array_text_v1(c.keywords)''';
  v_old_tech constant text := E'when ''__technologies'' then ''array_to_string(c.technologies, '' || quote_literal('' | '') || '')''';
  v_new_tech constant text := E'when ''__technologies'' then ''public.company_technologies_text_v1(c.technologies)''';
begin
  if position(v_old_kw in v_def) = 0 or position(v_old_tech in v_def) = 0 then
    raise exception 'company_filter_sql_v3 no longer compiles __keywords/__technologies the way this migration expects';
  end if;
  execute replace(replace(v_def, v_old_kw, v_new_kw), v_old_tech, v_new_tech);
end $BODY$;

revoke execute on function public.company_filter_sql_v3(text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.company_filter_sql_v3(text, jsonb, boolean) to service_role;

create index if not exists idx_companies_keywords_blank
  on public.companies (id)
  where btrim(coalesce(public.tag_array_text_v1(keywords), '')) = '';

create index if not exists idx_companies_description_blank
  on public.companies (id)
  where btrim(coalesce(short_description, '')) = '';

-- ---------------------------------------------------------------------------
-- The compiler emits the index predicates, and the counts are the old counts.
do $$
declare
  v_sql text;
  v_old bigint;
  v_new bigint;
begin
  v_sql := public.company_filter_sql_v3('', '[{"field":"__keywords","operator":"empty","values":[]}]'::jsonb);
  if v_sql <> '(btrim(coalesce(public.tag_array_text_v1(c.keywords), '''')) = '''')' then
    raise exception 'keywords empty compiled to %', v_sql;
  end if;
  execute format('select count(*) from public.companies c where %s', v_sql) into v_new;
  select count(*) into v_old from public.companies c where btrim(coalesce(array_to_string(c.keywords, ' | '), '')) = '';
  if v_new <> v_old then
    raise exception 'keywords empty now matches % companies, previously %', v_new, v_old;
  end if;

  v_sql := public.company_filter_sql_v3('', '[{"field":"__technologies","operator":"contains","values":["salesforce"]}]'::jsonb);
  if position('public.company_technologies_text_v1(c.technologies) ilike' in v_sql) = 0 then
    raise exception 'technologies contains compiled to %', v_sql;
  end if;
  execute format('select count(*) from public.companies c where %s', v_sql) into v_new;
  select count(*) into v_old from public.companies c where array_to_string(c.technologies, ' | ') ilike '%salesforce%';
  if v_new <> v_old then
    raise exception 'technologies contains now matches % companies, previously %', v_new, v_old;
  end if;

  v_sql := public.company_filter_sql_v3('', '[{"field":"__keywords","operator":"contains","values":["saas"]}]'::jsonb);
  execute format('select count(*) from public.companies c where %s', v_sql) into v_new;
  select count(*) into v_old from public.companies c
  where array_to_string(c.keywords, ' | ') ilike '%saas%';
  if v_new <> v_old then
    raise exception 'keywords contains now matches % companies, previously %', v_new, v_old;
  end if;
end $$;
