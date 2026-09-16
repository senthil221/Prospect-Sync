-- How many prospects and companies each of a client's ICPs has claimed.
--
-- WHY IT NEEDS A FUNCTION AT ALL. The ICPs screen lists a client's briefs, and
-- the one thing it could not say was whether any of them is being used. Without
-- that, "UK mid-market SaaS" and a brief somebody pasted in and abandoned look
-- exactly alike. The counts have to come from the link tables, and PostgREST
-- cannot group, so the alternative is one head-count request per ICP - fifty
-- round trips for a screen that opens on every client.
--
-- ONE ROW PER TAG, INCLUDING THE UNUSED ONES. A left-ish shape (the tag table
-- driving, the counts as scalar subqueries) rather than a join-and-group, so an
-- ICP that has never been applied reports 0 instead of vanishing from the list
-- - which is exactly the ICP the screen most needs to show.
--
-- BOTH ENTITIES, BECAUSE AN ICP IS ONE VOCABULARY. 20260915150000 gave
-- companies their own link table rather than a polymorphic one, so the same tag
-- id is counted in two places. Reading them together is the point: an ICP with
-- 400 companies and no people has been applied on the wrong side of the pivot.
--
-- BOUNDED, LIKE EVERY OTHER APP-CALLED FUNCTION. idx_tag_links_tag is
-- (tag_id, prospect_id) and the company index is the same shape, so each count
-- is an index-only scan - but a client with fifty large ICPs is fifty of them,
-- and 20260911090000/20260913020000 exist precisely so that no app-callable
-- function can run unbounded. The caller treats a timeout as "no counts", not
-- as a failed screen.
-- ---------------------------------------------------------------------------

create or replace function public.client_icp_tag_counts_v1(p_client_id text)
returns table (tag_id text, prospect_count bigint, company_count bigint)
language sql
stable
security definer
set search_path to 'public'
set statement_timeout to '8s'
as $$
  select t.id,
    (select count(*) from public.prospect_tag_links l where l.tag_id = t.id),
    (select count(*) from public.company_tag_links l where l.tag_id = t.id)
  from public.prospect_tags t
  -- Client-scoped only. An agency-wide tag belongs to no ICP, so counting one
  -- here would attribute it to whichever client happened to ask.
  where t.client_id = p_client_id;
$$;

grant execute on function public.client_icp_tag_counts_v1(text) to service_role;

-- ---------------------------------------------------------------------------
-- It counts what the link tables say, and nothing else.
do $$
declare
  v_client text;
  v_rows bigint;
  v_tags bigint;
  v_mismatch text;
begin
  select client_id into v_client from public.prospect_tags where client_id is not null limit 1;
  if v_client is null then
    raise notice 'no client-scoped tags exist yet; the counts are unproven on real rows';
    return;
  end if;

  -- One row per client tag, unused ones included.
  select count(*) into v_rows from public.client_icp_tag_counts_v1(v_client);
  select count(*) into v_tags from public.prospect_tags where client_id = v_client;
  if v_rows <> v_tags then
    raise exception 'client_icp_tag_counts_v1 returned % rows for % tags', v_rows, v_tags;
  end if;

  -- And each count equals the count taken directly.
  select string_agg(format('%s: reported %s/%s, actual %s/%s', c.tag_id,
      c.prospect_count, c.company_count,
      (select count(*) from public.prospect_tag_links l where l.tag_id = c.tag_id),
      (select count(*) from public.company_tag_links l where l.tag_id = c.tag_id)), '; ')
    into v_mismatch
    from public.client_icp_tag_counts_v1(v_client) c
   where c.prospect_count <> (select count(*) from public.prospect_tag_links l where l.tag_id = c.tag_id)
      or c.company_count <> (select count(*) from public.company_tag_links l where l.tag_id = c.tag_id);
  if v_mismatch is not null then
    raise exception 'the ICP counts disagree with the link tables: %', v_mismatch;
  end if;
end $$;

-- An agency-wide tag is never attributed to a client.
do $$
declare
  v_leaked text;
begin
  select string_agg(t.id, ', ') into v_leaked
    from public.prospect_tags t
   where t.client_id is null
     and exists (select 1 from public.clients c
                  where exists (select 1 from public.client_icp_tag_counts_v1(c.id) k where k.tag_id = t.id));
  if v_leaked is not null then
    raise exception 'agency-wide tags are being counted against a client: %', v_leaked;
  end if;
end $$;
