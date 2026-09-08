-- A title backfill changes only derived classifier values. Rebuilding every
-- list/client/tag aggregate and every search column caused unnecessary writes
-- and lock contention with profile cleanup. Keep existing index rows narrow;
-- use the canonical reindexer only to repair a missing index row.
do $patch$
declare v_definition text; v_rewritten text;
begin
  select pg_get_functiondef('public.reclassify_prospect_titles_v1(integer)'::regprocedure) into v_definition;
  v_rewritten:=replace(v_definition,
    'perform public.reindex_prospects(v_ids);',
    'update public.prospect_index pi set
      title_seniority=p.title_seniority,title_department=p.title_department,
      title_sub_department=p.title_sub_department,title_is_former=p.title_is_former,
      title_normalized=p.title_normalized
    from public.prospects p where pi.id=p.id and p.id=any(v_ids)
      and (pi.title_seniority,pi.title_department,pi.title_sub_department,pi.title_is_former,pi.title_normalized)
        is distinct from (p.title_seniority,p.title_department,p.title_sub_department,p.title_is_former,p.title_normalized);
    perform public.reindex_prospects(array(
      select id from unnest(v_ids) target(id)
      where not exists(select 1 from public.prospect_index pi where pi.id=target.id)
    ));');
  if v_rewritten=v_definition then raise exception 'Missing classifier reindex anchor'; end if;
  execute v_rewritten;
end;
$patch$;
