\set ON_ERROR_STOP on

do $$
begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing client-summary scoped-cache fixture outside its disposable database.';
  end if;
end $$;

insert into public.clients(id, name, normalized_name) values
  ('summary-scope-a', 'Summary Scope A', 'summary scope a'),
  ('summary-scope-b', 'Summary Scope B', 'summary scope b');
insert into public.client_settings(client_id, seg_emails) values
  ('summary-scope-a', 'discard'),
  ('summary-scope-b', 'keep');

insert into public.companies(
  id, name, normalized_name, domain, normalized_domain,
  keywords, short_description, email_provider_type
) values
  ('summary-scope-incomplete', 'Scope Incomplete', 'scope incomplete', 'scope-incomplete.test', 'scope-incomplete.test', '{}'::text[], '', 'Unknown'),
  ('summary-scope-seg', 'Scope SEG', 'scope seg', 'scope-seg.test', 'scope-seg.test', array['software'], 'Complete SEG profile', 'SEG'),
  ('summary-scope-normal', 'Scope Normal', 'scope normal', 'scope-normal.test', 'scope-normal.test', array['software'], 'Complete normal profile', 'Mailbox provider'),
  ('summary-scope-provider', 'Scope Provider', 'scope provider', 'scope-provider.test', 'scope-provider.test', array['software'], 'Complete provider profile', 'Unknown');

insert into public.prospects(id, full_name, work_email, company_id) values
  ('summary-scope-person-incomplete', 'Scope Incomplete Person', 'scope-incomplete@example.test', 'summary-scope-incomplete'),
  ('summary-scope-person-seg', 'Scope SEG Person', 'scope-seg@example.test', 'summary-scope-seg'),
  ('summary-scope-person-normal', 'Scope Normal Person', 'scope-normal@example.test', 'summary-scope-normal'),
  ('summary-scope-person-provider', 'Scope Provider Person', 'scope-provider@example.test', 'summary-scope-provider'),
  ('summary-scope-person-companyless', 'Scope Companyless Person', 'scope-companyless@example.test', null),
  ('summary-scope-person-blocked', 'Scope Blocked Person', 'scope-blocked@example.test', 'summary-scope-incomplete');

insert into public.client_prospects(client_id, prospect_id, status, icp_verified) values
  ('summary-scope-a', 'summary-scope-person-incomplete', 'active', true),
  ('summary-scope-a', 'summary-scope-person-seg', 'active', false),
  ('summary-scope-a', 'summary-scope-person-normal', 'active', true),
  ('summary-scope-a', 'summary-scope-person-provider', 'active', true),
  ('summary-scope-a', 'summary-scope-person-companyless', 'active', false),
  ('summary-scope-a', 'summary-scope-person-blocked', 'blocked', false),
  ('summary-scope-b', 'summary-scope-person-seg', 'active', false);

insert into public.client_companies(client_id, company_id)
select client_id, company_id
from (values ('summary-scope-a'), ('summary-scope-b')) clients(client_id)
cross join (values
  ('summary-scope-incomplete'), ('summary-scope-seg'),
  ('summary-scope-normal'), ('summary-scope-provider')
) companies(company_id)
on conflict (client_id, company_id) do nothing;

do $$
declare
  v_result jsonb;
  v_row jsonb;
  v_global jsonb;
  v_cache_before jsonb;
  v_cache_after jsonb;
  v_version_before bigint;
  v_version_after bigint;
begin
  delete from public.client_summary_cache;

  -- A single-client miss is scoped and must not publish a partial global row.
  v_result := public.client_summaries_v1('summary-scope-a');
  v_row := v_result->0;
  if jsonb_array_length(v_result) <> 1
     or (v_row->>'prospect_count')::integer <> 3
     or (v_row->>'icp_verified_count')::integer <> 2
     or (v_row->>'blocked_count')::integer <> 1
     or (v_row->>'company_count')::integer <> 2 then
    raise exception 'Initial scoped summary mismatch: %', v_result;
  end if;
  if exists (select 1 from public.client_summary_cache) then
    raise exception 'A cache-absent single-client miss created a partial global cache row';
  end if;

  -- The directory miss still fills the complete shared cache; the next read is
  -- an exact cache hit and does not change that row.
  v_global := public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  if v_cache_before is null or not ((v_cache_before->'counts') ? 'summary-scope-a')
     or not ((v_cache_before->'counts') ? 'summary-scope-b') then
    raise exception 'The directory miss did not fill the complete cache: %', v_cache_before;
  end if;
  if public.client_summaries_v1(null) <> v_global then
    raise exception 'The unchanged directory cache hit changed its result';
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'The unchanged directory cache hit rewrote its cache row';
  end if;

  -- An expired complete row is preserved byte-for-byte by a scoped miss. The
  -- single-client path neither refreshes its timestamp nor replaces its object.
  update public.client_summary_cache
     set computed_at = now() - interval '6 minutes'
   where id;
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  perform public.client_summaries_v1('summary-scope-a');
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'An expired-cache single-client miss rewrote the global cache';
  end if;

  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;

  -- Name, archive state and list count remain live on a valid count-cache hit.
  update public.clients
     set name = 'Summary Scope A Renamed', normalized_name = 'summary scope a renamed', archived_at = now()
   where id = 'summary-scope-a';
  insert into public.lists(id, client_id, name)
  values ('summary-scope-list-a', 'summary-scope-a', 'Scoped list');
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if v_row->>'name' <> 'Summary Scope A Renamed'
     or (v_row->>'archived_at') is null
     or (v_row->>'list_count')::integer <> 1 then
    raise exception 'Live client metadata was hidden by a count-cache hit: %', v_row;
  end if;

  -- Active/blocked/ICP changes invalidate counts, but a scoped miss must leave
  -- the stale global row byte-for-byte untouched.
  update public.client_prospects
     set status = 'blocked'
   where client_id = 'summary-scope-a' and prospect_id = 'summary-scope-person-normal';
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 2
     or (v_row->>'icp_verified_count')::integer <> 1
     or (v_row->>'blocked_count')::integer <> 2 then
    raise exception 'Membership transition was not reflected by the scoped miss: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A single-client membership miss rewrote the global cache';
  end if;

  -- Enrichment, company reassignment, SEG policy and provider classification
  -- all retain the established partition semantics on the scoped path.
  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  update public.companies set short_description = 'Enriched profile'
   where id = 'summary-scope-incomplete';
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 3
     or (v_row->>'icp_verified_count')::integer <> 2
     or (v_row->>'company_count')::integer <> 3 then
    raise exception 'Enrichment transition mismatch: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A scoped enrichment miss rewrote the global cache';
  end if;

  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  update public.prospects set company_id = 'summary-scope-seg'
   where id = 'summary-scope-person-companyless';
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 2 then
    raise exception 'Company reassignment did not apply the discard policy: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A scoped company-reassignment miss rewrote the global cache';
  end if;

  -- Refill a valid global object, then prove policy invalidation sends the
  -- scoped read live without publishing a replacement global object.
  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  update public.client_settings set seg_emails = 'keep' where client_id = 'summary-scope-a';
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 4
     or (v_row->>'company_count')::integer <> 4 then
    raise exception 'SEG keep transition mismatch: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A scoped SEG-policy miss rewrote the global cache';
  end if;

  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  update public.client_settings set seg_emails = 'discard' where client_id = 'summary-scope-a';
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 2
     or (v_row->>'company_count')::integer <> 3 then
    raise exception 'SEG discard transition mismatch: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A scoped SEG-discard miss rewrote the global cache';
  end if;

  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  v_version_before := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  update public.companies set email_provider_type = 'Unknown' where id = 'summary-scope-seg';
  v_version_after := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  if v_version_after <= v_version_before then
    raise exception 'SEG-to-non-SEG transition did not advance the client-count version';
  end if;
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 4
     or (v_row->>'company_count')::integer <> 4 then
    raise exception 'Provider reclassification transition mismatch: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A scoped provider-classification miss rewrote the global cache';
  end if;

  -- A directory refresh publishes the new counts. The reverse boundary also
  -- invalidates, while its scoped read continues to leave that global row
  -- untouched.
  v_global := public.client_summaries_v1(null);
  select value into v_row from jsonb_array_elements(v_global)
   where value->>'id' = 'summary-scope-a';
  if (v_row->>'prospect_count')::integer <> 4
     or (v_row->>'company_count')::integer <> 4 then
    raise exception 'Directory refresh after leaving SEG was stale: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  v_version_before := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  update public.companies set email_provider_type = 'SEG' where id = 'summary-scope-seg';
  v_version_after := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  if v_version_after <= v_version_before then
    raise exception 'Non-SEG-to-SEG transition did not advance the client-count version';
  end if;
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 2
     or (v_row->>'company_count')::integer <> 3 then
    raise exception 'Reverse provider reclassification transition mismatch: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A reverse scoped provider-classification miss rewrote the global cache';
  end if;

  -- One statement may contain both semantic and non-semantic provider changes.
  -- Any SEG boundary crossing advances the epoch; exact increments are not a
  -- contract because the row trigger and MX scan can both conservatively bump.
  perform public.client_summaries_v1(null);
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  v_version_before := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  update public.companies
     set email_provider_type = case id
       when 'summary-scope-normal' then 'SEG'
       when 'summary-scope-provider' then 'Mailbox provider'
       else email_provider_type end
   where id in ('summary-scope-normal', 'summary-scope-provider');
  v_version_after := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  if v_version_after <= v_version_before then
    raise exception 'Mixed provider update did not advance the client-count version';
  end if;
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 2
     or (v_row->>'company_count')::integer <> 2 then
    raise exception 'Mixed provider transition mismatch: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A mixed scoped provider-classification miss rewrote the global cache';
  end if;

  v_global := public.client_summaries_v1(null);
  select value into v_row from jsonb_array_elements(v_global)
   where value->>'id' = 'summary-scope-a';
  if (v_row->>'prospect_count')::integer <> 2
     or (v_row->>'company_count')::integer <> 2 then
    raise exception 'Directory refresh after mixed provider update was stale: %', v_row;
  end if;

  -- Updates that stay on one side of the boundary do not invalidate. This
  -- statement includes SEG-to-SEG and non-SEG-to-other-non-SEG rows.
  select to_jsonb(cache_row) into v_cache_before
    from public.client_summary_cache cache_row where id;
  v_version_before := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  update public.companies
     set email_provider_type = case id
       when 'summary-scope-normal' then 'SEG'
       when 'summary-scope-provider' then 'Email relay'
       else email_provider_type end
   where id in ('summary-scope-normal', 'summary-scope-provider');
  v_version_after := coalesce(pg_sequence_last_value('public.data_version_client_counts'::regclass), 0);
  if v_version_after <> v_version_before then
    raise exception 'A same-side provider update unexpectedly advanced the client-count version';
  end if;
  v_row := public.client_summaries_v1('summary-scope-a')->0;
  if (v_row->>'prospect_count')::integer <> 2
     or (v_row->>'company_count')::integer <> 2 then
    raise exception 'Same-side provider update changed scoped counts: %', v_row;
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A same-side provider update rewrote a valid global cache';
  end if;

  -- A new client makes the old global object incomplete. Its scoped miss still
  -- returns live zeros without mutating that object. Unknown ids remain [].
  insert into public.clients(id, name, normalized_name)
  values ('summary-scope-new', 'Summary Scope New', 'summary scope new');
  v_row := public.client_summaries_v1('summary-scope-new')->0;
  if v_row->>'id' <> 'summary-scope-new'
     or (v_row->>'prospect_count')::integer <> 0
     or (v_row->>'company_count')::integer <> 0 then
    raise exception 'New-client scoped summary mismatch: %', v_row;
  end if;
  if public.client_summaries_v1('summary-scope-missing') <> '[]'::jsonb then
    raise exception 'Unknown client did not return an empty array';
  end if;
  select to_jsonb(cache_row) into v_cache_after
    from public.client_summary_cache cache_row where id;
  if v_cache_after is distinct from v_cache_before then
    raise exception 'A new/unknown single-client miss rewrote the global cache';
  end if;

  -- Only the directory miss replaces the stale cache and covers the new client.
  perform public.client_summaries_v1(null);
  if not exists (
    select 1 from public.client_summary_cache cache_row
     where id and cache_row.counts ? 'summary-scope-new'
  ) then
    raise exception 'The final directory miss did not refresh the complete cache';
  end if;
end $$;

select 'client_summary_scoped_cache_ok' as result;
