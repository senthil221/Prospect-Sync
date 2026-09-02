-- Teach the compilers to read a filter set, and expose the two narrow entry
-- points the application needs.
--
-- 20260902000100 stored the values. This makes them usable: a filter carrying
-- `setId` compiles to a membership test against prospect_filters.filter_set_values
-- instead of thousands of literals inlined in the SQL text.
--
-- TWO PUBLIC WRAPPERS, BECAUSE PGRST_DB_SCHEMAS IS public. The storage lives in
-- a private schema PostgREST cannot see, which is the point - but the
-- application reaches the database through PostgREST, so it needs a door in
-- public. These are that door and nothing more: create a set, resolve a set.
-- Both are SECURITY DEFINER with a fixed search_path, revoked from
-- public/anon/authenticated, and granted only to service_role, which is the
-- posture section 8.3 asks for privileged operations.
--
-- OWNERSHIP IS CHECKED BEFORE COMPILATION, NOT DURING IT. The compilers take a
-- setId and emit a predicate for it; they do not decide whether the caller may
-- use that set. public.resolve_filter_set_v1 does, and the route calls it for
-- every set id in the request before the query runs. Section 4.1: neither a
-- hash nor a cache hit is an authorization decision. Keeping the check out of
-- the compiler also keeps it out of the cached plan, so a set cannot become
-- usable by a second caller because the first one warmed something.
--
-- THE INJECTION GUARD IS THE CAST. `(filter_item->>'setId')::uuid` raises on
-- anything that is not a uuid, and the result is then emitted with %L. A value
-- that reaches the SQL text has already been proven to be a uuid.
--
-- SPLICED, BUT LOUDLY. These two function bodies are large and neither is
-- transcribed here; the arms are inserted into the deployed definitions. That
-- is the technique 20260826050000 warns about - "SKIPS SILENTLY when it cannot
-- find the arm to splice after" - which is exactly how the __title_seniority
-- arm was lost and had to be restored in 20260902000050. So every splice below
-- raises if its anchor is missing or ambiguous. A migration that cannot do what
-- it says fails the release instead of half-applying.
--
-- Not extended: prospect_index_matches_v1 and company_matches_filters_v1, the
-- per-row fallbacks. prospect_filter_sql_v1 has no `return null` path at all
-- since 20260902000030, so its fallback is unreachable; company_filter_sql_v2
-- has exactly one, for an unknown field, where every filter matches nothing
-- anyway. A test asserts the prospect compiler stays total, so reintroducing a
-- null there fails loudly rather than silently dropping a set filter.

begin;

-- 1. The two public entry points ------------------------------------------

create or replace function public.create_filter_set_v1(
  p_owner_id text,
  p_entity_type text,
  p_client_scope text,
  p_field text,
  p_values text[]
)
returns table(set_id uuid, content_hash text, value_count integer, reused boolean)
language sql
security definer
set search_path = pg_catalog, public, prospect_filters
set statement_timeout = '30s'
as $function$
  select * from prospect_filters.create_set_v1(p_owner_id, p_entity_type, p_client_scope, p_field, p_values);
$function$;

create or replace function public.resolve_filter_set_v1(
  p_set_id uuid,
  p_owner_id text,
  p_entity_type text,
  p_client_scope text default ''
)
returns table(set_id uuid, content_hash text, value_count integer, field text)
language sql
security definer
set search_path = pg_catalog, public, prospect_filters
set statement_timeout = '10s'
as $function$
  select * from prospect_filters.resolve_set_v1(p_set_id, p_owner_id, p_entity_type, p_client_scope);
$function$;

-- 2. The compilers ---------------------------------------------------------

do $do$
declare
  v_definition text;
  v_anchor text;
  v_guard text;
  v_arm text;
  v_hits integer;
begin
  -- 2a. prospect_filter_sql_v1
  v_definition := pg_get_functiondef(to_regprocedure('public.prospect_filter_sql_v1(text, jsonb)'));
  if position('filter_set_values' in v_definition) = 0 then
    v_anchor := E'    candidate_expr := format(\'coalesce(%s, %L)\', candidate_expr, \'\');\n';
    v_hits := (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / nullif(length(v_anchor), 0);
    if coalesce(v_hits, 0) <> 1 then
      raise exception 'prospect_filter_sql_v1: expected exactly one splice anchor, found %', coalesce(v_hits, 0)
        using hint = 'The deployed body changed. Re-derive the anchor rather than letting this skip.';
    end if;
    v_arm := v_anchor || E'
    -- A durable filter set: the values are rows in prospect_filters, addressed
    -- by id, instead of thousands of literals inlined in this SQL. Ownership was
    -- already checked by public.resolve_filter_set_v1; this only compiles the
    -- membership test. The ::uuid cast is the injection guard - anything that is
    -- not a uuid raises here, before %L ever sees it.
    if coalesce(filter_item->>\'setId\', \'\') <> \'\' then
      if operator_key <> \'equals\' then
        raise exception \'A filter set supports the equals operator only, got %\', operator_key
          using errcode = \'22023\';
      end if;
      conjuncts := conjuncts || format(
        \'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))\',
        (filter_item->>\'setId\')::uuid, candidate_expr);
      continue;
    end if;
';
    execute replace(v_definition, v_anchor, v_arm);
    raise notice 'prospect_filter_sql_v1: filter set arm spliced';
  else
    raise notice 'prospect_filter_sql_v1: already knows filter sets, left alone';
  end if;

  -- 2b. company_filter_sql_v2
  --
  -- This one needs two edits, and the second was found by the self-check below
  -- rather than by reading: the compiler skips any filter carrying no values,
  --
  --   if cardinality(raw_values) = 0 and operator_key not in (...) then continue;
  --
  -- and a set-backed filter carries none - its values are rows. Without this the
  -- filter was dropped in silence and the predicate compiled to `true`, which is
  -- the widest possible answer. The prospect compiler is not affected: its
  -- equivalent guard sits after the point the set arm returns from.
  v_definition := pg_get_functiondef(to_regprocedure('public.company_filter_sql_v2(text, jsonb)'));
  if position('filter_set_values' in v_definition) = 0 then
    v_guard := E'    if cardinality(raw_values) = 0 and operator_key not in (\'empty\', \'not_empty\') then\n';
    v_hits := (length(v_definition) - length(replace(v_definition, v_guard, ''))) / nullif(length(v_guard), 0);
    if coalesce(v_hits, 0) <> 1 then
      raise exception 'company_filter_sql_v2: expected exactly one empty-values guard, found %', coalesce(v_hits, 0)
        using hint = 'Without this edit a set-backed filter is skipped and the predicate widens to true.';
    end if;
    v_definition := replace(v_definition, v_guard,
      E'    if cardinality(raw_values) = 0 and coalesce(filter_item->>\'setId\', \'\') = \'\' and operator_key not in (\'empty\', \'not_empty\') then\n');

    v_anchor := E'    if operator_key = \'equals\' then\n';
    v_hits := (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / nullif(length(v_anchor), 0);
    if coalesce(v_hits, 0) <> 1 then
      raise exception 'company_filter_sql_v2: expected exactly one splice anchor, found %', coalesce(v_hits, 0)
        using hint = 'The deployed body changed. Re-derive the anchor rather than letting this skip.';
    end if;
    -- The company side can match across several columns (the keyword scopes),
    -- so the set test is emitted per column and OR-ed, exactly as the literal
    -- form beside it does.
    v_arm := E'    if coalesce(filter_item->>\'setId\', \'\') <> \'\' then
      if operator_key <> \'equals\' then
        raise exception \'A filter set supports the equals operator only, got %\', operator_key
          using errcode = \'22023\';
      end if;
      value_parts := array(select format(
        \'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))\',
        (filter_item->>\'setId\')::uuid, col) from unnest(match_cols) col);
      conjuncts := conjuncts || (\'(\' || array_to_string(value_parts, \' or \') || \')\');
      continue;
    end if;

' || v_anchor;
    execute replace(v_definition, v_anchor, v_arm);
    raise notice 'company_filter_sql_v2: empty-values guard relaxed and filter set arm spliced';
  else
    raise notice 'company_filter_sql_v2: already knows filter sets, left alone';
  end if;
end
$do$;

-- 3. Prove the splices took, in the same transaction that made them --------
do $do$
declare
  v_prospect text := public.prospect_filter_sql_v1('',
    '[{"field":"__company_domain","operator":"equals","setId":"11111111-1111-1111-1111-111111111111"}]'::jsonb);
  v_company text := public.company_filter_sql_v2('',
    '[{"field":"__website","operator":"equals","setId":"11111111-1111-1111-1111-111111111111"}]'::jsonb);
begin
  if v_prospect is null or position('filter_set_values' in v_prospect) = 0 then
    raise exception 'prospect_filter_sql_v1 does not compile a filter set: %', coalesce(v_prospect, '(null)');
  end if;
  if v_company is null or position('filter_set_values' in v_company) = 0 then
    raise exception 'company_filter_sql_v2 does not compile a filter set: %', coalesce(v_company, '(null)');
  end if;
  -- And a set id that is not a uuid must never reach the emitted SQL.
  begin
    perform public.prospect_filter_sql_v1('',
      '[{"field":"__company_domain","operator":"equals","setId":"not-a-uuid'' or 1=1--"}]'::jsonb);
    raise exception 'a non-uuid setId was accepted';
  exception when invalid_text_representation then
    null;
  end;
end
$do$;

revoke execute on function public.create_filter_set_v1(text, text, text, text, text[]) from public, anon, authenticated;
revoke execute on function public.resolve_filter_set_v1(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.create_filter_set_v1(text, text, text, text, text[]) to service_role;
grant execute on function public.resolve_filter_set_v1(uuid, text, text, text) to service_role;

commit;
