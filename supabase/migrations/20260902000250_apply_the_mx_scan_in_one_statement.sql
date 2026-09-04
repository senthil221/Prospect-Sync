-- Write an MX scan batch in one statement instead of one per company.
--
-- app/api/email-providers/scan/route.ts looks up DNS for up to 25 companies in
-- parallel, then issues a separate UPDATE for each result. pg_stat_statements
-- has the shape of it:
--
--   UPDATE companies SET email_provider_type = ...
--     calls 44,185 · mean 5 ms · max 4,031 ms · total 224 s
--
-- Forty-four thousand statements, each a round trip, a transaction, and -- per
-- the audit's finding 02 -- a rewrite of all 23 indexes on companies, because
-- mx_checked_at sits in idx_companies_pending_mx_scan's predicate and no update
-- touching it can ever be HOT.
--
-- The DNS lookups are the honest cost here and they stay exactly as they are,
-- in parallel, in the route. This only collapses the writes that follow them.
--
-- Returns the number of rows actually updated so the caller can still report
-- "checked 25, updated 24" rather than assuming its own success. A company
-- deleted between the SELECT and the write simply is not in the count, which is
-- the same outcome the per-row version produced.

begin;

create or replace function public.apply_email_provider_scan_v1(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_updated integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return 0;
  end if;

  update public.companies c
  set esp = scanned.esp,
      email_provider_type = scanned.email_provider_type,
      mx_records = scanned.mx_records,
      mx_status = scanned.mx_status,
      mx_checked_at = scanned.mx_checked_at
  from jsonb_to_recordset(p_rows) as scanned(
    id text,
    esp text,
    email_provider_type text,
    mx_records text[],
    mx_status text,
    mx_checked_at timestamptz
  )
  where c.id = scanned.id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$function$;

comment on function public.apply_email_provider_scan_v1(jsonb) is
  'Applies one MX/ESP scan batch to public.companies in a single UPDATE. Replaces one statement per company; see 20260902000250.';

revoke execute on function public.apply_email_provider_scan_v1(jsonb) from public, anon, authenticated;
grant execute on function public.apply_email_provider_scan_v1(jsonb) to service_role;

commit;
