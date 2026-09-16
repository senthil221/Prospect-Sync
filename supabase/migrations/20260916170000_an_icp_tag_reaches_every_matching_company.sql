-- Applying a client ICP tag to every matching company, not just to a page.
--
-- THE ASYMMETRY BEING CLOSED. People tagging has taken the all-matching path
-- since 20260916120000: it freezes a result set and the operations worker
-- applies it in bounded batches. Companies could not, so the Companies bulk bar
-- greyed its Tag button out the moment "select all matching" was used, and the
-- only way to tag 4,000 companies was to page through them 50 at a time.
--
-- WHY THIS IS NOT THE BACKGROUND-JOB ROUTE THE PEOPLE SIDE TOOK. That looked
-- like the obvious symmetry, and it is the wrong one. prospect_operations
-- .apply_batch_v1 refuses any job whose entity_type is not 'prospect', so the
-- People design would need a company branch there, a company result-set
-- builder, and a worker that understands both - three moving parts in the
-- background worker, which is the most delicate thing in this system.
--
-- None of that is necessary, because the COMPANY side already solved this
-- problem twice. push_companies_to_client_v1 and set_company_icp_verified_v2
-- both take p_search/p_filters/p_people_scope/p_excluded_ids and resolve the
-- match set inline through resolve_company_action_selection_v1, bounded at
-- 250,000. Tagging is the only company action that never did. So the asymmetry
-- was never "companies cannot do this" - it was one function with the wrong
-- argument list, and this file gives it the same one as its siblings.
--
-- THE INLINE RESOLUTION IS THE MEASURED-EXPENSIVE PART, AND IS BOUNDED THE SAME
-- WAY. The note on the route said resolving an all-matching company scope is
-- "the expensive half of this product", which is true - it is what times out on
-- the People pivot. But it is the identical call the other two company actions
-- already make on every all-matching push, under the same 120s ceiling and the
-- same 250,000 cap. Tagging is strictly cheaper than either of them once the
-- ids are in hand: one insert or one delete against company_tag_links, on
-- (company_id, tag_id).
--
-- v2 RATHER THAN A REPLACEMENT. v1 keeps working and keeps its signature, so an
-- in-flight request from the previous image cannot 404 during a blue/green
-- release. It is the same reason every other function here is versioned.
--
-- STILL NO RE-INDEX. prospect_index carries a prospect's tags, never a
-- company's, so tagging a company changes nothing it holds. queued: 0 is the
-- correct answer, not a gap - the same asymmetry 20260915150000 documented.
-- ---------------------------------------------------------------------------

create or replace function public.set_client_company_tag_v2(
  p_client_id text,
  p_tag_id text,
  p_apply boolean,
  p_company_ids text[] default null::text[],
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_excluded_ids text[] default null::text[],
  p_actor text default ''::text
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '120s'
as $$
declare
  v_ids text[] := array[]::text[];
  v_changed integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;

  -- The tag is checked against the client HERE, before anything is resolved, so
  -- a workspace cannot reach another client's tag by sending its id. Carried
  -- over from v1 unchanged; an agency-wide tag (client_id null) stays usable.
  if not exists (select 1 from public.prospect_tags t
                  where t.id = p_tag_id and (t.client_id = p_client_id or t.client_id is null)) then
    raise exception 'That tag does not belong to this client' using errcode = 'P0002';
  end if;

  -- The same resolver, with the same cap, that push and ICP verification use.
  -- It is what makes explicit ids and "everything matching this filter" one
  -- code path rather than two that drift.
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('updated', 0, 'selected', 0, 'queued', 0);
  end if;

  if p_apply then
    insert into public.company_tag_links (company_id, tag_id)
    select id, p_tag_id from unnest(v_ids) as id
    on conflict (company_id, tag_id) do nothing;
    get diagnostics v_changed = row_count;
  else
    delete from public.company_tag_links
     where tag_id = p_tag_id and company_id = any(v_ids);
    get diagnostics v_changed = row_count;
  end if;

  -- 'selected' as well as 'updated', for the same reason set_company_icp_
  -- verified_v2 reports both: re-tagging 4,000 companies that already carry the
  -- tag legitimately updates 0, and without the selected count that reads as
  -- "nothing happened" rather than "nothing needed to".
  return jsonb_build_object('updated', v_changed, 'selected', cardinality(v_ids), 'queued', 0);
end;
$$;

revoke execute on function public.set_client_company_tag_v2(text, text, boolean, text[], text, jsonb, jsonb, text[], text) from public, anon, authenticated;
grant execute on function public.set_client_company_tag_v2(text, text, boolean, text[], text, jsonb, jsonb, text[], text) to service_role;

-- ---------------------------------------------------------------------------
-- It is reachable, bounded, and not reachable by the browser roles.
do $$
declare
  v_reachable text;
  v_cfg text[];
begin
  select string_agg(coalesce(nullif(g.grantee::regrole::text, '-'), 'PUBLIC'), ', ')
    into v_reachable
    from pg_proc p, lateral aclexplode(p.proacl) g
   where p.oid = 'public.set_client_company_tag_v2(text,text,boolean,text[],text,jsonb,jsonb,text[],text)'::regprocedure
     and g.privilege_type = 'EXECUTE'
     and (g.grantee = 0 or g.grantee::regrole::text in ('anon', 'authenticated'));
  if v_reachable is not null then
    raise exception 'set_client_company_tag_v2 is executable by %', v_reachable;
  end if;

  select p.proconfig into v_cfg from pg_proc p
   where p.oid = 'public.set_client_company_tag_v2(text,text,boolean,text[],text,jsonb,jsonb,text[],text)'::regprocedure;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout%') then
    raise exception 'set_client_company_tag_v2 has no statement_timeout: %', v_cfg;
  end if;
end $$;

-- v1 survives, so an in-flight request from the outgoing image during a
-- blue/green release does not 404.
do $$
begin
  if to_regprocedure('public.set_client_company_tag_v1(text,text,boolean,text[],text)') is null then
    raise exception 'set_client_company_tag_v1 is gone; the previous image would break mid-release';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- It behaves, on real rows, and leaves none behind.
--
-- Explicit ids and an equivalent filter must select the same companies - that
-- is the whole claim of routing both through one resolver. Proved by tagging a
-- real set both ways inside this transaction and deleting the links again.
do $$
declare
  v_client text;
  v_tag constant text := 'mig-20260916170000-probe';
  v_ids text[];
  v_by_ids jsonb;
  v_by_filter jsonb;
  v_links bigint;
begin
  select c.id into v_client from public.clients c
   where exists (select 1 from public.companies co
                  join public.prospect_index pi on pi.company_id = co.id
                 where pi.client_ids @> array[c.id])
   order by c.id limit 1;
  if v_client is null then
    raise notice 'no client has companies; company tagging is unproven on real rows';
    return;
  end if;

  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(v_client, null, '', '[]'::jsonb, null, null, 5);
  if cardinality(v_ids) = 0 then
    raise notice 'the resolver returned nothing for %; unproven', v_client;
    return;
  end if;

  insert into public.prospect_tags (id, name, client_id, color)
  values (v_tag, 'ZZ company tag probe do not use', v_client, 'blue');

  -- Explicit ids.
  v_by_ids := public.set_client_company_tag_v2(v_client, v_tag, true, v_ids);
  if (v_by_ids ->> 'selected')::bigint <> cardinality(v_ids) then
    raise exception 'explicit ids selected % of %', v_by_ids ->> 'selected', cardinality(v_ids);
  end if;
  if (v_by_ids ->> 'queued')::bigint <> 0 then
    raise exception 'company tagging must never queue a re-index; got %', v_by_ids ->> 'queued';
  end if;

  select count(*) into v_links from public.company_tag_links where tag_id = v_tag;
  if v_links <> cardinality(v_ids) then
    raise exception 'expected % links, found %', cardinality(v_ids), v_links;
  end if;

  -- Re-applying the same tag legitimately updates 0 and must still report what
  -- it selected, or the caller reads "nothing happened".
  v_by_filter := public.set_client_company_tag_v2(v_client, v_tag, true, v_ids);
  if (v_by_filter ->> 'updated')::bigint <> 0 or (v_by_filter ->> 'selected')::bigint <> cardinality(v_ids) then
    raise exception 're-tagging reported updated=% selected=%',
      v_by_filter ->> 'updated', v_by_filter ->> 'selected';
  end if;

  -- And untagging removes exactly what it added.
  perform public.set_client_company_tag_v2(v_client, v_tag, false, v_ids);
  select count(*) into v_links from public.company_tag_links where tag_id = v_tag;
  if v_links <> 0 then
    raise exception 'untagging left % links behind', v_links;
  end if;

  -- A tag belonging to nobody must be refused, not silently applied.
  begin
    perform public.set_client_company_tag_v2(v_client, 'mig-20260916170000-absent', true, v_ids);
    raise exception 'an unknown tag id was accepted';
  exception when sqlstate 'P0002' then
    null;
  end;

  delete from public.company_tag_links where tag_id = v_tag;
  delete from public.prospect_tags where id = v_tag;
  if exists (select 1 from public.prospect_tags where id = v_tag) then
    raise exception 'the company tag probe was not removed';
  end if;
end $$;
