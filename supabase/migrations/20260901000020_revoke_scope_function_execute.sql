-- Forward-only correction to 20260901000010.
--
-- That migration replaced three SECURITY DEFINER functions and granted EXECUTE to
-- service_role without revoking it from public, anon and authenticated. CI caught
-- it (check-migrations.mjs), but only after the file had already been pushed and
-- applied to production, and applied migration files are immutable -- so the
-- revokes arrive here instead of being edited into the original.
--
-- Nothing was ever exposed. CREATE OR REPLACE FUNCTION preserves an existing
-- function's ACL, so on every database that already had these functions the
-- earlier revokes survived; production was verified directly before this was
-- written:
--
--   company_scope_ids_v2           postgres=X/postgres | service_role=X/postgres
--   search_prospect_workspace_v12  postgres=X/postgres | service_role=X/postgres
--   search_prospect_export_v4      postgres=X/postgres | service_role=X/postgres
--
-- The exposure was latent, not live: migrate.sh replays every migration onto a
-- fresh database, where those same statements create the functions from nothing
-- and they inherit the default PUBLIC EXECUTE. That would put three
-- definer-rights functions in reach of anon, whose key is compiled into the
-- client bundle and is only harmless because nothing is granted to it.
--
-- These statements are idempotent: a no-op where the grants are already correct,
-- and the fix anywhere they are not.

begin;

revoke execute on function public.company_scope_ids_v2(text, jsonb) from public, anon, authenticated;
revoke execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean) from public, anon, authenticated;

grant execute on function public.company_scope_ids_v2(text, jsonb) to service_role;
grant execute on function public.search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean) to service_role;
grant execute on function public.search_prospect_export_v4(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean) to service_role;

commit;
