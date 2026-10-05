-- Client summary counts exclude SEG companies for clients whose SEG policy is
-- "discard". The MX scan function already advances the count epoch when a
-- company crosses that boundary, but other legitimate company writers can
-- update email_provider_type directly. Cover every writer at the table
-- boundary without invalidating non-semantic provider classification changes.

set local lock_timeout = '5s';

drop trigger if exists trg_client_counts_companies_seg_boundary on public.companies;
create trigger trg_client_counts_companies_seg_boundary
  after update of email_provider_type on public.companies
  for each row
  when ((old.email_provider_type = 'SEG') is distinct from (new.email_provider_type = 'SEG'))
  execute function public.bump_data_version_client_counts();

-- Fail the migration if PostgreSQL did not retain the narrow trigger shape.
do $$
declare
  v_trigger pg_trigger%rowtype;
  v_email_provider_attnum smallint;
  v_when text;
begin
  select * into v_trigger
    from pg_trigger
   where tgrelid = 'public.companies'::regclass
     and tgname = 'trg_client_counts_companies_seg_boundary'
     and not tgisinternal;
  if not found then
    raise exception 'SEG client-count invalidation trigger was not created';
  end if;

  select attnum into v_email_provider_attnum
    from pg_attribute
   where attrelid = 'public.companies'::regclass
     and attname = 'email_provider_type'
     and not attisdropped;

  if v_trigger.tgenabled <> 'O'
     or (v_trigger.tgtype & 1) = 0
     or (v_trigger.tgtype & 2) <> 0
     or (v_trigger.tgtype & 16) = 0
     or (v_trigger.tgtype & 44) <> 0 then
    raise exception 'SEG client-count invalidation trigger is not an enabled AFTER UPDATE row trigger';
  end if;
  if v_email_provider_attnum is null
     or cardinality(v_trigger.tgattr::smallint[]) <> 1
     or not (v_email_provider_attnum = any(v_trigger.tgattr::smallint[])) then
    raise exception 'SEG client-count invalidation trigger is not restricted to email_provider_type';
  end if;
  if v_trigger.tgfoid <> 'public.bump_data_version_client_counts()'::regprocedure then
    raise exception 'SEG client-count invalidation trigger calls the wrong function';
  end if;

  v_when := lower(pg_get_triggerdef(v_trigger.oid, true));
  if v_when is null
     or position('old.email_provider_type' in v_when) = 0
     or position('new.email_provider_type' in v_when) = 0
     or position('is distinct from' in v_when) = 0
     or position('''seg''' in v_when) = 0 then
    raise exception 'SEG client-count invalidation trigger lost its boundary transition guard';
  end if;
end $$;
