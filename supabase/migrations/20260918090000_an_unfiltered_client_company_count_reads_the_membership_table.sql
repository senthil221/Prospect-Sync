-- An unfiltered client Company DB counts its membership rows instead of
-- probing every company's primary key.
--
-- WHAT IT COSTS TODAY, MEASURED 2026-09-18 on production. The counted CTE is:
--
--   from public.companies c left join client_counts k on k.company_id = c.id
--   where (true) and exists (select 1 from public.client_companies retained
--                             where retained.company_id = c.id
--                               and retained.client_id = '<client>')
--
-- The planner does the right thing with it - it drives from the small side,
-- index-only over client_companies_pkey - and then pays for one companies_pkey
-- lookup per membership row purely to prove the company exists. On Unassigned,
-- which holds 151,188 of the 160,543 membership rows:
--
--   Index Only Scan using companies_pkey   loops=151188
--     Buffers: shared hit=559931 read=947
--   Execution Time: 977 ms
--
-- 559,931 of the statement's 561,031 buffer hits are that probe. Counting the
-- membership rows alone answers the same question in 17 ms.
--
-- WHY IT IS THE SAME NUMBER. client_companies_company_id_fkey is
--   FOREIGN KEY (company_id) REFERENCES companies(id) ON DELETE CASCADE
-- so a membership row cannot outlive its company, and the join can neither add
-- a row nor remove one. The FK is the reason this is a rewrite and not a
-- different answer; if it were ever dropped, this optimisation would have to go
-- with it. Asserted below so that cannot happen quietly.
--
-- WHEN IT APPLIES, AND WHY THE GUARD IS SO NARROW. Only when nothing in the
-- query mentions the companies row at all:
--
--   * a client is selected - otherwise there is no membership table to count
--   * the counting clause compiles to exactly 'true' - an empty search and no
--     filters. Anything else references c, and 'true' is what both
--     company_effective_filter_sql_v1 and company_full_scan_filter_sql_v1
--     return for empty input, so the ordinary unfiltered page takes this path
--   * no people scope - that adds "c.id in (select ...)" to the same predicate
--
-- Anything outside that keeps the existing plan, unchanged. This is the first
-- page of a client's Company DB, which is the page that is always loaded.
--
-- WHAT IT DOES NOT FIX. The listing as a whole is still slow on a large client:
-- the same call measured 10,101 ms end to end, and the dominant term is the
-- client_counts CTE aggregating prospect_index at query time plus the sort of
-- every matching company to return fifty rows. Denormalising a per-client
-- prospect count onto client_companies is the fix for that and is deliberately
-- not this migration - it needs a column, a backfill and a maintenance path.
-- This removes one whole second from the same call for the price of a guard.
-- ---------------------------------------------------------------------------

-- The FK this rewrite depends on.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.client_companies'::regclass
      and contype = 'f'
      and confrelid = 'public.companies'::regclass
  ) then
    raise exception 'client_companies has no foreign key to companies; counting membership rows would no longer be the same number as joining';
  end if;
end $$;

-- ---------------------------------------------------------------------------
do $BODY$
declare
  v_def text := pg_get_functiondef('public.filter_companies_v4'::regproc);
  v_declare_old constant text := '  v_where_counting text;';
  v_declare_new constant text := '  v_where_counting text;
  v_count_source text;
  v_count_pred text;';
  v_assign_old constant text :=
E'  v_where_counting := format(''(%s)'', v_counting_clause) || v_scope_suffix;';
  v_assign_new constant text :=
E'  v_where_counting := format(''(%s)'', v_counting_clause) || v_scope_suffix;

  -- The count only needs public.companies when something in the query mentions
  -- it. Unfiltered, inside a client, it does not: the membership rows are the
  -- answer, and the foreign key guarantees each one has a company behind it.
  -- 977 ms of primary-key probes against 17 ms of index-only scan.
  v_count_source := ''public.companies c'' || v_join;
  v_count_pred := v_where_counting;
  if p_client_id is not null
     and p_people_scope is null
     and btrim(v_counting_clause) = ''true'' then
    v_count_source := ''public.client_companies cc left join client_counts k on k.company_id = cc.company_id'';
    v_count_pred := format(''cc.client_id = %L'', p_client_id);
  end if;';
  v_template_old constant text :=
E'      from public.companies c%4$s
      where %8$s and %9$s
    )';
  v_template_new constant text :=
E'      from %11$s
      where %12$s and %9$s
    )';
  v_args_old constant text :=
E'  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_where_counting, v_want_total::text, v_versions::text);';
  v_args_new constant text :=
E'  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_where_counting, v_want_total::text, v_versions::text,
       v_count_source, v_count_pred);';
begin
  if position(v_declare_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer declares v_where_counting where expected';
  end if;
  if position(v_assign_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer assigns v_where_counting where expected';
  end if;
  if position(v_template_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer contains the counted CTE this migration rewrites';
  end if;
  if position(v_args_old in v_def) = 0 then
    raise exception 'filter_companies_v4 no longer passes the format arguments this migration extends';
  end if;

  -- Declaration, assignment, template and argument list in ONE rewrite. A
  -- partial application would store a function whose format() string references
  -- a placeholder it was never given.
  v_def := replace(v_def, v_declare_old, v_declare_new);
  v_def := replace(v_def, v_assign_old, v_assign_new);
  v_def := replace(v_def, v_template_old, v_template_new);
  v_def := replace(v_def, v_args_old, v_args_new);

  if position('%11$s' in v_def) = 0 or position('%12$s' in v_def) = 0
     or position('v_count_source, v_count_pred);' in v_def) = 0
     or position('public.client_companies cc left join client_counts k' in v_def) = 0 then
    raise exception 'the membership-count replacement did not take';
  end if;
  -- The page CTE must still read companies: only the count changed.
  if position(E'      from public.companies c%4$s\n      where %5$s' in v_def) = 0 then
    raise exception 'the page query stopped reading public.companies; only the count was meant to change';
  end if;
  execute v_def;
end
$BODY$;

-- ---------------------------------------------------------------------------
-- It is still the same function to everyone who calls it.
do $$
declare
  v_cfg text[];
begin
  select p.proconfig into v_cfg from pg_proc p where p.oid = 'public.filter_companies_v4'::regproc;
  if not (array_to_string(v_cfg, ',') like '%statement_timeout%') then
    raise exception 'filter_companies_v4 lost its statement_timeout: %', v_cfg;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The fast path returns exactly what the slow path returned, on every client.
-- Compared against the membership count directly, which is the number the fast
-- path now reads, AND against the old join, which is the number it replaces.
do $$
declare
  v_client record;
  v_fast record;
  v_by_join integer;
  v_by_membership integer;
begin
  for v_client in select id, name from public.clients order by id loop
    select total_count, covered_count, prospect_total into v_fast
    from public.filter_companies_v4('', '[]'::jsonb, v_client.id, null, 1, 0, null) limit 1;

    select count(*)::integer into v_by_membership
    from public.client_companies where client_id = v_client.id;

    execute format($q$
      select count(*)::integer from public.companies c
      where exists (select 1 from public.client_companies retained
                     where retained.company_id = c.id and retained.client_id = %L)
    $q$, v_client.id) into v_by_join;

    if v_by_join <> v_by_membership then
      raise exception 'client %: joining companies counted %, membership rows counted % - the foreign key is not holding', v_client.name, v_by_join, v_by_membership;
    end if;
    if v_fast.total_count is distinct from v_by_join then
      raise exception 'client %: the function returned % where the join counts %', v_client.name, v_fast.total_count, v_by_join;
    end if;
    -- covered_count and prospect_total still come from client_counts, so they
    -- must survive the source swap rather than quietly becoming zero.
    if v_fast.covered_count is null or v_fast.prospect_total is null then
      raise exception 'client %: covered_count or prospect_total went null when the count changed source', v_client.name;
    end if;
    if v_fast.covered_count > v_fast.total_count then
      raise exception 'client %: covered_count % exceeds total_count %', v_client.name, v_fast.covered_count, v_fast.total_count;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- A filtered request must NOT take the fast path: its predicate reads the
-- companies row, so counting membership alone would ignore the filter.
do $$
declare
  v_client text;
  v_filtered integer;
  v_unfiltered integer;
begin
  select id into v_client from public.clients
   where exists (select 1 from public.client_companies cc where cc.client_id = clients.id)
   order by id limit 1;
  if v_client is null then
    raise notice 'no client holds companies; the filtered guard is unproven';
    return;
  end if;

  select total_count into v_unfiltered
  from public.filter_companies_v4('', '[]'::jsonb, v_client, null, 1, 0, null) limit 1;
  -- A search that cannot match every company in the client.
  select total_count into v_filtered
  from public.filter_companies_v4('zzzzzzzzzznotacompany', '[]'::jsonb, v_client, null, 1, 0, null) limit 1;

  if v_filtered is null or v_unfiltered is null then
    raise notice 'no totals returned; the filtered guard is unproven';
    return;
  end if;
  if v_filtered >= v_unfiltered then
    raise exception 'a search returned % against % unfiltered - the filter was ignored, which is the fast path firing when it must not', v_filtered, v_unfiltered;
  end if;
end $$;
