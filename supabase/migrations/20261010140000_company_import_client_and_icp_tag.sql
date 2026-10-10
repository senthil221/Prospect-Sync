-- A company import can add its companies to a client and tag them with one of
-- the client's ICPs.
--
-- Asked for on 2026-10-10 ("add the client tag on the company import as
-- well"). The import chooses an optional client and, for that client, an
-- optional ICP tag; both are kept on company_imports. When the rows are in,
-- apply_company_import_to_client_v1 walks the import's companies
-- (company_import_memberships) a page at a time:
--   * adds them to the client through push_companies_to_client_v2, so the
--     client's blocklist still diverts blocked ones and the addition is
--     recorded like any push;
--   * tags each one the client now has with the ICP, and the client's people
--     at it - the same tag links the ICP check applies (20261010120000).
-- Its place is kept on the import (client_assign_after), so a page that times
-- out or a closed tab picks up where it stopped, and running it again is
-- harmless (every insert is on conflict do nothing).
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

alter table public.company_imports
  add column if not exists client_id text references public.clients(id) on delete set null,
  add column if not exists client_tag_id text references public.prospect_tags(id) on delete set null,
  add column if not exists client_assign_after text not null default '',
  add column if not exists client_assigned_at timestamptz;

create or replace function public.apply_company_import_to_client_v1(p_import_id text, p_limit integer default 2000, p_actor text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_import public.company_imports%rowtype;
  v_ids text[];
  v_push jsonb;
  v_tagged integer := 0;
  v_people text[] := array[]::text[];
  v_remaining integer;
begin
  select * into v_import from public.company_imports where id = p_import_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Company import not found.';
  end if;
  if v_import.client_id is null then
    return jsonb_build_object('done', true, 'processed', 0, 'added', 0, 'tagged', 0, 'remaining', 0);
  end if;
  if v_import.status <> 'completed' then
    raise exception using errcode = '22023', message = 'Finish the import before adding its companies to the client.';
  end if;
  if v_import.client_tag_id is not null and not exists (
       select 1 from public.prospect_tags t
        where t.id = v_import.client_tag_id and (t.client_id = v_import.client_id or t.client_id is null)) then
    raise exception using errcode = '22023', message = 'That ICP tag does not belong to this client.';
  end if;

  select coalesce(array_agg(company_id order by company_id), array[]::text[]) into v_ids
    from (select m.company_id from public.company_import_memberships m
           where m.import_id = p_import_id and m.company_id > v_import.client_assign_after
           order by m.company_id
           limit greatest(1, least(coalesce(p_limit, 2000), 5000))) page;

  if cardinality(v_ids) > 0 then
    v_push := public.push_companies_to_client_v2(v_import.client_id, v_ids, '', '[]'::jsonb, null, null,
      coalesce(nullif(p_actor, ''), 'company import'), null, format('%s:%s', p_import_id, v_ids[1]));

    if v_import.client_tag_id is not null then
      with added as (
        insert into public.company_tag_links (company_id, tag_id)
        select cc.company_id, v_import.client_tag_id
          from public.client_companies cc
         where cc.client_id = v_import.client_id and cc.company_id = any(v_ids)
        on conflict (company_id, tag_id) do nothing
        returning 1)
      select count(*)::integer into v_tagged from added;

      with added as (
        insert into public.prospect_tag_links (prospect_id, tag_id)
        select cp.prospect_id, v_import.client_tag_id
          from public.client_prospects cp
          join public.prospects p on p.id = cp.prospect_id
         where cp.client_id = v_import.client_id and cp.status = 'active' and p.company_id = any(v_ids)
        on conflict (prospect_id, tag_id) do nothing
        returning prospect_id)
      select coalesce(array_agg(prospect_id), array[]::text[]) into v_people from added;
      if cardinality(v_people) > 0 then
        perform public.reindex_scope_v1(p_prospect_ids => v_people);
      end if;
    end if;

    update public.company_imports set client_assign_after = v_ids[cardinality(v_ids)] where id = p_import_id;
  end if;

  select count(*)::integer into v_remaining
    from public.company_import_memberships m
   where m.import_id = p_import_id
     and m.company_id > coalesce(v_ids[cardinality(v_ids)], v_import.client_assign_after);
  if v_remaining = 0 then
    update public.company_imports set client_assigned_at = coalesce(client_assigned_at, now()) where id = p_import_id;
  end if;

  return jsonb_build_object('done', v_remaining = 0, 'processed', cardinality(v_ids),
    'added', coalesce((v_push->>'added')::integer, 0), 'blocked', coalesce((v_push->>'blocked')::integer, 0),
    'tagged', v_tagged, 'peopleTagged', cardinality(v_people), 'remaining', v_remaining);
end;
$$;

revoke execute on function public.apply_company_import_to_client_v1(text, integer, text) from public, anon, authenticated;
grant execute on function public.apply_company_import_to_client_v1(text, integer, text) to service_role;

-- Proof, rolled back with the rest of a dry run.
do $proof$
declare
  v_import text;
  v_client text;
  v_tag text;
  v_result jsonb;
  v_rounds integer := 0;
begin
  select ci.id into v_import from public.company_imports ci
   where ci.status = 'completed' and exists (select 1 from public.company_import_memberships m where m.import_id = ci.id)
   order by ci.created_at desc limit 1;
  select p.client_id, p.tag_id into v_client, v_tag from public.client_icp_profiles p where p.tag_id is not null limit 1;
  if v_import is null or v_client is null then
    raise notice 'Company import proof: nothing to try - compile only.';
    return;
  end if;
  -- Leave production as it was: this only runs inside the migration's own
  -- transaction when an import is already assigned to nobody.
  if exists (select 1 from public.company_imports where id = v_import and client_id is not null) then
    raise notice 'Company import proof: latest import already has a client - skipped.';
    return;
  end if;
  raise notice 'Company import proof: compile only on production (assigning would change data).';
end;
$proof$;
