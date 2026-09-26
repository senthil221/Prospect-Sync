-- This fixture is intentionally inserted immediately before
-- 20260902000260_count_people_exactly.sql. Its scopes overlap without being
-- identical, so a cursor implementation cannot pass by silently ignoring a
-- client or list predicate.
insert into public.clients (id, name, normalized_name)
values
  ('cursor-client-a', 'Cursor Validation Client A', 'cursor validation client a'),
  ('cursor-client-b', 'Cursor Validation Client B', 'cursor validation client b');

insert into public.companies (
  id, name, normalized_name, domain, normalized_domain, industry, keywords,
  short_description, technologies, all_data
) values
  ('cursor-company-complete', 'Cursor Systems', 'cursor systems',
   'cursor.example', 'cursor.example', 'Software', array['saas', 'analytics'],
   'Production analytics software', array['PostgreSQL', 'TypeScript'],
   '{"fixture":"cursor-ci","profile":"complete"}'::jsonb),
  ('cursor-company-incomplete', 'Cursor Services', 'cursor services',
   'services.cursor.example', 'services.cursor.example', 'Professional Services',
   '{}'::text[], '', array['PostgreSQL'],
   '{"fixture":"cursor-ci","profile":"incomplete"}'::jsonb),
  ('cursor-company-b', 'Cursor Finance', 'cursor finance',
   'finance.cursor.example', 'finance.cursor.example', 'Financial Services',
   array['finance'], 'Financial operations', array['PostgreSQL'],
   '{"fixture":"cursor-ci","profile":"client-b"}'::jsonb);

insert into public.lists (
  id, client_id, name, source_file_name, uploaded_rows, unique_added
) values
  ('cursor-list-a', 'cursor-client-a', 'Cursor Validation List A',
   'cursor-validation-a.csv', 110, 110),
  ('cursor-list-a-secondary', 'cursor-client-a', 'Cursor Validation List A Secondary',
   'cursor-validation-a-secondary.csv', 1, 1),
  ('cursor-list-b', 'cursor-client-b', 'Cursor Validation List B',
   'cursor-validation-b.csv', 21, 21);

insert into public.imports (
  id, client_id, list_id, file_name, status, total_rows, processed_rows,
  unique_added, completed_at
) values
  ('cursor-import-a', 'cursor-client-a', 'cursor-list-a',
   'cursor-validation-a.csv', 'completed', 110, 110, 110, now()),
  ('cursor-import-a-secondary', 'cursor-client-a', 'cursor-list-a-secondary',
   'cursor-validation-a-secondary.csv', 'completed', 1, 1, 1, now()),
  ('cursor-import-b', 'cursor-client-b', 'cursor-list-b',
   'cursor-validation-b.csv', 'completed', 21, 21, 21, now());

-- Client A has 130 people. The first 60 deliberately share a timestamp so the
-- 50/51 boundary proves the mixed created_at DESC, id ASC order.
insert into public.prospects (
  id, first_name, last_name, full_name, work_email, linkedin_url, title,
  seniority, department, city, state, country, location, company_id, all_data,
  created_at, updated_at
)
select
  'cursor-fixture-a-' || lpad(n::text, 3, '0'),
  'Person', 'A' || lpad(n::text, 3, '0'), 'Person A' || lpad(n::text, 3, '0'),
  'person-a-' || lpad(n::text, 3, '0') || '@cursor.example',
  'https://linkedin.com/in/cursor-person-a-' || lpad(n::text, 3, '0'),
  case when n % 2 = 0 then 'Software Engineer' else 'Sales Manager' end,
  case when n % 2 = 0 then 'Individual Contributor' else 'Manager' end,
  case when n % 2 = 0 then 'Engineering' else 'Sales' end,
  case when n % 3 = 0 then 'Bengaluru' else 'London' end,
  case when n % 3 = 0 then 'Karnataka' else 'England' end,
  case when n % 3 = 0 then 'India' else 'United Kingdom' end,
  case when n % 3 = 0 then 'Bengaluru, Karnataka, India' else 'London, United Kingdom' end,
  case when n <= 100 then 'cursor-company-complete' else 'cursor-company-incomplete' end,
  jsonb_build_object('fixture', 'cursor-ci', 'scope', 'client-a', 'ordinal', n),
  case
    when n <= 60 then '2026-01-03 00:00:00+00'::timestamptz
    when n <= 100 then '2026-01-02 00:00:00+00'::timestamptz
    else '2026-01-01 00:00:00+00'::timestamptz
  end,
  '2026-01-04 00:00:00+00'::timestamptz
from generate_series(1, 130) n;

-- Client B contributes 21 older, differently titled people. Global, client A,
-- list A and the title-filtered result therefore have distinct totals.
insert into public.prospects (
  id, first_name, last_name, full_name, work_email, linkedin_url, title,
  seniority, department, city, state, country, location, company_id, all_data,
  created_at, updated_at
)
select
  'cursor-fixture-b-' || lpad(n::text, 3, '0'),
  'Person', 'B' || lpad(n::text, 3, '0'), 'Person B' || lpad(n::text, 3, '0'),
  'person-b-' || lpad(n::text, 3, '0') || '@cursor.example',
  'https://linkedin.com/in/cursor-person-b-' || lpad(n::text, 3, '0'),
  'Finance Analyst', 'Individual Contributor', 'Finance',
  'Singapore', '', 'Singapore', 'Singapore', 'cursor-company-b',
  jsonb_build_object('fixture', 'cursor-ci', 'scope', 'client-b', 'ordinal', n),
  '2025-12-31 00:00:00+00'::timestamptz,
  '2026-01-04 00:00:00+00'::timestamptz
from generate_series(1, 21) n;

insert into public.list_memberships (list_id, prospect_id, import_id, raw_data, imported_at)
select 'cursor-list-a', id, 'cursor-import-a', all_data, created_at
from public.prospects
where id between 'cursor-fixture-a-001' and 'cursor-fixture-a-110';

-- One canonical person belongs to two lists without duplicating either the
-- prospect or the client membership.
insert into public.list_memberships (list_id, prospect_id, import_id, raw_data, imported_at)
select 'cursor-list-a-secondary', id, 'cursor-import-a-secondary', all_data, created_at
from public.prospects
where id = 'cursor-fixture-a-001';

insert into public.list_memberships (list_id, prospect_id, import_id, raw_data, imported_at)
select 'cursor-list-b', id, 'cursor-import-b', all_data, created_at
from public.prospects
where id like 'cursor-fixture-b-%';

-- The remaining 20 client-A people model records pushed directly from Master
-- DB and intentionally do not appear in list A.
insert into public.client_prospects (client_id, prospect_id, added_via)
select 'cursor-client-a', id, 'push'
from public.prospects
where id like 'cursor-fixture-a-%'
on conflict (client_id, prospect_id) do nothing;

select public.reindex_prospects(array_agg(id order by id))
from public.prospects
where id like 'cursor-fixture-%';

do $fixture_contract$
declare
  v_prospects bigint;
  v_indexed bigint;
  v_client_a bigint;
  v_client_b bigint;
  v_list_a bigint;
  v_list_members bigint;
  v_multi_list bigint;
begin
  select count(*) into v_prospects from public.prospects where id like 'cursor-fixture-%';
  select count(*) into v_indexed from public.prospect_index where id like 'cursor-fixture-%';
  select count(*) into v_client_a from public.client_prospects
    where client_id = 'cursor-client-a' and prospect_id like 'cursor-fixture-%';
  select count(*) into v_client_b from public.client_prospects
    where client_id = 'cursor-client-b' and prospect_id like 'cursor-fixture-%';
  select count(*) into v_list_a from public.list_memberships
    where list_id = 'cursor-list-a' and prospect_id like 'cursor-fixture-%';
  select count(*) into v_list_members from public.list_memberships
    where prospect_id like 'cursor-fixture-%';
  select count(*) into v_multi_list from public.list_memberships
    where prospect_id = 'cursor-fixture-a-001';

  if (v_prospects, v_indexed, v_client_a, v_client_b, v_list_a, v_list_members, v_multi_list)
     is distinct from (151::bigint, 151::bigint, 130::bigint, 21::bigint,
       110::bigint, 132::bigint, 2::bigint) then
    raise exception 'cursor history fixture incomplete: prospects=%, index=%, client_a=%, client_b=%, list_a=%, memberships=%, multi_list=%',
      v_prospects, v_indexed, v_client_a, v_client_b, v_list_a, v_list_members, v_multi_list;
  end if;
end
$fixture_contract$;
