\set ON_ERROR_STOP on

do $$
begin
  if current_database() <> 'cursor_migration_test' then
    raise exception 'Refusing client-summary fixture outside its disposable database.';
  end if;
end $$;

insert into public.clients(id, name, normalized_name) values
  ('summary-inline-discard', 'Summary Inline Discard', 'summary inline discard'),
  ('summary-inline-keep', 'Summary Inline Keep', 'summary inline keep');
insert into public.client_settings(client_id, seg_emails) values
  ('summary-inline-discard', 'discard'), ('summary-inline-keep', 'keep');

insert into public.companies(id, name, normalized_name, domain, normalized_domain, keywords, short_description, email_provider_type) values
  ('summary-inline-incomplete', 'Summary Incomplete', 'summary incomplete', 'summary-incomplete.test', 'summary-incomplete.test', '{}'::text[], '', 'Unknown'),
  ('summary-inline-seg', 'Summary SEG', 'summary seg', 'summary-seg.test', 'summary-seg.test', array['software'], 'Complete SEG profile', 'SEG'),
  ('summary-inline-normal', 'Summary Normal', 'summary normal', 'summary-normal.test', 'summary-normal.test', array['software'], 'Complete normal profile', 'Mailbox provider');
insert into public.prospects(id, full_name, work_email, company_id) values
  ('summary-inline-person-incomplete', 'Summary Incomplete Person', 'incomplete@summary.test', 'summary-inline-incomplete'),
  ('summary-inline-person-seg', 'Summary SEG Person', 'seg@summary.test', 'summary-inline-seg'),
  ('summary-inline-person-normal', 'Summary Normal Person', 'normal@summary.test', 'summary-inline-normal'),
  ('summary-inline-person-blocked', 'Summary Blocked Person', 'blocked@summary.test', null);

insert into public.client_prospects(client_id, prospect_id, status, icp_verified)
select client_id, prospect_id, 'active', prospect_id <> 'summary-inline-person-seg'
from (values ('summary-inline-discard'), ('summary-inline-keep')) clients(client_id)
cross join (values ('summary-inline-person-incomplete'), ('summary-inline-person-seg'), ('summary-inline-person-normal')) people(prospect_id);
insert into public.client_prospects(client_id, prospect_id, status, icp_verified)
select client_id, 'summary-inline-person-blocked', 'blocked', false
from (values ('summary-inline-discard'), ('summary-inline-keep')) clients(client_id);
insert into public.client_companies(client_id, company_id)
select client_id, company_id
from (values ('summary-inline-discard'), ('summary-inline-keep')) clients(client_id)
cross join (values ('summary-inline-incomplete'), ('summary-inline-seg'), ('summary-inline-normal')) companies(company_id)
on conflict (client_id, company_id) do nothing;
insert into public.lists(id, client_id, name)
values ('summary-inline-list-discard', 'summary-inline-discard', 'Fixture'),
       ('summary-inline-list-keep', 'summary-inline-keep', 'Fixture');

do $$
declare v_discard record; v_keep record;
begin
  select * into v_discard from public.client_summaries where id = 'summary-inline-discard';
  select * into v_keep from public.client_summaries where id = 'summary-inline-keep';
  if (v_discard.list_count, v_discard.prospect_count, v_discard.icp_verified_count, v_discard.blocked_count, v_discard.company_count)
       is distinct from (1, 1, 1, 1, 1)
     or (v_keep.list_count, v_keep.prospect_count, v_keep.icp_verified_count, v_keep.blocked_count, v_keep.company_count)
       is distinct from (1, 2, 1, 1, 2) then
    raise exception 'Initial SEG/incomplete summary mismatch: discard %, keep %', row_to_json(v_discard), row_to_json(v_keep);
  end if;

  update public.companies set short_description = 'Enriched profile' where id = 'summary-inline-incomplete';
  select * into v_discard from public.client_summaries where id = 'summary-inline-discard';
  select * into v_keep from public.client_summaries where id = 'summary-inline-keep';
  if (v_discard.prospect_count, v_discard.company_count) is distinct from (2, 2)
     or (v_keep.prospect_count, v_keep.company_count) is distinct from (3, 3) then
    raise exception 'Enrichment transition mismatch: discard %, keep %', row_to_json(v_discard), row_to_json(v_keep);
  end if;

  update public.companies set email_provider_type = 'Mailbox provider' where id = 'summary-inline-seg';
  select * into v_discard from public.client_summaries where id = 'summary-inline-discard';
  if (v_discard.prospect_count, v_discard.company_count) is distinct from (3, 3) then
    raise exception 'SEG-to-mailbox transition mismatch: %', row_to_json(v_discard);
  end if;

  update public.companies set email_provider_type = 'SEG' where id = 'summary-inline-seg';
  update public.client_settings set seg_emails = 'discard' where client_id = 'summary-inline-keep';
  select * into v_keep from public.client_summaries where id = 'summary-inline-keep';
  if (v_keep.prospect_count, v_keep.company_count) is distinct from (2, 2) then
    raise exception 'Keep-to-discard transition mismatch: %', row_to_json(v_keep);
  end if;
end $$;
