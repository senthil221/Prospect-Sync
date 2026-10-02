-- Pull people from the Master People DB into a client, for companies the
-- client already has.
--
-- The Master DB keeps growing after a client's companies were brought in: a
-- later import adds new people at the same companies. A pull takes the
-- client's selected companies (ticked, pasted, or everything matching the
-- Company DB's filters - the same selection every Company DB action takes),
-- finds the Master DB people at them who match a job title, management level
-- and department filter, and adds the ones the client does not have yet.
--
-- The adding is push_prospects_to_client_v2 with explicit ids, so the client
-- blocklist, "Recently Added" (one batch per pull, source Master DB), the
-- operation log and the bounded re-index are exactly a push's. Running the
-- same pull months later adds only the people who are new since.
--
-- The last criteria used are kept per client (client_settings.people_pull_filters)
-- so the next pull starts from them.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

alter table public.client_settings
  add column if not exists people_pull_filters jsonb not null default '[]'::jsonb;

comment on column public.client_settings.people_pull_filters is
  'The job title / management level / department filters of this client''s last pull from the Master People DB (pull_master_people_v1).';

create or replace function public.pull_master_people_v1(
  p_client_id text,
  p_company_ids text[] default null,
  p_search text default '',
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null,
  p_excluded_ids text[] default null,
  p_people_filters jsonb default '[]'::jsonb,
  p_apply boolean default false,
  p_actor text default '',
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_people_filters jsonb := coalesce(p_people_filters, '[]'::jsonb);
  v_field text;
  v_companies text[];
  v_where text;
  v_matching integer := 0;
  v_present integer := 0;
  v_blocked integer := 0;
  v_new text[] := array[]::text[];
  v_max_companies constant integer := 50000;
  v_max_people constant integer := 50000;
  v_counts jsonb;
  v_push jsonb;
begin
  if jsonb_typeof(v_people_filters) <> 'array' then
    raise exception using errcode = '22023', message = 'Invalid people filters.';
  end if;
  -- What a pull is for: who at the company, by their job title.
  select item->>'field' into v_field
    from jsonb_array_elements(v_people_filters) item
   where coalesce(item->>'field', '') not in
         ('__title', '__title_seniority', '__title_seniority_tier', '__title_department', '__title_sub_department')
   limit 1;
  if v_field is not null then
    raise exception using errcode = '22023',
      message = 'A pull filters people by job title, management level and department only.';
  end if;
  if not exists (select 1 from public.clients where id = p_client_id and archived_at is null) then
    raise exception using errcode = 'P0002', message = 'Client not found or archived.';
  end if;

  -- The client's own companies only: resolve_company_action_selection_v1 with
  -- the client id cannot return a company the client does not have.
  select coalesce(array_agg(company_id), array[]::text[]) into v_companies
    from public.resolve_company_action_selection_v1(
      p_client_id, p_company_ids, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb),
      p_people_scope, p_excluded_ids, v_max_companies + 1);
  if cardinality(v_companies) > v_max_companies then
    raise exception using errcode = '54000', message = 'More than 50,000 companies are selected. Narrow the selection first.';
  end if;

  if cardinality(v_companies) > 0 then
    v_where := public.prospect_filter_sql_v1('', v_people_filters);
    -- Matching = Master DB people at these companies who fit the filters. Of
    -- them: already in the client (active or blocked), on the client's
    -- blocklist, hidden by the client's SEG setting, and the rest - new.
    execute format($q$
      select count(*)::integer,
             count(*) filter (where cp.prospect_id is not null)::integer,
             count(*) filter (where cp.prospect_id is null and flags.blocked)::integer,
             coalesce(array_agg(pi.id order by pi.id)
               filter (where cp.prospect_id is null and not flags.blocked and not flags.seg_hidden), array[]::text[])
        from public.prospect_index pi
        left join public.client_prospects cp on cp.client_id = $2 and cp.prospect_id = pi.id
        cross join lateral (
          select exists (
                   select 1 from public.client_blocklist b
                    where b.client_id = $2
                      and ((b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
                        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value)))
                 ) as blocked,
                 pi.email_provider_type = 'SEG' and exists (
                   select 1 from public.client_settings s where s.client_id = $2 and s.seg_emails = 'discard'
                 ) as seg_hidden
        ) flags
       where pi.company_id = any($1) and (%s)$q$, v_where)
      into v_matching, v_present, v_blocked, v_new
      using v_companies, p_client_id;
  end if;

  v_counts := jsonb_build_object(
    'companies', cardinality(v_companies),
    'matching', v_matching,
    'alreadyInClient', v_present,
    'blocked', v_blocked,
    'toAdd', cardinality(v_new));
  if not coalesce(p_apply, false) then
    return v_counts;
  end if;

  if cardinality(v_new) > v_max_people then
    raise exception using errcode = '54000',
      message = format('%s new people match - more than %s in one pull. Narrow the job filters or the companies.', cardinality(v_new), v_max_people);
  end if;

  insert into public.client_settings (client_id, people_pull_filters, updated_at)
  values (p_client_id, v_people_filters, now())
  on conflict (client_id) do update set people_pull_filters = excluded.people_pull_filters, updated_at = now();

  if cardinality(v_new) = 0 then
    return v_counts || jsonb_build_object('added', 0, 'alreadyPresent', v_present, 'queued', 0);
  end if;
  v_push := public.push_prospects_to_client_v2(
    p_client_id, '', '[]'::jsonb, null, v_new, null, coalesce(p_actor, ''), p_request_id);
  return v_counts || v_push;
end;
$$;

revoke execute on function public.pull_master_people_v1(text, text[], text, jsonb, jsonb, text[], jsonb, boolean, text, text) from public, anon, authenticated;
grant execute on function public.pull_master_people_v1(text, text[], text, jsonb, jsonb, text[], jsonb, boolean, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- Proof, rolled back: on a real client's company, a pull finds the Master DB
-- people the client does not have, adds exactly those, and a second pull
-- finds nothing new.
do $proof$
declare
  v_client text;
  v_company text;
  v_missing text;
  v_preview jsonb;
  v_pulled jsonb;
  v_again jsonb;
begin
  begin
    perform public.pull_master_people_v1('no-such-client');
    raise exception 'Pull proof: an unknown client was accepted';
  exception when sqlstate 'P0002' then null;
  end;
  begin
    perform public.pull_master_people_v1('any-client', array['x'], '', '[]', null, null,
      '[{"field":"__company_industry","operator":"contains","values":["x"]}]'::jsonb);
    raise exception 'Pull proof: a non-title filter was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- A client company with a Master DB person the client does not have.
  select cc.client_id, cc.company_id, pi.id into v_client, v_company, v_missing
    from public.client_companies cc
    join public.clients c on c.id = cc.client_id and c.archived_at is null
    join public.prospect_index pi on pi.company_id = cc.company_id
   where not exists (select 1 from public.client_prospects cp where cp.client_id = cc.client_id and cp.prospect_id = pi.id)
     and not exists (select 1 from public.client_blocklist b where b.client_id = cc.client_id
                       and ((b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
                         or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))))
     and not (pi.email_provider_type = 'SEG'
              and exists (select 1 from public.client_settings s where s.client_id = cc.client_id and s.seg_emails = 'discard'))
   limit 1;
  if v_client is null then
    raise notice 'Pull proof skipped: no client company has a Master DB person the client lacks.';
    return;
  end if;

  begin
    v_preview := public.pull_master_people_v1(v_client, array[v_company]);
    if (v_preview->>'companies')::int <> 1 or (v_preview->>'toAdd')::int < 1
       or (v_preview->>'matching')::int <> (v_preview->>'alreadyInClient')::int + (v_preview->>'blocked')::int + (v_preview->>'toAdd')::int then
      raise exception 'Pull proof: preview is wrong: %', v_preview;
    end if;
    if exists (select 1 from public.client_prospects where client_id = v_client and prospect_id = v_missing) then
      raise exception 'Pull proof: a preview wrote';
    end if;

    v_pulled := public.pull_master_people_v1(v_client, array[v_company], '', '[]', null, null, '[]', true, 'pull-proof', 'pull-proof-' || gen_random_uuid());
    if (v_pulled->>'added')::int <> (v_preview->>'toAdd')::int
       or not exists (select 1 from public.client_prospects where client_id = v_client and prospect_id = v_missing and added_via = 'push') then
      raise exception 'Pull proof: the pull did not add the new people: %', v_pulled;
    end if;

    v_again := public.pull_master_people_v1(v_client, array[v_company]);
    if (v_again->>'toAdd')::int <> 0 then
      raise exception 'Pull proof: a second pull still finds % new', v_again->>'toAdd';
    end if;
    raise exception 'pull-proof-passed';
  exception when others then
    if sqlerrm <> 'pull-proof-passed' then raise; end if;
  end;
  raise notice 'Pull proof passed and was rolled back.';
end;
$proof$;
