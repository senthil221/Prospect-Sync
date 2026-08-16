-- Keep privileged company count maintenance behind the server-side service role.
revoke execute on function public.recompute_company_counts(text) from public, anon, authenticated;
revoke execute on function public.sync_company_counts_from_index() from public, anon, authenticated;

grant execute on function public.recompute_company_counts(text) to service_role;
grant execute on function public.sync_company_counts_from_index() to service_role;

-- Functions created by the migration owner must be exposed explicitly.
alter default privileges for role postgres in schema public
  revoke execute on functions from public;
