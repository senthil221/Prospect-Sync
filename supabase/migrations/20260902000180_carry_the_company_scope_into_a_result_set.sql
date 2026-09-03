-- Let a frozen set remember which companies it was scoped to.
--
-- THE PROBLEM THIS REMOVES. A Company DB pivot narrows the People grid to the
-- companies a company search matched: "the 12,000 people at these 800
-- companies". result_sets stores a search, a filter list and a client scope, and
-- build_batch_v1 applies exactly those three - so a set built from a pivoted
-- view came back with every person matching the filters, ignoring the companies
-- entirely. 674,000 people where the screen said 12,000.
--
-- 20260902000150 and 20260902000170 dealt with that by refusing: push, Date
-- Contacted, delete and background exports all decline while a pivot is active,
-- because freezing the wrong set would only have made it definite. That was the
-- right stopgap and a poor destination - four things the product says no to, in
-- the one view where a user is most likely to want them.
--
-- WHAT CHANGES. result_sets gains company_scope, request_set_v1 records it, and
-- build_batch_v1 applies it exactly the way search_prospect_export_v5 does: the
-- scope is resolved once into company ids by company_scope_ids_v2 and joined,
-- rather than re-evaluated per row. So a set built from a pivoted view contains
-- the people the screen was showing, and the four callers stop refusing.
--
-- IDENTITY HAS TO MOVE WITH IT, OR THE CACHE LIES. Sets are reused by
-- (owner, entity, client scope, authorization scope, content_hash). Two
-- questions that differ ONLY by their pivot would have hashed the same and
-- reused each other's answer - the same silent widening, arriving by a different
-- door. Two defences, deliberately not one:
--
--   1. the unique index now carries md5(company_scope::text), so the database
--      keeps scoped and unscoped sets apart whatever the client hashes. It is
--      md5 of the text rather than the jsonb itself because a btree entry is
--      capped near 2704 bytes and a scope can carry a thousand filter values.
--   2. request_set_v1 matches on company_scope as well, so a lookup can never
--      hand back a set built under a different pivot.
--
-- lib/result-sets.ts folds the scope into the content hash too. That is the
-- third belt on the same pair of braces, and it is the one that makes the other
-- two never fire.
--
-- WHY REPLACING TWO FUNCTIONS RATHER THAN OVERLOADING THEM. Adding a defaulted
-- parameter creates a second function with the same name, and PostgREST calls by
-- named arguments: a call supplying the original seven would match both and fail
-- with "function is not unique". So the old signatures are dropped, and their
-- grants are re-applied below rather than assumed to survive.

begin;

-- 1. Somewhere to keep it ---------------------------------------------------

alter table prospect_results.result_sets
  add column if not exists company_scope jsonb not null default '{}'::jsonb;

comment on column prospect_results.result_sets.company_scope is
  'The Company DB pivot this set was frozen under, applied by build_batch_v1 through company_scope_ids_v2. Empty means unscoped.';

drop index if exists prospect_results.uq_result_sets_identity;
create unique index uq_result_sets_identity
  on prospect_results.result_sets
     (owner_id, entity_type, client_scope, authorization_scope, content_hash, md5(company_scope::text))
  where status in ('pending', 'building', 'ready');

-- 2. Recording it -----------------------------------------------------------

drop function if exists prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, interval);

create or replace function prospect_results.request_set_v1(
  p_owner_id text,
  p_entity_type text,
  p_client_scope text,
  p_search text,
  p_filters jsonb,
  p_content_hash text,
  p_version_vector jsonb,
  p_company_scope jsonb default '{}'::jsonb,
  p_ttl interval default interval '24 hours'
)
returns table(set_id uuid, status text, row_count bigint, reused boolean, stale boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '15s'
as $function$
declare
  v_scope text := coalesce(p_client_scope, '');
  v_company_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_existing prospect_results.result_sets%rowtype;
  v_new uuid;
begin
  if coalesce(btrim(p_owner_id), '') = '' then
    raise exception 'A result set needs an owner' using errcode = '22023';
  end if;
  if p_entity_type not in ('prospect', 'company') then
    raise exception 'Unknown entity type %', p_entity_type using errcode = '22023';
  end if;
  -- A company scope over a set OF companies is not a narrowing, it is a
  -- confusion. Say so rather than storing something nothing will ever apply.
  if p_entity_type = 'company' and v_company_scope <> '{}'::jsonb then
    raise exception 'A company set cannot carry a company scope' using errcode = '22023';
  end if;

  select * into v_existing from prospect_results.result_sets rs
  where rs.owner_id = p_owner_id
    and rs.entity_type = p_entity_type
    and rs.client_scope = v_scope
    and rs.content_hash = p_content_hash
    -- The pivot is part of the question. Without this, a set frozen under one
    -- pivot could answer for another, which is the widening this migration
    -- exists to stop arriving by a different route.
    and rs.company_scope = v_company_scope
    and rs.status in ('pending', 'building', 'ready')
    and rs.expires_at > now();

  if found then
    return query select v_existing.id, v_existing.status, v_existing.row_count, true,
      (v_existing.status = 'ready' and v_existing.version_vector is distinct from p_version_vector);
    return;
  end if;

  insert into prospect_results.result_sets
    (owner_id, entity_type, client_scope, content_hash, version_vector, search, filters,
     company_scope, expires_at)
  values (p_owner_id, p_entity_type, v_scope, p_content_hash, p_version_vector,
          coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb), v_company_scope,
          now() + p_ttl)
  returning id into v_new;

  return query select v_new, 'pending'::text, 0::bigint, false, false;
end;
$function$;

revoke execute on function prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb, interval) from public, anon, authenticated;

-- 3. Applying it ------------------------------------------------------------

-- Same shape as before, plus the scope. The companies are resolved once into a
-- materialized list of ids and joined; company_scope_ids_v2 already caps that
-- list at 250,000 and prefers the complete SQL predicate over the per-row
-- function, so this is the same work the pivoted listing does, once per batch
-- instead of once per row.
create or replace function prospect_results.build_batch_v1(
  p_set_id uuid,
  p_batch_size integer default 25000
)
returns table(inserted integer, total bigint, done boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '120s'
as $function$
declare
  v_row prospect_results.result_sets%rowtype;
  v_batch integer := greatest(1000, least(coalesce(p_batch_size, 25000), 100000));
  v_predicate text;
  v_scope jsonb;
  v_has_scope boolean;
  v_scope_cte text := '';
  v_scope_join text := '';
  v_sql text;
  v_inserted integer;
  v_last_created timestamptz;
  v_last_id text;
begin
  select * into v_row from prospect_results.result_sets where id = p_set_id for update;
  if not found then
    raise exception 'Result set does not exist' using errcode = 'P0002';
  end if;
  if v_row.status not in ('pending', 'building') then
    return query select 0, v_row.row_count, true;
    return;
  end if;

  if v_row.entity_type = 'prospect' then
    v_predicate := public.prospect_filter_sql_v1(v_row.search, v_row.filters);
    if v_predicate is null then
      raise exception 'This filter set cannot be compiled into a result set' using errcode = '22023';
    end if;

    -- The same test scopeRestricts makes in the browser and v5 makes in SQL: a
    -- scope with neither a search nor a filter matches every company and is not
    -- a narrowing, so entering the join would cost a quarter of a million ids
    -- for nothing.
    v_scope := coalesce(v_row.company_scope, '{}'::jsonb);
    v_has_scope := v_scope <> '{}'::jsonb
      and (btrim(coalesce(v_scope->>'search', '')) <> ''
        or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
    if v_has_scope then
      v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
        nullif(v_row.client_scope, ''), v_scope::text);
      v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
    end if;

    v_sql := format($q$
      with %8$s batch as (
        select pi.id, pi.created_at
        from public.prospect_index pi%9$s
        where (%1$L is null or pi.client_ids @> array[%1$L])
          and (%2$s)
          and (%3$L::timestamptz is null
               or (pi.created_at, pi.id) < (%3$L::timestamptz, coalesce(%4$L, '')))
        order by pi.created_at desc, pi.id desc
        limit %5$s
      ), numbered as (
        select batch.*, %6$s + row_number() over (order by created_at desc, id desc) as ordinal
        from batch
      ), stored as (
        insert into prospect_results.result_set_items (result_set_id, ordinal, entity_id)
        select %7$L::uuid, numbered.ordinal, numbered.id from numbered
        on conflict do nothing
        returning 1
      )
      select (select count(*) from stored)::integer,
             (select created_at from numbered order by ordinal desc limit 1),
             (select id from numbered order by ordinal desc limit 1)
    $q$, nullif(v_row.client_scope, ''), v_predicate, v_row.cursor_created_at, v_row.cursor_id,
         v_batch::text, v_row.row_count::text, p_set_id, v_scope_cte, v_scope_join);
  else
    v_predicate := public.company_effective_filter_sql_v1(v_row.search, v_row.filters);
    if v_predicate is null then
      raise exception 'This filter set cannot be compiled into a result set' using errcode = '22023';
    end if;
    v_sql := format($q$
      with batch as (
        select c.id, c.created_at
        from public.companies c
        where (%1$s)
          and (%2$L::timestamptz is null
               or (c.created_at, c.id) < (%2$L::timestamptz, coalesce(%3$L, '')))
        order by c.created_at desc, c.id desc
        limit %4$s
      ), numbered as (
        select batch.*, %5$s + row_number() over (order by created_at desc, id desc) as ordinal
        from batch
      ), stored as (
        insert into prospect_results.result_set_items (result_set_id, ordinal, entity_id)
        select %6$L::uuid, numbered.ordinal, numbered.id from numbered
        on conflict do nothing
        returning 1
      )
      select (select count(*) from stored)::integer,
             (select created_at from numbered order by ordinal desc limit 1),
             (select id from numbered order by ordinal desc limit 1)
    $q$, v_predicate, v_row.cursor_created_at, v_row.cursor_id,
         v_batch::text, v_row.row_count::text, p_set_id);
  end if;

  execute v_sql into v_inserted, v_last_created, v_last_id;
  v_inserted := coalesce(v_inserted, 0);

  if v_inserted = 0 then
    update prospect_results.result_sets
    set status = 'ready', completed_at = now(), lease_expires_at = null, worker_id = null
    where id = p_set_id;
    return query select 0, v_row.row_count, true;
    return;
  end if;

  update prospect_results.result_sets
  set row_count = row_count + v_inserted,
      cursor_created_at = v_last_created,
      cursor_id = v_last_id,
      lease_expires_at = greatest(coalesce(lease_expires_at, now()), now() + interval '120 seconds'),
      status = case when v_inserted < v_batch then 'ready' else status end,
      completed_at = case when v_inserted < v_batch then now() else completed_at end
  where id = p_set_id
  returning row_count, status = 'ready' into total, done;

  inserted := v_inserted;
  return next;
end;
$function$;

-- 4. The application's door -------------------------------------------------

drop function if exists public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb);

create or replace function public.request_result_set_v1(
  p_owner_id text,
  p_entity_type text,
  p_client_scope text,
  p_search text,
  p_filters jsonb,
  p_content_hash text,
  p_version_vector jsonb default null,
  p_company_scope jsonb default '{}'::jsonb
)
returns table(set_id uuid, status text, row_count bigint, reused boolean, stale boolean)
language sql
security definer
set search_path = pg_catalog, public, prospect_results
set statement_timeout = '15s'
as $function$
  select * from prospect_results.request_set_v1(
    p_owner_id, p_entity_type, p_client_scope, p_search, p_filters, p_content_hash,
    -- Still taken here rather than accepted from the browser: a client-supplied
    -- vector could only ever make a stale set look fresh (20260902000160).
    coalesce(p_version_vector, public.data_versions_v1(array[p_entity_type])),
    p_company_scope);
$function$;

revoke execute on function public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb) to service_role;

-- 5. What the worker may do, unchanged --------------------------------------

do $$
declare
  v_problems text[] := array[]::text[];
begin
  -- build_batch_v1 keeps its signature, so CREATE OR REPLACE kept its grant.
  -- Asserted rather than assumed, because losing it would stop every set
  -- silently: the worker would claim work it could not perform.
  if not has_function_privilege('prospect_operator', 'prospect_results.build_batch_v1(uuid, integer)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator lost build_batch_v1');
  end if;
  if not has_function_privilege('prospect_operator', 'prospect_results.claim_next_v1(text, integer)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator lost claim_next_v1');
  end if;
  -- The two replaced functions must not have come back with PUBLIC execute:
  -- a dropped function takes its grants with it, and a recreated one is created
  -- executable by PUBLIC by default.
  if has_function_privilege('authenticated', 'public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb)', 'execute') then
    v_problems := array_append(v_problems, 'authenticated can request a result set directly');
  end if;
  if has_function_privilege('authenticated', 'prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb, interval)', 'execute') then
    v_problems := array_append(v_problems, 'authenticated can reach the private request_set_v1');
  end if;
  if has_function_privilege('prospect_operator', 'prospect_results.request_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb, interval)', 'execute') then
    v_problems := array_append(v_problems, 'prospect_operator can request a result set, which it must not');
  end if;
  if not has_function_privilege('service_role', 'public.request_result_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb)', 'execute') then
    v_problems := array_append(v_problems, 'service_role cannot request a result set, so the application has no door');
  end if;

  -- The old signatures must be gone, not shadowed: two functions of the same
  -- name is how PostgREST starts answering "function is not unique".
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'request_result_set_v1'
      and pg_get_function_identity_arguments(p.oid) = 'text, text, text, text, jsonb, text, jsonb'
  ) then
    v_problems := array_append(v_problems, 'the seven-argument request_result_set_v1 is still there');
  end if;

  if cardinality(v_problems) > 0 then
    raise exception using
      message = 'Result-set scope privileges are not what this migration intends',
      detail = array_to_string(v_problems, '; ');
  end if;
end $$;

commit;
