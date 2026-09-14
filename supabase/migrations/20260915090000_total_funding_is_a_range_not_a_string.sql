-- Total funding becomes a range filter with a "Not known" option, like
-- # Employees and Founded year already are.
--
-- WHY IT COULD NOT BE ONE BEFORE. companies.total_funding is text, and the
-- filter panel offered it as a token field - type a value, match it as a
-- substring. So "$5M or more" was not a question you could ask, and "10000000"
-- as a substring matched 110000000 as happily as itself.
--
-- WHAT THE DATA ACTUALLY LOOKS LIKE. Measured on production, 2026-09-15:
--
--   companies                        419,521
--   total_funding blank              410,630   (97.9%)
--   total_funding present              8,891   (2.1%)
--   of those, non-numeric                  4
--   min / median / max            701 / 5,100,000 / 178,014,000,000
--
-- Two things follow from those numbers. First, "Not known" is not an edge case
-- here, it is 98% of the database - which is exactly why it needs to be a
-- selectable option rather than an absence. Second, the maximum is 178 billion,
-- which does NOT fit in an integer, and the existing range machinery casts
-- bounds with ::integer. Funding therefore parses its own bounds as bigint
-- rather than reusing selected_range; reusing it would raise 22003 on any
-- filter above 2.1 billion.
--
-- THE FOUR NON-NUMERIC VALUES are 'Cisco Anyconnect', 'Metasploit', 'Tanium'
-- and 'Elite Software HVAC Solution' - technology names that landed in the
-- funding column through a mis-mapped import. They parse to null, which puts
-- them in "Not known". That is the correct answer for them, so they are left
-- exactly as they are: this migration does not edit anybody's data.
--
-- WHY A COLUMN AND NOT A GENERATED COLUMN. A STORED generated column would need
-- no trigger and no backfill, but adding one rewrites the whole table under an
-- ACCESS EXCLUSIVE lock. companies is on the read path of every workspace, so a
-- 419,521-row rewrite is not worth the tidiness. A nullable plain column is
-- instant, the backfill touches only the 8,891 rows that have a value, and a
-- trigger keeps it true afterwards.
-- ---------------------------------------------------------------------------

alter table public.companies
  add column if not exists total_funding_amount bigint;

comment on column public.companies.total_funding_amount is
  'Numeric form of total_funding, maintained by companies_total_funding_amount_sync. Null means not known, which is 98% of rows.';

-- Only rows that actually carry a value. Decimals are floored rather than
-- rejected: "1500000.50" is a funding amount, not a parse error.
update public.companies
   set total_funding_amount = floor(total_funding::numeric)::bigint
 where btrim(coalesce(total_funding, '')) <> ''
   and total_funding ~ '^[0-9]+(\.[0-9]+)?$'
   and total_funding_amount is null;

-- Partial: 98% of the table is null, and "not known" is answered by the null
-- test rather than by an index scan, so indexing those rows would be paying to
-- store the answer nobody looks up that way.
create index if not exists idx_companies_total_funding_amount
  on public.companies (total_funding_amount)
  where total_funding_amount is not null;

create or replace function public.sync_total_funding_amount()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.total_funding_amount := case
    when btrim(coalesce(new.total_funding, '')) <> '' and new.total_funding ~ '^[0-9]+(\.[0-9]+)?$'
      then floor(new.total_funding::numeric)::bigint
    else null
  end;
  return new;
end;
$$;

drop trigger if exists companies_total_funding_amount_sync on public.companies;
create trigger companies_total_funding_amount_sync
  before insert or update of total_funding on public.companies
  for each row execute function public.sync_total_funding_amount();

-- ---------------------------------------------------------------------------
-- Teach the two company filter paths about funding ranges.
--
-- They are patched rather than rewritten, using the splice that
-- 20260908141654 established: read the deployed body, replace a known anchor,
-- and RAISE if the anchor is missing. A blind replace that silently matched
-- nothing would leave the SQL builder and the row matcher disagreeing about
-- what a filter means, which is the one failure mode that produces wrong
-- answers rather than errors.
do $patch_funding$
declare
  v_definition text;
  v_rewritten text;
begin
  -- 1. The SQL builder. Funding joins the unknown branch and the range branch.
  select pg_get_functiondef('public.company_filter_sql_v3(text,jsonb,boolean)'::regprocedure) into v_definition;

  v_rewritten := replace(v_definition,
    $old$          elsif field_key = '__founded_year' then
            value_parts := array_append(value_parts, '(c.founded_year is null)');
          end if;$old$,
    $new$          elsif field_key = '__founded_year' then
            value_parts := array_append(value_parts, '(c.founded_year is null)');
          elsif field_key = '__total_funding' then
            value_parts := array_append(value_parts, '(c.total_funding_amount is null)');
          end if;$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 funding unknown branch'; end if;
  v_definition := v_rewritten;

  -- Bounds are written as literals straight from the validated value, so the
  -- bigint range is not squeezed through the ::integer casts the other two
  -- fields share.
  v_rewritten := replace(v_definition,
    $old$        elsif field_key = '__founded_year' then
          value_parts := value_parts || format('(c.founded_year is not null and c.founded_year >= %s and (%s))',
            minimum, case when maximum is null then 'true' else format('c.founded_year <= %s', maximum) end);
        end if;$old$,
    $new$        elsif field_key = '__founded_year' then
          value_parts := value_parts || format('(c.founded_year is not null and c.founded_year >= %s and (%s))',
            minimum, case when maximum is null then 'true' else format('c.founded_year <= %s', maximum) end);
        elsif field_key = '__total_funding' then
          value_parts := value_parts || format('(c.total_funding_amount is not null and c.total_funding_amount >= %s::bigint and (%s))',
            minimum, case when maximum is null then 'true' else format('c.total_funding_amount <= %s::bigint', maximum) end);
        end if;$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_filter_sql_v3 funding range branch'; end if;
  execute v_rewritten;

  -- 2. The row matcher, which must agree with the builder exactly. It gets its
  -- own bigint bounds in the same lateral, for the 178-billion reason above.
  select pg_get_functiondef('public.company_matches_filters_v1(public.companies,text,jsonb)'::regprocedure) into v_definition;

  v_rewritten := replace(v_definition,
    $old$            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum$old$,
    $new$            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum,
            case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::bigint end as minimum_big,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::bigint end as maximum_big$new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 range bounds'; end if;
  v_definition := v_rewritten;

  v_rewritten := replace(v_definition,
    $old$          or (filter_item->>'field' = '__founded_year' and ($old$,
    $new$          or (filter_item->>'field' = '__total_funding' and (
            (selected.value = 'unknown' and (p_row).total_funding_amount is null)
            or (selected.value <> 'unknown' and (p_row).total_funding_amount is not null
              and (selected_range.minimum_big is null or (p_row).total_funding_amount >= selected_range.minimum_big)
              and (selected_range.maximum_big is null or (p_row).total_funding_amount <= selected_range.maximum_big))))
          or (filter_item->>'field' = '__founded_year' and ($new$);
  if v_rewritten = v_definition then raise exception 'Could not patch company_matches_filters_v1 funding clause'; end if;
  execute v_rewritten;
end $patch_funding$;

-- ---------------------------------------------------------------------------
-- Assertions.
do $$
declare
  v_sql text;
  v_unknown integer;
  v_ranged integer;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'companies'
                    and column_name = 'total_funding_amount') then
    raise exception 'companies.total_funding_amount was not added';
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'companies_total_funding_amount_sync') then
    raise exception 'the total_funding sync trigger is missing; the column would go stale on the next import';
  end if;

  -- The builder must now emit funding predicates rather than silently dropping
  -- the filter - "matched nothing" and "was not understood" look identical to a
  -- user, so this is checked rather than assumed.
  v_sql := public.company_filter_sql_v3('', '[{"field":"__total_funding","operator":"number_ranges","values":["unknown"]}]'::jsonb);
  if v_sql not like '%total_funding_amount is null%' then
    raise exception 'funding unknown did not compile: %', v_sql;
  end if;
  v_sql := public.company_filter_sql_v3('', '[{"field":"__total_funding","operator":"number_ranges","values":["1000000:5000000"]}]'::jsonb);
  if v_sql not like '%total_funding_amount >= 1000000%' or v_sql not like '%total_funding_amount <= 5000000%' then
    raise exception 'funding range did not compile: %', v_sql;
  end if;

  -- A bound past 2.1 billion must compile and run, not raise 22003. This is the
  -- whole reason funding does not share the integer bounds.
  v_sql := public.company_filter_sql_v3('', '[{"field":"__total_funding","operator":"number_ranges","values":["3000000000:"]}]'::jsonb);
  if v_sql not like '%3000000000%' then
    raise exception 'a funding bound above the integer range did not compile: %', v_sql;
  end if;

  -- The backfill covered every parseable row.
  select count(*) into v_unknown from public.companies
   where btrim(coalesce(total_funding, '')) <> ''
     and total_funding ~ '^[0-9]+(\.[0-9]+)?$'
     and total_funding_amount is null;
  if v_unknown <> 0 then
    raise exception '% rows carry a numeric total_funding but no total_funding_amount', v_unknown;
  end if;

  select count(*) into v_ranged from public.companies where total_funding_amount is not null;
  raise notice 'total_funding_amount populated on % companies', v_ranged;
end $$;
