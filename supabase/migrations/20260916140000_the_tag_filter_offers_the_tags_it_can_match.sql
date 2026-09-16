-- The Tags filter offers the tags it can actually match.
--
-- THE BUG. prospect_filter_values_v3's '__tags' branch joins prospect_tags with
-- "and pt.client_id is null" hard-coded, so the value picker has only ever
-- offered AGENCY-WIDE tags. Production carries exactly one of those, so inside
-- a client workspace the Tags filter opens an empty list and the only way to
-- use it is to know a tag's name and type it.
--
-- The predicate has no such restriction. '__tags' compiles to a text match on
-- pi.tag_text (prospect_filter_sql_v1), and reindex_prospects builds tag_text
-- from EVERY prospect_tag_links row - client ICP tags included, as the 457-row
-- tagging run on 2026-09-16 confirmed. So the filter has always been able to
-- match a client ICP tag; the list simply refused to name one. A picker that
-- hides values the filter would have matched is worse than no picker: it reads
-- as "there is nothing to pick".
--
-- WHAT THIS CHANGES.
--
--   p_client_id null  (Master DB)  every tag, agency-wide and client-scoped
--   p_client_id set   (workspace)  agency-wide plus that client's own
--
-- The Master case is deliberately the wider one. tag_text is not scoped by
-- client, so a master-level search for a name already matches whoever carries
-- it; listing the names that can match is what makes the two agree. A client
-- workspace stays narrow because its own ICPs are the vocabulary it works in,
-- and another client's ICP names are not this client's business.
--
-- Note what does NOT need saying here: the rows are already restricted to the
-- client by "ps.client_ids @> array[client]" further down, so this clause is
-- about which tag NAMES may be offered, not about which prospects are counted.
--
-- THE CACHE NEEDS NOTHING. prospect_filter_values_cached_v1 keys its entries on
-- (field, client_id) and re-computes on the prospect data_version, so a list
-- that now differs per client is already stored per client. A tag with no links
-- cannot appear either way - the list is built by joining through
-- prospect_tag_links - so naming an ICP does not stale the cache; applying it
-- does, and applying it bumps the version.
-- ---------------------------------------------------------------------------

-- Spliced rather than restated: v3 is 90 lines of field mapping that this
-- migration has no opinion about, and a restated copy is a copy that drifts.
-- The anchor is the exact line being replaced, so a v3 that has moved on fails
-- here instead of being silently overwritten with an older body.
do $$
declare
  v_def text := pg_get_functiondef('public.prospect_filter_values_v3(text,text,text,integer)'::regprocedure);
  v_old constant text := E'      || '' and pt.client_id is null'';';
  v_new constant text := E'      || case when p_client_id is null then ''''\n'
    || E'              else format('' and (pt.client_id is null or pt.client_id = %L)'', p_client_id) end;';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'prospect_filter_values_v3 no longer contains the agency-wide tag join this migration replaces';
  end if;
  v_def := replace(v_def, v_old, v_new);
  if position('or pt.client_id = %L' in v_def) = 0 then
    raise exception 'the replacement did not take';
  end if;
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- The agency-wide list is unchanged.
--
-- This is the regression that matters: the Master DB has been answering from
-- this branch since it was written, and a client-aware join that quietly
-- dropped the agency-wide tags would empty the one list that used to work.
do $$
declare
  v_global_tags bigint;
  v_listed bigint;
begin
  select count(*) into v_global_tags
    from public.prospect_tags t
   where t.client_id is null
     and exists (select 1 from public.prospect_tag_links l where l.tag_id = t.id);

  select count(*) into v_listed
    from public.prospect_filter_values_v3('__tags', '', null, 100) v
   where exists (select 1 from public.prospect_tags t
                  where t.client_id is null and lower(t.name) = lower(v.value));

  if v_listed < v_global_tags then
    raise exception 'the master tag list lost agency-wide tags: % of % still listed', v_listed, v_global_tags;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- A client sees its own ICP tag, and no other client's.
--
-- Proved on real rows rather than asserted about the SQL text, because the
-- thing that was wrong was never the text - it was what the function returned.
-- Production currently carries no client-scoped tag LINKS at all (the
-- verification run on 2026-09-16 removed its own), so the rows are made here,
-- checked, and deleted inside this migration's transaction. prospect_tag_links
-- has no triggers, so nothing is queued for re-indexing by any of it.
do $$
declare
  v_client text;
  v_other text;
  v_tag constant text := 'mig-20260916140000-probe';
  v_name constant text := 'ZZ migration probe do not use';
  v_ids text[];
  v_seen boolean;
begin
  -- Two clients that actually have prospects, or there is nothing to prove.
  select c.id into v_client
    from public.clients c
   where exists (select 1 from public.prospect_index pi where pi.client_ids @> array[c.id])
   order by c.id limit 1;
  select c.id into v_other
    from public.clients c
   where c.id <> v_client
     and exists (select 1 from public.prospect_index pi where pi.client_ids @> array[c.id])
   order by c.id limit 1;

  if v_client is null then
    raise notice 'no client has prospects; the client-scoped tag list is unproven';
    return;
  end if;

  select array_agg(pi.id) into v_ids
    from (select id from public.prospect_index where client_ids @> array[v_client] limit 5) pi;

  insert into public.prospect_tags (id, name, client_id, color) values (v_tag, v_name, v_client, 'blue');
  insert into public.prospect_tag_links (prospect_id, tag_id)
    select unnest(v_ids), v_tag;

  select exists (select 1 from public.prospect_filter_values_v3('__tags', '', v_client, 100) v
                  where v.value = v_name)
    into v_seen;
  if not v_seen then
    raise exception 'a client workspace still cannot see its own ICP tag in the Tags filter';
  end if;

  -- And it is genuinely scoped: another client must not be offered it. Skipped
  -- rather than faked when there is only one client with prospects.
  if v_other is not null then
    select exists (select 1 from public.prospect_filter_values_v3('__tags', '', v_other, 100) v
                    where v.value = v_name)
      into v_seen;
    if v_seen then
      raise exception 'one client is being offered another client''s ICP tag';
    end if;
  end if;

  delete from public.prospect_tag_links where tag_id = v_tag;
  delete from public.prospect_tags where id = v_tag;

  -- Belt and braces: the probe must not survive this file under any path.
  if exists (select 1 from public.prospect_tags where id = v_tag) then
    raise exception 'the migration probe tag was not removed';
  end if;
end $$;
