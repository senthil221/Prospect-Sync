-- Number of Uses: how many times a client has contacted a person, counted as
-- changes of Date Contacted.
--
-- Asked for on 2026-10-10 for the client People DB, with a filter ("less than
-- 1 use, less than 2 uses ..."). Date Contacted is client_prospects.date_added
-- (imports overwrite it with the file's date, 20260921090000; the Set Date
-- Contacted bulk action sets it). There is no history of past changes -
-- contact_events is empty - so counting starts now:
--
--   use_count  0 with no Date Contacted, 1 once there is one, +1 every time
--              Date Contacted later changes to a different date. Clearing the
--              date does not count, and re-importing the same date does not.
--   backfill   1 for the 105k memberships that already carry a date.
--
-- Kept by a BEFORE INSERT / UPDATE OF date_added trigger, so every write path
-- (import sync, bulk set, push, pull) counts the same way.
--
-- FILTER. __client_use_count, operator equals, values [client id, N]: fewer
-- than N uses for that client. Compiler and row matcher.
--
-- READERS. The client People readers return it as client_use_count beside
-- client_date_contacted, for the Uses column.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

alter table public.client_prospects add column if not exists use_count integer not null default 0;

create or replace function public.count_client_prospect_use_v1()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.date_added is not null then
      new.use_count := greatest(coalesce(new.use_count, 0), 1);
    end if;
  elsif new.date_added is not null and new.date_added is distinct from old.date_added then
    new.use_count := coalesce(old.use_count, 0) + 1;
  end if;
  return new;
end;
$$;

revoke execute on function public.count_client_prospect_use_v1() from public, anon, authenticated;

drop trigger if exists trg_count_client_prospect_use on public.client_prospects;
create trigger trg_count_client_prospect_use
before insert or update of date_added on public.client_prospects
for each row execute function public.count_client_prospect_use_v1();

-- Backfill: a date already there is one use. Does not touch date_added, so the
-- trigger above does not fire.
update public.client_prospects set use_count = 1 where date_added is not null and use_count = 0;

do $patch$
declare
  v_definition text;
  v_anchor text;
  v_function regprocedure;
begin
  -- Filter, compiled.
  select pg_get_functiondef('public.prospect_filter_sql_v1(text,jsonb)'::regprocedure) into v_definition;
  if position('__client_use_count' in v_definition) = 0 then
    v_anchor := $old$    if field_key = '__client_date_contacted' then$old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_filter_sql_v1: Date Contacted anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$    -- Number of Uses: fewer than N for the client (20261010100000).
    if field_key = '__client_use_count' then
      if cardinality(raw_values) < 2 or raw_values[2] !~ '^[0-9]{1,4}$' then
        conjuncts := array_append(conjuncts, 'false');
        continue;
      end if;
      conjuncts := array_append(conjuncts, format(
        'exists (select 1 from public.client_prospects cp where cp.prospect_id = pi.id and cp.client_id = %L and cp.use_count < %s)',
        raw_values[1], raw_values[2]::integer));
      continue;
    end if;

    if field_key = '__client_date_contacted' then$new$);
  end if;

  -- Filter, row matcher.
  select pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure) into v_definition;
  if position('__client_use_count' in v_definition) = 0 then
    v_anchor := $old$      when filter_item->>'field' = '__icp_unverified' then ($old$;
    if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
      raise exception 'prospect_index_matches_v1: ICP Unverified anchor is not unique';
    end if;
    execute replace(v_definition, v_anchor,
      $new$      when filter_item->>'field' = '__client_use_count' then (
        coalesce(filter_item->'values'->>1, '') ~ '^[0-9]{1,4}$'
        and exists (select 1 from public.client_prospects cp
                     where cp.prospect_id = (p_row).id and cp.client_id = filter_item->'values'->>0
                       and cp.use_count < (filter_item->'values'->>1)::integer)
      )
      when filter_item->>'field' = '__icp_unverified' then ($new$);
  end if;

  -- Readers: client_use_count beside client_date_contacted.
  for v_function in
    select p.oid::regprocedure from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('search_prospect_workspace_v12', 'search_prospect_workspace_v13', 'search_prospect_workspace_cursor_v1',
                         'search_prospect_workspace_cursor_v2', 'search_prospect_workspace_page_v1')
  loop
    v_definition := pg_get_functiondef(v_function);
    if position('client_use_count' in v_definition) = 0 then
      v_anchor := 'select pi.*, cp.date_added as client_date_contacted,';
      if (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 then
        raise exception '%: hydration anchor is not unique', v_function;
      end if;
      execute replace(v_definition, v_anchor,
        'select pi.*, cp.date_added as client_date_contacted, cp.use_count as client_use_count,');
    end if;
  end loop;
end;
$patch$;

-- Proof, read-only.
do $proof$
declare
  v_client text;
  v_filters jsonb;
  v_compiled bigint;
  v_matched bigint;
  v_wrong bigint;
begin
  if exists (select 1 from public.client_prospects where date_added is not null and use_count < 1) then
    raise exception 'Uses proof: a dated membership has no use';
  end if;
  select client_id into v_client from public.client_prospects where date_added is not null group by 1 order by count(*) desc limit 1;
  if v_client is null then
    raise notice 'Uses proof: no dated membership - compile checks only.';
    return;
  end if;
  v_filters := jsonb_build_array(jsonb_build_object('field', '__client_use_count', 'operator', 'equals', 'values', jsonb_build_array(v_client, '1')));
  execute format('select count(*) filter (where %s), count(*) filter (where public.prospect_index_matches_v1(pi, '''', %L::jsonb))
                    from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 20000) pi',
    public.prospect_filter_sql_v1('', v_filters), v_filters, v_client) into v_compiled, v_matched;
  if v_compiled <> v_matched then
    raise exception 'Uses proof: compiled % vs matcher %', v_compiled, v_matched;
  end if;
  -- "Fewer than 1 use" is exactly "no Date Contacted".
  execute format('select count(*) from (select * from public.prospect_index pi where %L = any(pi.client_ids) limit 20000) pi
                   join public.client_prospects cp on cp.client_id = %L and cp.prospect_id = pi.id
                  where (%s) and cp.date_added is not null',
    v_client, v_client, public.prospect_filter_sql_v1('', v_filters)) into v_wrong;
  if v_wrong <> 0 then
    raise exception 'Uses proof: % people with a Date Contacted read as never used', v_wrong;
  end if;
  raise notice 'Uses proof passed.';
end;
$proof$;
