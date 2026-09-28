-- Source-first Recently Added listing. The current UI always requests a
-- rolling 48-hour window; p_hours remains explicit so older callers can keep
-- their established windows through client_recent_batches_v1.

create or replace function public.client_recent_batches_v2(
  p_client_id text,
  p_search text default '',
  p_entity text default '',
  p_source text default 'all',
  p_hours integer default 48,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(result_rows jsonb, total_count bigint)
language sql
stable
security invoker
set search_path = ''
set statement_timeout = '20s'
as $function$
  with matched as materialized (
    select b.id, b.entity_type, b.source_kind, b.source_label, b.outcome_kind,
      b.source_client_id, source_client.name as source_client_name,
      b.created_at, b.completed_at,
      count(i.entity_id)::bigint as record_count
    from public.client_addition_batches b
    left join public.client_addition_batch_items i on i.batch_id = b.id
    left join public.clients source_client on source_client.id = b.source_client_id
    where b.client_id = p_client_id
      and (coalesce(p_entity, '') = '' or b.entity_type = p_entity)
      and b.created_at >= now() - pg_catalog.make_interval(
        hours => greatest(1, least(coalesce(p_hours, 48), 48)))
      and (
        coalesce(p_source, 'all') = 'all'
        or (
          b.source_kind = p_source
          and b.outcome_kind <> 'historical_source_unavailable'
        )
      )
      and (
        btrim(coalesce(p_search, '')) = ''
        or b.source_label ilike '%' || p_search || '%'
        or source_client.name ilike '%' || p_search || '%'
        or exists (
          select 1
          from public.client_addition_batch_items searched
          left join public.prospect_index pi
            on b.entity_type = 'people' and pi.id = searched.entity_id
          left join public.companies co
            on b.entity_type = 'companies' and co.id = searched.entity_id
          where searched.batch_id = b.id
            and (
              pi.search_text ilike '%' || p_search || '%'
              or co.name ilike '%' || p_search || '%'
              or co.domain ilike '%' || p_search || '%'
            )
        )
      )
    group by b.id, source_client.name
  ), page_rows as (
    select *
    from matched
    order by created_at desc, id desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select
    coalesce(
      (select jsonb_agg(to_jsonb(page_rows) order by created_at desc, id desc)
       from page_rows),
      '[]'::jsonb
    ),
    (select count(*) from matched);
$function$;

revoke execute on function public.client_recent_batches_v2(
  text, text, text, text, integer, integer, integer
) from public, anon, authenticated;
grant execute on function public.client_recent_batches_v2(
  text, text, text, text, integer, integer, integer
) to service_role;
