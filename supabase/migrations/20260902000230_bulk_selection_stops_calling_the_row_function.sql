-- "Select all matching" was calling the per-row matcher, and had been all along.
--
-- FOUND BY AUDITING the other entry points after "See People" turned out to have
-- missed the plan chooser. resolve_company_action_selection_v1 is what turns
-- "select everything this filter matches" into the id list a bulk action works
-- on -- push to client, ICP validate, delete. On the reported 51-keyword filter:
--
--   resolve_company_action_selection_v1   38,448 ids in 242,483 ms
--
-- against SET statement_timeout '30s'. Four minutes for a thirty second budget:
-- not slow, dead. Every bulk action over a filtered selection has been failing
-- on any filter of this size.
--
-- WHY. It is the last caller left applying
-- public.company_matches_filters_v1(c, ...) as its primary predicate -- a
-- plpgsql function invoked once per row, 419,214 times, none of it inlinable or
-- indexable. Everything else moved to the translated SQL predicate over the
-- course of 20260901000080 and 20260902000190; this one was missed because it
-- has no listing of its own to be slow in.
--
-- AND IT WAS ANSWERING A DIFFERENT QUESTION. The row function is a separate
-- implementation of the same filter, so 20260902000210's case fix never reached
-- it: it returned 38,448 ids where the listing showed 41,057 for the identical
-- filter. A bulk action would have operated on a set the user could not see --
-- 2,609 companies short, silently. That is the worse half of this bug. Deleting
-- or pushing the wrong set is not a performance problem.
--
-- Both go away by asking company_full_scan_filter_sql_v1, the same chooser the
-- listing's count and the pivot's scope resolver use. Collecting every matching
-- id has no early exit, which is the full-scan case it exists for.
--
-- The row function stays as the fallback for filter shapes the translator cannot
-- express, exactly as it is everywhere else -- slow, but never wrong, and it is
-- what runs today for those shapes anyway.
--
-- NOT CHANGED HERE, checked and left alone: delete_companies_matching_v1 (300s)
-- and set_company_icp_validated_v1 (120s) already prefer the translated
-- predicate and fall back to the row function, so they carry the case fix and
-- sit inside their budgets. They are on the OR chain rather than the chooser,
-- which costs them speed and not correctness; moving them is a separate change
-- with its own measurements, and neither is currently failing.

begin;

-- Defaults preserved exactly; PostgREST resolves this function by argument name
-- and drops the ones a caller omits.
create or replace function public.resolve_company_action_selection_v1(
  p_client_id text default null::text,
  p_company_ids text[] default null::text[],
  p_search text default ''::text,
  p_filters jsonb default '[]'::jsonb,
  p_people_scope jsonb default null::jsonb,
  p_excluded_ids text[] default null::text[],
  p_limit integer default 250000
)
 returns table(company_id text)
 language plpgsql
 stable security definer
 set search_path to 'public'
 set statement_timeout to '30s'
as $function$
declare
  v_match text;
  v_limit text := greatest(1, least(coalesce(p_limit, 250000), 250000))::text;
  -- Everything except the match clause is identical between the two branches, so
  -- it is written once. The parameter numbering differs, which is why the two
  -- are executed separately rather than through one template with a gap in it.
  v_shell constant text := $q$
    select c.id
    from public.companies c
    where (%1$s is null or exists (
        select 1 from public.client_companies membership
        where membership.client_id = %1$s and membership.company_id = c.id
          and (membership.added_by not in ('membership-backfill', 'prospect-membership', 'prospect-company-change')
            or exists (select 1 from public.prospect_index pi where pi.company_id = c.id and pi.client_ids @> array[%1$s]))
      ))
      and (%2$s)
      and (%3$s is null or c.id in (select company_id from public.people_scope_company_ids_v1(%1$s, %3$s)))
      and not (c.id = any(%4$s))
    order by c.id
    limit %5$s
  $q$;
begin
  -- An explicit id list never consults the filters at all, so it never pays for
  -- them either.
  if p_company_ids is not null then
    return query execute
      format(v_shell, '$1', 'c.id = any($2[1:50000])', '$3', '$4', v_limit)
      using p_client_id, p_company_ids, p_people_scope, coalesce(p_excluded_ids, array[]::text[]);
    return;
  end if;

  -- Every matching id is wanted, so there is no early exit: the full-scan
  -- chooser, the same one filter_companies_v4 and company_scope_ids_v2 ask.
  v_match := coalesce(
    public.company_full_scan_filter_sql_v1(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)),
    format('public.company_matches_filters_v1(c, %L, %L::jsonb)',
      coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text));

  return query execute
    format(v_shell, '$1', v_match, '$2', '$3', v_limit)
    using p_client_id, p_people_scope, coalesce(p_excluded_ids, array[]::text[]);
end;
$function$;

revoke execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) from public, anon, authenticated;
grant execute on function public.resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer) to service_role;

commit;
