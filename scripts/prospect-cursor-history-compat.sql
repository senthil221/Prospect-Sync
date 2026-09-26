-- CI-only compatibility assertion for one reviewed historical migration drift.
-- The runner substitutes exactly "pre" or "post" for the phase token below.
-- This file is never applied to production and never changes migration history.
do $history_compat$
declare
  v_phase constant text := '__COMPAT_PHASE__';
  v_proc record;
begin
  if v_phase = 'pre' then
    select
      p.proargnames,
      p.proargmodes,
      p.proallargtypes,
      p.prorettype,
      p.proretset,
      p.prosecdef
    into v_proc
    from pg_catalog.pg_proc p
    where p.oid = pg_catalog.to_regprocedure(
      'public.import_company_batch_v2(text,jsonb)'
    );

    if not found then
      raise exception 'reviewed obsolete company import overload is missing';
    end if;
    if v_proc.proargnames is distinct from
       array['p_import_id', 'p_rows', 'processed', 'added', 'updated', 'skipped']::text[]
       or v_proc.proargmodes is distinct from
       array['i'::"char", 'i'::"char", 't'::"char", 't'::"char", 't'::"char", 't'::"char"]
       or v_proc.proallargtypes is distinct from
       array[
         'text'::pg_catalog.regtype::oid,
         'jsonb'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid
       ]::oid[]
       or v_proc.prorettype <> 'record'::pg_catalog.regtype::oid
       or not v_proc.proretset
       or not v_proc.prosecdef then
      raise exception 'obsolete company import overload no longer matches the reviewed precondition';
    end if;

    -- RESTRICT is deliberate: any new dependency makes the exception fail closed.
    drop function public.import_company_batch_v2(text, jsonb) restrict;

    if pg_catalog.to_regprocedure('public.import_company_batch_v2(text,jsonb)') is not null then
      raise exception 'obsolete company import overload was not removed';
    end if;
  elsif v_phase = 'post' then
    if pg_catalog.to_regprocedure('public.import_company_batch_v2(text,jsonb)') is not null then
      raise exception 'obsolete two-argument company import overload survived the forward fix';
    end if;

    select
      p.proargnames,
      p.proargmodes,
      p.proallargtypes,
      p.prorettype,
      p.proretset,
      p.prosecdef
    into v_proc
    from pg_catalog.pg_proc p
    where p.oid = pg_catalog.to_regprocedure(
      'public.import_company_batch_v2(text,jsonb,integer)'
    );

    if not found then
      raise exception 'active resumable company import function is missing after forward fix';
    end if;
    if v_proc.proargnames is distinct from
       array['p_import_id', 'p_rows', 'p_row_offset', 'processed', 'added', 'updated', 'skipped']::text[]
       or v_proc.proargmodes is distinct from
       array[
         'i'::"char", 'i'::"char", 'i'::"char",
         't'::"char", 't'::"char", 't'::"char", 't'::"char"
       ]
       or v_proc.proallargtypes is distinct from
       array[
         'text'::pg_catalog.regtype::oid,
         'jsonb'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid,
         'integer'::pg_catalog.regtype::oid
       ]::oid[]
       or v_proc.prorettype <> 'record'::pg_catalog.regtype::oid
       or not v_proc.proretset
       or not v_proc.prosecdef then
      raise exception 'active resumable company import contract drifted after forward fix';
    end if;

    if pg_catalog.has_function_privilege(
         'anon', 'public.import_company_batch_v2(text,jsonb,integer)', 'execute'
       )
       or pg_catalog.has_function_privilege(
         'authenticated', 'public.import_company_batch_v2(text,jsonb,integer)', 'execute'
       ) then
      raise exception 'active company import function is exposed to browser roles';
    end if;
    if not pg_catalog.has_function_privilege(
      'service_role', 'public.import_company_batch_v2(text,jsonb,integer)', 'execute'
    ) then
      raise exception 'service_role cannot execute the active company import function';
    end if;
  else
    raise exception 'unknown history compatibility phase: %', v_phase;
  end if;
end
$history_compat$;
