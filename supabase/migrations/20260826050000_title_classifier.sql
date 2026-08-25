-- Deterministic job title classifier (spec v1).
--
-- Raw title in, (department, sub_department, seniority) out. No AI, no network
-- call: two independent keyword scans over a normalized copy of the title. The
-- raw title is never modified -- every output is a derived column that can be
-- recomputed in bulk when the keyword lists improve.
--
-- WHY THIS LIVES IN POSTGRES
-- The keyword lists are data, not code. Holding them in tables means the lists can
-- be corrected without a deploy, and the whole People database can be re-classified
-- with a single set-based pass instead of streaming every row through the app.
--
-- The two lists are maintained as CSVs in data/ and pushed in with
-- scripts/sync-title-keywords.mjs, which reconciles the tables to match the files
-- exactly (upsert what is present, delete what is gone). The CSVs are the source of
-- truth; these tables are their loaded form.
--
-- WHAT IS DELIBERATELY NOT IMPLEMENTED (spec section 3b / 4)
--   * German "leiter/chef" suffix rule -- the spec says skip it when German volume
--     is low, and this database is India/US/GCC. The German department STEMS are in
--     department_map.csv, so Vertriebsleiter still resolves its department.
--   * Non-Latin scripts are out of scope by design. Normalization strips them, the
--     title normalizes to empty, both outputs are Undefined, and the title shows up
--     in the gaps report.

begin;

-- unaccent powers the accent folding the European keyword rows depend on
-- (Vertriebsleiter, Directeur, ...). It is STABLE, not IMMUTABLE, so nothing
-- downstream may be an index expression over the normalizer.
create extension if not exists unaccent;

-- ---------------------------------------------------------------------------
-- 1. Keyword tables
-- ---------------------------------------------------------------------------

create table if not exists public.title_seniority_keywords (
  keyword text primary key,
  tier text not null,
  notes text not null default '',
  -- Longest-phrase-first ordering is load-bearing: it is how demotion overrides
  -- work ("assistant manager" must match before "manager").
  token_count integer generated always as (coalesce(array_length(string_to_array(keyword, ' '), 1), 0)) stored
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'title_seniority_keywords_tier_check') then
    alter table public.title_seniority_keywords
      add constraint title_seniority_keywords_tier_check
      -- 'none' consumes its tokens and contributes no rank, so a phrase that merely
      -- contains a seniority word can suppress it ("lead generation" vs "lead").
      check (tier in ('owner', 'c_suite', 'vp', 'director', 'manager', 'senior_ic', 'entry', 'none'));
  end if;
end $$;

create table if not exists public.title_department_keywords (
  keyword text primary key,
  department text not null,
  sub_department text not null default '',
  notes text not null default '',
  token_count integer generated always as (coalesce(array_length(string_to_array(keyword, ' '), 1), 0)) stored
);

create index if not exists idx_title_seniority_keywords_tokens on public.title_seniority_keywords(token_count desc);
create index if not exists idx_title_department_keywords_tokens on public.title_department_keywords(token_count desc);

-- Bumped whenever either list changes, so reclassification knows which rows were
-- classified against a stale list without touching every prospect row.
create table if not exists public.title_classifier_state (
  id boolean primary key default true,
  keywords_updated_at timestamptz not null default now(),
  constraint title_classifier_state_singleton check (id)
);
insert into public.title_classifier_state(id) values (true) on conflict (id) do nothing;

create or replace function public.touch_title_classifier_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.title_classifier_state set keywords_updated_at = now() where id;
  return null;
end;
$$;

drop trigger if exists trg_touch_classifier_state_seniority on public.title_seniority_keywords;
create trigger trg_touch_classifier_state_seniority
after insert or update or delete on public.title_seniority_keywords
for each statement execute function public.touch_title_classifier_state();

drop trigger if exists trg_touch_classifier_state_department on public.title_department_keywords;
create trigger trg_touch_classifier_state_department
after insert or update or delete on public.title_department_keywords
for each statement execute function public.touch_title_classifier_state();

alter table public.title_seniority_keywords enable row level security;
alter table public.title_department_keywords enable row level security;
alter table public.title_classifier_state enable row level security;
revoke all on public.title_seniority_keywords, public.title_department_keywords, public.title_classifier_state from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Normalization (spec section 1)
-- ---------------------------------------------------------------------------

create or replace function public.normalize_job_title_v1(p_title text)
returns text
language sql
stable
set search_path = public
as $$
  select btrim(regexp_replace(
    -- 3. every remaining punctuation mark becomes a single space, which is what
    --    turns "vp- sales" into "vp sales" and "head-hr" into "head hr". This also
    --    strips non-Latin scripts, which are Undefined by design.
    regexp_replace(
      -- 2b. ampersand acronyms BEFORE punctuation stripping, since & -> space would
      --     otherwise shred them into meaningless single letters. These placeholder
      --     spellings have their own rows in the keyword CSVs.
      regexp_replace(
      regexp_replace(
      regexp_replace(
      regexp_replace(
        -- 2. collapse dotted acronyms: v.p. -> vp, c.e.o -> ceo. The \y guard means
        --    only a SINGLE letter followed by a dot collapses, so "dr. smith" and
        --    "inc." survive intact.
        regexp_replace(
          -- 1b/1c. lowercase, fold accents to ASCII, apostrophes become spaces
          --        ("founder's office" -> "founder s office").
          translate(lower(unaccent(coalesce(p_title, ''))), '''`', '  '),
        '\y([a-z])\.', '\1', 'g'),
      '\yfp\s*&\s*a\y', 'fpna', 'g'),
      '\yr\s*&\s*d\y', 'rnd', 'g'),
      '\yl\s*&\s*d\y', 'lnd', 'g'),
      '\ym\s*&\s*a\y', 'mna', 'g'),
    '[^a-z0-9]+', ' ', 'g'),
  -- 4. collapse runs of spaces and trim
  '\s+', ' ', 'g'));
$$;

-- Rank order, high -> low (spec section 3). Lower number wins.
create or replace function public.title_seniority_rank(p_tier text)
returns integer
language sql
immutable
as $$
  select case p_tier
    when 'owner' then 1
    when 'c_suite' then 2
    when 'vp' then 3
    when 'director' then 4
    when 'manager' then 5
    when 'senior_ic' then 6
    when 'entry' then 7
    else 99
  end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The classifier (spec section 2)
--
-- Two independent scans. Each one walks its keyword list longest-phrase-first,
-- matching whole token sequences only (never substrings, so "head" cannot match
-- "headhunter" and "md" cannot match "mdm"), and consumes the tokens it matched so
-- they cannot take part in a later, shorter match.
-- ---------------------------------------------------------------------------

create or replace function public.classify_job_title_v1(
  p_title text,
  p_company_name text default ''
)
returns table(
  seniority text,
  department text,
  sub_department text,
  secondary_departments text[],
  is_former boolean,
  normalized_title text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_norm text;
  v_tokens text[];
  v_count integer;
  v_healthcare boolean;
  v_consumed boolean[];
  v_overlap boolean;
  v_position integer;
  v_best_rank integer := 99;
  v_best_tier text := '';
  v_former boolean := false;
  v_primary_start integer := null;
  v_primary_department text := '';
  v_primary_sub text := '';
  v_sub_start integer := null;
  v_secondary text[] := '{}';
  match_row record;
begin
  seniority := '';
  department := '';
  sub_department := '';
  secondary_departments := '{}';
  is_former := false;

  v_norm := public.normalize_job_title_v1(p_title);
  normalized_title := v_norm;
  if v_norm = '' then
    return next;
    return;
  end if;

  v_tokens := string_to_array(v_norm, ' ');
  v_count := coalesce(array_length(v_tokens, 1), 0);
  if v_count = 0 then
    return next;
    return;
  end if;

  -- Known limitation (spec section 4): md is Managing Director far more often than
  -- medical doctor, except at a healthcare provider, where it is the reverse. Drop
  -- the keyword rather than guess.
  v_healthcare := coalesce(p_company_name, '') ~* '(hospital|clinic|medical|healthcare|health care|diagnostic|patholog|labs\y|laborator)';

  -- Former-role rule (spec 3b): "Former CEO | Advisor" must not classify as C-Suite.
  if v_tokens[1] in ('former', 'ex', 'retired', 'past') then
    v_former := true;
  end if;

  -- --- seniority scan ------------------------------------------------------
  v_consumed := array_fill(false, array[v_count]);
  for match_row in
    with ngram as (
      select start_pos.value as start_pos, len.value as len,
        array_to_string(v_tokens[start_pos.value : start_pos.value + len.value - 1], ' ') as phrase
      from generate_series(1, v_count) as start_pos(value)
      cross join generate_series(1, 4) as len(value)
      where start_pos.value + len.value - 1 <= v_count
    )
    select n.start_pos, n.len, k.tier
    from ngram n
    join public.title_seniority_keywords k on k.keyword = n.phrase
    where not (v_healthcare and n.phrase = 'md')
    order by n.len desc, n.start_pos asc
  loop
    select bool_or(v_consumed[position.value]) into v_overlap
    from generate_series(match_row.start_pos, match_row.start_pos + match_row.len - 1) as position(value);
    if coalesce(v_overlap, false) then continue; end if;

    for v_position in match_row.start_pos .. match_row.start_pos + match_row.len - 1 loop
      v_consumed[v_position] := true;
    end loop;

    -- "Former Managing Director": the marker sits immediately before the keyword.
    if match_row.start_pos > 1 and v_tokens[match_row.start_pos - 1] in ('former', 'ex', 'retired', 'past') then
      v_former := true;
    end if;

    -- 'none' rows exist purely to consume tokens; they carry no rank.
    if match_row.tier <> 'none' and public.title_seniority_rank(match_row.tier) < v_best_rank then
      v_best_rank := public.title_seniority_rank(match_row.tier);
      v_best_tier := match_row.tier;
    end if;
  end loop;

  -- Highest-ranked tier among everything that fired; ties are impossible.
  seniority := case when v_former then '' else v_best_tier end;
  is_former := v_former;

  -- --- department scan (independent of the one above) ----------------------
  v_consumed := array_fill(false, array[v_count]);
  for match_row in
    with ngram as (
      select start_pos.value as start_pos, len.value as len,
        array_to_string(v_tokens[start_pos.value : start_pos.value + len.value - 1], ' ') as phrase
      from generate_series(1, v_count) as start_pos(value)
      cross join generate_series(1, 4) as len(value)
      where start_pos.value + len.value - 1 <= v_count
    )
    select n.start_pos, n.len, k.department, k.sub_department
    from ngram n
    join public.title_department_keywords k on k.keyword = n.phrase
    order by n.len desc, n.start_pos asc
  loop
    select bool_or(v_consumed[position.value]) into v_overlap
    from generate_series(match_row.start_pos, match_row.start_pos + match_row.len - 1) as position(value);
    if coalesce(v_overlap, false) then continue; end if;

    for v_position in match_row.start_pos .. match_row.start_pos + match_row.len - 1 loop
      v_consumed[v_position] := true;
    end loop;

    -- Multi-department titles take the earliest-mentioned department.
    if v_primary_start is null or match_row.start_pos < v_primary_start then
      if v_primary_start is not null and not (match_row.department = any(v_secondary)) then
        v_secondary := v_secondary || v_primary_department;
      end if;
      v_primary_start := match_row.start_pos;
      v_primary_department := match_row.department;
      v_primary_sub := '';
      v_sub_start := null;
    elsif match_row.department <> v_primary_department and not (match_row.department = any(v_secondary)) then
      v_secondary := v_secondary || match_row.department;
    end if;
  end loop;

  if v_primary_start is not null then
    -- Specificity wins (spec 5b): within the chosen department, a keyword carrying a
    -- non-blank sub_department beats the generic one. Earliest such keyword wins.
    with ngram as (
      select start_pos.value as start_pos, len.value as len,
        array_to_string(v_tokens[start_pos.value : start_pos.value + len.value - 1], ' ') as phrase
      from generate_series(1, v_count) as start_pos(value)
      cross join generate_series(1, 4) as len(value)
      where start_pos.value + len.value - 1 <= v_count
    )
    select k.sub_department into v_primary_sub
    from ngram n
    join public.title_department_keywords k on k.keyword = n.phrase
    where k.department = v_primary_department and k.sub_department <> ''
    order by n.start_pos asc, n.len desc
    limit 1;
  end if;

  department := v_primary_department;
  sub_department := coalesce(v_primary_sub, '');
  secondary_departments := v_secondary;
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Derived columns
--
-- The Apollo-supplied seniority / department columns are left exactly as imported.
-- These sit beside them so a filter can use whichever source is trusted, and so a
-- re-run of the classifier can never destroy uploaded data.
-- ---------------------------------------------------------------------------

alter table public.prospects add column if not exists title_seniority text not null default '';
alter table public.prospects add column if not exists title_department text not null default '';
alter table public.prospects add column if not exists title_sub_department text not null default '';
alter table public.prospects add column if not exists title_secondary_departments text[] not null default '{}';
alter table public.prospects add column if not exists title_is_former boolean not null default false;
alter table public.prospects add column if not exists title_normalized text not null default '';
alter table public.prospects add column if not exists title_classified_at timestamptz;

alter table public.prospect_index add column if not exists title_seniority text not null default '';
alter table public.prospect_index add column if not exists title_department text not null default '';
alter table public.prospect_index add column if not exists title_sub_department text not null default '';
alter table public.prospect_index add column if not exists title_is_former boolean not null default false;
alter table public.prospect_index add column if not exists title_normalized text not null default '';

create index if not exists idx_prospect_index_title_department on public.prospect_index(title_department) where title_department <> '';
create index if not exists idx_prospect_index_title_seniority on public.prospect_index(title_seniority) where title_seniority <> '';
create index if not exists idx_prospect_index_title_sub_department on public.prospect_index(title_sub_department) where title_sub_department <> '';

-- Feeds the gaps report without scanning classified rows.
create index if not exists idx_prospects_unclassified_titles on public.prospects(title_normalized)
  where title_seniority = '' or title_department = '';
create index if not exists idx_prospects_title_classified_at on public.prospects(title_classified_at nulls first);

-- Classify on write. Firing only when the title (or the company, which decides the
-- md rule) actually changes keeps unrelated updates free, and keeps the bulk
-- reclassifier below from re-entering this trigger.
create or replace function public.prospects_classify_title()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_name text := '';
  v_result record;
begin
  if new.company_id is not null then
    select coalesce(c.name, '') into v_company_name from public.companies c where c.id = new.company_id;
  end if;

  select * into v_result from public.classify_job_title_v1(coalesce(new.title, ''), coalesce(v_company_name, ''));

  new.title_seniority := v_result.seniority;
  new.title_department := v_result.department;
  new.title_sub_department := v_result.sub_department;
  new.title_secondary_departments := v_result.secondary_departments;
  new.title_is_former := v_result.is_former;
  new.title_normalized := v_result.normalized_title;
  new.title_classified_at := now();
  return new;
end;
$$;

drop trigger if exists trg_prospects_classify_title_insert on public.prospects;
create trigger trg_prospects_classify_title_insert
before insert on public.prospects
for each row execute function public.prospects_classify_title();

drop trigger if exists trg_prospects_classify_title_update on public.prospects;
create trigger trg_prospects_classify_title_update
before update on public.prospects
for each row
when (old.title is distinct from new.title or old.company_id is distinct from new.company_id)
execute function public.prospects_classify_title();

-- prospect_index is written exclusively by reindex_prospects, which does not know
-- about these columns. Rather than re-transcribe that large function (and have to
-- re-transcribe it again on the next column), fill them in on the way in from the
-- prospects row that is being indexed. One primary-key lookup per indexed row.
create or replace function public.prospect_index_fill_title_class()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select coalesce(p.title_seniority, ''), coalesce(p.title_department, ''),
         coalesce(p.title_sub_department, ''), coalesce(p.title_is_former, false),
         coalesce(p.title_normalized, '')
  into new.title_seniority, new.title_department, new.title_sub_department,
       new.title_is_former, new.title_normalized
  from public.prospects p where p.id = new.id;
  return new;
end;
$$;

drop trigger if exists trg_prospect_index_fill_title_class on public.prospect_index;
create trigger trg_prospect_index_fill_title_class
before insert or update on public.prospect_index
for each row execute function public.prospect_index_fill_title_class();

-- ---------------------------------------------------------------------------
-- 5. Bulk re-classification and the Undefined log
-- ---------------------------------------------------------------------------

-- Re-run the classifier over rows never classified, or classified against an older
-- version of the keyword lists. Bounded per call so it can never exceed PostgREST's
-- statement budget; the caller loops until it returns 0.
create or replace function public.reclassify_prospect_titles_v1(p_limit integer default 500)
returns integer
language plpgsql
security definer
set search_path = public
set statement_timeout = '60s'
as $$
declare
  v_keywords_updated_at timestamptz;
  v_ids text[];
  v_updated integer := 0;
begin
  select s.keywords_updated_at into v_keywords_updated_at from public.title_classifier_state s where s.id;

  select coalesce(array_agg(t.id), '{}'::text[]) into v_ids
  from (
    select p.id from public.prospects p
    where p.title_classified_at is null or p.title_classified_at < v_keywords_updated_at
    order by p.title_classified_at nulls first
    limit greatest(1, least(coalesce(p_limit, 500), 5000))
  ) t;

  if array_length(v_ids, 1) is null then return 0; end if;

  -- Writes only the derived columns, so the BEFORE UPDATE trigger (which watches
  -- title and company_id) does not fire and re-do the same work.
  update public.prospects p set
    title_seniority = classified.seniority,
    title_department = classified.department,
    title_sub_department = classified.sub_department,
    title_secondary_departments = classified.secondary_departments,
    title_is_former = classified.is_former,
    title_normalized = classified.normalized_title,
    title_classified_at = now()
  from unnest(v_ids) as target(id)
  left join public.prospects source on source.id = target.id
  left join public.companies c on c.id = source.company_id
  cross join lateral public.classify_job_title_v1(coalesce(source.title, ''), coalesce(c.name, '')) classified
  where p.id = target.id;
  get diagnostics v_updated = row_count;

  perform public.reindex_prospects(v_ids);
  return v_updated;
end;
$$;

-- The Undefined log (spec section 0): every title the lists could not fully resolve,
-- grouped by its normalized form and ranked by how much coverage each fix would buy.
-- Computed on demand rather than written on every import -- it cannot drift, costs
-- nothing to maintain, and the partial index above keeps it cheap.
create or replace function public.title_classification_gaps_v1(
  p_limit integer default 200,
  p_missing text default 'any'
)
returns table(
  normalized_title text,
  sample_title text,
  occurrences bigint,
  missing_seniority boolean,
  missing_department boolean
)
language sql
stable
security definer
set search_path = public
set statement_timeout = '60s'
as $$
  select p.title_normalized,
    min(p.title) as sample_title,
    count(*) as occurrences,
    bool_and(p.title_seniority = '') as missing_seniority,
    bool_and(p.title_department = '') as missing_department
  from public.prospects p
  where btrim(coalesce(p.title, '')) <> ''
    and (p.title_seniority = '' or p.title_department = '')
    and (
      p_missing = 'any'
      or (p_missing = 'both' and p.title_seniority = '' and p.title_department = '')
      or (p_missing = 'seniority' and p.title_seniority = '')
      or (p_missing = 'department' and p.title_department = '')
    )
  group by p.title_normalized
  order by count(*) desc, p.title_normalized
  limit greatest(1, least(coalesce(p_limit, 200), 2000));
$$;

-- ---------------------------------------------------------------------------
-- 6. Make the three new outputs filterable
--
-- Each filterable field is a WHEN arm in a CASE that is inlined into several
-- functions. Splicing the deployed definitions (the pattern established by
-- 20260814060000_combined_filter_fields.sql) beats re-transcribing 500-line bodies
-- that would then have to be kept in sync by hand. Idempotent and grant-preserving.
-- ---------------------------------------------------------------------------

do $do$
declare
  -- (signature, text to find, text to insert after it)
  row_form text := $q$when '__department' then (p_row).department$q$;
  ps_form text := $q$when '__department' then ps.department$q$;
  sql_form text := $q$when '__department' then 'pi.department'$q$;
  sig text;
  def text;
begin
  -- a) the scalar matcher, which decides every filter
  if to_regprocedure('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)') is not null then
    def := pg_get_functiondef('public.prospect_index_matches_v1(public.prospect_index,text,jsonb)'::regprocedure);
    if position('__title_department' in def) = 0 then
      execute replace(def, row_form, row_form
        || $q$ when '__title_department' then (p_row).title_department$q$
        || $q$ when '__title_sub_department' then (p_row).title_sub_department$q$
        || $q$ when '__title_seniority_tier' then (p_row).title_seniority$q$);
    end if;
  end if;

  -- b) the index pre-filter, so a classifier filter narrows before the matcher runs
  if to_regprocedure('public.prospect_prefilter_sql(text,jsonb)') is not null then
    def := pg_get_functiondef('public.prospect_prefilter_sql(text,jsonb)'::regprocedure);
    if position('__title_department' in def) = 0 then
      execute replace(def, sql_form, sql_form
        || $q$ when '__title_department' then 'pi.title_department'$q$
        || $q$ when '__title_sub_department' then 'pi.title_sub_department'$q$
        || $q$ when '__title_seniority_tier' then 'pi.title_seniority'$q$);
    end if;
  end if;

  -- c) workspace and export, which both read the flat prospect_index
  --
  -- prospect_filter_values_v2/v3 are deliberately NOT spliced: their CASE reads the
  -- prospect_summaries VIEW, whose column list was fixed when it was created, so it
  -- does not carry the new columns. Recreating that view would reorder its columns
  -- (p.* now expands wider), which CREATE OR REPLACE VIEW rejects, and dropping it
  -- would cascade through a dozen functions. Autocomplete for the three new fields
  -- is served by title_class_filter_values_v1 below instead.
  foreach sig in array array[
    'public.search_prospect_workspace_v11(text,jsonb,text,text,integer,integer,text,jsonb,boolean)',
    'public.search_prospect_workspace_v7(text,jsonb,text,text,integer,integer,text)',
    'public.search_prospect_export_v1(text,jsonb,text,timestamptz,text,integer,boolean)'
  ] loop
    if to_regprocedure(sig) is null then continue; end if;
    def := pg_get_functiondef(sig::regprocedure);
    if position('__title_department' in def) > 0 then continue; end if;
    if position(ps_form in def) = 0 then continue; end if;
    execute replace(def, ps_form, ps_form
      || $q$ when '__title_department' then ps.title_department$q$
      || $q$ when '__title_sub_department' then ps.title_sub_department$q$
      || $q$ when '__title_seniority_tier' then ps.title_seniority$q$);
  end loop;
end
$do$;

-- Value autocomplete for the three classifier fields. Reads the flat index, honours
-- the client scope the workspace is in, and returns counts so the picker can show
-- how many people each value would bring.
create or replace function public.title_class_filter_values_v1(
  p_field text,
  p_search text default '',
  p_client_id text default null,
  p_limit integer default 50
)
returns table(value text, match_count bigint)
language sql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
  select candidate.value, count(*)::bigint as match_count
  from public.prospect_index pi
  cross join lateral (
    select case p_field
      when '__title_department' then pi.title_department
      when '__title_sub_department' then pi.title_sub_department
      when '__title_seniority_tier' then pi.title_seniority
      else ''
    end as value
  ) candidate
  where candidate.value <> ''
    and (p_client_id is null or p_client_id = any(pi.client_ids))
    and (btrim(coalesce(p_search, '')) = '' or candidate.value ilike '%' || btrim(p_search) || '%')
  group by candidate.value
  order by count(*) desc, candidate.value
  limit greatest(1, least(coalesce(p_limit, 50), 100));
$$;

revoke execute on function public.title_class_filter_values_v1(text, text, text, integer) from public, anon, authenticated;
grant execute on function public.title_class_filter_values_v1(text, text, text, integer) to service_role;

-- The three trigger functions are SECURITY DEFINER so they can write the
-- classifier columns regardless of who performed the insert. Triggers fire as the
-- table owner and never consult EXECUTE, so revoking it costs nothing and keeps
-- them off the PostgREST surface where a browser role could call them directly.
revoke execute on function public.touch_title_classifier_state() from public, anon, authenticated;
revoke execute on function public.prospects_classify_title() from public, anon, authenticated;
revoke execute on function public.prospect_index_fill_title_class() from public, anon, authenticated;

revoke execute on function public.normalize_job_title_v1(text) from public, anon, authenticated;
revoke execute on function public.classify_job_title_v1(text, text) from public, anon, authenticated;
revoke execute on function public.reclassify_prospect_titles_v1(integer) from public, anon, authenticated;
revoke execute on function public.title_classification_gaps_v1(integer, text) from public, anon, authenticated;

grant execute on function public.normalize_job_title_v1(text) to service_role;
grant execute on function public.classify_job_title_v1(text, text) to service_role;
grant execute on function public.reclassify_prospect_titles_v1(integer) to service_role;
grant execute on function public.title_classification_gaps_v1(integer, text) to service_role;

commit;
