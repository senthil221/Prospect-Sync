-- The ICP validator's default models, chosen by the team.
--
-- The three models pre-ticked in "New check" and "Validate ICP" were fixed in
-- code (worker/icp-validator-core.mjs ICP_MODELS). This stores the team's own
-- choice - one to three OpenRouter model slugs - in one row. The app validates
-- the slugs against OpenRouter's catalog before saving; with no row, the
-- built-in three still apply. Nothing reads this but the app.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create table if not exists public.icp_validator_settings (
  id boolean primary key default true check (id),
  default_models text[] not null
    check (cardinality(default_models) between 1 and 3
           and array_position(default_models, null) is null),
  updated_by text not null default '',
  updated_at timestamptz not null default now()
);

comment on table public.icp_validator_settings is
  'One row: the OpenRouter models pre-selected for ICP checks. Absent = the built-in defaults.';

alter table public.icp_validator_settings enable row level security;
revoke all on public.icp_validator_settings from public, anon, authenticated;
grant select, insert, update, delete on public.icp_validator_settings to service_role;
