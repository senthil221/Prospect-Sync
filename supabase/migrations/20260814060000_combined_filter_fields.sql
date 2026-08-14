-- Two combined People filters:
--   __title_seniority  -> Job Title + Seniority
--   __esp_type         -> ESP + ESP (provider) type
-- Each virtual field concatenates the two underlying columns so a single
-- include/exclude (contains) match hits either value.
--
-- The candidate-value CASE is inlined into three current functions
-- (search_prospect_workspace_v7, search_prospect_export_v1, and the shared
-- prospect_index_matches_v1). Rather than transcribe those large bodies, we edit
-- the deployed definition in place: fetch it with pg_get_functiondef, splice the
-- two new WHEN arms right after the __department arm, and re-create. Idempotent
-- (skips when the field is already present) and grant-preserving.

do $do$
declare
  targets text[] := array[
    'public.search_prospect_workspace_v7(text,jsonb,text,text,integer,integer,text)',
    'public.search_prospect_export_v1(text,jsonb,text,timestamptz,text,integer,boolean)'
  ];
  sig text;
  def text;
begin
  foreach sig in array targets loop
    def := pg_get_functiondef(sig::regprocedure);
    if position('__title_seniority' in def) = 0 then
      def := replace(def,
        $q$when '__department' then ps.department$q$,
        $q$when '__department' then ps.department when '__title_seniority' then concat_ws(' ', ps.title, ps.seniority) when '__esp_type' then concat_ws(' ', ps.esp, ps.email_provider_type)$q$);
      execute def;
    end if;
  end loop;
end
$do$;

do $do$
declare
  def text;
begin
  def := pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
  if position('__title_seniority' in def) = 0 then
    def := replace(def,
      $q$when '__department' then (p_row).department$q$,
      $q$when '__department' then (p_row).department when '__title_seniority' then concat_ws(' ', (p_row).title, (p_row).seniority) when '__esp_type' then concat_ws(' ', (p_row).esp, (p_row).email_provider_type)$q$);
    execute def;
  end if;
end
$do$;
