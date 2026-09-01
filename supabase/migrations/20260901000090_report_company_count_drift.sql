-- Make drift in the denormalized company counts detectable.
--
-- companies.prospect_count and client_count are stored columns maintained by the
-- statement-level trigger on prospect_index (20260815010000), and reads depend on
-- them: company_summaries, the client company listing since 20260901000060, and
-- the Companies tab's linked-prospect total since 20260901000050. That is the
-- right design -- live aggregation of these numbers measured 26 seconds -- but it
-- moves the failure mode. A stored count that stops being maintained does not get
-- slow, it gets quietly wrong, and every surface reading it then reports a
-- plausible number nobody thinks to question.
--
-- They agreed exactly when checked by hand (0 of 418,151 companies disagreed),
-- but that was a point-in-time check by someone who happened to look. This makes
-- it standing, on the page that already exists for it: the index health panel is
-- fed by prospect_index_drift, so the count check joins it rather than inventing
-- a second mechanism. Re-indexing is also what repairs drift, since the trigger
-- recomputes on write, so the existing "Re-index now" button is already the fix.
--
-- Sampled, not exhaustive, and named so in the payload. Checking every company
-- costs 55s cold on this database -- the per-company aggregate has to unnest
-- client_ids across all 674,804 prospects -- which is far too slow for a page
-- load, and it would run past this function's own statement_timeout without
-- stopping, because a SET inside a function does not re-arm a timer the statement
-- already started. A 2,000-company sample costs 3.2s and answers the question
-- that matters: a trigger that has stopped firing drifts companies wholesale, and
-- at that rate a sample this size finds it with near-certainty. Isolated
-- single-company drift can slip through, and that is the accepted trade.
--
-- The aggregate mirrors recompute_company_counts_bulk exactly, because "drifted"
-- has to mean "differs from what the maintainer would write", not "differs from
-- some other reasonable definition of the same word".

begin;

CREATE OR REPLACE FUNCTION public.prospect_index_drift()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
  select jsonb_build_object(
    'prospects', (select count(*) from public.prospects),
    'indexed', (select count(*) from public.prospect_index),
    'missingFromIndex', (
      select count(*) from (
        select 1 from public.prospects p
        where not exists (select 1 from public.prospect_index pi where pi.id = p.id)
        limit 10000
      ) sample
    ),
    'staleInIndex', (
      select count(*) from (
        select 1 from public.prospects p
        join public.prospect_index pi on pi.id = p.id
        where pi.updated_at < p.updated_at
        limit 10000
      ) sample
    ),
    'queued', (select count(*) from public.reindex_backlog),
    'queuedFailing', (select count(*) from public.reindex_backlog where attempts > 0),
    'oldestQueuedAt', (select min(enqueued_at) from public.reindex_backlog),
    'companies', (select count(*) from public.companies),
    'companyCountsSampled', 2000,
    -- Companies in the sample whose stored prospect_count or client_count differs
    -- from what recompute_company_counts_bulk would write for them right now.
    'companyCountsDrifted', (
      with sample as (
        select id, prospect_count, client_count
        from public.companies
        order by random()
        limit 2000
      )
      select count(*)
      from sample s
      left join lateral (
        select count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) as cid on true
        where pi.company_id = s.id
      ) agg on true
      where s.prospect_count is distinct from coalesce(agg.prospect_count, 0)
         or s.client_count is distinct from coalesce(agg.client_count, 0)
    )
  );
$function$;

revoke execute on function public.prospect_index_drift() from public, anon, authenticated;
grant execute on function public.prospect_index_drift() to service_role;

commit;
