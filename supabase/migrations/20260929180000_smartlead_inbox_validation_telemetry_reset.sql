-- A successful validation starts a fresh scan for the connected account.
-- Clear account-level progress here as well as during rotation because an API
-- key may have been rotated before account-scoped telemetry was introduced.
create or replace function public.confirm_smartlead_inbox_contract_v2(
  p_actor text,p_generation uuid,p_contract text,p_categories jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare s prospect_integrations.smartlead_inbox_settings%rowtype;
  c public.integration_connections%rowtype;
begin
  if p_contract not in ('official-v1','observed-flat-v1') then return false; end if;
  select * into s from prospect_integrations.smartlead_inbox_settings where singleton for update;
  select * into c from public.integration_connections where provider='smartlead' for share;
  if not found or not c.connected or c.generation is distinct from p_generation then return false; end if;
  perform 1 from prospect_integrations.smartlead_inbox_actions
    where connection_generation=p_generation and status in ('pending','applying') order by id for update;
  if not prospect_integrations.replace_smartlead_inbox_categories_v1(p_generation,p_categories) then return false; end if;
  update prospect_integrations.smartlead_inbox_actions set status='needs_review',attempt_token=null,lease_until=null,
    last_error_code='categories_revalidated'
    where connection_generation=p_generation and status in ('pending','applying');
  update prospect_integrations.smartlead_inbox_settings set verified_generation=p_generation,verified_contract=p_contract,
    verified_at=now(),enabled=false,status='paused',initial_backfill_complete=false,scan_cycle=gen_random_uuid(),
    scan_mode='full',scan_offset=0,scan_from=null,scan_to=null,incremental_cursor=null,next_full_sync_at=now(),
    next_sync_at='infinity',lease_token=null,lease_until=null,last_error_code=null,
    pages_scanned=0,rows_observed=0,last_synced_at=null,
    updated_by=left(coalesce(p_actor,''),300),updated_at=now() where singleton;
  return true;
end $$;

-- One-time repair for a key rotated before account-scoped telemetry shipped.
-- This is deliberately narrow and idempotent: the current connection must be
-- validated but paused, have no observations, and show progress older than
-- that validation. Historical observations and actions are not modified.
update prospect_integrations.smartlead_inbox_settings s
set pages_scanned=0,
    rows_observed=0,
    last_synced_at=null,
    updated_at=now()
from public.integration_connections c
where s.singleton
  and c.provider='smartlead'
  and c.connected
  and not s.enabled
  and s.verified_generation=c.generation
  and s.verified_at is not null
  and s.last_synced_at is not null
  and s.last_synced_at<s.verified_at
  and not exists (
    select 1
    from prospect_integrations.smartlead_inbox_observations o
    where o.connection_generation=c.generation
  );

revoke execute on function public.confirm_smartlead_inbox_contract_v2(text,uuid,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.confirm_smartlead_inbox_contract_v2(text,uuid,text,jsonb)
  to service_role;
