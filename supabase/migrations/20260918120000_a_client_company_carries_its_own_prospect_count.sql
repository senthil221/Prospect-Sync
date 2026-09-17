-- A client's company carries its own prospect count, instead of the listing
-- aggregating prospect_index every time the page is opened.
--
-- WHAT IT COSTS TODAY, MEASURED 2026-09-18 on production. filter_companies_v4
-- builds this CTE for every client request:
--
--   client_counts as (
--     select pi.company_id, count(distinct pi.id), count(distinct cid)
--     from public.prospect_index pi
--     left join lateral unnest(pi.client_ids) cid on true
--     where pi.client_ids @> array[<client>]
--     group by pi.company_id)
--
-- On Unassigned that unnests 675,504 prospect rows and double-count(distinct)s
-- them - 1,347 ms on its own - and the result is then joined to every one of
-- 151,188 companies and sorted, to return fifty rows. The whole call measured
-- 10,101 ms before 20260918090000 removed one of the two scans, and 4,580 ms
-- after it. The remaining time is this CTE and the sort it feeds.
--
-- THE SHAPE OF THE FIX IS ALREADY IN THE SCHEMA. companies.prospect_count and
-- companies.client_count are stored columns, kept fresh by statement-level
-- triggers on prospect_index with transition tables, which call
-- recompute_company_counts_bulk over the affected company ids. This is the same
-- thing one level down: the per-client count belongs on client_companies, the
-- row that already says the company is in the client.
--
-- IT RIDES THE EXISTING TRIGGERS RATHER THAN ADDING ANY. sync_company_counts_
-- statement already computes the set of affected company ids once per
-- statement; it now hands that same set to a sibling recompute. No new trigger,
-- no second transition table, and bulk re-indexing still pays for one statement
-- rather than one per row.
--
-- RECOMPUTE, NOT DELTA. A delta would be cheaper per statement and would drift:
-- one missed path and the number on screen is quietly wrong forever. Recomputing
-- the affected pairs from prospect_index cannot drift, which is the same trade
-- recompute_company_counts_bulk already makes. The update is guarded by
-- "is distinct from" so unchanged pairs are not rewritten, which keeps a large
-- re-index from bloating the table with identical rows.
--
-- WHAT STAYS COMPUTED. client_count - "this company is in 3 clients" - depends
-- on other clients' links to the same prospects, so it is not a per-pair fact
-- and is not stored. It is now evaluated only for the rows on the page, which
-- is fifty, instead of for every company in the client.
-- ---------------------------------------------------------------------------

alter table public.client_companies
  add column if not exists prospect_count integer not null default 0;

comment on column public.client_companies.prospect_count is
  'How many of this client''s prospects sit at this company. Denormalized from prospect_index by recompute_client_company_counts_bulk; reconcile_client_company_counts_v1 proves it.';

-- The listing orders by prospect_count desc and takes fifty. The trailing
-- company_id keeps the index covering for the count, which reads nothing else.
create index if not exists idx_client_companies_ranking
  on public.client_companies (client_id, prospect_count desc, company_id);

-- ---------------------------------------------------------------------------
-- Backfill. Set based rather than per row: one pass over prospect_index for
-- every client/company pair at once. Pairs with no prospects keep the 0 default.
update public.client_companies cc
set prospect_count = agg.n
from (
  select pi.company_id, cid as client_id, count(*)::integer as n
  from public.prospect_index pi
  cross join lateral unnest(pi.client_ids) as cid
  where pi.company_id is not null
  group by pi.company_id, cid
) agg
where agg.company_id = cc.company_id
  and agg.client_id = cc.client_id
  and cc.prospect_count is distinct from agg.n;

-- ---------------------------------------------------------------------------
-- Keeping it fresh, for the companies a statement touched.
create or replace function public.recompute_client_company_counts_bulk(p_company_ids text[])
returns void
language sql
security definer
set search_path to 'public'
as $FN$
  update public.client_companies cc
  set prospect_count = coalesce(agg.n, 0)
  from public.client_companies target
  left join (
    select pi.company_id, cid as client_id, count(*)::integer as n
    from public.prospect_index pi
    cross join lateral unnest(pi.client_ids) as cid
    where pi.company_id = any(coalesce(p_company_ids, array[]::text[]))
    group by pi.company_id, cid
  ) agg on agg.company_id = target.company_id and agg.client_id = target.client_id
  where target.company_id = any(coalesce(p_company_ids, array[]::text[]))
    and cc.client_id = target.client_id
    and cc.company_id = target.company_id
    -- Unchanged pairs are not rewritten: a re-index of 131,819 prospects must
    -- not leave a dead row behind for every pair it did not actually change.
    and cc.prospect_count is distinct from coalesce(agg.n, 0);
$FN$;

revoke execute on function public.recompute_client_company_counts_bulk(text[]) from public, anon, authenticated;
grant execute on function public.recompute_client_company_counts_bulk(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- Proof on demand: recompute every pair from prospect_index and report how many
-- disagreed. Returns the drift it found, after correcting it, so a maintenance
-- run can print a number and a human can watch it stay zero.
create or replace function public.reconcile_client_company_counts_v1()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $FN$
declare
  v_drift integer;
begin
  create temporary table if not exists _ccc_truth (
    company_id text, client_id text, n integer
  ) on commit drop;
  delete from _ccc_truth;

  insert into _ccc_truth (company_id, client_id, n)
  select pi.company_id, cid, count(*)::integer
  from public.prospect_index pi
  cross join lateral unnest(pi.client_ids) as cid
  where pi.company_id is not null
  group by pi.company_id, cid;

  select count(*)::integer into v_drift
  from public.client_companies cc
  left join _ccc_truth t on t.company_id = cc.company_id and t.client_id = cc.client_id
  where cc.prospect_count is distinct from coalesce(t.n, 0);

  update public.client_companies cc
  set prospect_count = coalesce(t.n, 0)
  from public.client_companies target
  left join _ccc_truth t on t.company_id = target.company_id and t.client_id = target.client_id
  where cc.client_id = target.client_id
    and cc.company_id = target.company_id
    and cc.prospect_count is distinct from coalesce(t.n, 0);

  return v_drift;
end;
$FN$;

revoke execute on function public.reconcile_client_company_counts_v1() from public, anon, authenticated;
grant execute on function public.reconcile_client_company_counts_v1() to service_role;

-- ---------------------------------------------------------------------------
-- The existing statement trigger hands its affected set to the new recompute.
-- One splice, so the company counts and the client/company counts can never be
-- computed from different sets of ids.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.sync_company_counts_statement'::regproc);
  v_old constant text :=
E'  if v_ids is not null and cardinality(v_ids) > 0 then
    perform public.recompute_company_counts_bulk(v_ids);
  end if;';
  v_new constant text :=
E'  if v_ids is not null and cardinality(v_ids) > 0 then
    perform public.recompute_company_counts_bulk(v_ids);
    -- Same ids, same statement: the per-client counts on client_companies are
    -- the same denormalisation one level down, and must not be computed from a
    -- different set than the company totals were.
    perform public.recompute_client_company_counts_bulk(v_ids);
  end if;';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'sync_company_counts_statement no longer calls recompute_company_counts_bulk where expected';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('recompute_client_company_counts_bulk(v_ids)' in v_def) = 0 then
    raise exception 'the client company recompute was not added to the statement trigger';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- The listing reads the column instead of building the CTE.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.filter_companies_v4'::regproc);
  v_branch_old constant text :=
E'    v_ctes := array_append(v_ctes, format($counts$client_counts as (
        select pi.company_id,
          count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) cid on true
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      )$counts$, p_client_id));
    v_join := '' left join client_counts k on k.company_id = c.id'';
    v_prospect_expr := ''coalesce(k.prospect_count, 0)'';
    v_client_expr := ''coalesce(k.client_count, 0)'';';
  v_branch_new constant text :=
E'    -- The per-client prospect count is a stored column on the membership row,
    -- so there is no aggregate to build and the join is an index lookup. The
    -- join is inner because a company is in this client exactly when the
    -- membership row exists, which is what the scope suffix also says.
    v_join := format('' join public.client_companies k on k.company_id = c.id and k.client_id = %L'', p_client_id);
    v_prospect_expr := ''k.prospect_count'';
    -- client_count depends on how other clients link to the same prospects, so
    -- it is not a per-pair fact and is not stored. It is evaluated for the rows
    -- on the page only - fifty - rather than for every company in the client.
    v_client_expr := format($ce$(select count(distinct cid)::integer
      from public.prospect_index pi
      cross join lateral unnest(pi.client_ids) as cid
      where pi.company_id = c.id and pi.client_ids @> array[%L])$ce$, p_client_id);';
  v_fast_old constant text :=
E'    v_count_source := ''public.client_companies cc left join client_counts k on k.company_id = cc.company_id'';
    v_count_pred := format(''cc.client_id = %L'', p_client_id);';
  v_fast_new constant text :=
E'    v_count_source := ''public.client_companies k'';
    v_count_pred := format(''k.client_id = %L'', p_client_id);';
begin
  if position(v_branch_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer contains the client_counts CTE this migration removes';
  end if;
  if position(v_fast_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer contains the membership count source from 20260918090000';
  end if;

  -- Both in ONE rewrite: the fast path referenced client_counts, so removing
  -- the CTE without moving it would store a function that names a CTE it no
  -- longer builds.
  v_def := replace(v_def, v_branch_old, v_branch_new);
  v_def := replace(v_def, v_fast_old, v_fast_new);

  if position('client_counts' in v_def) > 0 then
    raise exception 'client_counts still appears in filter_companies_v4 after the rewrite';
  end if;
  if position('k.prospect_count' in v_def) = 0
     or position('public.client_companies k' in v_def) = 0 then
    raise exception 'the stored-count replacement did not take';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- The column agrees with prospect_index everywhere, right now.
do $$
declare
  v_drift bigint;
begin
  with truth as (
    select pi.company_id, cid as client_id, count(*)::integer as n
    from public.prospect_index pi
    cross join lateral unnest(pi.client_ids) as cid
    where pi.company_id is not null
    group by pi.company_id, cid
  )
  select count(*) into v_drift
  from public.client_companies cc
  left join truth t on t.company_id = cc.company_id and t.client_id = cc.client_id
  where cc.prospect_count is distinct from coalesce(t.n, 0);

  if v_drift > 0 then
    raise exception 'the backfill left % client/company pairs disagreeing with prospect_index', v_drift;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- And the listing returns what it returned before, for every client. The totals
-- are compared against prospect_index directly rather than against the column,
-- so agreement here is not the column agreeing with itself.
do $$
declare
  v_client record;
  v_row record;
  v_total integer;
  v_covered integer;
  v_people bigint;
begin
  for v_client in select id, name from public.clients order by id loop
    select total_count, covered_count, prospect_total into v_row
    from public.filter_companies_v4('', '[]'::jsonb, v_client.id, null, 1, 0, null) limit 1;

    select count(*)::integer into v_total
    from public.client_companies where client_id = v_client.id;

    select count(*)::integer into v_covered
    from public.client_companies cc
    where cc.client_id = v_client.id
      and exists (select 1 from public.prospect_index pi
                   where pi.company_id = cc.company_id
                     and pi.client_ids @> array[v_client.id]);

    select count(*) into v_people
    from public.prospect_index pi
    where pi.company_id is not null and pi.client_ids @> array[v_client.id];

    if v_row.total_count is distinct from v_total then
      raise exception 'client %: listing counted % companies, membership has %', v_client.name, v_row.total_count, v_total;
    end if;
    if v_row.covered_count is distinct from v_covered then
      raise exception 'client %: listing reported % covered, prospect_index says %', v_client.name, v_row.covered_count, v_covered;
    end if;
    if v_row.prospect_total is distinct from v_people::integer then
      raise exception 'client %: listing summed % people, prospect_index has %', v_client.name, v_row.prospect_total, v_people;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- The page still carries the same per-row numbers, including client_count,
-- which moved from the removed CTE into a per-row expression.
do $$
declare
  v_client text;
  v_rows jsonb;
  v_row jsonb;
  v_true_people integer;
  v_true_clients integer;
begin
  select cc.client_id into v_client
  from public.client_companies cc
  where cc.prospect_count > 0
  order by cc.prospect_count desc
  limit 1;
  if v_client is null then
    raise notice 'no client holds a company with people; the page numbers are unproven';
    return;
  end if;

  select result_rows into v_rows
  from public.filter_companies_v4('', '[]'::jsonb, v_client, null, 5, 0, null) limit 1;

  for v_row in select value from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) loop
    select count(*)::integer into v_true_people
    from public.prospect_index pi
    where pi.company_id = v_row->>'id' and pi.client_ids @> array[v_client];

    select count(distinct cid)::integer into v_true_clients
    from public.prospect_index pi
    cross join lateral unnest(pi.client_ids) as cid
    where pi.company_id = v_row->>'id' and pi.client_ids @> array[v_client];

    if (v_row->>'prospect_count')::integer is distinct from v_true_people then
      raise exception 'company % reported % people, prospect_index says %', v_row->>'id', v_row->>'prospect_count', v_true_people;
    end if;
    if (v_row->>'client_count')::integer is distinct from v_true_clients then
      raise exception 'company % reported % clients, prospect_index says %', v_row->>'id', v_row->>'client_count', v_true_clients;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- The trigger keeps it true. A real prospect moves company inside a
-- subtransaction that rolls itself back, and the counts must follow it.
do $$
declare
  v_prospect text;
  v_client text;
  v_from text;
  v_to text;
  v_from_after integer;
  v_to_after integer;
  v_from_before integer;
  v_to_before integer;
begin
  select pi.id, pi.client_ids[1], pi.company_id
    into v_prospect, v_client, v_from
  from public.prospect_index pi
  where pi.company_id is not null and cardinality(pi.client_ids) > 0
  limit 1;

  select cc.company_id into v_to
  from public.client_companies cc
  where cc.client_id = v_client and cc.company_id <> v_from
  limit 1;

  if v_prospect is null or v_to is null then
    raise notice 'no prospect and second company available; the trigger is unproven';
    return;
  end if;

  select prospect_count into v_from_before from public.client_companies
   where client_id = v_client and company_id = v_from;
  select prospect_count into v_to_before from public.client_companies
   where client_id = v_client and company_id = v_to;

  begin
    update public.prospect_index set company_id = v_to where id = v_prospect;
    select prospect_count into v_from_after from public.client_companies
     where client_id = v_client and company_id = v_from;
    select prospect_count into v_to_after from public.client_companies
     where client_id = v_client and company_id = v_to;
    raise exception using errcode = 'ZZ999', message = 'probe-rollback';
  exception when sqlstate 'ZZ999' then
    null;
  end;

  if v_from_after is distinct from v_from_before - 1 then
    raise exception 'moving a prospect off company % left its count at %, expected %', v_from, v_from_after, v_from_before - 1;
  end if;
  if v_to_after is distinct from v_to_before + 1 then
    raise exception 'moving a prospect onto company % left its count at %, expected %', v_to, v_to_after, v_to_before + 1;
  end if;

  raise notice 'the statement trigger moved the counts with the prospect';
end $$;
