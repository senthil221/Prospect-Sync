-- A client's blocklist hides companies as well as people, now and in future.
--
-- WHAT WAS WRONG, MEASURED on production 2026-09-24. The blocklist already
-- worked for people: adding an entry blocks the client's matching people, and
-- every import and push checks it on the way in (0 active people match their
-- client's blocklist today). Companies were never covered. Krishify had 15
-- companies in its Company DB whose domains it had blocked, and one other
-- client had 1. Three paths add a company to a client and none of them looked
-- at the blocklist: a company push, the automatic "a company joins when its
-- people join" trigger (almost certainly how those 15 arrived - the people came
-- in blocked, their companies came in anyway), and a person being re-linked to
-- another company.
--
-- THE SHAPE OF THE FIX. A blocked company is MOVED OUT of client_companies into
-- client_companies_blocked, rather than flagged in place. Thirteen functions
-- read client_companies (the Company DB page, counts, filters, selections,
-- recently-added, the company-in-client filters on the master DB...). A status
-- column would have to be added to every one of them and to every future one,
-- and a single miss is exactly the kind of leak being fixed here. Moved out,
-- all thirteen stay correct unchanged. Nothing is deleted: the company stays in
-- the master database, keeps its original added_at/added_by, and comes back
-- when the blocklist entry that matched it is removed - the same reversible,
-- per-client semantics people already have.
--
-- WHERE IT IS ENFORCED.
--   1. On the way in - one BEFORE INSERT trigger on client_companies diverts a
--      blocked company for every write path, present and future.
--   2. When an entry is added - add_client_blocklist_batch_v2 (the app's path)
--      and apply_client_blocklist_v1 sweep the client's existing companies.
--   3. When an entry is removed - remove_client_blocklist_v1 restores the
--      companies no remaining entry matches, and refreshes their counts.
--   4. When the data changes under a client - a company gaining a blocked
--      domain (imports fill blank domains), or a person's email or company
--      changing to a blocked one, is blocked for every client already holding
--      it. Before this, both were only checked when a record first entered.
--
-- MATCHING. A company matches a domain entry on companies.normalized_domain,
-- the same value the people rule (client_block_reason_v1) reads: it compares
-- coalesce(normalized_domain, lower(domain), ''), and normalized_domain is
-- NOT NULL, so both reduce to normalized_domain - and it is indexed. Email
-- entries are about people and do not block companies.
-- ---------------------------------------------------------------------------

-- CREATE OR REPLACE TRIGGER, not DROP + CREATE: a drop needs an ACCESS EXCLUSIVE
-- lock, which the operations worker's 30-47 s snapshot reads block; creating a
-- trigger does not conflict with reads. lock_timeout still bounds the wait on
-- a concurrent import's writes - the deploy fails and retries rather than
-- stalling every write queued behind it.
set local lock_timeout = '5s';

create table if not exists public.client_companies_blocked (
  client_id text not null references public.clients(id) on delete cascade,
  company_id text not null references public.companies(id) on delete cascade,
  -- Carried over from client_companies, so a restore puts back what was there.
  added_at timestamptz not null default now(),
  added_by text not null default '',
  blocked_at timestamptz not null default now(),
  blocked_reason text not null default '',
  primary key (client_id, company_id)
);
create index if not exists idx_client_companies_blocked_company
  on public.client_companies_blocked (company_id, client_id);

alter table public.client_companies_blocked enable row level security;
revoke all on public.client_companies_blocked from public, anon, authenticated;
grant select, insert, update, delete on public.client_companies_blocked to service_role;

comment on table public.client_companies_blocked is
  'Companies a client holds but has blocked by domain. Kept out of client_companies so every reader of that table stays correct; restored when the matching blocklist entry is removed.';

-- ---------------------------------------------------------------------------
-- The one rule: why (if at all) a client blocks a company.
create or replace function public.client_company_block_reason_v1(p_client_id text, p_company_id text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(nullif(b.reason, ''), 'Matched client blocklist')
  from public.companies co
  join public.client_blocklist b
    on b.client_id = p_client_id and b.kind = 'domain' and b.value <> '' and b.value = co.normalized_domain
  where co.id = p_company_id
  order by b.created_at, b.id
  limit 1;
$$;
revoke execute on function public.client_company_block_reason_v1(text, text) from public, anon, authenticated;
grant execute on function public.client_company_block_reason_v1(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 1. On the way in. Every insert into client_companies - push, the people
-- membership trigger, a company change, anything written later - passes here.
create or replace function public.divert_blocked_client_company_v1()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_reason text;
begin
  v_reason := public.client_company_block_reason_v1(new.client_id, new.company_id);
  if v_reason is null then
    return new;
  end if;
  insert into public.client_companies_blocked (client_id, company_id, added_at, added_by, blocked_reason)
  values (new.client_id, new.company_id, coalesce(new.added_at, now()), coalesce(new.added_by, ''), v_reason)
  on conflict (client_id, company_id) do nothing;
  return null;
end;
$$;

create or replace trigger divert_blocked_client_company
  before insert on public.client_companies
  for each row execute function public.divert_blocked_client_company_v1();

-- ---------------------------------------------------------------------------
-- 2 and 3. Sweep a client's companies against its whole blocklist, and put
-- back the ones nothing matches any more. Driven from the blocklist through
-- idx_companies_normalized_domain, so the cost is the size of the blocklist,
-- not of the client - the Unassigned bucket holds 188,727 companies.
create or replace function public.sweep_client_company_blocklist_v1(p_client_id text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_moved integer := 0;
begin
  with matched as (
    select cc.client_id, cc.company_id, cc.added_at, cc.added_by,
      coalesce(nullif(b.reason, ''), 'Matched client blocklist') as reason
    from public.client_blocklist b
    join public.companies co on co.normalized_domain = b.value
    join public.client_companies cc on cc.client_id = b.client_id and cc.company_id = co.id
    where b.client_id = p_client_id and b.kind = 'domain' and b.value <> ''
  ), moved as (
    delete from public.client_companies cc
    using matched m
    where cc.client_id = m.client_id and cc.company_id = m.company_id
    returning cc.client_id, cc.company_id
  ), kept as (
    insert into public.client_companies_blocked (client_id, company_id, added_at, added_by, blocked_reason)
    select m.client_id, m.company_id, m.added_at, m.added_by, m.reason
    from matched m
    join moved using (client_id, company_id)
    on conflict (client_id, company_id) do nothing
    returning 1
  )
  select count(*)::integer into v_moved from moved;
  return v_moved;
end;
$$;
revoke execute on function public.sweep_client_company_blocklist_v1(text) from public, anon, authenticated;
grant execute on function public.sweep_client_company_blocklist_v1(text) to service_role;

create or replace function public.restore_client_company_blocklist_v1(p_client_id text)
returns text[]
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_ids text[];
begin
  with released as (
    delete from public.client_companies_blocked ccb
    where ccb.client_id = p_client_id
      and public.client_company_block_reason_v1(ccb.client_id, ccb.company_id) is null
    returning ccb.client_id, ccb.company_id, ccb.added_at, ccb.added_by
  ), restored as (
    insert into public.client_companies (client_id, company_id, added_at, added_by)
    select client_id, company_id, added_at, added_by from released
    on conflict (client_id, company_id) do nothing
    returning company_id
  )
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids from restored;

  -- The count was not maintained while the company was out of the table.
  if cardinality(v_ids) > 0 then
    perform public.recompute_client_company_counts_bulk(v_ids);
  end if;
  return v_ids;
end;
$$;
revoke execute on function public.restore_client_company_blocklist_v1(text) from public, anon, authenticated;
grant execute on function public.restore_client_company_blocklist_v1(text) to service_role;

-- add_client_blocklist_batch_v2 is what the app calls; it sweeps companies
-- after people and reports how many it moved.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.add_client_blocklist_batch_v2(text,text[],text[],text,text,text,integer)'::regprocedure);
  v_old_decl constant text := E'  v_result jsonb;\nbegin\n';
  v_new_decl constant text := E'  v_result jsonb;\n  v_companies integer := 0;\nbegin\n';
  v_old_sweep constant text := E'  perform public.record_operation(\n    ''blocklist_add_batch''';
  v_new_sweep constant text := E'  -- Companies too, against the whole list (20260924090000).\n  v_companies := public.sweep_client_company_blocklist_v1(p_client_id);\n\n  perform public.record_operation(\n    ''blocklist_add_batch''';
  v_old_result constant text := E'    ''queued'', v_queued\n  );';
  v_new_result constant text := E'    ''queued'', v_queued,\n    ''companiesBlocked'', v_companies\n  );';
begin
  if position(v_old_decl in v_def) = 0 or position(v_old_sweep in v_def) = 0 or position(v_old_result in v_def) = 0 then
    raise exception 'add_client_blocklist_batch_v2 no longer has the shape this migration patches';
  end if;
  v_def := replace(replace(replace(v_def, v_old_decl, v_new_decl), v_old_sweep, v_new_sweep), v_old_result, v_new_result);
  execute v_def;
end $BODY$;

do $BODY$
declare
  v_def text := pg_get_functiondef('public.apply_client_blocklist_v1(text)'::regprocedure);
  v_old constant text := E'  get diagnostics v_blocked = row_count;\n  return v_blocked;';
  v_new constant text := E'  get diagnostics v_blocked = row_count;\n  perform public.sweep_client_company_blocklist_v1(p_client_id);\n  return v_blocked;';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'apply_client_blocklist_v1 no longer has the shape this migration patches';
  end if;
  execute replace(v_def, v_old, v_new);
end $BODY$;

do $BODY$
declare
  v_def text := pg_get_functiondef('public.remove_client_blocklist_v1(text,text[],text)'::regprocedure);
  v_old_decl constant text := E'  v_ids text[];\nbegin\n';
  v_new_decl constant text := E'  v_ids text[];\n  v_company_ids text[];\nbegin\n';
  v_old_restore constant text := E'  perform public.reindex_scope_v1(p_prospect_ids => v_ids);\n';
  v_new_restore constant text := E'  perform public.reindex_scope_v1(p_prospect_ids => v_ids);\n  -- Companies no remaining entry matches come back too (20260924090000).\n  v_company_ids := public.restore_client_company_blocklist_v1(p_client_id);\n';
  v_old_result constant text := E'  return jsonb_build_object(''removed'', v_removed, ''restored'', cardinality(v_ids));';
  v_new_result constant text := E'  return jsonb_build_object(''removed'', v_removed, ''restored'', cardinality(v_ids),\n    ''companiesRestored'', cardinality(v_company_ids));';
begin
  if position(v_old_decl in v_def) = 0 or position(v_old_restore in v_def) = 0 or position(v_old_result in v_def) = 0 then
    raise exception 'remove_client_blocklist_v1 no longer has the shape this migration patches';
  end if;
  v_def := replace(replace(replace(v_def, v_old_decl, v_new_decl), v_old_restore, v_new_restore), v_old_result, v_new_result);
  execute v_def;
end $BODY$;

-- A push reports what it could not add, instead of counting blocked companies
-- as added.
do $BODY$
declare
  v_def text := pg_get_functiondef('public.push_companies_to_client_v1(text,text[],text,jsonb,jsonb,text[],text)'::regprocedure);
  v_old_decl constant text := E'declare v_ids text[] := array[]::text[]; v_added integer := 0; v_existing integer := 0;';
  v_new_decl constant text := E'declare v_ids text[] := array[]::text[]; v_added integer := 0; v_existing integer := 0; v_blocked integer := 0;';
  v_old_tail constant text := E'  v_added := greatest(0, cardinality(v_ids) - v_existing);\n  return jsonb_build_object(''selected'', cardinality(v_ids), ''added'', v_added, ''alreadyPresent'', v_existing);';
  v_new_tail constant text := E'  -- Diverted by the client''s blocklist on the way in (20260924090000).\n  select count(*)::integer into v_blocked from public.client_companies_blocked\n  where client_id = p_client_id and company_id = any(v_ids);\n  v_added := greatest(0, cardinality(v_ids) - v_existing - v_blocked);\n  return jsonb_build_object(''selected'', cardinality(v_ids), ''added'', v_added, ''alreadyPresent'', v_existing,\n    ''blocked'', v_blocked);';
begin
  if position(v_old_decl in v_def) = 0 or position(v_old_tail in v_def) = 0 then
    raise exception 'push_companies_to_client_v1 no longer has the shape this migration patches';
  end if;
  execute replace(replace(v_def, v_old_decl, v_new_decl), v_old_tail, v_new_tail);
end $BODY$;

-- ---------------------------------------------------------------------------
-- 4a. A company gains a domain a client has blocked. Imports fill a blank
-- domain in place, so a company can start matching long after it was added.
-- The company leaves every such client, and so do its people there.
create or replace function public.block_company_on_domain_change_v1()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r record;
  v_ids text[];
begin
  for r in
    select b.client_id, coalesce(nullif(b.reason, ''), 'Matched client blocklist') as reason
    from public.client_blocklist b
    where b.kind = 'domain' and b.value = new.normalized_domain
  loop
    with moved as (
      delete from public.client_companies cc
      where cc.client_id = r.client_id and cc.company_id = new.id
      returning cc.added_at, cc.added_by
    )
    insert into public.client_companies_blocked (client_id, company_id, added_at, added_by, blocked_reason)
    select r.client_id, new.id, moved.added_at, moved.added_by, r.reason from moved
    on conflict (client_id, company_id) do nothing;

    with blocked as (
      update public.client_prospects cp set
        status = 'blocked',
        blocked_at = coalesce(cp.blocked_at, now()),
        blocked_reason = coalesce(nullif(cp.blocked_reason, ''), r.reason)
      from public.prospects p
      where p.company_id = new.id
        and cp.prospect_id = p.id
        and cp.client_id = r.client_id
        and cp.status = 'active'
      returning cp.prospect_id
    )
    select array_agg(prospect_id) into v_ids from blocked;
    if v_ids is not null then
      perform public.reindex_prospects(v_ids);
    end if;
  end loop;
  return null;
end;
$$;

create or replace trigger block_company_on_domain_change
  after update of normalized_domain on public.companies
  for each row
  when (old.normalized_domain is distinct from new.normalized_domain and new.normalized_domain <> '')
  execute function public.block_company_on_domain_change_v1();

-- 4b. A person's email or company changes to one a client has blocked. Only
-- the clients already holding the person are checked, with the same rule
-- imports use, and only when one of the three columns actually changed.
create or replace function public.block_prospect_on_identity_change_v1()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_ids text[];
begin
  with matched as (
    select cp.client_id, public.client_block_reason_v1(cp.client_id, new.id) as reason
    from public.client_prospects cp
    where cp.prospect_id = new.id
      and cp.status = 'active'
      and exists (select 1 from public.client_blocklist b where b.client_id = cp.client_id)
  ), blocked as (
    update public.client_prospects cp set
      status = 'blocked',
      blocked_at = coalesce(cp.blocked_at, now()),
      blocked_reason = coalesce(nullif(cp.blocked_reason, ''), m.reason)
    from matched m
    where cp.prospect_id = new.id and cp.client_id = m.client_id and m.reason is not null
    returning cp.prospect_id
  )
  select array_agg(prospect_id) into v_ids from blocked;
  if v_ids is not null then
    perform public.reindex_prospects(array[new.id]);
  end if;
  return null;
end;
$$;

create or replace trigger block_prospect_on_identity_change
  after update of work_email, personal_email, company_id on public.prospects
  for each row
  when (old.work_email is distinct from new.work_email
     or old.personal_email is distinct from new.personal_email
     or old.company_id is distinct from new.company_id)
  execute function public.block_prospect_on_identity_change_v1();

-- ---------------------------------------------------------------------------
-- The companies that already leaked: sweep every client that has domain entries.
do $$
declare
  v_client text;
  v_total integer := 0;
begin
  for v_client in select distinct client_id from public.client_blocklist where kind = 'domain' loop
    v_total := v_total + public.sweep_client_company_blocklist_v1(v_client);
  end loop;
  raise notice 'moved % blocked companies out of client Company DBs', v_total;

  if exists (
    select 1 from public.client_companies cc
    join public.companies co on co.id = cc.company_id
    join public.client_blocklist b on b.client_id = cc.client_id and b.kind = 'domain' and b.value <> '' and b.value = co.normalized_domain
  ) then
    raise exception 'a client still lists a company whose domain it has blocked';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Every path, end to end, on throwaway rows. The inner block always ends in an
-- exception, which rolls back everything it wrote; only a real failure escapes.
do $$
declare
  v_client constant text := 'zz-blocklist-proof-client';
  v_result jsonb;
  v_state text;
begin
  begin
    insert into public.clients (id, name, normalized_name) values (v_client, 'zz blocklist proof', 'zz blocklist proof');
    insert into public.companies (id, name, normalized_name, normalized_domain, domain)
    values ('zz-co-blocked', 'Blocked Co', 'blocked co', 'zz-blocked.example', 'zz-blocked.example'),
           ('zz-co-fine',    'Fine Co',    'fine co',    'zz-fine.example',    'zz-fine.example'),
           ('zz-co-later',   'Later Co',   'later co',   'zz-later.example',   'zz-later.example');
    insert into public.client_blocklist (client_id, kind, value, reason)
    values (v_client, 'domain', 'zz-blocked.example', 'proof');

    -- 1. On the way in: a push of a blocked and a fine company.
    v_result := public.push_companies_to_client_v1(v_client, array['zz-co-blocked', 'zz-co-fine'], '', '[]'::jsonb, null, null, 'proof');
    if exists (select 1 from public.client_companies where client_id = v_client and company_id = 'zz-co-blocked') then
      raise exception 'FAIL: a pushed blocked company reached client_companies';
    end if;
    if not exists (select 1 from public.client_companies_blocked where client_id = v_client and company_id = 'zz-co-blocked') then
      raise exception 'FAIL: a pushed blocked company was not recorded as blocked';
    end if;
    if not exists (select 1 from public.client_companies where client_id = v_client and company_id = 'zz-co-fine') then
      raise exception 'FAIL: a fine company was not added';
    end if;
    if (v_result->>'added')::int <> 1 or (v_result->>'blocked')::int <> 1 then
      raise exception 'FAIL: push reported %', v_result;
    end if;

    -- 1b. On the way in through people: a person joining brings a blocked company.
    insert into public.prospects (id, company_id, work_email) values ('zz-p-1', 'zz-co-blocked', 'a@zz-blocked.example');
    insert into public.client_prospects (client_id, prospect_id, added_via, status) values (v_client, 'zz-p-1', 'import', 'blocked');
    if exists (select 1 from public.client_companies where client_id = v_client and company_id = 'zz-co-blocked') then
      raise exception 'FAIL: the people-membership trigger brought a blocked company in';
    end if;

    -- 4a. A company gains a blocked domain after it was added.
    insert into public.client_companies (client_id, company_id, added_by) values (v_client, 'zz-co-later', 'proof');
    insert into public.prospects (id, company_id, work_email) values ('zz-p-2', 'zz-co-later', 'b@zz-later.example');
    insert into public.client_prospects (client_id, prospect_id, added_via, status) values (v_client, 'zz-p-2', 'import', 'active');
    -- domain and normalized_domain move together (companies_domain_is_normalized).
    update public.companies set domain = 'zz-blocked.example', normalized_domain = 'zz-blocked.example' where id = 'zz-co-later';
    if exists (select 1 from public.client_companies where client_id = v_client and company_id = 'zz-co-later') then
      raise exception 'FAIL: a company that gained a blocked domain stayed in the client';
    end if;
    select status into v_state from public.client_prospects where client_id = v_client and prospect_id = 'zz-p-2';
    if v_state <> 'blocked' then
      raise exception 'FAIL: the person at a company that gained a blocked domain is %', v_state;
    end if;

    -- 4b. A person moves to a blocked company.
    insert into public.prospects (id, company_id, work_email) values ('zz-p-3', 'zz-co-fine', 'c@zz-fine.example');
    insert into public.client_prospects (client_id, prospect_id, added_via, status) values (v_client, 'zz-p-3', 'import', 'active');
    update public.prospects set company_id = 'zz-co-blocked' where id = 'zz-p-3';
    select status into v_state from public.client_prospects where client_id = v_client and prospect_id = 'zz-p-3';
    if v_state <> 'blocked' then
      raise exception 'FAIL: a person who moved to a blocked company is %', v_state;
    end if;

    -- 3. Removing the entry restores the companies.
    v_result := public.remove_client_blocklist_v1(v_client,
      array(select id from public.client_blocklist where client_id = v_client), 'proof');
    if (select count(*) from public.client_companies
        where client_id = v_client and company_id in ('zz-co-blocked', 'zz-co-later')) <> 2 then
      raise exception 'FAIL: removing the entry did not restore both companies: %', v_result;
    end if;
    if exists (select 1 from public.client_companies_blocked where client_id = v_client) then
      raise exception 'FAIL: restored companies are still recorded as blocked';
    end if;
    if (v_result->>'companiesRestored')::int <> 2 then
      raise exception 'FAIL: remove reported %', v_result;
    end if;

    -- 2. Adding the entry back sweeps them out again, through the app's path.
    v_result := public.add_client_blocklist_batch_v2(v_client, array['zz-blocked.example'], null, 'proof', 'proof',
      'zz-proof-request-0001', 5000);
    if (v_result->>'companiesBlocked')::int <> 2
       or exists (select 1 from public.client_companies
                  where client_id = v_client and company_id in ('zz-co-blocked', 'zz-co-later')) then
      raise exception 'FAIL: adding the entry did not sweep both companies: %', v_result;
    end if;
    if not exists (select 1 from public.client_companies where client_id = v_client and company_id = 'zz-co-fine') then
      raise exception 'FAIL: the sweep removed a company it does not match';
    end if;

    raise exception 'blocklist-proof-passed';
  exception when others then
    if sqlerrm <> 'blocklist-proof-passed' then
      raise;
    end if;
  end;

  if exists (select 1 from public.clients where id = v_client) then
    raise exception 'the proof rows were not rolled back';
  end if;
end $$;
