-- The three blocklist trigger functions from 20260924090000 are not callable
-- by the API roles.
--
-- They are SECURITY DEFINER, and Postgres grants EXECUTE on a new function to
-- PUBLIC. 20260924090000 revoked it from its callable helpers but not from its
-- three trigger functions, so the migration guard (check-migrations.mjs) failed
-- CI and the deploy stopped before anything reached production. That file is
-- immutable once committed, so the revokes land here, in the same deploy: the
-- runner applies both in order and the end state is what one file would have
-- produced. A trigger function cannot be invoked as a plain call anyway; the
-- revoke keeps the rule without exceptions.

revoke execute on function public.divert_blocked_client_company_v1() from public, anon, authenticated;
revoke execute on function public.block_company_on_domain_change_v1() from public, anon, authenticated;
revoke execute on function public.block_prospect_on_identity_change_v1() from public, anon, authenticated;

do $$
declare
  v_fn text;
begin
  foreach v_fn in array array[
    'public.divert_blocked_client_company_v1()',
    'public.block_company_on_domain_change_v1()',
    'public.block_prospect_on_identity_change_v1()'] loop
    if has_function_privilege('anon', v_fn, 'execute')
       or has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception '% is still executable by an API role', v_fn;
    end if;
  end loop;
end $$;
