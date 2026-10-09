-- A blocked domain also blocks every email address at that domain.
--
-- Asked for on 2026-10-10: "all blocklisted websites should also block their
-- email domain. Same for reply blocklist." A domain entry used to match a
-- person only through the company they are linked to (prospect_index
-- .company_domain), so john@johndeere.com stayed in a client whose blocklist
-- held johndeere.com whenever his company had no domain or a different one
-- (a subsidiary, a regional site). Every domain entry now matches the person's
-- work email domain too, whatever its source - ICP check, paste, client link,
-- or the Smartlead reply sync (which stores its domain blocks the same way).
-- Measured before this ran: 1,636 people across 7 clients.
--
-- EMAIL DOMAIN. public.email_domain_v1(email): the part after the @, lower
-- case, '' when there is none. A derived field rather than a stored column:
-- every check that needs it reads one person or one client's members at a
-- time, so nothing has to scan by it, and a stored copy on the 845k-row
-- prospects and prospect_index tables would be one more thing to keep in step.
-- Free-mail domains (gmail.com ...) never match by email domain - one stray
-- entry must not block every Gmail user.
--
-- Spliced into every place a domain entry is matched to a person:
-- client_block_reason_v1 (new members, identity changes), the paste/ICP batch
-- sweep, apply/remove (restore), push v1/v2 and pull. Smartlead's
-- integration_selection_v1 already compared email domains. Then the people the
-- new rule catches are blocked now, the way the batch sweep blocks them.
-- ---------------------------------------------------------------------------

set local lock_timeout = '10s';

create or replace function public.email_domain_v1(p_email text)
returns text
language sql
immutable
parallel safe
as $$
  select case when position('@' in coalesce(p_email, '')) > 0
              then lower(btrim(split_part(btrim(p_email), '@', 2))) else '' end;
$$;

revoke execute on function public.email_domain_v1(text) from public, anon, authenticated;
grant execute on function public.email_domain_v1(text) to service_role;

do $patch$
declare
  v_function regprocedure;
  v_definition text;
  v_old text;
  v_new text;
  v_changed integer := 0;
begin
  -- The pi-based form, in add/apply/remove/push v1+v2/pull.
  v_old := $o$(b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)$o$;
  v_new := $n$(b.kind = 'domain' and b.value <> '' and (lower(pi.company_domain) = b.value or (public.email_domain_v1(pi.work_email) = b.value and not public.is_free_email_domain_v1(b.value))))$n$;
  for v_function in
    select p.oid::regprocedure from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('add_client_blocklist_v1', 'apply_client_blocklist_v1', 'remove_client_blocklist_v1',
                         'push_prospects_to_client_v1', 'push_prospects_to_client_v2', 'pull_master_people_v1')
  loop
    v_definition := pg_get_functiondef(v_function);
    if position('email_domain_v1' in v_definition) = 0 then
      if position(v_old in v_definition) = 0 then
        raise exception '%: domain match anchor not found', v_function;
      end if;
      execute replace(v_definition, v_old, v_new);
      v_changed := v_changed + 1;
    end if;
  end loop;

  -- The batch sweep (paste, ICP check apply, client links).
  v_definition := pg_get_functiondef('public.add_client_blocklist_batch_v2(text,text[],text[],text,text,text,integer)'::regprocedure);
  if position('email_domain_v1' in v_definition) = 0 then
    v_old := $o$(cardinality(v_domains) > 0 and lower(coalesce(pi.company_domain, '')) = any(v_domains))$o$;
    if (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old) <> 2 then
      raise exception 'add_client_blocklist_batch_v2: expected the domain match twice';
    end if;
    execute replace(v_definition, v_old,
      $n$(cardinality(v_domains) > 0 and (lower(coalesce(pi.company_domain, '')) = any(v_domains)
          or (public.email_domain_v1(pi.work_email) = any(v_domains)
              and not public.is_free_email_domain_v1(public.email_domain_v1(pi.work_email)))))$n$);
    v_changed := v_changed + 1;
  end if;

  -- One person's reason (new members, work email or company changes).
  v_definition := pg_get_functiondef('public.client_block_reason_v1(text,text)'::regprocedure);
  if position('email_domain_v1' in v_definition) = 0 then
    v_old := $o$(b.kind = 'domain' and b.value <> '' and b.value = coalesce(c.normalized_domain, lower(c.domain), ''))$o$;
    if position(v_old in v_definition) = 0 then
      raise exception 'client_block_reason_v1: domain match anchor not found';
    end if;
    execute replace(v_definition, v_old,
      $n$(b.kind = 'domain' and b.value <> '' and (b.value = coalesce(c.normalized_domain, lower(c.domain), '')
          or (b.value = public.email_domain_v1(p.work_email) and not public.is_free_email_domain_v1(b.value))))$n$);
    v_changed := v_changed + 1;
  end if;

  if v_changed > 0 and v_changed <> 8 then
    raise exception 'Email domain blocking: patched % functions, expected 8', v_changed;
  end if;
end;
$patch$;

-- Block the people the new rule catches, as add_client_blocklist_batch_v2
-- does: the membership, the search index arrays, then a re-index.
do $sweep$
declare
  v_client record;
  v_ids text[];
  v_total integer := 0;
begin
  for v_client in
    select distinct b.client_id, c.name from public.client_blocklist b join public.clients c on c.id = b.client_id where b.kind = 'domain'
  loop
    with matched as (
      select distinct on (cp.prospect_id) cp.prospect_id, b.reason
        from public.client_prospects cp
        join public.prospect_index pi on pi.id = cp.prospect_id
        join public.client_blocklist b
          on b.client_id = cp.client_id and b.kind = 'domain' and b.value = public.email_domain_v1(pi.work_email)
       where cp.client_id = v_client.client_id and cp.status = 'active'
         and not public.is_free_email_domain_v1(b.value)
       order by cp.prospect_id, b.created_at
    ), blocked as (
      update public.client_prospects cp set
        status = 'blocked',
        blocked_at = coalesce(cp.blocked_at, now()),
        blocked_reason = coalesce(nullif(cp.blocked_reason, ''), nullif(m.reason, ''), 'Matched client blocklist')
        from matched m
       where cp.client_id = v_client.client_id and cp.prospect_id = m.prospect_id
      returning cp.prospect_id
    )
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids from blocked;

    if cardinality(v_ids) > 0 then
      update public.prospect_index pi set
        client_ids = array_remove(coalesce(pi.client_ids, array[]::text[]), v_client.client_id),
        client_names = array_remove(coalesce(pi.client_names, array[]::text[]), v_client.name),
        client_count = cardinality(array_remove(coalesce(pi.client_ids, array[]::text[]), v_client.client_id)),
        icp_verified_client_ids = array_remove(coalesce(pi.icp_verified_client_ids, array[]::text[]), v_client.client_id),
        blocked_client_ids = case
          when coalesce(pi.blocked_client_ids, array[]::text[]) @> array[v_client.client_id]
            then coalesce(pi.blocked_client_ids, array[]::text[])
          else array_append(coalesce(pi.blocked_client_ids, array[]::text[]), v_client.client_id)
        end
      where pi.id = any(v_ids);
      perform public.reindex_scope_v1(p_prospect_ids => v_ids, p_batch => 1000);
      perform public.record_operation('blocklist_email_domain', v_client.client_id, 'system',
        format('Blocked %s people whose work email is at a blocked domain', cardinality(v_ids)),
        cardinality(v_ids), v_ids);
      v_total := v_total + cardinality(v_ids);
    end if;
  end loop;
  raise notice 'Email domain blocking: % people blocked.', v_total;
end;
$sweep$;

-- Proof, read-only.
do $proof$
declare
  v_left bigint;
begin
  if public.email_domain_v1('Ana@JohnDeere.com ') <> 'johndeere.com' or public.email_domain_v1('no-at-sign') <> '' or public.email_domain_v1(null) <> '' then
    raise exception 'Email domain proof: email_domain_v1 is off';
  end if;
  select count(*) into v_left
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    join public.client_blocklist b on b.client_id = cp.client_id and b.kind = 'domain' and b.value = public.email_domain_v1(pi.work_email)
   where cp.status = 'active' and not public.is_free_email_domain_v1(b.value);
  if v_left <> 0 then
    raise exception 'Email domain proof: % active people still have a blocked email domain', v_left;
  end if;
  raise notice 'Email domain proof passed.';
end;
$proof$;
