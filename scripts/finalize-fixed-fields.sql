-- Run after the checkpointed payload cleanup. Keep list field counts aligned
-- with the retained schema; leave processing imports' resume headers intact.
begin;
set local statement_timeout='30s';
set local lock_timeout='5s';
update public.lists l set field_headers=(
  select coalesce(jsonb_agg(field order by field),'[]'::jsonb)
  from (select distinct public.fixed_import_key_v1('prospect',key) as field
    from jsonb_array_elements_text(l.field_headers) key) kept where field is not null
) where not exists(select 1 from public.imports i where i.list_id=l.id and i.status='processing');
update public.imports i set field_headers=(
  select coalesce(jsonb_agg(field order by field),'[]'::jsonb)
  from (select distinct public.fixed_import_key_v1('prospect',key) as field
    from jsonb_array_elements_text(i.field_headers) key) kept where field is not null
) where i.status='completed';
insert into public.prospect_fields(field_name)
select unnest(array['First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website'])
on conflict(field_name) do nothing;
commit;
