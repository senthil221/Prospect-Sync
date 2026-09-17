-- A company stays in its client's Company DB after the last of that client's
-- people leaves it. Removing the company itself still takes it out.
--
-- WHAT WAS ACTUALLY BROKEN. 20260916180000 shipped "remove a person, keep the
-- company" and asserted it by checking that the client_companies row survived.
-- The row does survive. It was the wrong thing to assert, because nothing that
-- draws the client Company DB reads that table:
--
--   filter_companies_v4, the client listing:
--     and exists (select 1 from public.prospect_index scoped
--                  where scoped.company_id = c.id and scoped.client_ids @> array[X])
--
-- A company was in a client's Company DB if and only if that client had a
-- person at it. So removing the last person removed the company from the
-- client's view - whatever added_by said, including companies pushed there
-- explicitly by a human. The master record was preserved, which is what the
-- previous migration promised and measured; the client-level record was not,
-- which is what the requirement actually asked for.
--
-- Measured on production 2026-09-17, rows that exist in client_companies while
-- being invisible to their own client:
--
--   Unassigned  prospect-membership     427
--   Unassigned  membership-backfill     189
--   Krishify    prospect-membership     122
--   Unassigned  prospect-company-change  56
--   Krishify    prospect-company-change  29
--                                       ---
--                                       823
--
-- Krishify gains 151 companies from this change, each listing zero people. They
-- are not new: they are rows that have been in client_companies all along with
-- no way to see or select them.
--
-- THE RULE, AND WHY ONE CLAUSE IS ENOUGH. A company belongs to a client if
-- client_companies says so. That table is already a strict superset of "has
-- people here" - measured 0 companies with a client's people and no membership
-- row, and guaranteed going forward by sync_client_company_membership_v1, which
-- fires AFTER INSERT OR UPDATE on client_prospects and inserts the row. So the
-- prospect_index probe is not just replaceable, it is redundant, and it is the
-- more expensive of the two: client_companies answers from its primary key
-- (client_id, company_id), while the old form probed prospect_index by
-- company_id and then tested a client_ids array.
--
-- The superset is asserted below rather than assumed, because the whole change
-- rests on it: if drift ever appeared, a company with real people would vanish
-- from its client, which is worse than the bug being fixed here.
--
-- THE ASYMMETRY IS PRESERVED, AND NOW FOR THE RIGHT REASON.
--
--   person out of the client  ->  membership row untouched  ->  company stays
--   company out of the client ->  remove_companies_from_client_v1 deletes the
--                                 membership row explicitly  ->  company goes
--
-- That delete already exists and its comment already says why. It is what makes
-- this change safe: making membership authoritative would otherwise mean no
-- company could ever leave a client.
--
-- THE LISTING AND THE RESOLVER MOVE TOGETHER. resolve_company_action_selection_v1
-- required a membership row AND (added_by explicit OR has people). Left alone it
-- would refuse exactly the companies this migration makes visible, and the grid
-- would list 151 companies in Krishify whose checkboxes did nothing. Both
-- selection resolvers drop the added_by guard in the same file, and the
-- agreement is proved on real rows at the foot of it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FIRST: the invariant the whole change rests on.
do $$
declare
  v_drift bigint;
begin
  select count(*) into v_drift
  from (
    select distinct pi.company_id, cid
    from public.prospect_index pi, unnest(pi.client_ids) cid
    where pi.company_id is not null
  ) held
  where not exists (
    select 1 from public.client_companies cc
    where cc.company_id = held.company_id and cc.client_id = held.cid);

  if v_drift > 0 then
    raise exception 'client_companies is not a superset of held people: % company/client pairs have people but no membership row. Making membership authoritative would hide them.', v_drift;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The client listing scopes by membership instead of by people.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.filter_companies_v4'::regproc);
  v_old constant text :=
E'    v_scope_suffix := v_scope_suffix || format($e$ and exists (
      select 1 from public.prospect_index scoped
      where scoped.company_id = c.id and scoped.client_ids @> array[%L]
    )$e$, p_client_id);';
  v_new constant text :=
E'    -- Membership, not people. A company whose last person was removed from
    -- this client keeps its client_companies row and therefore keeps its place
    -- in the client Company DB; removing the COMPANY deletes that row and takes
    -- it out. client_companies is a strict superset of "has people here", so
    -- this widens the set without dropping anything from it, and answers from
    -- the primary key instead of probing prospect_index.
    v_scope_suffix := v_scope_suffix || format($e$ and exists (
      select 1 from public.client_companies retained
      where retained.company_id = c.id and retained.client_id = %L
    )$e$, p_client_id);';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer contains the prospect_index client scope this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('public.client_companies retained' in v_def) = 0
     or position('scoped.client_ids @> array[%L]' in v_def) > 0 then
    raise exception 'the membership scope replacement did not take';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- The action resolver stops refusing the companies the listing now shows.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.resolve_company_action_selection_v1'::regproc);
  v_old constant text :=
E'        select 1 from public.client_companies membership
        where membership.client_id = %1$s and membership.company_id = c.id
          and (membership.added_by not in (''membership-backfill'', ''prospect-membership'', ''prospect-company-change'')
            or exists (select 1 from public.prospect_index pi where pi.company_id = c.id and pi.client_ids @> array[%1$s]))';
  v_new constant text :=
E'        select 1 from public.client_companies membership
        where membership.client_id = %1$s and membership.company_id = c.id';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'resolve_company_action_selection_v1 no longer contains the added_by guard this migration removes';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('membership.added_by not in' in v_def) > 0 then
    raise exception 'the added_by guard survived the replacement in resolve_company_action_selection_v1';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- And so does the paste-a-domain resolver, for the same reason.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.resolve_client_company_selection_v1'::regproc);
  v_old constant text :=
E'    and (membership.added_by not in (''membership-backfill'', ''prospect-membership'', ''prospect-company-change'')
      or exists (select 1 from public.prospect_index pi where pi.company_id = c.id and pi.client_ids @> array[p_client_id]))
';
  v_new constant text := '';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'resolve_client_company_selection_v1 no longer contains the added_by guard this migration removes';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('membership.added_by not in' in v_def) > 0 then
    raise exception 'the added_by guard survived the replacement in resolve_client_company_selection_v1';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- A retained company is visible AND selectable. Proved on a real row, because
-- a listing that shows a company its own bulk bar refuses is the failure mode
-- this pair of edits exists to prevent.
do $$
declare
  v_client text;
  v_company text;
  v_name text;
  v_rows jsonb;
  v_selected boolean;
begin
  select cc.client_id, cc.company_id, c.name into v_client, v_company, v_name
  from public.client_companies cc
  join public.companies c on c.id = cc.company_id
  where coalesce(c.name, '') <> ''
    and not exists (select 1 from public.prospect_index pi
                     where pi.company_id = cc.company_id
                       and pi.client_ids @> array[cc.client_id])
  limit 1;

  if v_client is null then
    raise notice 'no client holds a company with no people; retention is unproven here';
    return;
  end if;

  select result_rows into v_rows
  from public.filter_companies_v4(v_name, '[]'::jsonb, v_client, null, 5000, 0, null) limit 1;

  if not exists (select 1 from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) row_item
                  where row_item->>'id' = v_company) then
    raise exception 'company % has a membership row in client % but the listing does not show it', v_company, v_client;
  end if;

  select exists (
    select 1 from public.resolve_company_action_selection_v1(
      v_client, array[v_company], '', '[]'::jsonb, null, null, 250000)
  ) into v_selected;

  if not v_selected then
    raise exception 'the listing shows company % in client % but the action resolver refuses it; the grid would contradict its own bulk bar', v_company, v_client;
  end if;

  raise notice 'retained company % is listed and selectable in client %', v_company, v_client;
end $$;

-- ---------------------------------------------------------------------------
-- A company with people is still listed - the widening must not have replaced
-- the old set, only grown it.
do $$
declare
  v_client text;
  v_company text;
  v_name text;
  v_rows jsonb;
begin
  select pi.client_ids[1], pi.company_id, c.name into v_client, v_company, v_name
  from public.prospect_index pi
  join public.companies c on c.id = pi.company_id
  where pi.company_id is not null and cardinality(pi.client_ids) > 0
    and coalesce(c.name, '') <> ''
  limit 1;

  if v_client is null then
    raise notice 'no client holds a company with people; the ordinary case is unproven';
    return;
  end if;

  select result_rows into v_rows
  from public.filter_companies_v4(v_name, '[]'::jsonb, v_client, null, 5000, 0, null) limit 1;

  if not exists (select 1 from jsonb_array_elements(coalesce(v_rows, '[]'::jsonb)) row_item
                  where row_item->>'id' = v_company) then
    raise exception 'company % has people in client % and dropped out of the listing', v_company, v_client;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Removing the COMPANY still takes it out of the client, and removing its
-- PEOPLE still does not. Both run inside a subtransaction that rolls itself
-- back with a sentinel SQLSTATE, so this probe touches real rows and keeps
-- none of it. PL/pgSQL locals are not transactional, so the findings survive
-- the rollback while the writes do not.
do $$
declare
  v_client text;
  v_company text;
  v_prospect text;
  v_still_listed boolean := true;
  v_company_kept boolean := false;
begin
  -- Deliberately the smallest company available: this probe really removes and
  -- really re-indexes before it rolls back, and doing that to a company with
  -- hundreds of people would be a slow migration for no extra proof.
  select small.client_id, small.company_id, small.prospect_id
    into v_client, v_company, v_prospect
  from (
    select pi.client_ids[1] as client_id, pi.company_id,
           min(pi.id) as prospect_id, count(*) as people
    from public.prospect_index pi
    where pi.company_id is not null and cardinality(pi.client_ids) > 0
    group by pi.client_ids[1], pi.company_id
    order by count(*) asc
    limit 1
  ) small;

  if v_client is null then
    raise notice 'no client holds a company with people; the removal directions are unproven';
    return;
  end if;

  -- Direction one: the company leaves, and stops being listed.
  begin
    perform public.remove_companies_from_client_v1(
      p_client_id => v_client, p_company_ids => array[v_company],
      p_search => '', p_filters => '[]'::jsonb, p_people_scope => null,
      p_excluded_ids => null, p_max_people => 50000, p_actor => 'migration-probe');
    v_still_listed := exists (select 1 from public.client_companies
                               where client_id = v_client and company_id = v_company);
    raise exception using errcode = 'ZZ999', message = 'probe-rollback';
  exception when sqlstate 'ZZ999' then
    null;
  end;

  if v_still_listed then
    raise exception 'removing company % from client % left its membership row; it would still be listed', v_company, v_client;
  end if;

  -- Direction two: the people leave, and the company does not.
  begin
    perform public.remove_prospects_from_client_v2(
      p_client_id => v_client, p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => array[v_prospect], p_excluded_ids => null, p_actor => 'migration-probe');
    v_company_kept := exists (select 1 from public.client_companies
                               where client_id = v_client and company_id = v_company);
    raise exception using errcode = 'ZZ999', message = 'probe-rollback';
  exception when sqlstate 'ZZ999' then
    null;
  end;

  if not v_company_kept then
    raise exception 'removing a person took company % out of client %; the two directions are not meant to be symmetric', v_company, v_client;
  end if;

  raise notice 'company removal clears the membership, people removal keeps it';
end $$;

-- ---------------------------------------------------------------------------
-- Nothing here touches a master record. Stated as an assertion because every
-- description of this feature promises it.
do $$
begin
  if pg_get_functiondef('public.filter_companies_v4'::regproc) like '%delete from%'
     or pg_get_functiondef('public.resolve_company_action_selection_v1'::regproc) like '%delete from%'
     or pg_get_functiondef('public.resolve_client_company_selection_v1'::regproc) like '%delete from%' then
    raise exception 'a listing or resolver gained a delete; these functions only ever read';
  end if;
end $$;
