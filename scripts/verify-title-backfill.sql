-- Run after installing the projection change, inside a caller-owned transaction.
create temporary table title_test_targets as
select id from public.prospects p
where title_classified_at is null or title_classified_at<(select keywords_updated_at from public.title_classifier_state where id)
order by title_classified_at nulls first limit 1000;
create temporary table title_test_before as
select pi.id,to_jsonb(pi)-array['title_seniority','title_department','title_sub_department','title_is_former','title_normalized'] as value
from public.prospect_index pi join title_test_targets t using(id);
select * from public.run_title_classification_batch_v2(1000);
create temporary table title_test_optimized as
select pi.id,to_jsonb(pi) as value from public.prospect_index pi join title_test_targets t using(id);
do $unchanged$
begin
  if exists(select 1 from title_test_before b join title_test_optimized o using(id)
    where b.value is distinct from o.value-array['title_seniority','title_department','title_sub_department','title_is_former','title_normalized']) then
    raise exception 'Title backfill changed unrelated index fields';
  end if;
end;
$unchanged$;
select public.reindex_prospects(array(select id from title_test_targets));
do $assert$
begin
  if exists(select 1 from title_test_optimized o join public.prospect_index pi using(id),
    lateral unnest(array['title_seniority','title_department','title_sub_department','title_is_former','title_normalized']) field(key)
    where o.value->field.key is distinct from to_jsonb(pi)->field.key) then
    raise exception 'Optimized title projection differs from full canonical reindex';
  end if;
  if exists(select 1 from title_test_targets t join public.prospects p using(id) join public.prospect_index pi using(id)
    where (p.title_seniority,p.title_department,p.title_sub_department,p.title_is_former,p.title_normalized)
      is distinct from (pi.title_seniority,pi.title_department,pi.title_sub_department,pi.title_is_former,pi.title_normalized)) then
    raise exception 'Classifier result and search index disagree';
  end if;
end;
$assert$;
