-- Removing a company from a client takes that client's people at the same
-- company with it. Removing a person never takes the company.
--
-- WHAT THIS IS NOT. It is not a delete. Nothing in public.companies or
-- public.prospects is touched, and no other client's links are touched. This is
-- the company-side twin of remove_prospects_from_client_v2, which has existed
-- since the client workspaces did and reports masterProspectPreserved: true for
-- exactly this reason. The Company DB in a client workspace had no removal at
-- all - only the master Company DB could delete, and that deletes for everybody.
--
-- THE ASYMMETRY IS THE REQUIREMENT, NOT AN OVERSIGHT.
--
--   company out of the client  ->  its people go too
--   person out of the client   ->  the company stays
--
-- The second half needs no code: sync_client_company_membership fires AFTER
-- INSERT OR UPDATE on client_prospects and NOT on delete, so removing people
-- already leaves client_companies alone. It is asserted below anyway, because
-- "it happens to work" and "it is guaranteed" are different things and a future
-- delete trigger would silently break it.
--
-- THAT SAME MISSING DELETE TRIGGER IS WHY THIS DELETES MEMBERSHIP EXPLICITLY.
-- Nothing has ever cleaned client_companies up after a prospect removal, which
-- is measurable: on 2026-09-16 the Krishify Company DB listed 179 companies
-- founded 1980-89 while resolve_company_action_selection_v1 selected 177. The
-- two extra carry an added_by = 'prospect-membership' row whose prospects are
-- long gone from the client. This function removes the membership row itself so
-- it cannot add to that pile.
--
-- THE CAP IS THE POINT OF THE PREVIEW. One company can carry hundreds of people
-- - UPL alone is 416 in Krishify - so "remove 3 companies" can quietly mean
-- "remove 700 people". The preview function below is STABLE, so it physically
-- cannot write, and the UI must show its numbers before the confirm button does
-- anything. p_max_people then refuses beyond a ceiling, so a mis-click on a
-- filter matching the whole workspace fails loudly instead of emptying it.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- FIRST, A COUNT THAT HAS ALWAYS BEEN WRONG.
--
-- remove_prospects_from_client_v2 reports 'removed' from the row_count of its
-- own DELETE on client_prospects. That DELETE almost never removes anything,
-- because the statement before it already has: trg_client_prospects_delete
-- fires on list_memberships and runs sync_client_prospects_from_lists(), which
-- takes the client_prospects rows with it. The function's comment shows the
-- author knew that trigger could RE-ADD a row, and ordered the two deletes to
-- prevent it; it does not account for the trigger REMOVING them.
--
-- Measured on production 2026-09-16, in a rolled-back transaction: 19 prospects
-- of one company, client_prospects 19 -> 0, list_memberships 19 -> 0, and the
-- function returned {"removed": 0}. The rows go; the number does not describe
-- it. Anything imported through a list - which is the normal path - has always
-- reported zero.
--
-- It matters most where a human reads it. A background "remove all matching"
-- job merges this result, so a job that correctly removed 8,000 people reports
-- "0 removed" and reads as a silent failure. It is also why the probe at the
-- foot of this file caught it: the new company removal is specified in terms of
-- how many people it took, and that number came back zero.
--
-- Counted before and after instead, so it no longer matters WHICH statement
-- did the work - only that the link is gone. CREATE OR REPLACE with the same
-- signature: every caller keeps working and the contract is unchanged, it was
-- simply never met.
create or replace function public.remove_prospects_from_client_v2(
  p_client_id text,
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_prospect_ids text[] default null::text[],
  p_excluded_ids text[] default null::text[],
  p_actor text default ''::text
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '120s'
as $$
declare
  v_ids text[];
  v_removed integer := 0;
  v_linked_before bigint := 0;
  v_linked_after bigint := 0;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('removed', 0, 'masterProspectPreserved', true);
  end if;

  -- What this client actually holds, before anything is touched.
  select count(*) into v_linked_before
  from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);

  -- Drop the list links first so the membership trigger cannot re-add the row,
  -- then the membership itself (which covers pushed records with no list).
  delete from public.list_memberships lm
  using public.lists l
  where lm.list_id = l.id and l.client_id = p_client_id and lm.prospect_id = any(v_ids);

  delete from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);

  -- Not row_count: the delete above is usually a no-op because the list trigger
  -- has already cascaded. The honest measure is what is left.
  select count(*) into v_linked_after
  from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);
  v_removed := greatest(0, v_linked_before - v_linked_after)::integer;

  perform public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation('remove_from_client', p_client_id, p_actor,
    format('Removed %s prospects from the client', v_removed), v_removed, v_ids);

  return jsonb_build_object('removed', v_removed, 'masterProspectPreserved', true);
end;
$$;

revoke execute on function public.remove_prospects_from_client_v2(text, text, jsonb, text[], text[], text) from public, anon, authenticated;
grant execute on function public.remove_prospects_from_client_v2(text, text, jsonb, text[], text[], text) to service_role;

-- What would happen, asked before anything happens. STABLE by construction:
-- a preview that could write is not a preview.
create or replace function public.client_company_removal_preview_v1(
  p_client_id text,
  p_company_ids text[] default null::text[],
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_excluded_ids text[] default null::text[]
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '60s'
as $$
declare
  v_company_ids text[] := array[]::text[];
  v_people bigint := 0;
begin
  select coalesce(array_agg(company_id), array[]::text[]) into v_company_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if cardinality(v_company_ids) = 0 then
    return jsonb_build_object('companies', 0, 'people', 0);
  end if;

  select count(*) into v_people
  from public.prospect_index pi
  where pi.company_id = any(v_company_ids)
    and pi.client_ids @> array[p_client_id];

  return jsonb_build_object('companies', cardinality(v_company_ids), 'people', v_people);
end;
$$;

revoke execute on function public.client_company_removal_preview_v1(text, text[], text, jsonb, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.client_company_removal_preview_v1(text, text[], text, jsonb, jsonb, text[]) to service_role;

-- ---------------------------------------------------------------------------

create or replace function public.remove_companies_from_client_v1(
  p_client_id text,
  p_company_ids text[] default null::text[],
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_excluded_ids text[] default null::text[],
  p_max_people integer default 50000,
  p_actor text default ''::text
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '120s'
as $$
declare
  v_company_ids text[] := array[]::text[];
  v_prospect_ids text[] := array[]::text[];
  v_people bigint := 0;
  v_removed_companies integer := 0;
  v_people_result jsonb := jsonb_build_object('removed', 0);
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;

  -- The same resolver every other company action uses, so "these three" and
  -- "everything matching this filter" cannot mean different things here than
  -- they do for push, ICP verification or tagging.
  select coalesce(array_agg(company_id), array[]::text[]) into v_company_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if cardinality(v_company_ids) = 0 then
    return jsonb_build_object('removedCompanies', 0, 'removedPeople', 0, 'masterRecordsPreserved', true);
  end if;

  -- This client's people at those companies. Scoped by client_ids, so another
  -- client's people at the same company are not in the set at all.
  select coalesce(array_agg(pi.id), array[]::text[]), count(*)
    into v_prospect_ids, v_people
  from public.prospect_index pi
  where pi.company_id = any(v_company_ids)
    and pi.client_ids @> array[p_client_id];

  -- Refused, not truncated. Removing 49,999 of 60,000 people and reporting
  -- success is the worst available outcome: it is neither what was asked for
  -- nor obviously wrong afterwards.
  if p_max_people is not null and v_people > p_max_people then
    raise exception using errcode = '54000',
      message = format('This would remove %s people from the client, above the %s limit. Narrow the selection.', v_people, p_max_people);
  end if;

  -- People first. Reused rather than reimplemented: that function also clears
  -- list_memberships, re-indexes and writes the audit row, and a second copy of
  -- that sequence is a second copy to keep in step.
  if cardinality(v_prospect_ids) > 0 then
    v_people_result := public.remove_prospects_from_client_v2(
      p_client_id => p_client_id,
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_prospect_ids, p_excluded_ids => null, p_actor => p_actor);
  end if;

  -- Then the membership itself. Nothing removes this on its own -
  -- sync_client_company_membership does not fire on delete - so without this
  -- the company would still be listed in the client with no people behind it.
  delete from public.client_companies
   where client_id = p_client_id and company_id = any(v_company_ids);
  get diagnostics v_removed_companies = row_count;

  perform public.record_operation('remove_companies_from_client', p_client_id, p_actor,
    format('Removed %s companies and %s people from the client', v_removed_companies, coalesce((v_people_result ->> 'removed')::bigint, 0)),
    v_removed_companies, v_company_ids);

  return jsonb_build_object(
    'removedCompanies', v_removed_companies,
    'removedPeople', coalesce((v_people_result ->> 'removed')::bigint, 0),
    'selectedCompanies', cardinality(v_company_ids),
    'masterRecordsPreserved', true);
end;
$$;

revoke execute on function public.remove_companies_from_client_v1(text, text[], text, jsonb, jsonb, text[], integer, text) from public, anon, authenticated;
grant execute on function public.remove_companies_from_client_v1(text, text[], text, jsonb, jsonb, text[], integer, text) to service_role;

-- ---------------------------------------------------------------------------
-- Bounded, and not reachable from a browser role.
do $$
declare
  v_target text;
  v_reachable text;
  v_cfg text[];
begin
  foreach v_target in array array[
    'public.client_company_removal_preview_v1(text,text[],text,jsonb,jsonb,text[])',
    'public.remove_companies_from_client_v1(text,text[],text,jsonb,jsonb,text[],integer,text)'
  ] loop
    select string_agg(coalesce(nullif(g.grantee::regrole::text, '-'), 'PUBLIC'), ', ')
      into v_reachable
      from pg_proc p, lateral aclexplode(p.proacl) g
     where p.oid = v_target::regprocedure
       and g.privilege_type = 'EXECUTE'
       and (g.grantee = 0 or g.grantee::regrole::text in ('anon', 'authenticated'));
    if v_reachable is not null then
      raise exception '% is executable by %', v_target, v_reachable;
    end if;

    select p.proconfig into v_cfg from pg_proc p where p.oid = v_target::regprocedure;
    if not (array_to_string(v_cfg, ',') like '%statement_timeout%') then
      raise exception '% has no statement_timeout: %', v_target, v_cfg;
    end if;
  end loop;
end $$;

-- The preview cannot write, by declaration rather than by inspection.
do $$
declare
  v_volatility "char";
begin
  select p.provolatile into v_volatility from pg_proc p
   where p.oid = 'public.client_company_removal_preview_v1(text,text[],text,jsonb,jsonb,text[])'::regprocedure;
  if v_volatility not in ('s', 'i') then
    raise exception 'the removal preview is VOLATILE (%); a preview that can write is not a preview', v_volatility;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- It behaves, on real rows, and undoes every one of them.
--
-- THIS PROBE PERFORMS REAL REMOVALS AND THEN ROLLS THEM BACK. migrate.sh wraps
-- each file in one transaction and COMMITS it, so an assertion that removed a
-- real company from a real client would be a migration that quietly took
-- production data with it. The destructive half therefore runs inside a
-- subtransaction (a BEGIN ... EXCEPTION block) which always ends by raising a
-- sentinel, so every write it made is rolled back before this file commits.
--
-- PL/pgSQL variables are not transactional, so the results captured inside the
-- block survive the rollback and are asserted afterwards, against a database
-- that is once again untouched. A genuine failure inside the block carries a
-- different SQLSTATE, is not caught by the sentinel handler, and aborts the
-- whole migration - with the probe's writes still rolled back.
do $$
declare
  v_client text;
  v_company text;
  v_people_before bigint := 0;
  v_membership_before bigint := 0;
  v_prospects text[] := array[]::text[];
  v_preview jsonb;
  v_result jsonb;
  v_cap_refused boolean := false;
  v_people_after_refusal bigint := -1;
  v_company_survived boolean := false;
  v_prospects_survived bigint := -1;
begin
  -- A company with a handful of one client's people behind it, so the cascade
  -- has something to prove and the probe stays small.
  select pi.client_ids[1], pi.company_id into v_client, v_company
  from public.prospect_index pi
  where pi.company_id is not null and cardinality(pi.client_ids) > 0
  group by pi.client_ids[1], pi.company_id
  having count(*) between 2 and 50
  limit 1;

  if v_client is null then
    raise notice 'no client has a company with people behind it; the cascade is unproven';
    return;
  end if;

  select coalesce(array_agg(pi.id), array[]::text[]), count(*)
    into v_prospects, v_people_before
  from public.prospect_index pi
  where pi.company_id = v_company and pi.client_ids @> array[v_client];

  select count(*) into v_membership_before
  from public.client_companies where client_id = v_client and company_id = v_company;

  begin
    -- The preview says what will happen, before anything does.
    v_preview := public.client_company_removal_preview_v1(v_client, array[v_company]);

    -- The cap refuses rather than truncating.
    begin
      perform public.remove_companies_from_client_v1(v_client, array[v_company],
        '', '[]'::jsonb, null, null, 0, 'migration-probe');
    exception when sqlstate '54000' then
      v_cap_refused := true;
    end;
    select count(*) into v_people_after_refusal
    from public.prospect_index pi
    where pi.company_id = v_company and pi.client_ids @> array[v_client];

    -- The real thing.
    v_result := public.remove_companies_from_client_v1(v_client, array[v_company],
      '', '[]'::jsonb, null, null, 50000, 'migration-probe');

    -- The master records must survive it.
    v_company_survived := exists (select 1 from public.companies where id = v_company);
    select count(*) into v_prospects_survived
    from public.prospects where id = any(v_prospects);

    -- Undo all of the above. Everything read into a variable survives; every
    -- row this block touched does not.
    raise exception using errcode = 'ZZ999', message = 'probe-rollback';
  exception when sqlstate 'ZZ999' then
    null;
  end;

  if (v_preview ->> 'people')::bigint <> v_people_before then
    raise exception 'the preview said % people, the client actually has %', v_preview ->> 'people', v_people_before;
  end if;
  if not v_cap_refused then
    raise exception 'the people cap did not refuse an over-limit removal';
  end if;
  if v_people_after_refusal <> v_people_before then
    raise exception 'a refused removal still took % people', v_people_before - v_people_after_refusal;
  end if;
  if (v_result ->> 'removedPeople')::bigint <> v_people_before then
    raise exception 'removed % people, expected %', v_result ->> 'removedPeople', v_people_before;
  end if;
  if (v_result ->> 'removedCompanies')::integer <> v_membership_before then
    raise exception 'removed % memberships, expected %', v_result ->> 'removedCompanies', v_membership_before;
  end if;
  -- THE CONTRACT: the master records are untouched.
  if not v_company_survived then
    raise exception 'the company was deleted from the master database';
  end if;
  if v_prospects_survived <> cardinality(v_prospects) then
    raise exception 'prospects were deleted from the master database: % of % survived', v_prospects_survived, cardinality(v_prospects);
  end if;

  -- And the rollback actually happened.
  if (select count(*) from public.prospect_index pi
       where pi.company_id = v_company and pi.client_ids @> array[v_client]) <> v_people_before then
    raise exception 'the probe did not roll back; the client lost people to a migration assertion';
  end if;
  if (select count(*) from public.client_companies
       where client_id = v_client and company_id = v_company) <> v_membership_before then
    raise exception 'the probe did not roll back; the client lost a company membership';
  end if;
end $$;

-- Removing PEOPLE must never remove the company. Asserted rather than assumed:
-- it holds today only because sync_client_company_membership does not fire on
-- delete, and a future delete trigger would break it silently. Same
-- rolled-back subtransaction, for the same reason.
do $$
declare
  v_client text;
  v_company text;
  v_prospect text;
  v_company_still_linked boolean := false;
begin
  select pi.client_ids[1], pi.company_id, pi.id into v_client, v_company, v_prospect
  from public.prospect_index pi
  where pi.company_id is not null and cardinality(pi.client_ids) > 0
    and exists (select 1 from public.client_companies cc
                 where cc.client_id = pi.client_ids[1] and cc.company_id = pi.company_id)
  limit 1;

  if v_client is null then
    raise notice 'no client has a company membership to test the reverse direction against';
    return;
  end if;

  begin
    perform public.remove_prospects_from_client_v2(
      p_client_id => v_client, p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => array[v_prospect], p_excluded_ids => null, p_actor => 'migration-probe');
    v_company_still_linked := exists (select 1 from public.client_companies
                                       where client_id = v_client and company_id = v_company);
    raise exception using errcode = 'ZZ999', message = 'probe-rollback';
  exception when sqlstate 'ZZ999' then
    null;
  end;

  if not v_company_still_linked then
    raise exception 'removing a person removed its company from the client; the two directions are not meant to be symmetric';
  end if;
end $$;
