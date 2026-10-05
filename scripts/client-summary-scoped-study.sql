-- REJECTED DIAGNOSTIC CANDIDATE ONLY. This aggregate is not used by the
-- migration or runtime: it measured about 1,866 ms versus about 363 ms for the
-- existing scoped view on the same bounded production read.
\set ON_ERROR_STOP on

set statement_timeout = '5s';
set lock_timeout = '1s';

-- Read-only production diagnostic for the single-client cache-miss path of
-- client_summaries_v1. Invoke with:
--   psql ... -v client_id='the-client-id' -f scripts/client-summary-scoped-study.sql
--
-- The candidate deliberately reads canonical prospects/companies rather than
-- prospect_index. It preserves companyless active people, all blocked people,
-- the both-fields-blank incomplete rule, and per-client SEG discard policy.
begin read only;
set local statement_timeout = '5s';

with requested_client as (
  select c.id,
    coalesce((select cs.seg_emails = 'discard'
                from public.client_settings cs
               where cs.client_id = c.id), false) as discard_seg
  from public.clients c
  where c.id = :'client_id'
), candidate_people as (
  select cp.client_id,
    count(*) filter (
      where cp.status = 'active'
        and not (
          p.company_id is not null
          and co.id is not null
          and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
          and btrim(coalesce(co.short_description, '')) = ''
        )
        and not (
          rc.discard_seg
          and co.id is not null
          and co.email_provider_type is not distinct from 'SEG'
          and not (
            btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''
          )
        )
    )::integer as prospect_count,
    count(*) filter (
      where cp.status = 'active'
        and cp.icp_verified
        and not (
          p.company_id is not null
          and co.id is not null
          and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
          and btrim(coalesce(co.short_description, '')) = ''
        )
        and not (
          rc.discard_seg
          and co.id is not null
          and co.email_provider_type is not distinct from 'SEG'
          and not (
            btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''
          )
        )
    )::integer as icp_verified_count,
    count(*) filter (where cp.status = 'blocked')::integer as blocked_count
  from requested_client rc
  left join public.client_prospects cp on cp.client_id = rc.id
  left join public.prospects p on p.id = cp.prospect_id
  left join public.companies co on co.id = p.company_id
  group by cp.client_id
), candidate_companies as (
  select cc.client_id,
    count(*) filter (
      where not (
        co.id is not null
        and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
        and btrim(coalesce(co.short_description, '')) = ''
      )
      and not (
        rc.discard_seg
        and co.id is not null
        and co.email_provider_type is not distinct from 'SEG'
        and not (
          btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
          and btrim(coalesce(co.short_description, '')) = ''
        )
      )
    )::integer as company_count
  from requested_client rc
  left join public.client_companies cc on cc.client_id = rc.id
  left join public.companies co on co.id = cc.company_id
  group by cc.client_id
), candidate as (
  select rc.id,
    coalesce(cp.prospect_count, 0) as prospect_count,
    coalesce(cp.icp_verified_count, 0) as icp_verified_count,
    coalesce(cp.blocked_count, 0) as blocked_count,
    coalesce(cc.company_count, 0) as company_count
  from requested_client rc
  left join candidate_people cp on cp.client_id = rc.id
  left join candidate_companies cc on cc.client_id = rc.id
)
select candidate.*,
  candidate.prospect_count = baseline.prospect_count
    and candidate.icp_verified_count = baseline.icp_verified_count
    and candidate.blocked_count = baseline.blocked_count
    and candidate.company_count = baseline.company_count as exact_parity
from candidate
join public.client_summaries baseline using (id);

explain (analyze, buffers, settings, summary, format text)
with requested_client as (
  select c.id,
    coalesce((select cs.seg_emails = 'discard'
                from public.client_settings cs
               where cs.client_id = c.id), false) as discard_seg
  from public.clients c
  where c.id = :'client_id'
), people as (
  select cp.client_id,
    count(*) filter (
      where cp.status = 'active'
        and not (p.company_id is not null and co.id is not null
          and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
          and btrim(coalesce(co.short_description, '')) = '')
        and not (rc.discard_seg and co.id is not null
          and co.email_provider_type is not distinct from 'SEG'
          and not (btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''))
    )::integer as prospect_count,
    count(*) filter (
      where cp.status = 'active' and cp.icp_verified
        and not (p.company_id is not null and co.id is not null
          and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
          and btrim(coalesce(co.short_description, '')) = '')
        and not (rc.discard_seg and co.id is not null
          and co.email_provider_type is not distinct from 'SEG'
          and not (btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''))
    )::integer as icp_verified_count,
    count(*) filter (where cp.status = 'blocked')::integer as blocked_count
  from requested_client rc
  left join public.client_prospects cp on cp.client_id = rc.id
  left join public.prospects p on p.id = cp.prospect_id
  left join public.companies co on co.id = p.company_id
  group by cp.client_id
), companies as (
  select cc.client_id,
    count(*) filter (
      where not (co.id is not null
        and btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
        and btrim(coalesce(co.short_description, '')) = '')
      and not (rc.discard_seg and co.id is not null
        and co.email_provider_type is not distinct from 'SEG'
        and not (btrim(coalesce(public.tag_array_text_v1(co.keywords), '')) = ''
          and btrim(coalesce(co.short_description, '')) = ''))
    )::integer as company_count
  from requested_client rc
  left join public.client_companies cc on cc.client_id = rc.id
  left join public.companies co on co.id = cc.company_id
  group by cc.client_id
)
select rc.id,
  coalesce(p.prospect_count, 0),
  coalesce(p.icp_verified_count, 0),
  coalesce(p.blocked_count, 0),
  coalesce(c.company_count, 0)
from requested_client rc
left join people p on p.client_id = rc.id
left join companies c on c.client_id = rc.id;

rollback;
