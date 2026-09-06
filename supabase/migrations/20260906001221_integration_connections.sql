-- Server-only singleton connections for this agency. Never expose ciphertext
-- through browser-role grants. Master encryption key is outside the database.
create table public.integration_connections (
  provider text primary key check (provider in ('smartlead','verifier')),
  credential_ciphertext text check (length(credential_ciphertext) between 1 and 8192),
  connected boolean not null default false,
  checked_at timestamptz,
  updated_by text,
  attempt_token uuid,
  next_request_at timestamptz not null default '-infinity',
  check (not connected or credential_ciphertext is not null)
);
alter table public.integration_connections enable row level security;
revoke all on public.integration_connections from public, anon, authenticated;
grant select, update on public.integration_connections to service_role;
insert into public.integration_connections(provider) values ('smartlead'),('verifier');

-- Atomic cross-process limiter for connection checks/campaign reads, not the
-- eventual dispatch limiter. No DB lock is held across the provider request.
create function public.reserve_integration_read_v1(p_provider text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_token uuid;
begin
  update public.integration_connections
     set attempt_token=gen_random_uuid(), next_request_at=clock_timestamp()+interval '15 seconds'
   where provider=p_provider and next_request_at<=clock_timestamp()
   returning attempt_token into v_token;
  return v_token;
end;
$$;
revoke execute on function public.reserve_integration_read_v1(text) from public, anon, authenticated;
grant execute on function public.reserve_integration_read_v1(text) to service_role;
