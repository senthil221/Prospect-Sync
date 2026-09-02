-- Durable filter sets: send ten thousand values once, then reference them.
--
-- Today a pasted list of exact values travels in full on every request. The cap
-- is 5,000 (lib/prospect-filters.ts), and at that size the filter payload is
-- roughly 75 KB re-sent for the page, the count, each subsequent page, the
-- pivot and every export page. 20260902000030 already recorded where that ends
-- up: "40 filters carrying thousands of values each produced megabytes of SQL,
-- where planning alone dominates".
--
-- Section 6.3 asks for the values to live in the database, addressed by a set
-- id, so the request carries a uuid instead of a column of domains.
--
-- IDENTITY, NOT THE UUID. Section 4.1 is explicit that a set's random id must
-- not affect cache identity: "If the AST references a setId, canonicalization
-- uses that set's immutable content hash and normalization version, never the
-- random UUID." Two users pasting the same 5,000 domains must produce the same
-- cache key. So the unique index is on (owner, entity, scope, field,
-- normalization_version, content_hash) and creating a set that already exists
-- returns the existing one rather than a second copy - idempotent per owner and
-- scope, as the section requires.
--
-- OWNERSHIP IS CHECKED, NOT INFERRED. Section 4.1: "Neither a hash nor a cache
-- hit is an authorization decision." Every read of a set takes the owner id and
-- verifies it. A set id is a bearer token otherwise, and they are guessable
-- enough to matter once they appear in URLs and logs.
--
-- PRIVATE SCHEMA, following prospect_import. Nothing here is reachable through
-- the Data API; the application calls the functions with the service role.
--
-- NORMALIZATION. Values are lowercased and trimmed here, which is exactly what
-- the compilers compare against: both prospect_filter_sql_v1 and
-- company_filter_sql_v2 emit `lower(<column>) = any (...)` for equals. The
-- application already normalizes domains, emails and LinkedIn URLs before
-- sending (lib/bulk-values.ts), so this is the second, authoritative pass
-- rather than the only one. normalization_version records which rules produced
-- the stored values, so a future change to them invalidates old sets instead of
-- silently comparing values normalized two different ways.
--
-- WHAT THIS DOES NOT DO: make the query faster. Measured on production with
-- 5,000 real domains matching 13,021 rows, the three available shapes:
--
--   array literal, 5,000 values (today) .. Parallel Seq Scan  170,530 buf   496 ms
--   filter set, as compiled below ........ Parallel Seq Scan  170,671 buf   650 ms
--   filter set, index-friendly form ...... Nested Loop+index   25,801 buf 2,492 ms
--
-- All the same order of magnitude, and the index-driven form is the slowest:
-- 5,000 random index probes lose to one sequential parallel scan on this box,
-- even while touching a sixth of the buffers. The planner picking a sequential
-- scan here is right, which is the same conclusion 20260902000010 reached about
-- broad company keywords.
--
-- So this is not a performance change and must not be sold as one. What it buys
-- is payload, ceiling and identity:
--
--   * the values travel once, not on every page, count, pivot and export page -
--     roughly 75 KB per request at the current 5,000 cap
--   * the emitted SQL drops from 82 KB to about 200 bytes, which is the cost
--     20260902000030 identified as dominating when filters multiply
--   * the ceiling moves from 5,000 to 10,000
--   * normalization and deduplication happen once, server side, and produce a
--     stable content hash the count cache can key on
--
-- One thing the measurement exposed in passing: the compilers wrap candidates as
-- lower(coalesce(<column>, '')), which does not match the
-- idx_prospect_index_company_domain_lower expression - that index is on
-- lower(company_domain). Only the pre-filter, which omits the coalesce, can use
-- it. That is not costing latency today (form B above is faster than form A),
-- but it means the index earns its keep solely through the pre-filter path. Left
-- alone deliberately rather than "fixed" into the slower plan.
--
-- NOT BUILT, with the measurement: section 6.2 also asks for a
-- reindex-maintained prospect_index.normalized_domain to join against. Measured
-- on production first:
--
--   companies where domain <> normalized_domain ............. 0 of 419,214
--   prospect_index rows that would miss an exact match ...... 0 of 656,431
--
-- companies.domain is already stored in its normalized form - the application
-- normalizes before insert - so prospect_index.company_domain inherits it and
-- the existing idx_prospect_index_company_domain_lower already serves exact
-- matching correctly. A new column would duplicate a correct one and add
-- reindex write cost to do it. The invariant is enforced below instead, so the
-- existing index stays correct by construction rather than by convention.

begin;

create schema if not exists prospect_filters;
revoke all on schema prospect_filters from public, anon, authenticated;

create table if not exists prospect_filters.filter_sets (
  id uuid primary key default gen_random_uuid(),
  owner_id text not null,
  entity_type text not null check (entity_type in ('prospect', 'company')),
  -- '' rather than null, so the unique index below treats "no client scope" as
  -- one value instead of as many distinct nulls that never collide.
  client_scope text not null default '',
  field text not null,
  normalization_version integer not null,
  content_hash text not null,
  value_count integer not null check (value_count between 1 and 10000),
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  expires_at timestamptz not null
);
revoke all on prospect_filters.filter_sets from public, anon, authenticated;

-- The identity from section 4.1. Creating the same set twice returns the first.
create unique index if not exists uq_filter_sets_identity
  on prospect_filters.filter_sets (owner_id, entity_type, client_scope, field, normalization_version, content_hash);
create index if not exists idx_filter_sets_expires_at
  on prospect_filters.filter_sets (expires_at);

create table if not exists prospect_filters.filter_set_values (
  filter_set_id uuid not null references prospect_filters.filter_sets(id) on delete cascade,
  normalized_value text not null,
  -- This primary key is the whole point: the compiled predicate probes it once
  -- per candidate row instead of carrying 10,000 values through the SQL text.
  primary key (filter_set_id, normalized_value)
);
revoke all on prospect_filters.filter_set_values from public, anon, authenticated;

-- Create a set, or return the identical one that already exists.
--
-- Returns reused = true when an existing set matched, so the caller can tell the
-- difference between "stored 10,000 values" and "recognised them".
create or replace function prospect_filters.create_set_v1(
  p_owner_id text,
  p_entity_type text,
  p_client_scope text,
  p_field text,
  p_values text[],
  p_ttl interval default interval '7 days'
)
returns table(set_id uuid, content_hash text, value_count integer, reused boolean)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_filters
set statement_timeout = '30s'
as $function$
declare
  v_normalization_version constant integer := 1;
  v_scope text := coalesce(p_client_scope, '');
  v_values text[];
  v_hash text;
  v_count integer;
  v_existing uuid;
  v_new uuid;
begin
  if coalesce(btrim(p_owner_id), '') = '' then
    raise exception 'A filter set needs an owner' using errcode = '22023';
  end if;
  if p_entity_type not in ('prospect', 'company') then
    raise exception 'Unknown entity type %', p_entity_type using errcode = '22023';
  end if;
  if coalesce(btrim(p_field), '') = '' then
    raise exception 'A filter set needs a field' using errcode = '22023';
  end if;

  -- Normalize, drop blanks, deduplicate, and order. Ordering is what makes the
  -- hash independent of the order the values were pasted in.
  select array_agg(value order by value) into v_values
  from (select distinct lower(btrim(unnested)) as value
        from unnest(coalesce(p_values, array[]::text[])) as unnested
        where btrim(coalesce(unnested, '')) <> '') deduplicated;

  v_count := coalesce(cardinality(v_values), 0);
  if v_count = 0 then
    raise exception 'A filter set needs at least one value' using errcode = '22023';
  end if;
  if v_count > 10000 then
    raise exception 'A filter set holds at most 10000 values, received %', v_count
      using errcode = '22023',
            hint = 'Split the list and run it in batches.';
  end if;

  v_hash := md5(array_to_string(v_values, E'\n'));

  select fs.id into v_existing
  from prospect_filters.filter_sets fs
  where fs.owner_id = p_owner_id
    and fs.entity_type = p_entity_type
    and fs.client_scope = v_scope
    and fs.field = p_field
    and fs.normalization_version = v_normalization_version
    and fs.content_hash = v_hash;

  if v_existing is not null then
    -- Recognised. Extend its life rather than storing the values again.
    update prospect_filters.filter_sets
    set last_used_at = now(), expires_at = greatest(expires_at, now() + p_ttl)
    where id = v_existing;
    return query select v_existing, v_hash, v_count, true;
    return;
  end if;

  insert into prospect_filters.filter_sets
    (owner_id, entity_type, client_scope, field, normalization_version, content_hash, value_count, expires_at)
  values (p_owner_id, p_entity_type, v_scope, p_field, v_normalization_version, v_hash, v_count, now() + p_ttl)
  returning id into v_new;

  insert into prospect_filters.filter_set_values (filter_set_id, normalized_value)
  select v_new, value from unnest(v_values) as value;

  return query select v_new, v_hash, v_count, false;
end;
$function$;

-- Resolve a set for use. Returns its identity only when the caller owns it and
-- it has not expired; a hash is not an authorization decision, so this is the
-- single place that decides whether a set id may be used at all.
create or replace function prospect_filters.resolve_set_v1(
  p_set_id uuid,
  p_owner_id text,
  p_entity_type text,
  p_client_scope text default ''
)
returns table(set_id uuid, content_hash text, value_count integer, field text)
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_filters
set statement_timeout = '10s'
as $function$
declare
  v_row prospect_filters.filter_sets%rowtype;
begin
  select * into v_row from prospect_filters.filter_sets fs
  where fs.id = p_set_id
    and fs.owner_id = p_owner_id
    and fs.entity_type = p_entity_type
    and fs.client_scope = coalesce(p_client_scope, '')
    and fs.expires_at > now();

  if not found then
    -- Deliberately one message for "no such set", "not yours" and "expired": a
    -- caller probing ids learns nothing from the difference.
    raise exception 'Filter set is not available' using errcode = 'P0002';
  end if;

  update prospect_filters.filter_sets set last_used_at = now() where id = v_row.id;
  return query select v_row.id, v_row.content_hash, v_row.value_count, v_row.field;
end;
$function$;

-- TTL cleanup. Returns how many sets went, so a caller can log it.
create or replace function prospect_filters.expire_sets_v1()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, prospect_filters
set statement_timeout = '60s'
as $function$
declare
  v_deleted integer;
begin
  with removed as (
    delete from prospect_filters.filter_sets where expires_at <= now() returning 1
  )
  select count(*)::integer into v_deleted from removed;
  return v_deleted;
end;
$function$;

-- Storage monitoring, as section 6.3 asks for.
create or replace function prospect_filters.usage_v1()
returns table(sets bigint, values_stored bigint, bytes bigint, oldest timestamptz)
language sql
stable
security definer
set search_path = pg_catalog, public, prospect_filters
as $function$
  select (select count(*) from prospect_filters.filter_sets),
         (select count(*) from prospect_filters.filter_set_values),
         pg_total_relation_size('prospect_filters.filter_set_values')
           + pg_total_relation_size('prospect_filters.filter_sets'),
         (select min(created_at) from prospect_filters.filter_sets);
$function$;

-- The invariant that makes prospect_index.normalized_domain unnecessary.
--
-- companies.domain is stored already-normalized by the application, which is
-- why lower(company_domain) on the index is a correct exact-match key. That was
-- true by convention; NOT VALID makes it true by constraint for every future
-- write without taking a full-table lock to re-check 419,214 existing rows,
-- which were measured to have zero violations.
alter table public.companies
  drop constraint if exists companies_domain_is_normalized;
alter table public.companies
  add constraint companies_domain_is_normalized
  check (domain is null or normalized_domain is null or lower(domain) = normalized_domain)
  not valid;

revoke execute on function prospect_filters.create_set_v1(text, text, text, text, text[], interval) from public, anon, authenticated;
revoke execute on function prospect_filters.resolve_set_v1(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function prospect_filters.expire_sets_v1() from public, anon, authenticated;
revoke execute on function prospect_filters.usage_v1() from public, anon, authenticated;
grant usage on schema prospect_filters to service_role;
grant execute on function prospect_filters.create_set_v1(text, text, text, text, text[], interval) to service_role;
grant execute on function prospect_filters.resolve_set_v1(uuid, text, text, text) to service_role;
grant execute on function prospect_filters.expire_sets_v1() to service_role;
grant execute on function prospect_filters.usage_v1() to service_role;

commit;
