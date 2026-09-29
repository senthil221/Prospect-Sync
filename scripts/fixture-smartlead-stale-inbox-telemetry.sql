-- Reproduce an account key that was rotated and validated before telemetry
-- became account-scoped. The following migration must repair this state while
-- leaving historical inbox ledgers untouched.
update public.integration_connections
set connected=true,
    credential_ciphertext='fixture-stale-telemetry',
    generation='10000000-0000-4000-8000-000000000001'::uuid
where provider='smartlead';

update prospect_integrations.smartlead_inbox_settings
set enabled=false,
    status='paused',
    verified_generation='10000000-0000-4000-8000-000000000001'::uuid,
    verified_contract='official-v1',
    verified_at=now(),
    pages_scanned=267,
    rows_observed=4214,
    last_synced_at=now()-interval '1 hour'
where singleton;
