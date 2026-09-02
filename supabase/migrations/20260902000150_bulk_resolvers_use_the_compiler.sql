-- Put the bulk resolvers on the complete compiler, like everything else.
--
-- Section 6.4: "Migrate listing, counts, pivots, exports and bulk resolvers
-- first". The listings, counts, pivots and exports moved in 20260902000000 and
-- 20260902000020. The bulk resolvers did not, and they are the ones that read
-- the most rows: a bulk action resolves the whole match set, not a page of it.
--
-- The row function is not inlinable, so every candidate that survives the
-- pre-filter pays a function call. A page of 50 hides that; "push all 40,000
-- matching" does not.
--
-- The size of the win therefore depends on how many rows survive the
-- pre-filter, and quoting only the large number would misrepresent it. Both
-- ends, measured on production through prospect_ids_matching_v1 before and
-- after, in one rolled-back transaction:
--
--   title contains + country equals    175 rows      784 ms ->   574 ms   (27%)
--   title NOT contains              200,000 rows  66,346 ms ->   411 ms  (161x)
--
-- The first shape's pre-filter narrows to 175 rows, so only 175 function calls
-- ever happen and there is little to save. The second is the case that matters:
-- the pre-filter handles contains and equals only, so a negative filter narrows
-- nothing and every row in the table went through the row function. A bulk
-- action carrying one took over a minute.
--
-- A caller inventory on production found five bulk resolvers still on the row
-- function. Four of them move here:
--
--   prospect_ids_matching_v1 (both overloads)  push, remove, tag, mark contacted
--   delete_prospects_matching_v1               delete all matching
--   delete_companies_matching_v1               delete all matching
--   set_company_icp_validated_v1               ICP verification
--
-- The fifth, resolve_company_action_selection_v1, is deliberately left alone.
-- It calls the row function from STATIC SQL:
--
--   or (p_company_ids is null and public.company_matches_filters_v1(
--         c, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)))
--
-- The compiler returns SQL text, which only helps a query built dynamically, so
-- moving that one means restructuring the function rather than substituting an
-- expression. It is a company bulk-selection path with its own authorization
-- checks, and a rewrite of it belongs in its own change with its own parity
-- run - not folded into a mechanical substitution across four others. Recorded
-- here so the remaining caller is a decision rather than an oversight.
--
-- SAME CONTRACT AS THE LISTINGS, NOT A NEW ONE. Each call site becomes
-- coalesce(<complete compiler>, <the row function>) - exactly the shape
-- search_prospect_workspace_v12 and search_prospect_export_v4 already use. When
-- the compiler can express the filter set it is used; when it cannot it returns
-- null and the row function still answers. A coverage gap therefore costs speed
-- and never correctness, which is the property that made this safe to do to the
-- listings and makes it safe here.
--
-- THE PREFILTERS AND ROW FUNCTIONS ARE NOT RETIRED. Section 6.4 is explicit that
-- they go "only after a caller inventory and parity prove no active dependency".
-- After this migration the inventory still shows live callers -
-- company_scope_ids_v2, client_company_workspace_v2, people_scope_company_ids_v1
-- and the fallback arm of every function touched here - so retiring them stays
-- out of scope and keeps the forward-fix path section 6.4 asks for.
--
-- SPLICED, WITH BOTH SHAPES CHECKED. The deployed bodies use two call-site
-- forms; each function must match exactly one, and a function matching neither
-- fails the migration rather than being skipped. That is the lesson of
-- 20260826050000 and of the empty-values guard 20260902000110 nearly shipped
-- past.

begin;

do $do$
declare
  v_targets text[] := array[
    'prospect_ids_matching_v1',
    'delete_prospects_matching_v1',
    'delete_companies_matching_v1',
    'set_company_icp_validated_v1'
  ];
  v_name text;
  v_proc oid;
  v_definition text;
  v_updated text;
  v_is_company boolean;
  v_row_call text;
  v_compiler text;
  v_shape_a_old text;
  v_shape_a_new text;
  v_shape_b_old text;
  v_shape_b_new text;
  v_close_old text;
  v_close_new text;
  v_migrated integer := 0;
  v_already integer := 0;
begin
  foreach v_name in array v_targets loop
    for v_proc in
      select p.oid from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = v_name
      order by p.oid
    loop
      v_definition := pg_get_functiondef(v_proc);

      -- Already on the compiler (an overload migrated earlier, or a re-run).
      if position('filter_sql_v1' in v_definition) > 0
         or position('company_filter_sql_v2' in v_definition) > 0 then
        v_already := v_already + 1;
        continue;
      end if;

      v_is_company := position('company_matches_filters_v1' in v_definition) > 0;
      if v_is_company then
        v_row_call := 'public.company_matches_filters_v1(c, %L, %L::jsonb)';
        v_compiler := 'public.company_filter_sql_v2';
      else
        v_row_call := 'public.prospect_index_matches_v1(pi, %L, %L::jsonb)';
        v_compiler := 'public.prospect_filter_sql_v1';
      end if;

      -- Shape A: the row call is the tail of a match-clause expression. The two
      -- deployed bodies put the line break in different places between the
      -- format string and its arguments, so the call is wrapped by replacing
      -- its opening and closing fragments separately. That is line-break
      -- agnostic where a single anchor was not - which is how
      -- set_company_icp_validated_v1 was missed on the first attempt.
      v_shape_a_old := format(E'|| format(%L,', v_row_call);
      v_shape_a_new := format(E'|| coalesce(%s(p_search, coalesce(p_filters, \'[]\'::jsonb)), format(%L,',
        v_compiler, v_row_call);
      v_close_old := E'coalesce(p_filters, \'[]\'::jsonb)::text);';
      v_close_new := E'coalesce(p_filters, \'[]\'::jsonb)::text));';

      -- Shape B: the row call is appended to the SQL directly.
      v_shape_b_old := format(
        E'format(\' and %s\',\n      coalesce(p_search, \'\'), coalesce(p_filters, \'[]\'::jsonb)::text)',
        v_row_call);
      v_shape_b_new := format(
        E'format(\' and (%%s)\', coalesce(%s(coalesce(p_search, \'\'), coalesce(p_filters, \'[]\'::jsonb)), format(%L, coalesce(p_search, \'\'), coalesce(p_filters, \'[]\'::jsonb)::text)))',
        v_compiler, v_row_call);

      if position(v_shape_a_old in v_definition) > 0 then
        -- Both halves or neither: an opening wrap without its closing paren
        -- would not compile, and is exactly the sort of half-applied edit this
        -- migration refuses to make.
        if (length(v_definition) - length(replace(v_definition, v_close_old, ''))) / length(v_close_old) <> 1 then
          raise exception 'Shape A in %: expected exactly one closing fragment for its opening', v_name
            using hint = 'Re-derive the anchors rather than letting a half-wrapped call through.';
        end if;
        v_updated := replace(replace(v_definition, v_shape_a_old, v_shape_a_new), v_close_old, v_close_new);
      elsif position(v_shape_b_old in v_definition) > 0 then
        v_updated := replace(v_definition, v_shape_b_old, v_shape_b_new);
      else
        raise exception 'Could not find a known call site in %(%)',
          v_name, pg_get_function_identity_arguments(v_proc)
          using hint = 'The deployed body changed shape. Re-derive the anchor rather than letting this skip.';
      end if;

      execute v_updated;
      v_migrated := v_migrated + 1;
    end loop;
  end loop;

  if v_migrated = 0 and v_already = 0 then
    raise exception 'No bulk resolver was found to migrate; the target list is stale.';
  end if;
  raise notice 'bulk resolvers on the compiler: % migrated, % already there', v_migrated, v_already;
end
$do$;

-- Prove it in the transaction that did it: every target now reaches the
-- compiler, and none of them lost its fallback.
do $do$
declare
  v_name text;
  v_proc oid;
  v_definition text;
  v_problems text[] := array[]::text[];
begin
  foreach v_name in array array['prospect_ids_matching_v1', 'delete_prospects_matching_v1',
                                'delete_companies_matching_v1',
                                'set_company_icp_validated_v1'] loop
    for v_proc in
      select p.oid from pg_proc p
      where p.pronamespace = 'public'::regnamespace and p.proname = v_name
    loop
      v_definition := pg_get_functiondef(v_proc);
      if position('filter_sql_v1' in v_definition) = 0
         and position('company_filter_sql_v2' in v_definition) = 0 then
        v_problems := v_problems || (v_name || ' still never reaches the compiler');
      end if;
      -- The fallback is what makes a coverage gap cost speed rather than rows.
      if position('matches_filters_v1' in v_definition) = 0
         and position('index_matches_v1' in v_definition) = 0 then
        v_problems := v_problems || (v_name || ' lost its row-function fallback');
      end if;
    end loop;
  end loop;

  if cardinality(v_problems) > 0 then
    raise exception 'bulk resolver migration is incomplete: %', array_to_string(v_problems, '; ');
  end if;
end
$do$;

commit;
