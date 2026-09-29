-- What the Smartlead reply sync added to which client's blocklist, and why.
--
-- The Reply blocklist page showed totals (1,117 block actions applied on
-- 2026-09-30) but not what they were. Each action already records the client,
-- the value (an email, or a domain for "Not the right fit"), and the Smartlead
-- category that caused it - that category is the reason - and joins to the
-- reply observation for the campaign and reply time. This reads them back:
--
--   summary  per client: emails and domains blocked, reasons, last block
--   reasons  per Smartlead category, for the filter
--   rows     one page of the activity log, newest first
--
-- Scoped to the current Smartlead connection generation, like
-- smartlead_inbox_status_v1: a replaced account's history is kept but not
-- shown. Read-only.
-- ---------------------------------------------------------------------------

set local lock_timeout = '5s';

create or replace function public.smartlead_reply_blocks_v1(
  p_client_id text default null,
  p_category_id integer default null,
  p_kind text default null,
  p_search text default '',
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language sql
stable
security definer
set search_path = ''
set statement_timeout = '15s'
as $$
with current_connection as (
  select generation from public.integration_connections where provider = 'smartlead'
),
blocks as (
  select a.id, a.client_id, cl.name as client_name, a.kind, a.value, a.status, a.category_id,
         coalesce(k.category_name, 'Category ' || a.category_id) as reason,
         o.campaign_name, o.email as reply_email, o.reply_time,
         a.created_at, a.applied_at
    from prospect_integrations.smartlead_inbox_actions a
    join current_connection cc on cc.generation = a.connection_generation
    join public.clients cl on cl.id = a.client_id
    left join prospect_integrations.smartlead_inbox_observations o
      on o.connection_generation = a.connection_generation and o.provider_key = a.provider_key
    left join prospect_integrations.smartlead_inbox_categories k
      on k.connection_generation = a.connection_generation and k.category_id = a.category_id
),
filtered as (
  select * from blocks b
   where (p_client_id is null or p_client_id = '' or b.client_id = p_client_id)
     and (p_category_id is null or b.category_id = p_category_id)
     and (p_kind is null or p_kind = '' or b.kind = p_kind)
     and (coalesce(btrim(p_search), '') = ''
          or b.value ilike '%' || btrim(p_search) || '%'
          or b.campaign_name ilike '%' || btrim(p_search) || '%'
          or b.reply_email ilike '%' || btrim(p_search) || '%')
)
select jsonb_build_object(
  'summary', coalesce((
    select jsonb_agg(s order by s.total desc, s.client_name)
      from (
        select b.client_id, b.client_name,
               count(*) filter (where b.status = 'applied') as total,
               count(*) filter (where b.status = 'applied' and b.kind = 'email') as emails,
               count(*) filter (where b.status = 'applied' and b.kind = 'domain') as domains,
               count(*) filter (where b.status in ('pending', 'applying')) as pending,
               count(*) filter (where b.status = 'manual_removed') as removed,
               max(b.applied_at) as last_applied_at,
               (select jsonb_agg(r order by r.count desc, r.reason)
                  from (select x.reason, count(*) as count from blocks x
                         where x.client_id = b.client_id and x.status = 'applied'
                         group by x.reason) r) as reasons
          from blocks b
         group by b.client_id, b.client_name) s), '[]'::jsonb),
  'reasons', coalesce((
    select jsonb_agg(r order by r.count desc, r.reason)
      from (select b.category_id, b.reason, count(*) as count
              from blocks b
             where p_client_id is null or p_client_id = '' or b.client_id = p_client_id
             group by b.category_id, b.reason) r), '[]'::jsonb),
  'total', (select count(*) from filtered),
  'rows', coalesce((
    select jsonb_agg(to_jsonb(f) - 'id' - 'category_id' order by f.sort_at desc, f.value)
      from (select *, coalesce(applied_at, created_at) as sort_at from filtered
             order by coalesce(applied_at, created_at) desc, value
             limit greatest(1, least(coalesce(p_limit, 50), 5000))
            offset greatest(0, coalesce(p_offset, 0))) f), '[]'::jsonb)
);
$$;

revoke execute on function public.smartlead_reply_blocks_v1(text, integer, text, text, integer, integer) from public, anon, authenticated;
grant execute on function public.smartlead_reply_blocks_v1(text, integer, text, text, integer, integer) to service_role;

-- Proof: it answers against the live data, and a filter can only narrow it.
do $$
declare
  v_all jsonb := public.smartlead_reply_blocks_v1();
  v_domains jsonb := public.smartlead_reply_blocks_v1(null, null, 'domain');
begin
  if (v_domains->>'total')::int > (v_all->>'total')::int then
    raise exception 'reply blocks proof: a filter widened the log (% > %)', v_domains->>'total', v_all->>'total';
  end if;
  raise notice 'Reply block activity: % actions, % clients, % reasons.',
    v_all->>'total', jsonb_array_length(v_all->'summary'), jsonb_array_length(v_all->'reasons');
end $$;
