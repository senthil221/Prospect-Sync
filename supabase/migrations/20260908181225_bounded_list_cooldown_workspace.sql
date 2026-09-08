-- Resolve list membership before hydrating records. The old workspace joined
-- the whole aggregating prospect_summaries view before limiting the page.
create or replace function public.list_workspace(
  p_list_id text,p_search text default '',p_limit integer default 50,p_offset integer default 0
)
returns table(result_rows jsonb,total_count bigint)
language plpgsql stable security definer set search_path='' set statement_timeout='30s'
as $fn$
declare v_search text:=btrim(coalesce(p_search,'')); v_match text:='true';
begin
  if v_search<>'' then
    v_match:=format($where$
      (concat_ws(' ',pi.full_name,pi.work_email,pi.title,pi.company_name) ilike %1$L
       or exists(select 1 from public.list_rows lr
         where lr.list_id=lm.list_id and lr.prospect_id=lm.prospect_id and lr.import_id=lm.import_id
           and lr.raw_data::text ilike %1$L))
    $where$,'%'||v_search||'%');
  end if;
  return query execute format($sql$
    with matched as materialized (
      select lm.prospect_id,lm.import_id,lm.imported_at
      from public.list_memberships lm
      join public.prospect_index pi on pi.id=lm.prospect_id
      where lm.list_id=$1 and (%1$s)
    ), page as (
      select * from matched order by imported_at desc,prospect_id limit $2 offset $3
    ), hydrated as (
      select page.imported_at,page.prospect_id,
        to_jsonb(pi)||jsonb_build_object('list_data',coalesce(source.raw_data,'{}'::jsonb),
          'imported_at',page.imported_at,'client_date_contacted',cp.date_added,
          'last_contacted_at',cp.date_added::timestamp at time zone 'UTC',
          'next_eligible_at',cp.date_added+coalesce(settings.cooldown_days,90),
          'eligible',cp.date_added is null or cp.date_added+coalesce(settings.cooldown_days,90)<=(now() at time zone 'UTC')::date) as row_data
      from page join public.prospect_index pi on pi.id=page.prospect_id
      join public.lists l on l.id=$1
      left join public.client_prospects cp on cp.client_id=l.client_id and cp.prospect_id=page.prospect_id
      left join public.client_settings settings on settings.client_id=l.client_id
      left join lateral (
        select lr.raw_data from public.list_rows lr
        where lr.list_id=$1 and lr.prospect_id=page.prospect_id and lr.import_id=page.import_id
        order by lr.id desc limit 1
      ) source on true
    ) select coalesce((select jsonb_agg(row_data order by imported_at desc,prospect_id) from hydrated),'[]'::jsonb),
      (select count(*) from matched)
  $sql$,v_match) using p_list_id,greatest(1,least(coalesce(p_limit,50),100)),greatest(0,coalesce(p_offset,0));
end;
$fn$;
revoke execute on function public.list_workspace(text,text,integer,integer) from public,anon,authenticated;
grant execute on function public.list_workspace(text,text,integer,integer) to service_role;
