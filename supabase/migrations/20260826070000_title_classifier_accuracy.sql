-- Accuracy follow-up for the deterministic job-title classifier.
--
-- The original classifier generated n-grams only up to four tokens even though
-- the supplied map contains deliberate five- and six-token demotion overrides
-- such as "executive assistant to the md". Those rows could never fire, allowing
-- the later "md" token to incorrectly promote the title to C-Suite.

begin;

do $do$
declare
  def text;
  old_window constant text := 'generate_series(1, 4)';
  new_window constant text := 'generate_series(1, least(v_count, 8))';
begin
  if to_regprocedure('public.classify_job_title_v1(text,text)') is null then
    raise exception 'classify_job_title_v1(text,text) must exist before applying title_classifier_accuracy';
  end if;

  def := pg_get_functiondef('public.classify_job_title_v1(text,text)'::regprocedure);
  if position(old_window in def) > 0 then
    execute replace(def, old_window, new_window);
  elsif position(new_window in def) = 0 then
    raise exception 'classify_job_title_v1 scan window did not match the expected old or new definition';
  end if;
end
$do$;

-- CREATE OR REPLACE preserves grants, but assert the intended PostgREST boundary
-- explicitly so this migration stays safe if run against a hand-modified database.
revoke execute on function public.classify_job_title_v1(text, text) from public, anon, authenticated;
grant execute on function public.classify_job_title_v1(text, text) to service_role;

commit;
