--
-- PostgreSQL database dump
--

-- Dumped from database version 15.8
-- Dumped by pg_dump version 15.8

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: prospect_exports; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA prospect_exports;


ALTER SCHEMA prospect_exports OWNER TO postgres;

--
-- Name: prospect_filters; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA prospect_filters;


ALTER SCHEMA prospect_filters OWNER TO postgres;

--
-- Name: prospect_import; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA prospect_import;


ALTER SCHEMA prospect_import OWNER TO postgres;

--
-- Name: prospect_integrations; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA prospect_integrations;


ALTER SCHEMA prospect_integrations OWNER TO postgres;

--
-- Name: prospect_operations; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA prospect_operations;


ALTER SCHEMA prospect_operations OWNER TO postgres;

--
-- Name: prospect_results; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA prospect_results;


ALTER SCHEMA prospect_results OWNER TO postgres;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: supabase_migrations; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA supabase_migrations;


ALTER SCHEMA supabase_migrations OWNER TO postgres;

--
-- Name: build_batch_v1(uuid, integer, integer); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.build_batch_v1(p_job_id uuid, p_batch_size integer DEFAULT 5000, p_lease_seconds integer DEFAULT 300) RETURNS TABLE(appended integer, total_rows bigint, total_parts integer, done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports', 'prospect_results'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_job prospect_exports.jobs%rowtype;
  v_set_status text;
  v_batch integer := greatest(500, least(coalesce(p_batch_size, 5000), 25000));
  v_rows jsonb;
  v_kept integer;
  v_scanned integer;
  v_last_ordinal bigint;
  v_part integer;
begin
  select * into v_job from prospect_exports.jobs where id = p_job_id for update;
  if not found then
    raise exception 'That export job does not exist' using errcode = 'P0002';
  end if;
  if v_job.status not in ('queued', 'building') then
    return query select 0, v_job.row_count, v_job.part_count, true;
    return;
  end if;

  select rs.status into v_set_status from prospect_results.result_sets rs where rs.id = v_job.result_set_id;
  if v_set_status is null then
    raise exception 'The result set this export was built from is gone; ask for the export again' using errcode = 'P0002';
  end if;
  if v_set_status <> 'ready' then
    raise exception 'That result set is not finished yet' using errcode = '22023';
  end if;

  -- Two numbers, deliberately separate. `scanned` and the last ordinal come from
  -- the ids in the set, so an excluded id and an id deleted since the set was
  -- frozen both advance the cursor; `kept` counts only what went into the file.
  -- Taking either from the hydrated rows would stall a job whose whole batch was
  -- excluded.
  if v_job.entity_type = 'prospect' then
    with batch as (
      select i.ordinal, i.entity_id
      from prospect_results.result_set_items i
      where i.result_set_id = v_job.result_set_id and i.ordinal > v_job.next_ordinal
      order by i.ordinal
      limit v_batch
    ), hydrated as (
      select b.ordinal, public.jsonb_project_v1(to_jsonb(pi), v_job.keys) as row_json
      from batch b
      join public.prospect_export_source pi on pi.id = b.entity_id
      where not (b.entity_id = any (v_job.excluded_ids))
    )
    select (select jsonb_agg(hydrated.row_json order by hydrated.ordinal) from hydrated),
           (select count(*)::integer from hydrated),
           (select count(*)::integer from batch),
           (select max(batch.ordinal) from batch)
    into v_rows, v_kept, v_scanned, v_last_ordinal;
  else
    with batch as (
      select i.ordinal, i.entity_id
      from prospect_results.result_set_items i
      where i.result_set_id = v_job.result_set_id and i.ordinal > v_job.next_ordinal
      order by i.ordinal
      limit v_batch
    ), hydrated as (
      select b.ordinal, public.jsonb_project_v1(to_jsonb(c), v_job.keys) as row_json
      from batch b
      join public.companies c on c.id = b.entity_id
      where not (b.entity_id = any (v_job.excluded_ids))
    )
    select (select jsonb_agg(hydrated.row_json order by hydrated.ordinal) from hydrated),
           (select count(*)::integer from hydrated),
           (select count(*)::integer from batch),
           (select max(batch.ordinal) from batch)
    into v_rows, v_kept, v_scanned, v_last_ordinal;
  end if;

  v_scanned := coalesce(v_scanned, 0);
  v_kept := coalesce(v_kept, 0);

  if v_scanned = 0 then
    update prospect_exports.jobs
    set status = 'ready', completed_at = now(), lease_expires_at = null, worker_id = null
    where id = p_job_id;
    return query select 0, v_job.row_count, v_job.part_count, true;
    return;
  end if;

  v_part := v_job.part_count + 1;
  if v_kept > 0 then
    insert into prospect_exports.job_parts (job_id, part_index, row_count, rows)
    values (p_job_id, v_part, v_kept, v_rows)
    on conflict (job_id, part_index) do nothing;
  end if;

  update prospect_exports.jobs
  set row_count = jobs.row_count + v_kept,
      byte_count = jobs.byte_count + case when v_kept > 0 then pg_column_size(v_rows) else 0 end,
      part_count = case when v_kept > 0 then v_part else jobs.part_count end,
      next_ordinal = v_last_ordinal,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds)),
      status = case when v_scanned < v_batch then 'ready' else jobs.status end,
      completed_at = case when v_scanned < v_batch then now() else jobs.completed_at end
  where jobs.id = p_job_id
  returning jobs.row_count, jobs.part_count, jobs.status = 'ready'
  into total_rows, total_parts, done;

  appended := v_kept;
  return next;
end;
$$;


ALTER FUNCTION prospect_exports.build_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) OWNER TO postgres;

--
-- Name: claim_next_v1(text, integer); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.claim_next_v1(p_worker_id text, p_lease_seconds integer DEFAULT 300) RETURNS TABLE(job_id uuid, entity_type text, result_set_id uuid, row_count bigint, next_ordinal bigint, set_rows bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_id uuid;
begin
  select j.id into v_id
  from prospect_exports.jobs j
  join prospect_results.result_sets rs on rs.id = j.result_set_id
  where j.expires_at > now()
    and rs.status = 'ready'
    and (j.status = 'queued'
         or (j.status = 'building' and coalesce(j.lease_expires_at, now()) <= now()))
  order by j.created_at
  for update of j skip locked
  limit 1;

  if v_id is null then return; end if;

  update prospect_exports.jobs j
  set status = 'building',
      worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds)),
      started_at = coalesce(j.started_at, now())
  where j.id = v_id;

  return query
  select j.id, j.entity_type, j.result_set_id, j.row_count, j.next_ordinal, rs.row_count
  from prospect_exports.jobs j
  join prospect_results.result_sets rs on rs.id = j.result_set_id
  where j.id = v_id;
end;
$$;


ALTER FUNCTION prospect_exports.claim_next_v1(p_worker_id text, p_lease_seconds integer) OWNER TO postgres;

--
-- Name: expire_jobs_v1(); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.expire_jobs_v1() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations'
    AS $$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('export',5000); $$;


ALTER FUNCTION prospect_exports.expire_jobs_v1() OWNER TO postgres;

--
-- Name: fail_v1(uuid, text); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.fail_v1(p_job_id uuid, p_error text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_exports'
    SET statement_timeout TO '15s'
    AS $$
  update prospect_exports.jobs
  set status = 'failed', error = left(coalesce(p_error, 'Export failed'), 2000),
      lease_expires_at = null, worker_id = null, completed_at = now()
  where id = p_job_id;
$$;


ALTER FUNCTION prospect_exports.fail_v1(p_job_id uuid, p_error text) OWNER TO postgres;

--
-- Name: part_v1(uuid, text, text, integer); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) RETURNS TABLE(rows jsonb, row_count integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_exports'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_job prospect_exports.jobs%rowtype;
begin
  select * into v_job from prospect_exports.jobs j where j.id = p_job_id;
  if not found or v_job.owner_id is distinct from p_owner_id then
    raise exception 'That export does not exist' using errcode = 'P0002';
  end if;
  if v_job.download_token is distinct from p_token then
    raise exception 'That download link is not valid' using errcode = '42501';
  end if;
  if v_job.expires_at <= now() then
    raise exception 'That download has expired' using errcode = '22023';
  end if;
  if v_job.status <> 'ready' then
    raise exception 'That export is not finished yet' using errcode = '22023';
  end if;

  return query
  select p.rows, p.row_count from prospect_exports.job_parts p
  where p.job_id = p_job_id and p.part_index = p_part_index;
end;
$$;


ALTER FUNCTION prospect_exports.part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) OWNER TO postgres;

--
-- Name: parts_present_v1(uuid); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.parts_present_v1(p_job_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_exports'
    AS $$
  select (select j.part_count from prospect_exports.jobs j where j.id = p_job_id)
       = (select count(*)::integer from prospect_exports.job_parts p where p.job_id = p_job_id);
$$;


ALTER FUNCTION prospect_exports.parts_present_v1(p_job_id uuid) OWNER TO postgres;

--
-- Name: request_v1(text, text, text, text, uuid, text[], text[], text[], text, interval); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.request_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[] DEFAULT '{}'::text[], p_keys text[] DEFAULT '{}'::text[], p_excluded_ids text[] DEFAULT '{}'::text[], p_file_base_name text DEFAULT 'export'::text, p_ttl interval DEFAULT '24:00:00'::interval) RETURNS TABLE(job_id uuid, status text, row_count bigint, download_token text, reused boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_existing prospect_exports.jobs%rowtype;
  v_set prospect_results.result_sets%rowtype;
  v_id uuid;
  v_token text;
begin
  if coalesce(btrim(p_owner_id), '') = '' then
    raise exception 'An export needs an owner' using errcode = '22023';
  end if;
  if coalesce(btrim(p_request_id), '') = '' then
    raise exception 'An export needs a request id' using errcode = '22023';
  end if;

  select * into v_existing from prospect_exports.jobs j
  where j.owner_id = p_owner_id and j.request_id = p_request_id;
  if found then
    return query select v_existing.id, v_existing.status, v_existing.row_count, v_existing.download_token, true;
    return;
  end if;

  -- The result set is the authorization: a job may only be built from a set its
  -- own owner asked for. Without this check a guessed request would be enough
  -- to export somebody else's frozen list.
  select * into v_set from prospect_results.result_sets rs where rs.id = p_result_set_id and rs.expires_at > now() for update;
  if not found then
    raise exception 'That result set does not exist' using errcode = 'P0002';
  end if;
  if v_set.owner_id is distinct from p_owner_id then
    raise exception 'That result set belongs to someone else' using errcode = '42501';
  end if;
  if v_set.entity_type is distinct from p_entity_type then
    raise exception 'That result set is not a % set', p_entity_type using errcode = '22023';
  end if;

  -- Two UUIDs rather than gen_random_bytes: that one lives in pgcrypto, which
  -- this database has never been asked to install, and a token generator is a
  -- poor reason to take a new extension dependency. gen_random_uuid is core and
  -- draws on the same strong RNG, so 64 hex characters here is 244 bits.
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into prospect_exports.jobs
    (owner_id, request_id, entity_type, client_scope, result_set_id, fields, keys, excluded_ids,
     file_base_name, download_token, expires_at)
  values (p_owner_id, p_request_id, p_entity_type, coalesce(p_client_scope, ''), p_result_set_id,
          coalesce(p_fields, '{}'::text[]), coalesce(p_keys, '{}'::text[]), coalesce(p_excluded_ids, '{}'::text[]),
          coalesce(nullif(btrim(p_file_base_name), ''), 'export'), v_token, now() + p_ttl)
  returning id into v_id;

  return query select v_id, 'queued'::text, 0::bigint, v_token, false;
end;
$$;


ALTER FUNCTION prospect_exports.request_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text, p_ttl interval) OWNER TO postgres;

--
-- Name: status_v1(uuid, text); Type: FUNCTION; Schema: prospect_exports; Owner: postgres
--

CREATE FUNCTION prospect_exports.status_v1(p_job_id uuid, p_owner_id text) RETURNS TABLE(job_id uuid, status text, row_count bigint, byte_count bigint, part_count integer, set_status text, set_rows bigint, entity_type text, file_base_name text, fields text[], download_token text, error text, expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_exports', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
begin
  return query
  select j.id, j.status, j.row_count, j.byte_count, j.part_count,
         rs.status, rs.row_count, j.entity_type, j.file_base_name, j.fields,
         j.download_token, j.error, j.expires_at
  from prospect_exports.jobs j
  left join prospect_results.result_sets rs on rs.id = j.result_set_id
  where j.id = p_job_id and j.owner_id = p_owner_id;
  if not found then
    raise exception 'That export does not exist' using errcode = 'P0002';
  end if;
end;
$$;


ALTER FUNCTION prospect_exports.status_v1(p_job_id uuid, p_owner_id text) OWNER TO postgres;

--
-- Name: create_set_v1(text, text, text, text, text[], interval); Type: FUNCTION; Schema: prospect_filters; Owner: postgres
--

CREATE FUNCTION prospect_filters.create_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[], p_ttl interval DEFAULT '7 days'::interval) RETURNS TABLE(set_id uuid, content_hash text, value_count integer, reused boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_filters'
    SET statement_timeout TO '30s'
    AS $$
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
    and fs.content_hash = v_hash for update;

  if v_existing is not null then
    insert into prospect_filters.filter_set_values(filter_set_id,normalized_value) select v_existing,value from unnest(v_values) value on conflict do nothing;
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
$$;


ALTER FUNCTION prospect_filters.create_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[], p_ttl interval) OWNER TO postgres;

--
-- Name: expire_sets_v1(); Type: FUNCTION; Schema: prospect_filters; Owner: postgres
--

CREATE FUNCTION prospect_filters.expire_sets_v1() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations'
    AS $$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('filter',5000); $$;


ALTER FUNCTION prospect_filters.expire_sets_v1() OWNER TO postgres;

--
-- Name: resolve_set_v1(uuid, text, text, text); Type: FUNCTION; Schema: prospect_filters; Owner: postgres
--

CREATE FUNCTION prospect_filters.resolve_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text DEFAULT ''::text) RETURNS TABLE(set_id uuid, content_hash text, value_count integer, field text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_filters'
    SET statement_timeout TO '10s'
    AS $$
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
$$;


ALTER FUNCTION prospect_filters.resolve_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text) OWNER TO postgres;

--
-- Name: usage_v1(); Type: FUNCTION; Schema: prospect_filters; Owner: postgres
--

CREATE FUNCTION prospect_filters.usage_v1() RETURNS TABLE(sets bigint, values_stored bigint, bytes bigint, oldest timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_filters'
    AS $$
  select (select count(*) from prospect_filters.filter_sets),
         (select count(*) from prospect_filters.filter_set_values),
         pg_total_relation_size('prospect_filters.filter_set_values')
           + pg_total_relation_size('prospect_filters.filter_sets'),
         (select min(created_at) from prospect_filters.filter_sets);
$$;


ALTER FUNCTION prospect_filters.usage_v1() OWNER TO postgres;

--
-- Name: process_staged_batch_v1(text, text, integer, integer); Type: FUNCTION; Schema: prospect_import; Owner: postgres
--

CREATE FUNCTION prospect_import.process_staged_batch_v1(p_import_id text, p_list_id text, p_row_offset integer, p_batch_size integer DEFAULT 1000) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_import'
    SET statement_timeout TO '120s'
    AS $$
declare
  rows_payload jsonb;
  selected_count integer;
  first_offset integer;
  last_offset integer;
  base_result record;
begin
  if p_row_offset is null or p_row_offset < 0 then
    raise exception 'A non-negative row offset is required' using errcode = '22023';
  end if;
  if p_batch_size < 100 or p_batch_size > 5000 then
    raise exception 'Batch size must be between 100 and 5000' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.imports i
    where i.id = p_import_id and i.list_id = p_list_id
      and i.status = 'processing' and i.committed_row_offset = p_row_offset
  ) then
    raise exception 'Import cursor does not match the requested staged batch' using errcode = 'P0002';
  end if;

  select jsonb_agg(batch.payload order by batch.row_offset), count(*)::integer,
    min(batch.row_offset), max(batch.row_offset)
  into rows_payload, selected_count, first_offset, last_offset
  from (
    select sr.row_offset, sr.payload
    from prospect_import.staged_rows sr
    where sr.import_id = p_import_id and sr.row_offset >= p_row_offset
    order by sr.row_offset
    limit p_batch_size
  ) batch;

  if selected_count = 0 then
    return query select 0, 0, 0, 0;
    return;
  end if;
  if first_offset <> p_row_offset or last_offset <> p_row_offset + selected_count - 1 then
    raise exception 'Staged import rows are not contiguous at offset %', p_row_offset using errcode = 'P0002';
  end if;

  select * into base_result
  from public.import_prospect_batch_v5(p_import_id, p_list_id, rows_payload, p_row_offset);

  delete from prospect_import.staged_rows
  where import_id = p_import_id and row_offset between first_offset and last_offset;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;


ALTER FUNCTION prospect_import.process_staged_batch_v1(p_import_id text, p_list_id text, p_row_offset integer, p_batch_size integer) OWNER TO postgres;

--
-- Name: claim_v1(text); Type: FUNCTION; Schema: prospect_integrations; Owner: postgres
--

CREATE FUNCTION prospect_integrations.claim_v1(p_kind text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare c public.integration_connections%rowtype; j prospect_integrations.jobs%rowtype; b prospect_integrations.batches%rowtype; r prospect_integrations.campaign_requests%rowtype;
begin
  select * into c from public.integration_connections where provider='smartlead' for update;
  update prospect_integrations.jobs expired_job set status='needs_review',error_code='worker_lease_expired'
    where expired_job.status in ('queued','running') and exists(select 1 from prospect_integrations.batches expired_batch where expired_batch.job_id=expired_job.id and (expired_batch.status='needs_review' or (expired_batch.status='sending' and expired_batch.lease_until<=now())));
  update prospect_integrations.batches set status='needs_review',outcome='{"reason":"worker_lease_expired"}' where status='sending' and lease_until<=now();
  update prospect_integrations.campaign_requests set status='needs_review',error_code='worker_lease_expired' where status='sending' and lease_until<=now();
  update prospect_integrations.jobs set status='needs_review',error_code='draft_expired' where status in ('queued','running') and expires_at<=now();
  if not c.connected or c.next_request_at>now() or exists(select 1 from prospect_integrations.batches where status='sending')
    or exists(select 1 from prospect_integrations.campaign_requests where status='sending') then return null; end if;
  if p_kind='create' then
    select * into r from prospect_integrations.campaign_requests where status='queued' and next_attempt_at<=now() order by created_at for update skip locked limit 1;
    if not found then return null; end if;
    if r.generation<>c.generation or r.attempts>=8 or r.created_at<now()-interval '1 day' then
      update prospect_integrations.campaign_requests set status='needs_review',error_code='connection_changed_or_retry_limit' where id=r.id; return null; end if;
    update prospect_integrations.campaign_requests set status='sending',token=gen_random_uuid(),lease_until=now()+interval '120 seconds',attempts=attempts+1 where id=r.id returning * into r;
    update public.integration_connections set next_request_at=now()+interval '120 seconds' where provider='smartlead';
    return jsonb_build_object('kind','create','id',r.id,'token',r.token,'name',r.name,'attempts',r.attempts,'credential',c.credential_ciphertext);
  end if;
  if p_kind<>'upload' then return null; end if;
  select * into j from prospect_integrations.jobs queued_job where queued_job.status in ('queued','running')
    and exists(select 1 from prospect_integrations.batches queued_batch where queued_batch.job_id=queued_job.id and queued_batch.status='pending' and queued_batch.next_attempt_at<=now())
    order by coalesce(queued_job.last_attempt_at,queued_job.created_at) for update skip locked limit 1;
  if not found then return null; end if;
  if j.connection_generation is distinct from c.generation or not exists(select 1 from prospect_integrations.client_campaigns where client_id=j.client_id and campaign_id=j.campaign_id and enabled and generation=c.generation) then
    update prospect_integrations.jobs set status='needs_review',error_code='destination_changed' where id=j.id; return null; end if;
  select * into b from prospect_integrations.batches where job_id=j.id and status='pending' and next_attempt_at<=now() order by ordinal for update limit 1;
  if b.attempts>=8 then update prospect_integrations.jobs set status='needs_review',error_code='retry_limit' where id=j.id; return null; end if;
  update prospect_integrations.batches set status='sending',attempt_token=gen_random_uuid(),lease_until=now()+interval '120 seconds',attempts=attempts+1 where id=b.id returning * into b;
  update prospect_integrations.jobs set status='running',last_attempt_at=now(),error_code=null where id=j.id;
  update public.integration_connections set next_request_at=now()+interval '120 seconds' where provider='smartlead';
  return jsonb_build_object('kind','upload','id',b.id,'token',b.attempt_token,'campaign',j.campaign_id,'allowActive',j.allow_active,'attempts',b.attempts,'credential',c.credential_ciphertext);
end;
$$;


ALTER FUNCTION prospect_integrations.claim_v1(p_kind text) OWNER TO postgres;

--
-- Name: cleanup_v1(); Type: FUNCTION; Schema: prospect_integrations; Owner: postgres
--

CREATE FUNCTION prospect_integrations.cleanup_v1() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare ids uuid[]; removed integer;
begin
  select array_agg(id) into ids from (select id from prospect_integrations.jobs where status in ('completed','cancelled')
    and created_at<now()-interval '30 days' order by created_at for update skip locked limit 10) old_jobs;
  delete from prospect_integrations.batches where job_id=any(ids);
  delete from prospect_integrations.jobs where id=any(ids);
  get diagnostics removed=row_count;
  delete from prospect_integrations.campaign_requests where id in (select id from prospect_integrations.campaign_requests
    where status in ('completed','cancelled') and created_at<now()-interval '30 days' order by created_at limit 10);
  return removed;
end;
$$;


ALTER FUNCTION prospect_integrations.cleanup_v1() OWNER TO postgres;

--
-- Name: finish_v1(text, uuid, uuid, text, jsonb, integer); Type: FUNCTION; Schema: prospect_integrations; Owner: postgres
--

CREATE FUNCTION prospect_integrations.finish_v1(p_kind text, p_id uuid, p_token uuid, p_state text, p_result jsonb, p_delay integer DEFAULT 5) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare c public.integration_connections%rowtype; b prospect_integrations.batches%rowtype; r prospect_integrations.campaign_requests%rowtype; j prospect_integrations.jobs%rowtype; v_generation uuid;
begin
  if p_state not in ('completed','cooldown','read_retry','connection_paused','rejected','needs_review')
    or p_result is null or jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>262144 then return false; end if;
  select * into c from public.integration_connections where provider='smartlead' for update;
  if p_kind='create' then
    select * into r from prospect_integrations.campaign_requests where id=p_id and token=p_token and status='sending' and lease_until>now() for update;
    if not found then return false; end if;
    v_generation:=r.generation;
    update prospect_integrations.campaign_requests set status=case when p_state='completed' then 'completed' when p_state in ('cooldown','read_retry') then 'queued' else 'needs_review' end,
      error_code=p_result->>'reason',campaign_id=(p_result->>'campaignId')::bigint,next_attempt_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))) where id=p_id;
    if p_state='completed' and r.generation=c.generation and c.connected then
      insert into prospect_integrations.client_campaigns(campaign_id,client_id,generation,campaign_name,updated_by)
        values((p_result->>'campaignId')::bigint,r.client_id,r.generation,r.name,r.actor) on conflict(campaign_id) do nothing;
      if not exists(select 1 from prospect_integrations.client_campaigns where campaign_id=(p_result->>'campaignId')::bigint and client_id=r.client_id and enabled and generation=r.generation) then
        update prospect_integrations.campaign_requests set status='needs_review',error_code='campaign_destination_conflict' where id=p_id;
      end if;
    elsif p_state='completed' then
      update prospect_integrations.campaign_requests set status='needs_review',error_code='connection_changed_after_creation' where id=p_id;
    end if;
  elsif p_kind='upload' then
    select j0.* into j from prospect_integrations.jobs j0 join prospect_integrations.batches b0 on b0.job_id=j0.id where b0.id=p_id for update of j0;
    select * into b from prospect_integrations.batches where id=p_id and attempt_token=p_token and status='sending' and lease_until>now() for update;
    if not found then return false; end if;
    v_generation:=j.connection_generation;
    update prospect_integrations.batches set status=case when p_state='completed' then 'completed' when p_state in ('cooldown','read_retry') and j.status='running' then 'pending' else 'needs_review' end,
      outcome=p_result,next_attempt_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))) where id=p_id;
    update prospect_integrations.jobs set status=case when exists(select 1 from prospect_integrations.batches where job_id=j.id and status='needs_review') or j.status='needs_review' then 'needs_review'
      when not exists(select 1 from prospect_integrations.batches where job_id=j.id and status<>'completed') then 'completed' else status end,
      error_code=p_result->>'reason' where id=j.id;
  else return false; end if;
  update public.integration_connections set next_request_at=now()+make_interval(secs=>greatest(5,least(coalesce(p_delay,60),86400))),
    connected=case when p_state='connection_paused' then false else connected end where provider='smartlead' and generation=v_generation;
  return true;
end;
$$;


ALTER FUNCTION prospect_integrations.finish_v1(p_kind text, p_id uuid, p_token uuid, p_state text, p_result jsonb, p_delay integer) OWNER TO postgres;

--
-- Name: prepare_upload_v1(uuid, uuid); Type: FUNCTION; Schema: prospect_integrations; Owner: postgres
--

CREATE FUNCTION prospect_integrations.prepare_upload_v1(p_batch uuid, p_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare c public.integration_connections%rowtype; j prospect_integrations.jobs%rowtype; b prospect_integrations.batches%rowtype; v_payload jsonb;
begin
  select * into c from public.integration_connections where provider='smartlead' for share;
  select j0.* into j from prospect_integrations.jobs j0 join prospect_integrations.batches b0 on b0.job_id=j0.id where b0.id=p_batch for update of j0;
  select * into b from prospect_integrations.batches where id=p_batch and attempt_token=p_token and status='sending' and lease_until>now() for update;
  if not found or j.status<>'running' or not c.connected or j.connection_generation is distinct from c.generation
    or not exists(select 1 from prospect_integrations.client_campaigns where client_id=j.client_id and campaign_id=j.campaign_id and enabled and generation=c.generation) then return null; end if;
  select coalesce(jsonb_agg(lead),'[]') into v_payload from jsonb_array_elements(b.payload) lead where
    exists(select 1 from jsonb_array_elements_text(j.preview_summary->'sourceIds'->(lead->>'email')) sid join public.prospects p on p.id=sid)
    and not exists(select 1 from public.client_blocklist bl where bl.client_id=j.client_id and (
      (bl.kind='email' and bl.value=lead->>'email') or (bl.kind='domain' and bl.value=split_part(lead->>'email','@',2))))
    and not exists(select 1 from jsonb_array_elements_text(j.preview_summary->'sourceIds'->(lead->>'email')) sid
      join public.prospects p on p.id=sid left join public.companies co on co.id=p.company_id
      where exists(select 1 from public.client_prospects cp where cp.client_id=j.client_id and cp.prospect_id=p.id and cp.status='blocked')
      or exists(select 1 from public.client_blocklist bl where bl.client_id=j.client_id and bl.kind='domain' and bl.value<>'' and bl.value=co.normalized_domain));
  update prospect_integrations.batches set dispatch_payload=v_payload,suppressed=jsonb_array_length(b.payload)-jsonb_array_length(v_payload) where id=p_batch;
  return v_payload;
end;
$$;


ALTER FUNCTION prospect_integrations.prepare_upload_v1(p_batch uuid, p_token uuid) OWNER TO postgres;

--
-- Name: apply_batch_v1(uuid, integer, integer); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.apply_batch_v1(p_job_id uuid, p_batch_size integer DEFAULT 500, p_lease_seconds integer DEFAULT 300) RETURNS TABLE(applied bigint, total_items bigint, applied_items bigint, done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_job prospect_operations.operation_jobs%rowtype;
  v_ids text[];
  v_batch jsonb;
  v_marked bigint;
  v_date date;
begin
  select * into v_job from prospect_operations.operation_jobs j where j.id = p_job_id;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
  -- Anything already finished, failed or not yet frozen is not ours to run.
  -- Returning rather than raising keeps a worker that claimed a job which
  -- completed underneath it from recording a spurious failure.
  if v_job.status not in ('frozen', 'running') then
    return query select 0::bigint, v_job.total_items, v_job.applied_items, true;
    return;
  end if;

  select array_agg(batch.entity_id) into v_ids
  from prospect_operations.next_batch_v1(p_job_id, p_batch_size) as batch;

  if v_ids is null or cardinality(v_ids) = 0 then
    -- Frozen over an empty selection, or every item already applied. Close it
    -- rather than leaving a job that is claimable forever.
    update prospect_operations.operation_jobs
    set status = 'completed', completed_at = now(), worker_id = null, lease_expires_at = null
    where id = p_job_id and status <> 'completed';
    return query select 0::bigint, v_job.total_items, v_job.applied_items, true;
    return;
  end if;

  if v_job.entity_type <> 'prospect' then
    raise exception 'Only prospect operations can be applied here, not %', v_job.entity_type
      using errcode = '22023';
  end if;

  -- The same four functions the interactive route calls, given explicit ids.
  -- p_search and p_filters are deliberately empty: the selection is frozen.
  if v_job.action = 'push' then
    v_batch := public.push_prospects_to_client_v2(
      p_client_id => v_job.client_scope,
      p_search => '', p_filters => '[]'::jsonb,
      p_source_client_id => nullif(v_job.payload ->> 'sourceClientId', ''),
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor,
      p_request_id => v_job.request_id::text);
  elsif v_job.action in ('set_icp_verified', 'clear_icp_verified') then
    v_batch := public.set_icp_verified_v1(
      p_client_id => v_job.client_scope,
      p_verified => (v_job.action = 'set_icp_verified'),
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action in ('set_lead', 'clear_lead') then
    -- Exactly the ICP arm above with one name changed; the two functions take
    -- the same arguments. Nothing in prospect_index carries is_lead, so this
    -- always reports queued: 0, which is correct rather than a gap.
    v_batch := public.set_client_lead_v1(
      p_client_id => v_job.client_scope,
      p_is_lead => (v_job.action = 'set_lead'),
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action in ('add_tag', 'remove_tag') then
    -- The tag travels in the payload, and a job without one can never run - so
    -- say so, the same way a missing Date Contacted does below. The tag is
    -- checked against the client INSIDE set_client_prospect_tag_v1, so a job
    -- cannot reach another client's tag by carrying its id.
    if coalesce(v_job.payload ->> 'tagId', '') = '' then
      raise exception 'This operation has no ICP tag to apply' using errcode = '22023';
    end if;
    v_batch := public.set_client_prospect_tag_v1(
      p_client_id => v_job.client_scope,
      p_tag_id => v_job.payload ->> 'tagId',
      p_apply => (v_job.action = 'add_tag'),
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action = 'set_date_contacted' then
    -- Clearing the date is a legitimate request, so a missing key and an
    -- explicit null are different things and only the first is an error.
    if not (v_job.payload ? 'dateContacted') then
      raise exception 'This operation has no Date Contacted to apply' using errcode = '22023';
    end if;
    v_date := case
      when jsonb_typeof(v_job.payload -> 'dateContacted') = 'null' then null
      else (v_job.payload ->> 'dateContacted')::date
    end;
    v_batch := public.set_client_date_contacted_v1(
      p_client_id => v_job.client_scope,
      p_date_contacted => v_date,
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  elsif v_job.action = 'remove' then
    v_batch := public.remove_prospects_from_client_v2(
      p_client_id => v_job.client_scope,
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_ids, p_excluded_ids => null, p_actor => v_job.actor);
  else
    raise exception 'Unsupported operation action %', v_job.action using errcode = '22023';
  end if;

  -- Same transaction as the mutation above, so progress and reality cannot
  -- disagree: either both happened or neither did.
  v_marked := prospect_operations.mark_applied_v1(p_job_id, v_ids);

  -- Progress extends the lease, exactly as build_batch_v1 does for result sets:
  -- a job of 250,000 ids is 500 batches and will outlive any fixed lease taken
  -- at claim time. Without this a second worker could reclaim a job that is
  -- still running and apply the same batch twice. mark_applied_v1 has already
  -- nulled the lease if this batch finished the job, so only a job with work
  -- left gets a new one.
  update prospect_operations.operation_jobs j
  set result = prospect_operations.merge_result_v1(j.result, v_batch),
      lease_expires_at = case
        when j.lease_expires_at is null then null
        else now() + make_interval(secs => greatest(30, p_lease_seconds))
      end
  where j.id = p_job_id;

  select * into v_job from prospect_operations.operation_jobs j where j.id = p_job_id;
  return query select v_marked, v_job.total_items, v_job.applied_items, (v_job.status = 'completed');
end;
$$;


ALTER FUNCTION prospect_operations.apply_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) OWNER TO postgres;

--
-- Name: claim_next_v1(text, integer); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.claim_next_v1(p_worker_id text, p_lease_seconds integer DEFAULT 300) RETURNS TABLE(job_id uuid, action text, entity_type text, client_scope text, payload jsonb, total_items bigint, applied_items bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_id uuid;
begin
  select j.id into v_id from prospect_operations.operation_jobs j
  where j.expires_at > now()
    and (j.status = 'frozen'
         or (j.status = 'running' and coalesce(j.lease_expires_at, now()) <= now()))
  order by j.created_at
  for update skip locked
  limit 1;

  if v_id is null then return; end if;

  update prospect_operations.operation_jobs j
  set status = 'running', worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds))
  where j.id = v_id;

  return query
  select j.id, j.action, j.entity_type, j.client_scope, j.payload, j.total_items, j.applied_items
  from prospect_operations.operation_jobs j where j.id = v_id;
end;
$$;


ALTER FUNCTION prospect_operations.claim_next_v1(p_worker_id text, p_lease_seconds integer) OWNER TO postgres;

--
-- Name: enqueue_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[], interval); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.enqueue_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb DEFAULT '{}'::jsonb, p_excluded_ids text[] DEFAULT ARRAY[]::text[], p_ttl interval DEFAULT '7 days'::interval) RETURNS TABLE(job_id uuid, status text, total_items bigint, applied_items bigint, result jsonb, reused boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_row prospect_operations.operation_jobs%rowtype;
begin
  if coalesce(btrim(p_actor), '') = '' then
    raise exception 'An operation needs an actor' using errcode = '22023';
  end if;
  if p_request_id is null then
    raise exception 'An operation needs a client-generated request id'
      using errcode = '22023',
            hint = 'Without one a retry cannot be told apart from a second, deliberate operation.';
  end if;

  insert into prospect_operations.operation_jobs
    (actor, action, request_id, entity_type, client_scope, content_hash, version_vector,
     payload, excluded_ids, expires_at)
  values (p_actor, p_action, p_request_id, p_entity_type, coalesce(p_client_scope, ''),
          p_content_hash, p_version_vector, coalesce(p_payload, '{}'::jsonb),
          coalesce(p_excluded_ids, array[]::text[]), now() + p_ttl)
  on conflict (actor, action, request_id) do nothing;

  select * into v_row from prospect_operations.operation_jobs j
  where j.actor = p_actor and j.action = p_action and j.request_id = p_request_id;

  -- `reused` means this exact request has been seen before, whatever state it
  -- reached. The caller checks status to decide whether to re-run or to answer
  -- with the recorded result.
  return query select v_row.id, v_row.status, v_row.total_items, v_row.applied_items, v_row.result,
    (v_row.status <> 'pending' or v_row.frozen_at is not null);
end;
$$;


ALTER FUNCTION prospect_operations.enqueue_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[], p_ttl interval) OWNER TO postgres;

--
-- Name: expire_jobs_v1(); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.expire_jobs_v1() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations'
    AS $$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('operation',5000); $$;


ALTER FUNCTION prospect_operations.expire_jobs_v1() OWNER TO postgres;

--
-- Name: fail_v1(uuid, text); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.fail_v1(p_job_id uuid, p_error text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    AS $$
  update prospect_operations.operation_jobs
  set status = 'failed', error = left(coalesce(p_error, 'unknown'), 2000),
      worker_id = null, lease_expires_at = null, completed_at = now()
  where id = p_job_id;
$$;


ALTER FUNCTION prospect_operations.fail_v1(p_job_id uuid, p_error text) OWNER TO postgres;

--
-- Name: freeze_from_ids_v1(uuid, text, text[]); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.freeze_from_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) RETURNS TABLE(total_items bigint, excluded_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_row prospect_operations.operation_jobs%rowtype;
  v_inserted bigint;
  v_excluded bigint;
begin
  select * into v_row from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor for update;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
  -- Freezing twice would be the silent expansion this exists to prevent.
  if v_row.status <> 'pending' then
    return query select v_row.total_items, v_row.excluded_count;
    return;
  end if;

  with candidate as (
    select distinct value as entity_id from unnest(coalesce(p_ids, array[]::text[])) value
    where btrim(coalesce(value, '')) <> ''
  ), kept as (
    select entity_id, row_number() over (order by entity_id) as ordinal
    from candidate
    where not (entity_id = any (v_row.excluded_ids))
  ), stored as (
    insert into prospect_operations.operation_job_items (job_id, ordinal, entity_id)
    select p_job_id, kept.ordinal, kept.entity_id from kept
    on conflict do nothing
    returning 1
  )
  select (select count(*) from stored), (select count(*) from candidate) - (select count(*) from kept)
  into v_inserted, v_excluded;

  update prospect_operations.operation_jobs
  set status = 'frozen', total_items = v_inserted, excluded_count = v_excluded, frozen_at = now()
  where id = p_job_id;

  return query select v_inserted, v_excluded;
end;
$$;


ALTER FUNCTION prospect_operations.freeze_from_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) OWNER TO postgres;

--
-- Name: freeze_from_result_set_v1(uuid, text, uuid); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.freeze_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) RETURNS TABLE(total_items bigint, excluded_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations', 'prospect_results'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_row prospect_operations.operation_jobs%rowtype;
  v_set prospect_results.result_sets%rowtype;
  v_inserted bigint;
  v_excluded bigint;
begin
  select * into v_row from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor for update;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
  if v_row.status <> 'pending' then
    return query select v_row.total_items, v_row.excluded_count;
    return;
  end if;

  select * into v_set from prospect_results.result_sets rs
  where rs.id = p_result_set_id and rs.owner_id = p_actor and rs.expires_at > now();
  if not found then
    raise exception 'Result set is not available' using errcode = 'P0002';
  end if;
  if v_set.status <> 'ready' then
    raise exception 'That result set is still being built'
      using errcode = '22023',
            hint = 'Freezing a half-built set would silently truncate the operation.';
  end if;

  with kept as (
    select i.entity_id, row_number() over (order by i.ordinal) as ordinal
    from prospect_results.result_set_items i
    where i.result_set_id = p_result_set_id
      and not (i.entity_id = any (v_row.excluded_ids))
  ), stored as (
    insert into prospect_operations.operation_job_items (job_id, ordinal, entity_id)
    select p_job_id, kept.ordinal, kept.entity_id from kept
    on conflict do nothing
    returning 1
  )
  select (select count(*) from stored), v_set.row_count - (select count(*) from kept)
  into v_inserted, v_excluded;

  update prospect_operations.operation_jobs
  set status = 'frozen', total_items = v_inserted, excluded_count = greatest(v_excluded, 0),
      frozen_at = now()
  where id = p_job_id;

  return query select v_inserted, greatest(v_excluded, 0);
end;
$$;


ALTER FUNCTION prospect_operations.freeze_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) OWNER TO postgres;

--
-- Name: mark_applied_v1(uuid, text[]); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.mark_applied_v1(p_job_id uuid, p_ids text[]) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_marked bigint;
begin
  with marked as (
    update prospect_operations.operation_job_items i
    set applied_at = now()
    where i.job_id = p_job_id and i.applied_at is null
      and i.entity_id = any (coalesce(p_ids, array[]::text[]))
    returning 1
  )
  select count(*) into v_marked from marked;

  update prospect_operations.operation_jobs j
  set applied_items = j.applied_items + v_marked,
      status = case when j.applied_items + v_marked >= j.total_items then 'completed' else 'running' end,
      completed_at = case when j.applied_items + v_marked >= j.total_items then now() else null end,
      lease_expires_at = case when j.applied_items + v_marked >= j.total_items then null else j.lease_expires_at end
  where j.id = p_job_id;

  return v_marked;
end;
$$;


ALTER FUNCTION prospect_operations.mark_applied_v1(p_job_id uuid, p_ids text[]) OWNER TO postgres;

--
-- Name: merge_result_v1(jsonb, jsonb); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.merge_result_v1(p_current jsonb, p_batch jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  select coalesce((
    select jsonb_object_agg(merged.key, merged.value)
    from (
      select
        coalesce(current_entry.key, batch_entry.key) as key,
        case
          when jsonb_typeof(coalesce(current_entry.value, 'null'::jsonb)) = 'number'
           and jsonb_typeof(coalesce(batch_entry.value, 'null'::jsonb)) = 'number'
            then to_jsonb(current_entry.value::numeric + batch_entry.value::numeric)
          else coalesce(batch_entry.value, current_entry.value)
        end as value
      from jsonb_each(coalesce(p_current, '{}'::jsonb)) as current_entry
      full outer join jsonb_each(coalesce(p_batch, '{}'::jsonb)) as batch_entry
        on batch_entry.key = current_entry.key
    ) merged
  ), '{}'::jsonb);
$$;


ALTER FUNCTION prospect_operations.merge_result_v1(p_current jsonb, p_batch jsonb) OWNER TO postgres;

--
-- Name: next_batch_v1(uuid, integer); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.next_batch_v1(p_job_id uuid, p_batch_size integer DEFAULT 500) RETURNS TABLE(entity_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '30s'
    AS $$
begin
  return query
  select i.entity_id from prospect_operations.operation_job_items i
  where i.job_id = p_job_id and i.applied_at is null
  order by i.ordinal
  limit greatest(1, least(coalesce(p_batch_size, 500), 5000));
end;
$$;


ALTER FUNCTION prospect_operations.next_batch_v1(p_job_id uuid, p_batch_size integer) OWNER TO postgres;

--
-- Name: prune_metrics_v1(); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.prune_metrics_v1() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations'
    AS $$
DECLARE v_count integer;
BEGIN
  DELETE FROM prospect_operations.job_metrics WHERE ctid IN
    (SELECT ctid FROM prospect_operations.job_metrics WHERE hour<now()-interval '30 days' ORDER BY hour LIMIT 1000);
  GET DIAGNOSTICS v_count=ROW_COUNT;
  RETURN v_count;
END;
$$;


ALTER FUNCTION prospect_operations.prune_metrics_v1() OWNER TO postgres;

--
-- Name: reclaim_unit_v1(text, integer); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.reclaim_unit_v1(p_kind text, p_limit integer DEFAULT 5000) RETURNS TABLE(items_removed integer, parents_removed integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations', 'prospect_results', 'prospect_exports', 'prospect_filters'
    AS $_$
DECLARE
  v_schema text; v_parent text; v_child text; v_fk text; v_guard text;
  v_id uuid; v_removed integer := 0; v_parents integer := 0; v_remaining boolean;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 5000 THEN
    RAISE EXCEPTION 'Cleanup limit must be 1–5000' USING ERRCODE='22023';
  END IF;
  CASE p_kind
    WHEN 'search' THEN
      v_schema := 'prospect_results'; v_parent := 'result_sets'; v_child := 'result_set_items'; v_fk := 'result_set_id';
      -- Export metadata is a durable dependency pin until that export is terminal.
      v_guard := 'coalesce(s.lease_expires_at,now()) <= now()
        AND NOT EXISTS (SELECT 1 FROM prospect_exports.jobs j WHERE j.result_set_id=s.id AND j.status IN (''queued'',''building''))';
    WHEN 'operation' THEN
      v_schema := 'prospect_operations'; v_parent := 'operation_jobs'; v_child := 'operation_job_items'; v_fk := 'job_id';
      -- Never age out an acknowledged mutation that still needs to run.
      v_guard := 's.status IN (''completed'',''failed'') AND coalesce(s.lease_expires_at,now()) <= now()';
    WHEN 'export' THEN
      v_schema := 'prospect_exports'; v_parent := 'jobs'; v_child := 'job_parts'; v_fk := 'job_id';
      v_guard := 'coalesce(s.lease_expires_at,now()) <= now()';
      p_limit := least(p_limit,2); -- Parts can hold thousands of wide rows.
    WHEN 'filter' THEN
      v_schema := 'prospect_filters'; v_parent := 'filter_sets'; v_child := 'filter_set_values'; v_fk := 'filter_set_id';
      v_guard := 'NOT EXISTS (SELECT 1 FROM prospect_results.result_sets r
        WHERE r.status IN (''pending'',''building'')
          AND (strpos(r.filters::text,s.id::text)>0 OR strpos(r.company_scope::text,s.id::text)>0))';
    ELSE RAISE EXCEPTION 'Unknown cleanup class' USING ERRCODE='22023';
  END CASE;
  IF NOT pg_try_advisory_xact_lock(hashtextextended('prospect-background-unit-v1',0)) THEN
    RETURN QUERY SELECT 0,0; RETURN;
  END IF;
  -- Lock the parent before any child deletion. Builders and dependency creators
  -- use this same row lock; no cleanup can race an export attaching its input.
  EXECUTE format('SELECT s.id FROM %I.%I s WHERE s.expires_at<=now() AND %s
    ORDER BY s.expires_at,s.id LIMIT 1 FOR UPDATE OF s SKIP LOCKED',v_schema,v_parent,v_guard) INTO v_id;
  IF v_id IS NULL THEN RETURN QUERY SELECT 0,0; RETURN; END IF;
  EXECUTE format('DELETE FROM %I.%I WHERE ctid IN
    (SELECT ctid FROM %I.%I WHERE %I=$1 LIMIT $2)',v_schema,v_child,v_schema,v_child,v_fk)
    USING v_id,p_limit;
  GET DIAGNOSTICS v_removed=ROW_COUNT;
  EXECUTE format('SELECT EXISTS(SELECT 1 FROM %I.%I WHERE %I=$1)',v_schema,v_child,v_fk)
    INTO v_remaining USING v_id;
  IF NOT v_remaining THEN
    EXECUTE format('DELETE FROM %I.%I WHERE id=$1',v_schema,v_parent) USING v_id;
    GET DIAGNOSTICS v_parents=ROW_COUNT;
  END IF;
  RETURN QUERY SELECT v_removed,v_parents;
END;
$_$;


ALTER FUNCTION prospect_operations.reclaim_unit_v1(p_kind text, p_limit integer) OWNER TO postgres;

--
-- Name: record_job_metric_v1(); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.record_job_metric_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations'
    AS $$
DECLARE v_kind text; v_ms double precision; v_bucket integer;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('ready','completed','failed') THEN RETURN NEW; END IF;
  v_kind := CASE TG_TABLE_SCHEMA WHEN 'prospect_results' THEN 'search' WHEN 'prospect_exports' THEN 'export' ELSE 'operation' END;
  v_ms := greatest(0,extract(epoch FROM (clock_timestamp()-NEW.created_at))*1000);
  v_bucket := CASE WHEN v_ms<=2000 THEN 2000 WHEN v_ms<=5000 THEN 5000 WHEN v_ms<=15000 THEN 15000
    WHEN v_ms<=30000 THEN 30000 WHEN v_ms<=60000 THEN 60000 WHEN v_ms<=120000 THEN 120000 ELSE 2147483647 END;
  INSERT INTO prospect_operations.job_metrics(hour,kind,outcome,duration_bucket_ms,jobs,total_ms,max_ms)
    VALUES(date_trunc('hour',clock_timestamp()),v_kind,NEW.status,v_bucket,1,v_ms,v_ms)
    ON CONFLICT(hour,kind,outcome,duration_bucket_ms) DO UPDATE
      SET jobs=job_metrics.jobs+1,total_ms=job_metrics.total_ms+excluded.total_ms,max_ms=greatest(job_metrics.max_ms,excluded.max_ms);
  RETURN NEW;
END;
$$;


ALTER FUNCTION prospect_operations.record_job_metric_v1() OWNER TO postgres;

--
-- Name: record_result_v1(uuid, text, jsonb); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.record_result_v1(p_job_id uuid, p_actor text, p_result jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '15s'
    AS $$
begin
  update prospect_operations.operation_jobs
  set result = p_result, status = 'completed', completed_at = now(),
      worker_id = null, lease_expires_at = null
  where id = p_job_id and actor = p_actor;
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;
end;
$$;


ALTER FUNCTION prospect_operations.record_result_v1(p_job_id uuid, p_actor text, p_result jsonb) OWNER TO postgres;

--
-- Name: refresh_dashboard_snapshots_v1(); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.refresh_dashboard_snapshots_v1() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '300s'
    AS $$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect', 'company']);
  v_refreshed integer := 0;
  v_started timestamptz;
  v_payload jsonb;
  v_key text;
begin
  foreach v_key in array array['dataQuality', 'indexDrift', 'titleTaxonomy'] loop
    -- Same version means the stored answer is the answer. Skipping is the
    -- point: a quiet database costs three cheap comparisons per cycle.
    if exists (
      select 1 from public.dashboard_snapshot s
      where s.key = v_key and s.data_version = v_versions
    ) then
      continue;
    end if;

    v_started := clock_timestamp();
    v_payload := case v_key
      when 'dataQuality' then public.data_quality_overview()
      when 'indexDrift' then public.prospect_index_drift()
      when 'titleTaxonomy' then public.prospect_title_taxonomy_v1(null)
    end;

    insert into public.dashboard_snapshot (key, payload, data_version, computed_at, duration_ms)
    values (v_key, coalesce(v_payload, '{}'::jsonb), v_versions, now(),
            (extract(epoch from clock_timestamp() - v_started) * 1000)::integer)
    on conflict (key) do update
      set payload = excluded.payload,
          data_version = excluded.data_version,
          computed_at = excluded.computed_at,
          duration_ms = excluded.duration_ms;
    v_refreshed := v_refreshed + 1;
  end loop;

  return v_refreshed;
end;
$$;


ALTER FUNCTION prospect_operations.refresh_dashboard_snapshots_v1() OWNER TO postgres;

--
-- Name: run_queue_unit_v1(text, text, integer); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.run_queue_unit_v1(p_kind text, p_worker text, p_batch integer DEFAULT 5000) RETURNS TABLE(job_id uuid, total bigint, done boolean, outcome text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations', 'prospect_results', 'prospect_exports'
    AS $$
DECLARE
  v_id uuid;
  v_result record;
  v_total bigint := 0;
  v_done boolean := false;
  v_error text;
BEGIN
  IF p_kind NOT IN ('search','operation','export') OR p_kind IS NULL
     OR coalesce(btrim(p_worker),'')='' OR length(p_worker)>200
     OR p_batch IS NULL OR p_batch<1 OR p_batch>100000 THEN
    RAISE EXCEPTION 'Invalid background unit' USING ERRCODE='22023';
  END IF;
  -- This permit covers new operations workers, NOT imports/the entire VPS.
  IF NOT pg_try_advisory_xact_lock(hashtextextended('prospect-background-unit-v1',0)) THEN
    RETURN QUERY SELECT NULL::uuid,0::bigint,false,'busy'::text;
    RETURN;
  END IF;
  CASE p_kind
    WHEN 'search' THEN SELECT c.set_id INTO v_id FROM prospect_results.claim_next_v1(p_worker,300) c;
    WHEN 'operation' THEN SELECT c.job_id INTO v_id FROM prospect_operations.claim_next_v1(p_worker,300) c;
    WHEN 'export' THEN SELECT c.job_id INTO v_id FROM prospect_exports.claim_next_v1(p_worker,300) c;
  END CASE;
  IF v_id IS NULL THEN RETURN; END IF;
  -- Claim locks are outside this subtransaction. Failure rolls back only this
  -- unit's changes; prior committed checkpoints remain intact.
  BEGIN
    CASE p_kind
      WHEN 'search' THEN
        SELECT * INTO v_result FROM prospect_results.build_batch_v1(v_id,p_batch);
        v_total := v_result.total; v_done := v_result.done;
        UPDATE prospect_results.result_sets s
          SET status=CASE WHEN v_done THEN s.status ELSE 'pending' END,
              worker_id=NULL,lease_expires_at=NULL,
              completed_at=CASE WHEN v_done THEN clock_timestamp() ELSE s.completed_at END
          WHERE s.id=v_id;
      WHEN 'operation' THEN
        SELECT * INTO v_result FROM prospect_operations.apply_batch_v1(v_id,least(p_batch,5000),300);
        v_total := v_result.applied_items; v_done := v_result.done;
        UPDATE prospect_operations.operation_jobs j
          SET status=CASE WHEN v_done THEN j.status ELSE 'frozen' END,
              worker_id=NULL,lease_expires_at=NULL,
              completed_at=CASE WHEN v_done THEN clock_timestamp() ELSE j.completed_at END
          WHERE j.id=v_id;
      WHEN 'export' THEN
        SELECT * INTO v_result FROM prospect_exports.build_batch_v1(v_id,least(p_batch,25000),300);
        v_total := v_result.total_rows; v_done := v_result.done;
        UPDATE prospect_exports.jobs j
          SET status=CASE WHEN v_done THEN j.status ELSE 'queued' END,
              worker_id=NULL,lease_expires_at=NULL,
              completed_at=CASE WHEN v_done THEN clock_timestamp() ELSE j.completed_at END
          WHERE j.id=v_id;
    END CASE;
  EXCEPTION WHEN OTHERS OR query_canceled THEN
    v_error := 'Background unit failed (SQLSTATE ' || SQLSTATE || ').';
    CASE p_kind
      WHEN 'search' THEN PERFORM prospect_results.fail_set_v1(v_id,v_error);
      WHEN 'operation' THEN PERFORM prospect_operations.fail_v1(v_id,v_error);
      WHEN 'export' THEN PERFORM prospect_exports.fail_v1(v_id,v_error);
    END CASE;
    RETURN QUERY SELECT v_id,0::bigint,true,'failed'::text;
    RETURN;
  END;
  RETURN QUERY SELECT v_id,v_total,v_done,'progress'::text;
END;
$$;


ALTER FUNCTION prospect_operations.run_queue_unit_v1(p_kind text, p_worker text, p_batch integer) OWNER TO postgres;

--
-- Name: status_v1(uuid, text, jsonb); Type: FUNCTION; Schema: prospect_operations; Owner: postgres
--

CREATE FUNCTION prospect_operations.status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb DEFAULT NULL::jsonb) RETURNS TABLE(status text, total_items bigint, applied_items bigint, excluded_count bigint, stale boolean, frozen_at timestamp with time zone, error text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '10s'
    AS $$
declare
  v_row prospect_operations.operation_jobs%rowtype;
begin
  select * into v_row from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor and j.expires_at > now();
  if not found then
    raise exception 'Operation is not available' using errcode = 'P0002';
  end if;

  return query select v_row.status, v_row.total_items, v_row.applied_items, v_row.excluded_count,
    (p_version_vector is not null and v_row.version_vector is distinct from p_version_vector),
    v_row.frozen_at, v_row.error;
end;
$$;


ALTER FUNCTION prospect_operations.status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb) OWNER TO postgres;

--
-- Name: build_batch_v1(uuid, integer); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.build_batch_v1(p_set_id uuid, p_batch_size integer DEFAULT 25000) RETURNS TABLE(inserted integer, total bigint, done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '120s'
    AS $_$
DECLARE v_row prospect_results.result_sets%rowtype; v_count integer; v_predicate text;
BEGIN
  SELECT * INTO v_row FROM prospect_results.result_sets WHERE id=p_set_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Result set does not exist' USING errcode='P0002'; END IF;
  IF v_row.content_hash NOT LIKE 'company-pivot-v1:%' THEN
    RETURN QUERY SELECT * FROM prospect_results.build_regular_batch_v2(p_set_id,p_batch_size);
    RETURN;
  END IF;
  IF v_row.status NOT IN ('pending','building') THEN
    RETURN QUERY SELECT 0,v_row.row_count,true;
    RETURN;
  END IF;
  IF v_row.entity_type<>'company' OR v_row.client_scope<>'' OR v_row.company_scope<>'{}'::jsonb THEN
    RAISE EXCEPTION 'Invalid prepared company search' USING errcode='22023';
  END IF;
  -- One worker statement and snapshot. Keep the full set for Companies; the
  -- People resolver applies its established scope ceiling on read.
  v_predicate := coalesce(public.company_full_scan_filter_sql_v1(v_row.search,v_row.filters),
    format('public.company_matches_filters_v1(c,%L,%L::jsonb)',v_row.search,v_row.filters::text));
  EXECUTE format($query$
    WITH stored AS (
      INSERT INTO prospect_results.result_set_items(result_set_id,ordinal,entity_id)
      SELECT %L::uuid,row_number() OVER(ORDER BY c.id),c.id FROM public.companies c WHERE %s
      ON CONFLICT DO NOTHING RETURNING 1
    ) SELECT count(*)::integer FROM stored
  $query$,p_set_id,v_predicate) INTO v_count;
  UPDATE prospect_results.result_sets
    SET status='ready',row_count=v_count,completed_at=clock_timestamp(),lease_expires_at=NULL,worker_id=NULL
    WHERE id=p_set_id;
  RETURN QUERY SELECT v_count,v_count::bigint,true;
END;
$_$;


ALTER FUNCTION prospect_results.build_batch_v1(p_set_id uuid, p_batch_size integer) OWNER TO postgres;

--
-- Name: build_regular_batch_v1(uuid, integer); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.build_regular_batch_v1(p_set_id uuid, p_batch_size integer DEFAULT 25000) RETURNS TABLE(inserted integer, total bigint, done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_row prospect_results.result_sets%rowtype;
  v_batch integer := greatest(1000, least(coalesce(p_batch_size, 25000), 100000));
  v_predicate text;
  v_scope jsonb;
  v_has_scope boolean;
  v_scope_cte text := '';
  v_scope_join text := '';
  v_sql text;
  v_inserted integer;
  v_last_created timestamptz;
  v_last_id text;
begin
  select * into v_row from prospect_results.result_sets where id = p_set_id for update;
  if not found then
    raise exception 'Result set does not exist' using errcode = 'P0002';
  end if;
  if v_row.status not in ('pending', 'building') then
    return query select 0, v_row.row_count, true;
    return;
  end if;

  if v_row.entity_type = 'prospect' then
    v_predicate := public.prospect_filter_sql_v1(v_row.search, v_row.filters);
    if v_predicate is null then
      raise exception 'This filter set cannot be compiled into a result set' using errcode = '22023';
    end if;

    -- The same test scopeRestricts makes in the browser and v5 makes in SQL: a
    -- scope with neither a search nor a filter matches every company and is not
    -- a narrowing, so entering the join would cost a quarter of a million ids
    -- for nothing.
    v_scope := coalesce(v_row.company_scope, '{}'::jsonb);
    v_has_scope := v_scope <> '{}'::jsonb
      and (btrim(coalesce(v_scope->>'search', '')) <> ''
        or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
    if v_has_scope then
      v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
        nullif(v_row.client_scope, ''), v_scope::text);
      v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
    end if;

    v_sql := format($q$
      with %8$s batch as (
        select pi.id, pi.created_at
        from public.prospect_index pi%9$s
        where (%1$L is null or pi.client_ids @> array[%1$L])
          and (%2$s)
          and (%3$L::timestamptz is null
               or (pi.created_at, pi.id) < (%3$L::timestamptz, coalesce(%4$L, '')))
        order by pi.created_at desc, pi.id desc
        limit %5$s
      ), numbered as (
        select batch.*, %6$s + row_number() over (order by created_at desc, id desc) as ordinal
        from batch
      ), stored as (
        insert into prospect_results.result_set_items (result_set_id, ordinal, entity_id)
        select %7$L::uuid, numbered.ordinal, numbered.id from numbered
        on conflict do nothing
        returning 1
      )
      select (select count(*) from stored)::integer,
             (select created_at from numbered order by ordinal desc limit 1),
             (select id from numbered order by ordinal desc limit 1)
    $q$, nullif(v_row.client_scope, ''), v_predicate, v_row.cursor_created_at, v_row.cursor_id,
         v_batch::text, v_row.row_count::text, p_set_id, v_scope_cte, v_scope_join);
  else
    v_predicate := public.company_effective_filter_sql_v1(v_row.search, v_row.filters);
    if v_predicate is null then
      raise exception 'This filter set cannot be compiled into a result set' using errcode = '22023';
    end if;
    v_sql := format($q$
      with batch as (
        select c.id, c.created_at
        from public.companies c
        where (%1$s)
          and (%2$L::timestamptz is null
               or (c.created_at, c.id) < (%2$L::timestamptz, coalesce(%3$L, '')))
        order by c.created_at desc, c.id desc
        limit %4$s
      ), numbered as (
        select batch.*, %5$s + row_number() over (order by created_at desc, id desc) as ordinal
        from batch
      ), stored as (
        insert into prospect_results.result_set_items (result_set_id, ordinal, entity_id)
        select %6$L::uuid, numbered.ordinal, numbered.id from numbered
        on conflict do nothing
        returning 1
      )
      select (select count(*) from stored)::integer,
             (select created_at from numbered order by ordinal desc limit 1),
             (select id from numbered order by ordinal desc limit 1)
    $q$, v_predicate, v_row.cursor_created_at, v_row.cursor_id,
         v_batch::text, v_row.row_count::text, p_set_id);
  end if;

  execute v_sql into v_inserted, v_last_created, v_last_id;
  v_inserted := coalesce(v_inserted, 0);

  if v_inserted = 0 then
    update prospect_results.result_sets
    set status = 'ready', completed_at = now(), lease_expires_at = null, worker_id = null
    where id = p_set_id;
    return query select 0, v_row.row_count, true;
    return;
  end if;

  update prospect_results.result_sets
  set row_count = row_count + v_inserted,
      cursor_created_at = v_last_created,
      cursor_id = v_last_id,
      lease_expires_at = greatest(coalesce(lease_expires_at, now()), now() + interval '120 seconds'),
      status = case when v_inserted < v_batch then 'ready' else status end,
      completed_at = case when v_inserted < v_batch then now() else completed_at end
  where id = p_set_id
  returning row_count, status = 'ready' into total, done;

  inserted := v_inserted;
  return next;
end;
$_$;


ALTER FUNCTION prospect_results.build_regular_batch_v1(p_set_id uuid, p_batch_size integer) OWNER TO postgres;

--
-- Name: build_regular_batch_v2(uuid, integer); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.build_regular_batch_v2(p_set_id uuid, p_batch_size integer DEFAULT 25000) RETURNS TABLE(inserted integer, total bigint, done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_row prospect_results.result_sets%rowtype;
  v_has_cap boolean;
  v_sql text;
  v_inserted integer;
begin
  select * into v_row from prospect_results.result_sets where id = p_set_id for update;
  if not found then raise exception 'Result set does not exist' using errcode = 'P0002'; end if;
  v_has_cap := v_row.entity_type = 'prospect' and exists (
    select 1 from jsonb_array_elements(coalesce(v_row.filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company');
  if not v_has_cap then
    return query select * from prospect_results.build_regular_batch_v1(p_set_id, p_batch_size);
    return;
  end if;
  if v_row.status not in ('pending', 'building') then
    return query select 0, v_row.row_count, true;
    return;
  end if;

  -- A capped result is frozen in one database snapshot. Re-running the ranking
  -- in later chunks could admit person N+1 after person N from the same company
  -- stopped matching, violating the chosen quota. The normal result-set cap is
  -- 250,000 ids and the statement has its own 120-second safety boundary.
  v_sql := format($sql$
    with candidates as materialized (
      select * from public.prospect_capped_candidate_ids_v1(%1$L, %2$L::jsonb, %3$L, %4$L::jsonb)
    ), numbered as (
      select candidate.prospect_id as id,
        row_number() over (order by candidate.created_at desc, candidate.prospect_id desc) as ordinal
      from candidates candidate
    ), stored as (
      insert into prospect_results.result_set_items(result_set_id, ordinal, entity_id)
      select %5$L::uuid, numbered.ordinal, numbered.id from numbered
      on conflict do nothing returning 1
    )
    select (select count(*) from stored)::integer
  $sql$, v_row.search, v_row.filters::text, nullif(v_row.client_scope, ''),
    coalesce(v_row.company_scope, '{}'::jsonb)::text, p_set_id);
  execute v_sql into v_inserted;
  v_inserted := coalesce(v_inserted, 0);
  update prospect_results.result_sets
    set row_count = v_inserted, status = 'ready', completed_at = now(),
      lease_expires_at = null, worker_id = null
    where id = p_set_id
    returning row_count into total;
  inserted := v_inserted;
  done := true;
  return next;
end;
$_$;


ALTER FUNCTION prospect_results.build_regular_batch_v2(p_set_id uuid, p_batch_size integer) OWNER TO postgres;

--
-- Name: claim_next_v1(text, integer); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.claim_next_v1(p_worker_id text, p_lease_seconds integer DEFAULT 300) RETURNS TABLE(set_id uuid, entity_type text, client_scope text, search text, filters jsonb, row_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_id uuid;
begin
  select rs.id into v_id
  from prospect_results.result_sets rs
  where rs.expires_at > now()
    and (rs.status = 'pending'
         or (rs.status = 'building' and coalesce(rs.lease_expires_at, now()) <= now()))
  order by rs.created_at
  for update skip locked
  limit 1;

  if v_id is null then return; end if;

  update prospect_results.result_sets rs
  set status = 'building',
      worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => greatest(30, p_lease_seconds)),
      started_at = coalesce(rs.started_at, now())
  where rs.id = v_id;

  return query
  select rs.id, rs.entity_type, rs.client_scope, rs.search, rs.filters, rs.row_count
  from prospect_results.result_sets rs where rs.id = v_id;
end;
$$;


ALTER FUNCTION prospect_results.claim_next_v1(p_worker_id text, p_lease_seconds integer) OWNER TO postgres;

--
-- Name: expire_sets_v1(); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.expire_sets_v1() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations'
    AS $$ SELECT parents_removed FROM prospect_operations.reclaim_unit_v1('search',5000); $$;


ALTER FUNCTION prospect_results.expire_sets_v1() OWNER TO postgres;

--
-- Name: fail_set_v1(uuid, text); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.fail_set_v1(p_set_id uuid, p_error text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    AS $$
  update prospect_results.result_sets
  set status = 'failed', error = left(coalesce(p_error, 'unknown'), 2000),
      lease_expires_at = null, worker_id = null, completed_at = now()
  where id = p_set_id;
$$;


ALTER FUNCTION prospect_results.fail_set_v1(p_set_id uuid, p_error text) OWNER TO postgres;

--
-- Name: page_v1(uuid, text, integer, integer); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.page_v1(p_set_id uuid, p_owner_id text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(entity_id text, ordinal bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '20s'
    AS $$
declare
  v_row prospect_results.result_sets%rowtype;
begin
  select * into v_row from prospect_results.result_sets rs
  where rs.id = p_set_id and rs.owner_id = p_owner_id and rs.expires_at > now();
  if not found then
    raise exception 'Result set is not available' using errcode = 'P0002';
  end if;

  return query
  select i.entity_id, i.ordinal
  from prospect_results.result_set_items i
  where i.result_set_id = p_set_id
  order by i.ordinal
  limit greatest(1, least(coalesce(p_limit, 50), 1000))
  offset greatest(0, coalesce(p_offset, 0));
end;
$$;


ALTER FUNCTION prospect_results.page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: request_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb, interval); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.request_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb DEFAULT '{}'::jsonb, p_ttl interval DEFAULT '24:00:00'::interval) RETURNS TABLE(set_id uuid, status text, row_count bigint, reused boolean, stale boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_scope text := coalesce(p_client_scope, '');
  v_company_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_existing prospect_results.result_sets%rowtype;
  v_new uuid;
begin
  if coalesce(btrim(p_owner_id), '') = '' then
    raise exception 'A result set needs an owner' using errcode = '22023';
  end if;
  if p_entity_type not in ('prospect', 'company') then
    raise exception 'Unknown entity type %', p_entity_type using errcode = '22023';
  end if;
  -- A company scope over a set OF companies is not a narrowing, it is a
  -- confusion. Say so rather than storing something nothing will ever apply.
  if p_entity_type = 'company' and v_company_scope <> '{}'::jsonb then
    raise exception 'A company set cannot carry a company scope' using errcode = '22023';
  end if;

  select * into v_existing from prospect_results.result_sets rs
  where rs.owner_id = p_owner_id
    and rs.entity_type = p_entity_type
    and rs.client_scope = v_scope
    and rs.content_hash = p_content_hash
    -- The pivot is part of the question. Without this, a set frozen under one
    -- pivot could answer for another, which is the widening this migration
    -- exists to stop arriving by a different route.
    and rs.company_scope = v_company_scope
    and rs.status in ('pending', 'building', 'ready')
    and rs.expires_at > now();

  if found then
    return query select v_existing.id, v_existing.status, v_existing.row_count, true,
      (v_existing.status = 'ready' and v_existing.version_vector is distinct from p_version_vector);
    return;
  end if;

  insert into prospect_results.result_sets
    (owner_id, entity_type, client_scope, content_hash, version_vector, search, filters,
     company_scope, expires_at)
  values (p_owner_id, p_entity_type, v_scope, p_content_hash, p_version_vector,
          coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb), v_company_scope,
          now() + p_ttl)
  returning id into v_new;

  return query select v_new, 'pending'::text, 0::bigint, false, false;
end;
$$;


ALTER FUNCTION prospect_results.request_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb, p_ttl interval) OWNER TO postgres;

--
-- Name: status_v1(uuid, text, jsonb); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb DEFAULT NULL::jsonb) RETURNS TABLE(status text, row_count bigint, stale boolean, frozen_at timestamp with time zone, version_vector jsonb, error text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '10s'
    AS $$
declare
  v_row prospect_results.result_sets%rowtype;
begin
  select * into v_row from prospect_results.result_sets rs
  where rs.id = p_set_id and rs.owner_id = p_owner_id and rs.expires_at > now();
  if not found then
    raise exception 'Result set is not available' using errcode = 'P0002';
  end if;

  return query select
    v_row.status,
    v_row.row_count,
    -- Never "refresh it for them": say the answer is as of a moment, and let
    -- the caller ask again. Silently adding rows to a frozen list is the thing
    -- section 7 forbids.
    (p_version_vector is not null and v_row.version_vector is distinct from p_version_vector),
    coalesce(v_row.completed_at, v_row.started_at, v_row.created_at),
    v_row.version_vector,
    v_row.error;
end;
$$;


ALTER FUNCTION prospect_results.status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb) OWNER TO postgres;

--
-- Name: uncached_company_scope_ids_v1(text, jsonb); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.uncached_company_scope_ids_v1(p_client_id text, p_company_scope jsonb) RETURNS TABLE(company_id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_search text := coalesce(p_company_scope->>'search', '');
  v_filters jsonb := coalesce(p_company_scope->'filters', '[]'::jsonb);
  v_prefilter text := public.company_prefilter_sql(v_search, v_filters);
  v_complete text;
  v_limit integer := case
    when coalesce(p_company_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((p_company_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_sql text := 'select c.id from public.companies c where ';
begin
  -- With an empty search and no filters, company_matches_filters_v1 reduces to
  -- `true and not exists (select from jsonb_array_elements('[]'))` and returns
  -- true for every row. Calling it 418,151 times to learn that costs 93 seconds;
  -- not calling it costs 514 ms for the identical result set.
  if btrim(v_search) = '' and v_filters = '[]'::jsonb then
    return query execute format('select c.id from public.companies c order by c.id limit %s', v_limit);
    return;
  end if;

  -- Every id is wanted, so there is no early exit and this is the full-scan
  -- case. Same chooser the listing's count uses, so the two cannot drift.
  v_complete := public.company_full_scan_filter_sql_v1(v_search, v_filters);

  v_sql := v_sql
    || coalesce(v_complete,
         case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
           || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', v_search, v_filters::text))
    || format(' order by c.id limit %s', v_limit);
  return query execute v_sql;
end;
$_$;


ALTER FUNCTION prospect_results.uncached_company_scope_ids_v1(p_client_id text, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: usage_v1(); Type: FUNCTION; Schema: prospect_results; Owner: postgres
--

CREATE FUNCTION prospect_results.usage_v1() RETURNS TABLE(sets bigint, pending bigint, building bigint, ready bigint, items bigint, bytes bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    AS $$
  select (select count(*) from prospect_results.result_sets),
         (select count(*) from prospect_results.result_sets where status = 'pending'),
         (select count(*) from prospect_results.result_sets where status = 'building'),
         (select count(*) from prospect_results.result_sets where status = 'ready'),
         (select count(*) from prospect_results.result_set_items),
         pg_total_relation_size('prospect_results.result_set_items')
           + pg_total_relation_size('prospect_results.result_sets');
$$;


ALTER FUNCTION prospect_results.usage_v1() OWNER TO postgres;

--
-- Name: add_client_blocklist_batch_v2(text, text[], text[], text, text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_client_blocklist_batch_v2(p_client_id text, p_domains text[] DEFAULT NULL::text[], p_emails text[] DEFAULT NULL::text[], p_reason text DEFAULT ''::text, p_actor text DEFAULT ''::text, p_request_id text DEFAULT ''::text, p_match_limit integer DEFAULT 5000) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '90s'
    AS $$
declare
  v_domains text[] := array[]::text[];
  v_emails text[] := array[]::text[];
  v_ids text[] := array[]::text[];
  v_added integer := 0;
  v_blocked integer := 0;
  v_reindexed integer := 0;
  v_queued integer := 0;
  v_limit integer := greatest(100, least(coalesce(p_match_limit, 5000), 5000));
  v_remaining boolean := false;
  v_client_name text := '';
  v_cached_client_id text := '';
  v_result jsonb;
  v_companies integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  if cardinality(coalesce(p_domains, array[]::text[]))
      + cardinality(coalesce(p_emails, array[]::text[])) > 200 then
    raise exception using errcode = '22023', message = 'A blocklist batch can contain at most 200 entries.';
  end if;
  if length(btrim(coalesce(p_request_id, ''))) < 8 or length(p_request_id) > 100 then
    raise exception using errcode = '22023', message = 'A valid blocklist request id is required.';
  end if;

  select cached.client_id, cached.result into v_cached_client_id, v_result
  from public.client_blocklist_batch_results cached
  where cached.request_id = p_request_id;
  if found then
    if v_cached_client_id <> p_client_id then
      raise exception using errcode = '22023', message = 'That blocklist request id belongs to another client.';
    end if;
    return v_result;
  end if;

  select coalesce(array_agg(value order by value), array[]::text[]) into v_domains
  from (
    select distinct lower(btrim(value)) as value
    from unnest(coalesce(p_domains, array[]::text[])) submitted(value)
    where btrim(value) <> ''
  ) normalized;
  select coalesce(array_agg(value order by value), array[]::text[]) into v_emails
  from (
    select distinct lower(btrim(value)) as value
    from unnest(coalesce(p_emails, array[]::text[])) submitted(value)
    where btrim(value) <> ''
  ) normalized;

  with incoming as (
    select 'domain'::text as kind, value from unnest(v_domains) submitted(value)
    union all
    select 'email'::text, value from unnest(v_emails) submitted(value)
  ), inserted as (
    insert into public.client_blocklist (client_id, kind, value, reason, source)
    select p_client_id, kind, value, left(coalesce(p_reason, ''), 300), 'paste'
    from incoming
    on conflict (client_id, kind, value) do nothing
    returning 1
  )
  select count(*)::integer into v_added from inserted;

  with candidates as materialized (
    select cp.prospect_id
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    where cp.client_id = p_client_id
      and cp.status = 'active'
      and (
        (cardinality(v_domains) > 0 and lower(coalesce(pi.company_domain, '')) = any(v_domains))
        or (cardinality(v_emails) > 0 and (
          lower(coalesce(pi.work_email, '')) = any(v_emails)
          or lower(coalesce(pi.personal_email, '')) = any(v_emails)
        ))
      )
    order by cp.prospect_id
    limit v_limit
  ), blocked as (
    update public.client_prospects cp set
      status = 'blocked',
      blocked_at = coalesce(cp.blocked_at, now()),
      blocked_reason = coalesce(nullif(cp.blocked_reason, ''), nullif(left(coalesce(p_reason, ''), 300), ''), 'Matched client blocklist')
    from candidates
    where cp.client_id = p_client_id and cp.prospect_id = candidates.prospect_id
    returning cp.prospect_id
  )
  select coalesce(array_agg(prospect_id order by prospect_id), array[]::text[])
  into v_ids from blocked;
  v_blocked := cardinality(v_ids);

  -- Make the client visibility boundary correct immediately, even if a full
  -- search-index rebuild is queued because a batch is unusually expensive.
  if v_blocked > 0 then
    select name into v_client_name from public.clients where id = p_client_id;
    update public.prospect_index pi set
      client_ids = array_remove(coalesce(pi.client_ids, array[]::text[]), p_client_id),
      client_names = array_remove(coalesce(pi.client_names, array[]::text[]), v_client_name),
      client_count = cardinality(array_remove(coalesce(pi.client_ids, array[]::text[]), p_client_id)),
      icp_verified_client_ids = array_remove(coalesce(pi.icp_verified_client_ids, array[]::text[]), p_client_id),
      blocked_client_ids = case
        when coalesce(pi.blocked_client_ids, array[]::text[]) @> array[p_client_id]
          then coalesce(pi.blocked_client_ids, array[]::text[])
        else array_append(coalesce(pi.blocked_client_ids, array[]::text[]), p_client_id)
      end
    where pi.id = any(v_ids);

    select reindexed, queued into v_reindexed, v_queued
    from public.reindex_scope_v1(p_prospect_ids => v_ids, p_batch => 1000);
  end if;

  select exists (
    select 1
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    where cp.client_id = p_client_id
      and cp.status = 'active'
      and (
        (cardinality(v_domains) > 0 and lower(coalesce(pi.company_domain, '')) = any(v_domains))
        or (cardinality(v_emails) > 0 and (
          lower(coalesce(pi.work_email, '')) = any(v_emails)
          or lower(coalesce(pi.personal_email, '')) = any(v_emails)
        ))
      )
  ) into v_remaining;

  -- Companies too, against the whole list (20260924090000).
  v_companies := public.sweep_client_company_blocklist_v1(p_client_id);

  perform public.record_operation(
    'blocklist_add_batch', p_client_id, p_actor,
    format('Added %s blocklist entries and removed %s client records%s',
      v_added, v_blocked, case when v_remaining then ' (more queued by caller)' else '' end),
    v_blocked, v_ids
  );

  v_result := jsonb_build_object(
    'added', v_added,
    'suppressed', v_blocked,
    'remaining', v_remaining,
    'reindexed', v_reindexed,
    'queued', v_queued,
    'companiesBlocked', v_companies
  );
  insert into public.client_blocklist_batch_results (request_id, client_id, result)
  values (p_request_id, p_client_id, v_result)
  on conflict (request_id) do nothing;
  return v_result;
end;
$$;


ALTER FUNCTION public.add_client_blocklist_batch_v2(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text, p_request_id text, p_match_limit integer) OWNER TO postgres;

--
-- Name: add_client_blocklist_v1(text, text[], text[], text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_client_blocklist_v1(p_client_id text, p_domains text[] DEFAULT NULL::text[], p_emails text[] DEFAULT NULL::text[], p_reason text DEFAULT ''::text, p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_added integer := 0;
  v_blocked integer := 0;
  v_ids text[];
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  with incoming as (
    select 'domain'::text as kind, lower(btrim(value)) as value
    from unnest(coalesce(p_domains, array[]::text[])) as value
    where btrim(value) <> ''
    union
    select 'email', lower(btrim(value))
    from unnest(coalesce(p_emails, array[]::text[])) as value
    where btrim(value) <> ''
  ), inserted as (
    insert into public.client_blocklist (client_id, kind, value, reason, source)
    select p_client_id, incoming.kind, incoming.value, left(coalesce(p_reason, ''), 300), 'paste'
    from incoming
    on conflict (client_id, kind, value) do nothing
    returning 1
  )
  select count(*)::integer into v_added from inserted;

  -- Suppress anything already in the client that the new entries match.
  select coalesce(array_agg(cp.prospect_id), array[]::text[]) into v_ids
  from public.client_prospects cp
  join public.prospect_index pi on pi.id = cp.prospect_id
  join public.client_blocklist b on b.client_id = p_client_id
  where cp.client_id = p_client_id
    and (
      (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
      or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
    );

  v_blocked := public.apply_client_blocklist_v1(p_client_id);
  perform public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    'blocklist_add', p_client_id, p_actor,
    format('Blocked %s new entries, suppressing %s records', v_added, v_blocked), v_blocked, v_ids);

  return jsonb_build_object('added', v_added, 'suppressed', v_blocked);
end;
$$;


ALTER FUNCTION public.add_client_blocklist_v1(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text) OWNER TO postgres;

--
-- Name: add_prospects_to_list_v1(text, text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.add_prospects_to_list_v1(p_list_id text, p_import_id text, p_prospect_ids text[]) RETURNS TABLE(added integer, already_present integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  candidate_count integer := 0;
  inserted_count integer := 0;
begin
  if p_prospect_ids is null or array_length(p_prospect_ids, 1) is null then
    return query select 0, 0;
    return;
  end if;
  if not exists (select 1 from public.imports i where i.id = p_import_id and i.list_id = p_list_id) then
    raise exception 'Push not found for this list' using errcode = 'P0002';
  end if;

  -- Only ids that actually exist in the People database; a stale id is skipped,
  -- never invented.
  with existing as (
    select p.id from public.prospects p where p.id = any(p_prospect_ids)
  ), inserted as (
    insert into public.list_memberships(list_id, prospect_id, import_id)
    select p_list_id, existing.id, p_import_id from existing
    on conflict (list_id, prospect_id) do nothing
    returning 1
  )
  select (select count(*)::integer from existing), (select count(*)::integer from inserted)
  into candidate_count, inserted_count;

  update public.imports set
    total_rows = total_rows + candidate_count,
    processed_rows = processed_rows + candidate_count,
    duplicates_linked = duplicates_linked + (candidate_count - inserted_count)
  where id = p_import_id;

  return query select inserted_count, candidate_count - inserted_count;
end;
$$;


ALTER FUNCTION public.add_prospects_to_list_v1(p_list_id text, p_import_id text, p_prospect_ids text[]) OWNER TO postgres;

--
-- Name: analyze_prospect_index(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.analyze_prospect_index() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
begin
  analyze public.prospect_index;
  analyze public.companies;
end;
$$;


ALTER FUNCTION public.analyze_prospect_index() OWNER TO postgres;

--
-- Name: apply_client_blocklist_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.apply_client_blocklist_v1(p_client_id text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_blocked integer;
begin
  update public.client_prospects cp set
    status = 'blocked',
    blocked_at = coalesce(cp.blocked_at, now()),
    blocked_reason = coalesce(nullif(cp.blocked_reason, ''), matched.reason)
  from (
    select distinct cp2.prospect_id, first_value(b.reason) over (partition by cp2.prospect_id order by b.created_at) as reason
    from public.client_prospects cp2
    join public.prospect_index pi on pi.id = cp2.prospect_id
    join public.client_blocklist b on b.client_id = p_client_id
    where cp2.client_id = p_client_id
      and (
        (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
      )
  ) matched
  where cp.client_id = p_client_id
    and cp.prospect_id = matched.prospect_id
    and cp.status <> 'blocked';

  get diagnostics v_blocked = row_count;
  perform public.sweep_client_company_blocklist_v1(p_client_id);
  return v_blocked;
end;
$$;


ALTER FUNCTION public.apply_client_blocklist_v1(p_client_id text) OWNER TO postgres;

--
-- Name: apply_email_provider_scan_v1(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.apply_email_provider_scan_v1(p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_updated integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return 0;
  end if;

  update public.companies c
  set esp = scanned.esp,
      email_provider_type = scanned.email_provider_type,
      mx_records = scanned.mx_records,
      mx_status = scanned.mx_status,
      mx_checked_at = scanned.mx_checked_at
  from jsonb_to_recordset(p_rows) as scanned(
    id text,
    esp text,
    email_provider_type text,
    mx_records text[],
    mx_status text,
    mx_checked_at timestamptz
  )
  where c.id = scanned.id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;


ALTER FUNCTION public.apply_email_provider_scan_v1(p_rows jsonb) OWNER TO postgres;

--
-- Name: background_health_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.background_health_v1() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'prospect_operations', 'prospect_results', 'prospect_exports'
    AS $$
  WITH queues AS (
    SELECT 'search'::text kind,count(*) pending,
      coalesce(max(extract(epoch FROM (now()-created_at))),0) oldest_seconds
      FROM prospect_results.result_sets WHERE status IN ('pending','building') AND expires_at>now()
    UNION ALL SELECT 'operation',count(*),coalesce(max(extract(epoch FROM (now()-created_at))),0)
      FROM prospect_operations.operation_jobs WHERE status IN ('pending','frozen','running')
    UNION ALL SELECT 'export',count(*),coalesce(max(extract(epoch FROM (now()-created_at))),0)
      FROM prospect_exports.jobs WHERE status IN ('queued','building') AND expires_at>now()
  ), metrics AS (
    SELECT kind,outcome,duration_bucket_ms,sum(jobs) jobs,sum(total_ms) total_ms,max(max_ms) max_ms
      FROM prospect_operations.job_metrics WHERE hour>=date_trunc('hour',now())-interval '1 hour'
      GROUP BY kind,outcome,duration_bucket_ms
  )
  SELECT jsonb_build_object(
    'measuredAt',now(),'schemaVersion',1,
    'queues',(SELECT jsonb_agg(to_jsonb(queues)) FROM queues),
    'recentJobs',coalesce((SELECT jsonb_agg(to_jsonb(metrics)) FROM metrics),'[]'::jsonb),
    'recentWindow','current and previous UTC hour',
    'searchBytes',pg_total_relation_size('prospect_results.result_sets')+pg_total_relation_size('prospect_results.result_set_items'),
    'exportBytes',pg_total_relation_size('prospect_exports.jobs')+pg_total_relation_size('prospect_exports.job_parts'),
    'operationBytes',pg_total_relation_size('prospect_operations.operation_jobs')+pg_total_relation_size('prospect_operations.operation_job_items'),
    'metricBytes',pg_total_relation_size('prospect_operations.job_metrics')
  );
$$;


ALTER FUNCTION public.background_health_v1() OWNER TO postgres;

--
-- Name: block_company_on_domain_change_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.block_company_on_domain_change_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  r record;
  v_ids text[];
begin
  for r in
    select b.client_id, coalesce(nullif(b.reason, ''), 'Matched client blocklist') as reason
    from public.client_blocklist b
    where b.kind = 'domain' and b.value = new.normalized_domain
  loop
    with moved as (
      delete from public.client_companies cc
      where cc.client_id = r.client_id and cc.company_id = new.id
      returning cc.added_at, cc.added_by
    )
    insert into public.client_companies_blocked (client_id, company_id, added_at, added_by, blocked_reason)
    select r.client_id, new.id, moved.added_at, moved.added_by, r.reason from moved
    on conflict (client_id, company_id) do nothing;

    with blocked as (
      update public.client_prospects cp set
        status = 'blocked',
        blocked_at = coalesce(cp.blocked_at, now()),
        blocked_reason = coalesce(nullif(cp.blocked_reason, ''), r.reason)
      from public.prospects p
      where p.company_id = new.id
        and cp.prospect_id = p.id
        and cp.client_id = r.client_id
        and cp.status = 'active'
      returning cp.prospect_id
    )
    select array_agg(prospect_id) into v_ids from blocked;
    if v_ids is not null then
      perform public.reindex_prospects(v_ids);
    end if;
  end loop;
  return null;
end;
$$;


ALTER FUNCTION public.block_company_on_domain_change_v1() OWNER TO postgres;

--
-- Name: block_prospect_on_identity_change_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.block_prospect_on_identity_change_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_ids text[];
begin
  with matched as (
    select cp.client_id, public.client_block_reason_v1(cp.client_id, new.id) as reason
    from public.client_prospects cp
    where cp.prospect_id = new.id
      and cp.status = 'active'
      and exists (select 1 from public.client_blocklist b where b.client_id = cp.client_id)
  ), blocked as (
    update public.client_prospects cp set
      status = 'blocked',
      blocked_at = coalesce(cp.blocked_at, now()),
      blocked_reason = coalesce(nullif(cp.blocked_reason, ''), m.reason)
    from matched m
    where cp.prospect_id = new.id and cp.client_id = m.client_id and m.reason is not null
    returning cp.prospect_id
  )
  select array_agg(prospect_id) into v_ids from blocked;
  if v_ids is not null then
    perform public.reindex_prospects(array[new.id]);
  end if;
  return null;
end;
$$;


ALTER FUNCTION public.block_prospect_on_identity_change_v1() OWNER TO postgres;

--
-- Name: bump_data_version_company(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.bump_data_version_company() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform nextval('public.data_version_company');
  return null;
end;
$$;


ALTER FUNCTION public.bump_data_version_company() OWNER TO postgres;

--
-- Name: bump_data_version_prospect(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.bump_data_version_prospect() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  -- Once per statement, not once per row: an import batch of 5,000 rows bumps
  -- this once. The value carries no meaning beyond "something moved".
  perform nextval('public.data_version_prospect');
  return null;
end;
$$;


ALTER FUNCTION public.bump_data_version_prospect() OWNER TO postgres;

--
-- Name: cancel_integration_job_v1(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cancel_integration_job_v1(p_actor text, p_job uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_id uuid;
begin
  select id into v_id from prospect_integrations.jobs where id=p_job and actor=p_actor and status in ('draft','queued','running') for update;
  if not found then return false; end if;
  update prospect_integrations.batches set status='cancelled' where job_id=v_id and status='pending';
  update prospect_integrations.jobs set status=case when exists(select 1 from prospect_integrations.batches where job_id=v_id and status='sending') then 'needs_review' else 'cancelled' end where id=v_id;
  return true;
end;
$$;


ALTER FUNCTION public.cancel_integration_job_v1(p_actor text, p_job uuid) OWNER TO postgres;

--
-- Name: capture_company_import_membership_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.capture_company_import_membership_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.company_id is not null then
    insert into public.company_import_memberships(import_id, company_id, first_seen_at)
    values (new.import_id, new.company_id, coalesce(new.imported_at, now()))
    on conflict (import_id, company_id) do nothing;
  end if;
  return new;
end;
$$;


ALTER FUNCTION public.capture_company_import_membership_v1() OWNER TO postgres;

--
-- Name: claim_next_prospect_import_v1(text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.claim_next_prospect_import_v1(p_worker_id text, p_lease_seconds integer DEFAULT 300) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '5s'
    AS $$
declare
  import_id_value text;
  result_value jsonb;
begin
  if nullif(btrim(p_worker_id), '') is null then
    raise exception 'worker id is required' using errcode = '22023';
  end if;
  if p_lease_seconds < 30 or p_lease_seconds > 1800 then
    raise exception 'lease must be between 30 and 1800 seconds' using errcode = '22023';
  end if;

  select i.id into import_id_value
  from public.imports i
  where i.ingestion_mode = 'background'
    and i.next_attempt_at <= now()
    and (
      i.status = 'queued'
      or (i.status = 'processing' and coalesce(i.lease_expires_at, '-infinity'::timestamptz) < now())
    )
  order by i.created_at, i.id
  for update skip locked
  limit 1;

  if import_id_value is null then
    return null;
  end if;

  update public.imports i
  set status = 'processing',
      worker_id = p_worker_id,
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      heartbeat_at = now(),
      started_at = coalesce(i.started_at, now()),
      attempt_count = i.attempt_count + 1
  where i.id = import_id_value
  returning jsonb_build_object(
    'id', i.id,
    'listId', i.list_id,
    'fileName', i.file_name,
    'storageObjectPath', i.storage_object_path,
    'fileSizeBytes', i.file_size_bytes,
    'committedRowOffset', i.committed_row_offset,
    'totalRows', i.total_rows,
    'sourceHeaders', i.source_headers,
    'fieldMap', i.field_map,
    'attemptCount', i.attempt_count
  ) into result_value;

  return result_value;
end;
$$;


ALTER FUNCTION public.claim_next_prospect_import_v1(p_worker_id text, p_lease_seconds integer) OWNER TO postgres;

--
-- Name: classify_job_title_v1(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.classify_job_title_v1(p_title text, p_company_name text DEFAULT ''::text) RETURNS TABLE(seniority text, department text, sub_department text, secondary_departments text[], is_former boolean, normalized_title text)
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
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
      cross join generate_series(1, least(v_count, 8)) as len(value)
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
      cross join generate_series(1, least(v_count, 8)) as len(value)
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
      cross join generate_series(1, least(v_count, 8)) as len(value)
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


ALTER FUNCTION public.classify_job_title_v1(p_title text, p_company_name text) OWNER TO postgres;

--
-- Name: client_addition_batch_records_v1(text, uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_addition_batch_records_v1(p_client_id text, p_batch_id uuid, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $$
declare v_entity text;
begin
  select entity_type into v_entity from public.client_addition_batches
  where id = p_batch_id and client_id = p_client_id;
  if v_entity is null then raise exception 'Batch not found' using errcode = 'P0002'; end if;
  if v_entity = 'people' then
    return query with matched as materialized (
      select pi.id as record_id, pi.full_name as display_name,
        coalesce(pi.company_name, pi.work_email) as secondary_text, i.added_at
      from public.client_addition_batch_items i
      join public.prospect_index pi on pi.id = i.entity_id
      where i.batch_id = p_batch_id
    ), page_rows as (
      select * from matched order by added_at desc, record_id
      limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
    ) select coalesce((select jsonb_agg(to_jsonb(page_rows) order by added_at desc, record_id) from page_rows), '[]'::jsonb),
      (select count(*) from matched);
  else
    return query with matched as materialized (
      select co.id as record_id, co.name as display_name,
        co.domain as secondary_text, i.added_at
      from public.client_addition_batch_items i
      join public.companies co on co.id = i.entity_id
      where i.batch_id = p_batch_id
    ), page_rows as (
      select * from matched order by added_at desc, record_id
      limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
    ) select coalesce((select jsonb_agg(to_jsonb(page_rows) order by added_at desc, record_id) from page_rows), '[]'::jsonb),
      (select count(*) from matched);
  end if;
end;
$$;


ALTER FUNCTION public.client_addition_batch_records_v1(p_client_id text, p_batch_id uuid, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: client_block_reason_v1(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_block_reason_v1(p_client_id text, p_prospect_id text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '5s'
    AS $$
  select coalesce(nullif(b.reason, ''), 'Matched client blocklist')
  from public.prospects p
  left join public.companies c on c.id = p.company_id
  join public.client_blocklist b on b.client_id = p_client_id
    and (
      (b.kind = 'domain' and b.value <> '' and b.value = coalesce(c.normalized_domain, lower(c.domain), ''))
      or (b.kind = 'email' and b.value <> '' and b.value in (lower(coalesce(p.work_email, '')), lower(coalesce(p.personal_email, ''))))
    )
  where p.id = p_prospect_id
  order by b.created_at, b.id
  limit 1;
$$;


ALTER FUNCTION public.client_block_reason_v1(p_client_id text, p_prospect_id text) OWNER TO postgres;

--
-- Name: client_blocked_prospect_ids(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_blocked_prospect_ids(p_client_id text) RETURNS TABLE(prospect_id text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select cp.prospect_id
  from public.client_prospects cp
  where cp.client_id = p_client_id and cp.status = 'blocked';
$$;


ALTER FUNCTION public.client_blocked_prospect_ids(p_client_id text) OWNER TO postgres;

--
-- Name: client_blocklist_export_page_v1(text, text[], boolean, text, text, date, date, text[], timestamp with time zone, timestamp with time zone, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_blocklist_export_page_v1(p_client_id text, p_ids text[] DEFAULT NULL::text[], p_all_matching boolean DEFAULT false, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_excluded_ids text[] DEFAULT NULL::text[], p_selected_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 1000) RETURNS TABLE(id text, value text, kind text, reason text, created_at timestamp with time zone)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  select b.id, b.value::text, b.kind::text, b.reason::text, b.created_at
  from public.client_blocklist_selection_v1(
    p_client_id, p_ids, p_all_matching, p_search, p_kind, p_date_from,
    p_date_to, p_excluded_ids, p_selected_before, 250001
  ) selected
  join public.client_blocklist b on b.id = selected.entry_id and b.client_id = p_client_id
  where p_after_created_at is null
     or b.created_at < p_after_created_at
     or (b.created_at = p_after_created_at and b.id > coalesce(p_after_id, ''))
  order by b.created_at desc, b.id
  limit greatest(1, least(coalesce(p_limit, 1000), 1000));
$$;


ALTER FUNCTION public.client_blocklist_export_page_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer) OWNER TO postgres;

--
-- Name: client_blocklist_selection_count_v1(text, text[], boolean, text, text, date, date, text[], timestamp with time zone); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_blocklist_selection_count_v1(p_client_id text, p_ids text[] DEFAULT NULL::text[], p_all_matching boolean DEFAULT false, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_excluded_ids text[] DEFAULT NULL::text[], p_selected_before timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  select count(*)::integer
  from public.client_blocklist_selection_v1(
    p_client_id, p_ids, p_all_matching, p_search, p_kind, p_date_from,
    p_date_to, p_excluded_ids, p_selected_before, 250001
  );
$$;


ALTER FUNCTION public.client_blocklist_selection_count_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone) OWNER TO postgres;

--
-- Name: client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamp with time zone, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_blocklist_selection_v1(p_client_id text, p_ids text[] DEFAULT NULL::text[], p_all_matching boolean DEFAULT false, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_excluded_ids text[] DEFAULT NULL::text[], p_selected_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 250000) RETURNS TABLE(entry_id text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  select b.id
  from public.client_blocklist b
  where b.client_id = p_client_id
    and (
      (not coalesce(p_all_matching, false) and p_ids is not null and b.id = any(p_ids))
      or (coalesce(p_all_matching, false)
        and (btrim(coalesce(p_search, '')) = '' or b.value ilike '%' || p_search || '%')
        and (btrim(coalesce(p_kind, '')) = '' or b.kind = p_kind)
        and (p_date_from is null or b.created_at >= (p_date_from::text || 'T00:00:00Z')::timestamptz)
        and (p_date_to is null or b.created_at < ((p_date_to + 1)::text || 'T00:00:00Z')::timestamptz)
        and (p_selected_before is null or b.created_at <= p_selected_before))
    )
    and not (b.id = any(coalesce(p_excluded_ids, array[]::text[])))
  order by b.created_at desc, b.id
  limit greatest(1, least(coalesce(p_limit, 250001), 250001));
$$;


ALTER FUNCTION public.client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_limit integer) OWNER TO postgres;

--
-- Name: client_company_block_reason_v1(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_company_block_reason_v1(p_client_id text, p_company_id text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(nullif(b.reason, ''), 'Matched client blocklist')
  from public.companies co
  join public.client_blocklist b
    on b.client_id = p_client_id and b.kind = 'domain' and b.value <> '' and b.value = co.normalized_domain
  where co.id = p_company_id
  order by b.created_at, b.id
  limit 1;
$$;


ALTER FUNCTION public.client_company_block_reason_v1(p_client_id text, p_company_id text) OWNER TO postgres;

--
-- Name: client_company_prospects(text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_company_prospects(p_client_id text, p_company_id text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  with matched as materialized (
    select ps.*
    from public.client_prospects cp
    join public.prospect_summaries ps on ps.id = cp.prospect_id
    where cp.client_id = p_client_id and cp.status = 'active' and ps.company_id = p_company_id
  ), page_rows as (
    select * from matched order by full_name
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows)) from page_rows), '[]'::jsonb),
    (select count(*) from matched);
$$;


ALTER FUNCTION public.client_company_prospects(p_client_id text, p_company_id text, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: client_company_removal_preview_v1(text, text[], text, jsonb, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_company_removal_preview_v1(p_client_id text, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[]) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_company_ids text[] := array[]::text[];
  v_people bigint := 0;
begin
  select coalesce(array_agg(company_id), array[]::text[]) into v_company_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if cardinality(v_company_ids) = 0 then
    return jsonb_build_object('companies', 0, 'people', 0);
  end if;

  select count(*) into v_people
  from public.prospect_index pi
  where pi.company_id = any(v_company_ids)
    and pi.client_ids @> array[p_client_id];

  return jsonb_build_object('companies', cardinality(v_company_ids), 'people', v_people);
end;
$$;


ALTER FUNCTION public.client_company_removal_preview_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[]) OWNER TO postgres;

--
-- Name: client_company_workspace(text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_company_workspace(p_client_id text, p_search text DEFAULT ''::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  with client_prospects as materialized (
    select distinct lm.prospect_id, p.company_id
    from public.list_memberships lm
    join public.lists l on l.id = lm.list_id and l.client_id = p_client_id
    join public.prospects p on p.id = lm.prospect_id
  ), matched as materialized (
    select c.id, c.name, c.domain, c.created_at,
      count(distinct cp.prospect_id)::integer as prospect_count,
      1::integer as client_count
    from client_prospects cp
    join public.companies c on c.id = cp.company_id
    where trim(coalesce(p_search, '')) = ''
      or concat_ws(' ', c.name, c.domain) ilike '%' || trim(p_search) || '%'
    group by c.id
  ), page_rows as (
    select * from matched
    order by prospect_count desc, name
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows)) from page_rows), '[]'::jsonb),
    (select count(*) from matched),
    (select count(*) from matched where matched.prospect_count > 0),
    (select count(*) from client_prospects where company_id is not null);
$$;


ALTER FUNCTION public.client_company_workspace(p_client_id text, p_search text, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: client_company_workspace_v2(text, text, jsonb, jsonb, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint, covered_count bigint, prospect_count bigint, total_capped boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $_$
declare
  -- Taken out before compilation on purpose: company_filter_sql_v3 would render
  -- this as companies.prospect_count, which counts every client's people.
  v_coverage text := (
    select value->'values'->>0
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
    where value->>'field' = '__company_coverage'
    limit 1
  );
  v_filters jsonb := coalesce((
    select jsonb_agg(value)
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
    where value->>'field' <> '__company_coverage'
  ), '[]'::jsonb);
  v_coverage_clause text := case v_coverage
    when 'with' then 'where matched.prospect_count > 0'
    when 'without' then 'where matched.prospect_count = 0'
    else '' end;
  v_unfiltered boolean := btrim(coalesce(p_search, '')) = ''
    and v_filters = '[]'::jsonb;
  v_prefilter text := public.company_prefilter_sql(p_search, v_filters);
  v_match_clause text;
  v_counts_cte text;
  v_counts_join text;
  v_count_cap text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_complete text;
  v_sql text;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, v_filters);

  if v_unfiltered then
    v_match_clause := coalesce(v_complete, 'true');
    -- Only the per-client prospect count still has to be computed; client_count
    -- comes off companies, where the trigger keeps it current.
    v_counts_cte := format($counts$client_counts as (
        select pi.company_id, count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id is not null and pi.client_ids @> array[%L]
        group by pi.company_id
      ), $counts$, p_client_id);
    v_counts_join := 'left join client_counts counts on counts.company_id = c.id';
  else
    v_match_clause := coalesce(v_complete,
      case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
        || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, v_filters::text));
    v_counts_cte := '';
    v_counts_join := format($joins$left join lateral (
        select count(*)::integer as prospect_count
        from public.prospect_index pi
        where pi.company_id = c.id and pi.client_ids @> array[%L]
      ) counts on true$joins$, p_client_id);
  end if;

  -- Cap only when something narrows the set. An unfiltered client listing is the
  -- headline count and has to stay exact. Coverage narrows it, so it counts as
  -- a filter here even though it is not carried as one.
  v_count_cap := case when v_match_clause = 'true' and p_people_scope is null and v_coverage is null then 'all' else '50001' end;

  v_sql := format($query$
    with %6$s matched as materialized (
      select c.id, c.name, c.domain, c.created_at,
        coalesce(counts.prospect_count, 0)::integer as prospect_count,
        c.client_count
      from public.client_companies membership
      join public.companies c on c.id = membership.company_id
      %7$s
      where membership.client_id = %1$L
        and (%2$s)
        and (%3$L::jsonb is null or c.id in (
          select company_id from public.people_scope_company_ids_v1(%1$L, %3$L::jsonb)
        ))
    ), visible as (
      select * from matched %9$s
    ), page_rows as (
      select * from visible
      order by prospect_count desc, lower(name), id
      limit %5$s offset %4$s
    ), capped as (
      -- Bounded count. The page is cheap -- it is ordered off an index and stops
      -- after one screen -- but counting every match is not, and it grows with
      -- the data. On this database a broad description filter cost ~1.3s warm to
      -- count and roughly 34s from a cold cache, which is what pushed this past
      -- the statement timeout and cascaded into pool exhaustion.
      select * from visible limit %8$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page_rows) order by page_rows.prospect_count desc, lower(page_rows.name), page_rows.id)
        from page_rows
      ), '[]'::jsonb),
      (select case when %8$L = 'all' then count(*) else least(count(*), 50000) end from capped),
      (select count(*) from capped where capped.prospect_count > 0),
      (select coalesce(sum(capped.prospect_count), 0) from capped),
      (select (count(*) > 50000 and %8$L <> 'all') from capped)
  $query$, p_client_id, v_match_clause,
       case when p_people_scope is null then null else p_people_scope::text end,
       v_offset::text, v_limit::text, v_counts_cte, v_counts_join, v_count_cap, v_coverage_clause);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text, p_filters jsonb, p_people_scope jsonb, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: client_icp_tag_counts_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_icp_tag_counts_v1(p_client_id text) RETURNS TABLE(tag_id text, prospect_count bigint, company_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '8s'
    AS $$
  select t.id,
    (select count(*) from public.prospect_tag_links l where l.tag_id = t.id),
    (select count(*) from public.company_tag_links l where l.tag_id = t.id)
  from public.prospect_tags t
  -- Client-scoped only. An agency-wide tag belongs to no ICP, so counting one
  -- here would attribute it to whichever client happened to ask.
  where t.client_id = p_client_id;
$$;


ALTER FUNCTION public.client_icp_tag_counts_v1(p_client_id text) OWNER TO postgres;

--
-- Name: client_recent_batches_v1(text, text, text, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_recent_batches_v1(p_client_id text, p_search text DEFAULT ''::text, p_entity text DEFAULT ''::text, p_hours integer DEFAULT NULL::integer, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $$
  with matched as materialized (
    select b.id, b.entity_type, b.source_kind, b.source_label, b.outcome_kind,
      b.source_client_id, source_client.name as source_client_name,
      b.created_at, b.completed_at,
      count(i.entity_id)::bigint as record_count
    from public.client_addition_batches b
    left join public.client_addition_batch_items i on i.batch_id = b.id
    left join public.clients source_client on source_client.id = b.source_client_id
    where b.client_id = p_client_id
      and (coalesce(p_entity, '') = '' or b.entity_type = p_entity)
      and (p_hours is null or b.created_at >= now() - make_interval(hours => greatest(1, least(p_hours, 24 * 3650))))
      and (
        btrim(coalesce(p_search, '')) = ''
        or b.source_label ilike '%' || p_search || '%'
        or source_client.name ilike '%' || p_search || '%'
        or exists (
          select 1
          from public.client_addition_batch_items searched
          left join public.prospect_index pi
            on b.entity_type = 'people' and pi.id = searched.entity_id
          left join public.companies co
            on b.entity_type = 'companies' and co.id = searched.entity_id
          where searched.batch_id = b.id
            and (pi.search_text ilike '%' || p_search || '%'
              or co.name ilike '%' || p_search || '%'
              or co.domain ilike '%' || p_search || '%')
        )
      )
    group by b.id, source_client.name
  ), page_rows as (
    select * from matched
    order by created_at desc, id desc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(page_rows) order by created_at desc, id desc)
    from page_rows), '[]'::jsonb), (select count(*) from matched);
$$;


ALTER FUNCTION public.client_recent_batches_v1(p_client_id text, p_search text, p_entity text, p_hours integer, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: client_recently_added_v1(text, text, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.client_recently_added_v1(p_client_id text, p_entity text DEFAULT 'people'::text, p_hours integer DEFAULT 24, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  -- Bounded rather than trusted: the window arrives from a query string. Ninety
  -- days is well past the point where "recently added" means anything, and it
  -- keeps the scan inside the index range above.
  v_hours integer := greatest(1, least(coalesce(p_hours, 24), 24 * 90));
  v_since timestamptz := now() - make_interval(hours => v_hours);
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
begin
  if p_entity = 'companies' then
    return query
      with matched as (
        select c.id, c.name, c.domain, cc.prospect_count, cc.added_at
        from public.client_companies cc
        join public.companies c on c.id = cc.company_id
        where cc.client_id = p_client_id
          and cc.added_at >= v_since
      ), page_rows as (
        select * from matched
        order by added_at desc, lower(name), id
        limit v_limit offset v_offset
      )
      select coalesce((
          select jsonb_agg(to_jsonb(page_rows) order by page_rows.added_at desc, lower(page_rows.name), page_rows.id)
          from page_rows
        ), '[]'::jsonb),
        (select count(*) from matched);
  else
    return query
      with matched as (
        select pi.id, pi.full_name, pi.title, pi.work_email, pi.company_name,
               cp.added_at, cp.added_via
        from public.client_prospects cp
        join public.prospect_index pi on pi.id = cp.prospect_id
        where cp.client_id = p_client_id
          and cp.added_at >= v_since
      ), page_rows as (
        select * from matched
        order by added_at desc, id
        limit v_limit offset v_offset
      )
      select coalesce((
          select jsonb_agg(to_jsonb(page_rows) order by page_rows.added_at desc, page_rows.id)
          from page_rows
        ), '[]'::jsonb),
        (select count(*) from matched);
  end if;
end;
$$;


ALTER FUNCTION public.client_recently_added_v1(p_client_id text, p_entity text, p_hours integer, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: company_effective_filter_sql_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_effective_filter_sql_v1(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_clean jsonb;
  v_import_count integer;
  v_import_id text;
  v_prefilter text;
  v_complete text;
  v_base text;
begin
  select count(*), min(item->'values'->>0) into v_import_count, v_import_id
  from jsonb_array_elements(v_filters) item
  where item->>'field' = '__company_import_id';
  if v_import_count > 1 or (v_import_count = 1 and coalesce(btrim(v_import_id), '') = '') then
    raise exception 'Choose one company import.' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(item order by ordinal), '[]'::jsonb) into v_clean
  from jsonb_array_elements(v_filters) with ordinality entries(item, ordinal)
  where item->>'field' <> '__company_import_id';
  v_prefilter := public.company_prefilter_sql(p_search, v_clean);
  v_complete := public.company_filter_sql_v3(p_search, v_clean, false);
  if v_complete is null then return null; end if;
  v_base := case
    when v_prefilter <> 'true' and v_prefilter is distinct from v_complete
      then '(' || v_prefilter || ') and (' || v_complete || ')'
    else v_complete end;
  if v_import_count = 1 then
    v_base := '(' || v_base || ') and exists (select 1 from public.company_import_memberships cim'
      || ' where cim.company_id = c.id and cim.import_id = ' || quote_literal(v_import_id) || ')';
  end if;
  return v_base;
end;
$$;


ALTER FUNCTION public.company_effective_filter_sql_v1(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: company_export_field_names_v1(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_export_field_names_v1(p_limit integer DEFAULT 200) RETURNS TABLE(field_name text, populated bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '8s'
    AS $$
  with scanned as (
    select c.all_data
    from public.companies c
    where c.all_data <> '{}'::jsonb
    limit 20000
  )
  select entry.key::text, count(*)::bigint
  from scanned
  cross join lateral jsonb_each_text(scanned.all_data) entry
  where btrim(coalesce(entry.value, '')) <> ''
  group by entry.key
  order by count(*) desc, entry.key
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$$;


ALTER FUNCTION public.company_export_field_names_v1(p_limit integer) OWNER TO postgres;

--
-- Name: company_filter_is_probed_v1(text, jsonb, text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_filter_is_probed_v1(p_field text, p_scopes jsonb, p_operator text, p_values text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $_$
  select p_operator in ('contains', 'not_contains')
    -- Below this many values the planner can still BitmapOr the trigram indexes
    -- from an OR chain, and the chain plans faster than a semi-join.
    and cardinality(coalesce(p_values, array[]::text[])) >= 8
    -- The row form tests coalesce(col, '') ilike '%v%', so a NULL column behaves
    -- as ''. The probe form lets NULL fail the join. Those agree for every value
    -- except one made entirely of '%', which matches the empty string. Such a
    -- value keeps the OR chain rather than being quietly redefined.
    and not exists (select 1 from unnest(coalesce(p_values, array[]::text[])) v where v ~ '^%+$')
    and cardinality(public.company_probe_columns_v1(p_field, p_scopes)) > 0;
$_$;


ALTER FUNCTION public.company_filter_is_probed_v1(p_field text, p_scopes jsonb, p_operator text, p_values text[]) OWNER TO postgres;

--
-- Name: company_filter_sql_v2(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_filter_sql_v2(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select public.company_filter_sql_v3(p_search, p_filters, false);
$$;


ALTER FUNCTION public.company_filter_sql_v2(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: company_filter_sql_v3(text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean DEFAULT false) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $_$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  selected_scopes jsonb;
  candidate_expr text;
  boolean_expr text;
  keyword_hit text;
  keyword_values text[];
  match_cols text[];
  raw_cols text[];
  probe_sql text;
  scope_parts text[];
  value_parts text[];
  raw_values text[];
  value_text text;
  lowered text[];
  minimum text;
  maximum text;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('(c.name ilike %1$L or c.domain ilike %1$L)', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    field_key := filter_item->>'field';

    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;

    if cardinality(raw_values) = 0 and coalesce(filter_item->>'setId', '') = '' and operator_key not in ('empty', 'not_empty') then
      continue;
    end if;

    keyword_hit := 'false';
    keyword_values := null;

    selected_scopes := case
      when field_key <> '__company_keywords' then null
      when jsonb_typeof(filter_item->'scopes') = 'array'
        then case when jsonb_array_length(filter_item->'scopes') > 0
          then filter_item->'scopes' else '["name","keywords"]'::jsonb end
      else '["name","keywords"]'::jsonb
    end;

    if field_key = '__company_keywords' then
      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      candidate_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      match_cols := scope_parts;

      scope_parts := array[]::text[];
      if selected_scopes ? 'name' then scope_parts := array_append(scope_parts, 'c.name'); end if;
      if selected_scopes ? 'keywords' then scope_parts := array_append(scope_parts, 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'); end if;
      if selected_scopes ? 'description' then scope_parts := array_append(scope_parts, 'c.short_description'); end if;
      boolean_expr := case when cardinality(scope_parts) = 0 then quote_literal('')
        else 'concat_ws(' || quote_literal(' | ') || ', ' || array_to_string(scope_parts, ', ') || ')' end;

      if selected_scopes ? 'keywords' and cardinality(raw_values) > 0 then
        -- Both spellings: the tag store is lowercase, so "IT services" typed as
        -- the user thinks of it matched nothing at all.
        keyword_hit := format('c.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
        keyword_values := raw_values;
      end if;
    else
      if field_key = '__company_client_ids' then
        if cardinality(raw_values) = 0 then continue; end if;
        if operator_key in ('not_contains', 'not_equals') then
          conjuncts := conjuncts || format($cc$(not exists (select 1 from public.client_companies cc
            where cc.company_id = c.id and cc.client_id = any (%L::text[])))$cc$, raw_values);
        else
          conjuncts := conjuncts || format($cc$(exists (select 1 from public.client_companies cc
            where cc.company_id = c.id and cc.client_id = any (%L::text[])))$cc$, raw_values);
        end if;
        continue;
      end if;
      if field_key = '__company_tags' then
        if cardinality(raw_values) = 0 then continue; end if;
        if operator_key in ('not_contains', 'not_equals') then
          conjuncts := conjuncts || format($t$(not exists (select 1 from public.company_tag_links ctl
            where ctl.company_id = c.id and ctl.tag_id = any (%L::text[])))$t$, raw_values);
        else
          conjuncts := conjuncts || format($t$(exists (select 1 from public.company_tag_links ctl
            where ctl.company_id = c.id and ctl.tag_id = any (%L::text[])))$t$, raw_values);
        end if;
        continue;
      end if;
      if field_key = '__company_ids' then
        if cardinality(raw_values) = 0 then continue; end if;
        if operator_key in ('not_contains', 'not_equals') then
          conjuncts := conjuncts || format('(not (c.id = any (%L::text[])))', raw_values);
        else
          conjuncts := conjuncts || format('(c.id = any (%L::text[]))', raw_values);
        end if;
        continue;
      end if;
      if field_key = '__company_coverage' then
        if cardinality(raw_values) = 0 then continue; end if;
        if raw_values[1] = 'with' then
          conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) > 0)');
        elsif raw_values[1] = 'without' then
          conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) = 0)');
        end if;
        continue;
      end if;
      candidate_expr := case field_key
        when '__company_icp_verified' then '(select array_to_string(array_agg(v.client_id order by v.client_id), '' | '') from public.client_company_icp_validations v where v.company_id = c.id)'
        when '__company' then 'c.name'
        when '__website' then 'c.domain'
        when '__industry' then 'c.industry'
        when '__company_city' then 'c.city'
        when '__company_state' then 'c.state'
        when '__company_country' then 'c.country'
        when '__company_location' then 'coalesce(nullif(c.location, ' || quote_literal('') || '), concat_ws(' || quote_literal(', ') || ', nullif(c.city, ' || quote_literal('') || '), nullif(c.state, ' || quote_literal('') || '), nullif(c.country, ' || quote_literal('') || ')))'
        when '__keywords' then 'array_to_string(c.keywords, ' || quote_literal(' | ') || ')'
        when '__short_description' then 'c.short_description'
        when '__founded_year' then 'c.founded_year::text'
        when '__technologies' then 'array_to_string(c.technologies, ' || quote_literal(' | ') || ')'
        when '__total_funding' then 'c.total_funding'
        when '__employee_count' then quote_literal('')
        else null
      end;
      if candidate_expr is null then return null; end if;
      boolean_expr := candidate_expr;
      match_cols := array[candidate_expr];
    end if;

    candidate_expr := 'coalesce(' || candidate_expr || ', ' || quote_literal('') || ')';
    raw_cols := match_cols;
    match_cols := array(select 'coalesce(' || col || ', ' || quote_literal('') || ')' from unnest(match_cols) col);
    if cardinality(match_cols) = 0 then match_cols := array[candidate_expr]; raw_cols := array[candidate_expr]; end if;
    boolean_expr := 'coalesce(' || boolean_expr || ', ' || quote_literal('') || ')';

    if coalesce(filter_item->>'setId', '') <> '' then
      if operator_key <> 'equals' then
        raise exception 'A filter set supports the equals operator only, got %', operator_key
          using errcode = '22023';
      end if;
      value_parts := array(select format(
        'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))',
        (filter_item->>'setId')::uuid, col) from unnest(match_cols) col);
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      continue;
    end if;

    probe_sql := null;
    if coalesce(p_probe, false)
       and public.company_filter_is_probed_v1(field_key, selected_scopes, operator_key, raw_values) then
      probe_sql := public.company_substring_probe_sql_v1(
        public.company_probe_columns_v1(field_key, selected_scopes), raw_values, keyword_values);
    end if;

    if operator_key = 'equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := case when keyword_hit <> 'false' then array[keyword_hit] else array[]::text[] end;
      value_parts := value_parts || array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(raw_cols) col);
      if field_key = '__keywords' then
        value_parts := value_parts || format('c.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      elsif field_key = '__technologies' then
        value_parts := value_parts || format('c.technologies && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      end if;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'not_equals' then
      lowered := array(select lower(value) from unnest(raw_values) value);
      value_parts := array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_cols) col);
      conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));

    elsif operator_key = 'not_contains' then
      if probe_sql is not null then
        conjuncts := conjuncts || format('(not (%s))', probe_sql);
      else
        value_parts := array[]::text[];
        foreach value_text in array raw_values loop
          value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(match_cols) col);
        end loop;
        conjuncts := conjuncts || format('(not (%s) and not (%s))', keyword_hit, array_to_string(value_parts, ' or '));
      end if;

    elsif operator_key = 'boolean' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)', 'simple', boolean_expr, 'simple', value_text);
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');

    elsif operator_key = 'empty' then
      conjuncts := conjuncts || format('(btrim(%s) = %L)', candidate_expr, '');

    elsif operator_key = 'not_empty' then
      conjuncts := conjuncts || format('(btrim(%s) <> %L)', candidate_expr, '');

    elsif operator_key = 'number_ranges' then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        if value_text = 'unknown' then
          if field_key = '__employee_count' then
            value_parts := array_append(value_parts, '(c.employee_count_min is null and c.employee_count_max is null)');
          elsif field_key = '__founded_year' then
            value_parts := array_append(value_parts, '(c.founded_year is null)');
          elsif field_key = '__total_funding' then
            value_parts := array_append(value_parts, '(c.total_funding_amount is null)');
          end if;
          continue;
        end if;
        if value_text !~ '^[0-9]+:[0-9]*$' then continue; end if;
        minimum := split_part(value_text, ':', 1);
        maximum := case when value_text ~ '^[0-9]+:[0-9]+$' then split_part(value_text, ':', 2) else null end;
        if field_key = '__employee_count' then
          value_parts := value_parts || format(
            '(c.employee_count_min is not null and (%s) and (c.employee_count_max is null or c.employee_count_max >= %s))',
            case when maximum is null then 'true' else format('c.employee_count_min <= %s', maximum) end, minimum);
        elsif field_key = '__founded_year' then
          value_parts := value_parts || format('(c.founded_year is not null and c.founded_year >= %s and (%s))',
            minimum, case when maximum is null then 'true' else format('c.founded_year <= %s', maximum) end);
        elsif field_key = '__total_funding' then
          value_parts := value_parts || format('(c.total_funding_amount is not null and c.total_funding_amount >= %s::bigint and (%s))',
            minimum, case when maximum is null then 'true' else format('c.total_funding_amount <= %s::bigint', maximum) end);
        end if;
      end loop;
      if cardinality(value_parts) = 0 then
        conjuncts := array_append(conjuncts, 'false');
      else
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;

    else
      if probe_sql is not null then
        conjuncts := conjuncts || ('(' || probe_sql || ')');
      else
        value_parts := case when keyword_hit <> 'false' then array[keyword_hit] else array[]::text[] end;
        foreach value_text in array raw_values loop
          value_parts := value_parts || array(select format('%s ilike %L', col, '%' || value_text || '%') from unnest(raw_cols) col);
        end loop;
        conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      end if;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$_$;


ALTER FUNCTION public.company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean) OWNER TO postgres;

--
-- Name: company_filter_values_v1(text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_filter_values_v1(p_field text, p_search text DEFAULT ''::text, p_limit integer DEFAULT 50) RETURNS TABLE(value text, match_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $$
declare
  v_search text := btrim(coalesce(p_search, ''));
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_kind text;
  v_have boolean;
begin
  -- '__company_keywords' searches name + keywords (+ description) as one field,
  -- but the only sensible thing to SUGGEST for it is a keyword.
  v_kind := case
    when p_field in ('__keywords', '__company_keywords') then 'keywords'
    when p_field in ('__technologies', '__company_technologies') then 'technologies'
    else null
  end;

  if v_kind is not null then
    select exists (select 1 from public.company_value_suggestions where kind = v_kind) into v_have;
    if v_have then
      return query
        select s.value, s.company_count::bigint
        from public.company_value_suggestions s
        where s.kind = v_kind and (v_search = '' or s.value ilike '%' || v_search || '%')
        order by s.company_count desc, lower(s.value)
        limit v_limit;
      return;
    end if;

    return query
      select entry.val, count(*)::bigint
      from public.companies c
      cross join lateral unnest(case when v_kind = 'technologies' then c.technologies else c.keywords end) entry(val)
      where btrim(coalesce(entry.val, '')) <> '' and (v_search = '' or entry.val ilike '%' || v_search || '%')
      group by entry.val
      order by count(*) desc, lower(entry.val)
      limit v_limit;
    return;
  end if;

  if p_field not in ('__industry', '__company_industry', '__company_city', '__company_state',
                     '__company_country', '__company_location', '__total_funding',
                     '__company_total_funding', '__company', '__website') then
    return;
  end if;

  return query
    select picked.val, count(*)::bigint
    from public.companies c
    cross join lateral (
      select case p_field
        when '__industry' then c.industry
        when '__company_industry' then c.industry
        when '__company_city' then c.city
        when '__company_state' then c.state
        when '__company_country' then c.country
        when '__company_location' then coalesce(nullif(c.location, ''),
          concat_ws(', ', nullif(c.city, ''), nullif(c.state, ''), nullif(c.country, '')))
        when '__total_funding' then c.total_funding
        when '__company_total_funding' then c.total_funding
        when '__company' then c.name
        when '__website' then c.domain
        else '' end as val
    ) picked
    where btrim(coalesce(picked.val, '')) <> '' and (v_search = '' or picked.val ilike '%' || v_search || '%')
    group by picked.val
    order by count(*) desc, lower(picked.val)
    limit v_limit;
end;
$$;


ALTER FUNCTION public.company_filter_values_v1(p_field text, p_search text, p_limit integer) OWNER TO postgres;

--
-- Name: company_full_scan_filter_sql_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_full_scan_filter_sql_v1(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_complete text;
  v_probe text;
  v_fraction numeric;
  v_value_count integer;
  v_sample_rows integer;
  -- Counting or collecting every match has no early exit, so the OR chain only
  -- wins once the filter is very broad. Measured either side: at 65.1% of the
  -- table the probe won 32.2s to 37.3s, at 79.9% the chain won 6.9s to 12.7s.
  v_broad_fraction constant numeric := 0.72;
begin
  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is null then return null; end if;

  v_probe := public.company_probe_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_probe is null then return v_complete; end if;

  select coalesce(max(cardinality(v)), 0) into v_value_count
  from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) f
  cross join lateral (select array(select jsonb_array_elements_text(f.value->'values'))) s(v);

  -- Per-row sample cost grows with the value list, so bound the product rather
  -- than the row count.
  v_sample_rows := greatest(120, least(400, 60000 / greatest(v_value_count, 1)));

  begin
    -- Sampled, not estimated: EXPLAIN raises 0A000 in a non-volatile function,
    -- and the planner's estimate was wrong by 2.4x on exactly this shape.
    execute format(
      'select coalesce(avg(case when %s then 1.0 else 0.0 end), 1.0) from '
      || '(select * from public.companies tablesample system (0.05) repeatable (1) limit %s) c',
      v_complete, v_sample_rows) into v_fraction;
  exception when others then
    -- Choosing a shape is an optimisation, never a correctness input.
    return v_complete;
  end;

  return case when v_fraction < v_broad_fraction then v_probe else v_complete end;
end;
$$;


ALTER FUNCTION public.company_full_scan_filter_sql_v1(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: company_keyword_expr_sql_v1(jsonb, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
declare
  v_scopes jsonb := public.company_keyword_scopes_v1(p_scopes);
  v_parts text[] := array[]::text[];
begin
  if p_alias !~ '^[a-z_][a-z0-9_]*$' then
    raise exception 'unsafe company alias %', p_alias;
  end if;
  if v_scopes ? 'name' then
    v_parts := array_append(v_parts, format('nullif(%I.name, %L)', p_alias, ''));
  end if;
  if v_scopes ? 'keywords' then
    v_parts := array_append(v_parts, format('nullif(array_to_string(%I.keywords, %L), %L)', p_alias, ' | ', ''));
  end if;
  if v_scopes ? 'description' then
    v_parts := array_append(v_parts, format('nullif(%I.short_description, %L)', p_alias, ''));
  end if;
  if cardinality(v_parts) = 0 then
    return quote_literal('');
  end if;
  return format('concat_ws(%L, %s)', ' | ', array_to_string(v_parts, ', '));
end;
$_$;


ALTER FUNCTION public.company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text) OWNER TO postgres;

--
-- Name: company_keyword_scopes_v1(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_keyword_scopes_v1(p_scopes jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
  select case
    when jsonb_typeof(p_scopes) = 'array' and jsonb_array_length(p_scopes) > 0 then p_scopes
    else '["keywords"]'::jsonb
  end;
$$;


ALTER FUNCTION public.company_keyword_scopes_v1(p_scopes jsonb) OWNER TO postgres;

--
-- Name: company_keyword_text_expr_sql_v1(jsonb, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
declare
  v_scopes jsonb := public.company_keyword_scopes_v1(p_scopes);
  v_parts text[] := array[]::text[];
begin
  if p_alias !~ '^[a-z_][a-z0-9_]*$' then
    raise exception 'unsafe company alias %', p_alias;
  end if;
  if v_scopes ? 'name' then
    v_parts := array_append(v_parts, format('nullif(%I.name, %L)', p_alias, ''));
  end if;
  if v_scopes ? 'description' then
    v_parts := array_append(v_parts, format('nullif(%I.short_description, %L)', p_alias, ''));
  end if;
  if cardinality(v_parts) = 0 then
    return quote_literal('');
  end if;
  return format('concat_ws(%L, %s)', ' | ', array_to_string(v_parts, ', '));
end;
$_$;


ALTER FUNCTION public.company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: companies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.companies (
    id text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    normalized_name text DEFAULT ''::text NOT NULL,
    domain text DEFAULT ''::text NOT NULL,
    normalized_domain text DEFAULT ''::text NOT NULL,
    all_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    esp text DEFAULT ''::text NOT NULL,
    email_provider_type text DEFAULT 'Unknown'::text NOT NULL,
    mx_records text[] DEFAULT '{}'::text[] NOT NULL,
    mx_status text DEFAULT 'pending'::text NOT NULL,
    mx_checked_at timestamp with time zone,
    employee_count_min integer,
    employee_count_max integer,
    location text DEFAULT ''::text NOT NULL,
    city text DEFAULT ''::text NOT NULL,
    state text DEFAULT ''::text NOT NULL,
    country text DEFAULT ''::text NOT NULL,
    industry text DEFAULT ''::text NOT NULL,
    keywords text[] DEFAULT '{}'::text[] NOT NULL,
    short_description text DEFAULT ''::text NOT NULL,
    founded_year integer,
    technologies text[] DEFAULT '{}'::text[] NOT NULL,
    total_funding text DEFAULT ''::text NOT NULL,
    prospect_count integer DEFAULT 0 NOT NULL,
    client_count integer DEFAULT 0 NOT NULL,
    total_funding_amount bigint,
    CONSTRAINT companies_email_provider_type_check CHECK ((email_provider_type = ANY (ARRAY['SEG'::text, 'Mailbox provider'::text, 'Email relay'::text, 'Unknown'::text]))),
    CONSTRAINT companies_employee_count_range_check CHECK ((((employee_count_min IS NULL) OR (employee_count_min >= 0)) AND ((employee_count_max IS NULL) OR (employee_count_max >= 0)) AND ((employee_count_min IS NULL) OR (employee_count_max IS NULL) OR (employee_count_max >= employee_count_min)))),
    CONSTRAINT companies_founded_year_valid CHECK (((founded_year IS NULL) OR ((founded_year >= 1000) AND (founded_year <= 9999)))),
    CONSTRAINT companies_mx_status_check CHECK ((mx_status = ANY (ARRAY['pending'::text, 'resolved'::text, 'no_mx'::text, 'lookup_failed'::text])))
)
WITH (autovacuum_vacuum_scale_factor='0.05', autovacuum_vacuum_insert_scale_factor='0.05', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.companies OWNER TO postgres;

--
-- Name: company_matches_filters_v1(public.companies, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_matches_filters_v1(p_row public.companies, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $_$
  select (
    btrim(coalesce(p_search, '')) = ''
    or (p_row).name ilike '%' || btrim(p_search) || '%'
    or (p_row).domain ilike '%' || btrim(p_search) || '%'
  ) and not exists (
    select 1
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
    cross join lateral (
      select case
        when filter_item->>'field' = '__company_keywords' and jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end as selected_scopes
    ) scope
    cross join lateral (
      select coalesce(case filter_item->>'field'
        when '__company_keywords' then concat_ws(' | ',
          case when scope.selected_scopes ? 'name' then (p_row).name end,
          case when scope.selected_scopes ? 'description' then (p_row).short_description end)
        when '__company_icp_verified' then (select array_to_string(array_agg(v.client_id order by v.client_id), ' | ') from public.client_company_icp_validations v where v.company_id = (p_row).id)
        when '__company' then (p_row).name
        when '__website' then (p_row).domain
        when '__industry' then (p_row).industry
        when '__company_city' then (p_row).city
        when '__company_state' then (p_row).state
        when '__company_country' then (p_row).country
        when '__company_location' then coalesce(nullif((p_row).location, ''),
          concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, '')))
        when '__keywords' then array_to_string((p_row).keywords, ' | ')
        when '__short_description' then (p_row).short_description
        when '__founded_year' then (p_row).founded_year::text
        when '__technologies' then array_to_string((p_row).technologies, ' | ')
        when '__total_funding' then (p_row).total_funding
        else '' end, '') as candidate_value
    ) candidate
    cross join lateral (
      select
        filter_item->>'field' = '__company_keywords'
        and scope.selected_scopes ? 'keywords'
        and (p_row).keywords && (
          select coalesce(array_agg(value), array[]::text[])
          from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb))
        ) as keyword_hit,
        -- Boolean search keeps matching keywords as text. It is an expression the
        -- user wrote, not a value they picked, so narrowing it to exact array
        -- elements would remove capability rather than add precision.
        concat_ws(' | ',
          case when scope.selected_scopes ? 'name' then (p_row).name end,
          case when scope.selected_scopes ? 'keywords' then array_to_string((p_row).keywords, ' | ') end,
          case when scope.selected_scopes ? 'description' then (p_row).short_description end) as boolean_value
    ) kw
    where not case
      when filter_item->>'field' = '__company_tags' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.company_tag_links ctl
                  where ctl.company_id = (p_row).id
                    and ctl.tag_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__company_client_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.client_companies cc
                  where cc.company_id = (p_row).id
                    and cc.client_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__company_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).id = any (select value from jsonb_array_elements_text(filter_item->'values'))))
      )
      when filter_item->>'field' = '__company_coverage' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or case filter_item->'values'->>0
             when 'with' then coalesce((p_row).prospect_count, 0) > 0
             when 'without' then coalesce((p_row).prospect_count, 0) = 0
             else true
           end
      )
      else case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then kw.keyword_hit or exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
          or (filter_item->>'field' = '__keywords' and selected.value = any((p_row).keywords))
          or (filter_item->>'field' = '__technologies' and selected.value = any((p_row).technologies))
      )
      when 'not_equals' then not kw.keyword_hit and not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where lower(candidate.candidate_value) = lower(selected.value)
      )
      when 'not_contains' then not kw.keyword_hit and not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
      when 'boolean' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where to_tsvector('simple', kw.boolean_value) @@ to_tsquery('simple', selected.value)
      )
      when 'number_ranges' then exists (
        select 1
        from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        cross join lateral (
          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum,
            case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::bigint end as minimum_big,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::bigint end as maximum_big
        ) selected_range
        where (filter_item->>'field' = '__employee_count' and (
            (selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum))))
          or (filter_item->>'field' = '__total_funding' and (
            (selected.value = 'unknown' and (p_row).total_funding_amount is null)
            or (selected.value <> 'unknown' and (p_row).total_funding_amount is not null
              and (selected_range.minimum_big is null or (p_row).total_funding_amount >= selected_range.minimum_big)
              and (selected_range.maximum_big is null or (p_row).total_funding_amount <= selected_range.maximum_big))))
          or (filter_item->>'field' = '__founded_year' and (
            (selected.value = 'unknown' and (p_row).founded_year is null)
            or (selected.value <> 'unknown' and (p_row).founded_year is not null
              and (selected_range.minimum is null or (p_row).founded_year >= selected_range.minimum)
              and (selected_range.maximum is null or (p_row).founded_year <= selected_range.maximum))))
      )
      when 'empty' then btrim(candidate.candidate_value) = ''
      when 'not_empty' then btrim(candidate.candidate_value) <> ''
      else kw.keyword_hit or exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
    end end
  );
$_$;


ALTER FUNCTION public.company_matches_filters_v1(p_row public.companies, p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: company_matches_scope_v1(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_matches_scope_v1(p_company_id text, p_client_id text, p_company_scope jsonb) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  select coalesce(p_company_scope, '{}'::jsonb) = '{}'::jsonb or exists (
    select 1 from public.companies c
    where c.id = p_company_id
      and (btrim(coalesce(p_company_scope->>'search', '')) = '' or c.name ilike '%' || btrim(p_company_scope->>'search') || '%' or c.domain ilike '%' || btrim(p_company_scope->>'search') || '%')
      and (jsonb_array_length(coalesce(p_company_scope->'names', '[]'::jsonb)) = 0 or exists (
        select 1 from jsonb_array_elements_text(p_company_scope->'names') selected(value) where c.name ilike '%' || selected.value || '%'
      ))
      and (jsonb_array_length(coalesce(p_company_scope->'domains', '[]'::jsonb)) = 0 or exists (
        select 1 from jsonb_array_elements_text(p_company_scope->'domains') selected(value) where c.normalized_domain = selected.value
      ))
      and ((jsonb_array_length(coalesce(p_company_scope->'seniority', '[]'::jsonb)) = 0 and jsonb_array_length(coalesce(p_company_scope->'locations', '[]'::jsonb)) = 0) or exists (
        select 1 from public.prospect_index qualifier
        where qualifier.company_id = c.id
          and (p_client_id is null or qualifier.client_ids @> array[p_client_id])
          and (jsonb_array_length(coalesce(p_company_scope->'seniority', '[]'::jsonb)) = 0 or exists (
            select 1 from jsonb_array_elements_text(p_company_scope->'seniority') selected(value) where lower(qualifier.seniority) = lower(selected.value)
          ))
          and (jsonb_array_length(coalesce(p_company_scope->'locations', '[]'::jsonb)) = 0 or exists (
            select 1 from jsonb_array_elements_text(p_company_scope->'locations') selected(value)
            where concat_ws(', ', nullif(qualifier.city, ''), nullif(qualifier.state, ''), nullif(qualifier.country, '')) ilike '%' || selected.value || '%'
          ))
      ))
  );
$$;


ALTER FUNCTION public.company_matches_scope_v1(p_company_id text, p_client_id text, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: company_prefilter_sql(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_prefilter_sql(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $_$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  selected_scopes jsonb;
  scope_parts text[];
  value_parts text[];
  raw_values text[];
  value_text text;
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format(
      '(c.name ilike %1$L or c.domain ilike %1$L)',
      '%' || btrim(p_search) || '%'
    );
  end if;

  for filter_item in
    select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb))
  loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';
    if field_key = '__company_coverage' then
      if coalesce(filter_item->'values'->>0, '') = 'with' then
        conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) > 0)');
      elsif coalesce(filter_item->'values'->>0, '') = 'without' then
        conjuncts := array_append(conjuncts, '(coalesce(c.prospect_count, 0) = 0)');
      end if;
      continue;
    end if;

    -- companies_pkey. Only reached for contains/equals; the loop skipped every
    -- other operator above.
    if field_key = '__company_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(c.id = any (%L::text[]))', raw_values);
      end if;
      continue;
    end if;

    if field_key = '__company_tags' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format($t$(exists (select 1 from public.company_tag_links ctl
          where ctl.company_id = c.id and ctl.tag_id = any (%L::text[])))$t$, raw_values);
      end if;
      continue;
    end if;

    -- Served by idx_client_companies_company (company_id, client_id). Only
    -- reached for contains/equals; the loop skipped every other operator above.
    if field_key = '__company_client_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format($cc$(exists (select 1 from public.client_companies cc
          where cc.company_id = c.id and cc.client_id = any (%L::text[])))$cc$, raw_values);
      end if;
      continue;
    end if;


    raw_values := array[]::text[];
    for value_text in
      select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb))
    loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    if field_key = '__company_keywords' then
      selected_scopes := case
        when jsonb_typeof(filter_item->'scopes') = 'array'
          then case when jsonb_array_length(filter_item->'scopes') > 0
            then filter_item->'scopes' else '["name","keywords"]'::jsonb end
        else '["name","keywords"]'::jsonb
      end;
      scope_parts := array[]::text[];

      if selected_scopes ? 'keywords' then
        scope_parts := array_append(scope_parts, format('c.keywords && %L::text[]',
          public.keyword_tag_variants_v1(raw_values)));
      end if;
      foreach value_text in array raw_values loop
        if selected_scopes ? 'name' then
          scope_parts := array_append(scope_parts, format('c.name ilike %L', '%' || value_text || '%'));
        end if;
        if selected_scopes ? 'description' then
          scope_parts := array_append(scope_parts, format('c.short_description ilike %L', '%' || value_text || '%'));
        end if;
      end loop;

      if cardinality(scope_parts) > 0 then
        conjuncts := conjuncts || ('(' || array_to_string(scope_parts, ' or ') || ')');
      end if;
      continue;
    end if;

    column_expr := case field_key
      when '__company' then 'c.name'
      when '__website' then 'c.domain'
      when '__industry' then 'c.industry'
      when '__company_city' then 'c.city'
      when '__company_state' then 'c.state'
      when '__company_country' then 'c.country'
      when '__company_location' then 'c.location'
      when '__short_description' then 'c.short_description'
      when '__total_funding' then 'c.total_funding'
      when '__keywords' then 'array_to_string(c.keywords, '' | '')'
      when '__technologies' then 'array_to_string(c.technologies, '' | '')'
      else null
    end;
    if column_expr is null then continue; end if;

    if operator_key = 'equals' and field_key = '__keywords' then
      conjuncts := conjuncts || format('c.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      continue;
    end if;
    if operator_key = 'equals' and field_key = '__technologies' then
      conjuncts := conjuncts || format('c.technologies && %L::text[]', public.keyword_tag_variants_v1(raw_values));
      continue;
    end if;

    if operator_key = 'equals' and field_key = '__website' then
      conjuncts := conjuncts || format('c.normalized_domain = any (%L::text[])',
        array(select lower(value) from unnest(raw_values) value));
      continue;
    end if;

    if operator_key = 'equals' then
      conjuncts := conjuncts || format('lower(%s) = any (%L::text[])',
        column_expr, array(select lower(value) from unnest(raw_values) value));
    elsif cardinality(raw_values) <= bulk_or_threshold then
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      null;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$_$;


ALTER FUNCTION public.company_prefilter_sql(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: company_probe_columns_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_probe_columns_v1(p_field text, p_scopes jsonb) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select case
    when p_field = '__company_keywords' then
      -- Substring scopes only. The keywords scope is an array overlap and is
      -- carried as its own branch.
      (case when coalesce(p_scopes, '["name","keywords"]'::jsonb) ? 'name' then array['name'] else array[]::text[] end)
      || (case when coalesce(p_scopes, '["name","keywords"]'::jsonb) ? 'description' then array['short_description'] else array[]::text[] end)
    -- Only columns carrying a trigram index of their own. __company_location is
    -- deliberately absent: idx_companies_location covers c.location, not the
    -- coalesce over city/state/country that the filter actually tests. So are
    -- __keywords and __technologies, whose filters test array_to_string(...).
    -- Probing an unindexed column turns one sequential scan into several.
    when p_field = '__company' then array['name']
    when p_field = '__website' then array['domain']
    when p_field = '__industry' then array['industry']
    when p_field = '__company_city' then array['city']
    when p_field = '__company_state' then array['state']
    when p_field = '__company_country' then array['country']
    when p_field = '__short_description' then array['short_description']
    when p_field = '__total_funding' then array['total_funding']
    else array[]::text[]
  end;
$$;


ALTER FUNCTION public.company_probe_columns_v1(p_field text, p_scopes jsonb) OWNER TO postgres;

--
-- Name: company_probe_filter_sql_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_probe_filter_sql_v1(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  filter_item jsonb;
  raw_values text[];
  value_text text;
  scopes jsonb;
  probeable boolean := false;
begin
  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    scopes := case
      when filter_item->>'field' <> '__company_keywords' then null
      when jsonb_typeof(filter_item->'scopes') = 'array'
        then case when jsonb_array_length(filter_item->'scopes') > 0
          then filter_item->'scopes' else '["name","keywords"]'::jsonb end
      else '["name","keywords"]'::jsonb
    end;
    if public.company_filter_is_probed_v1(filter_item->>'field', scopes,
         coalesce(filter_item->>'operator', 'contains'), raw_values) then
      probeable := true;
      exit;
    end if;
  end loop;

  if not probeable then return null; end if;
  return public.company_filter_sql_v3(p_search, p_filters, true);
end;
$$;


ALTER FUNCTION public.company_probe_filter_sql_v1(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: company_scope_ids_v2(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb) RETURNS TABLE(company_id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    AS $_$
DECLARE
  v_row prospect_results.result_sets%rowtype;
  v_limit integer := CASE WHEN coalesce(p_company_scope->>'limit','') ~ '^[0-9]+$'
    THEN greatest(1000,least((p_company_scope->>'limit')::bigint,250000))::integer ELSE 250000 END;
BEGIN
  IF NOT (p_company_scope ? '_prepared_set_id') THEN
    RETURN QUERY SELECT * FROM prospect_results.uncached_company_scope_ids_v1(p_client_id,p_company_scope);
    RETURN;
  END IF;
  -- These two fields are added by the authorized API, never accepted by
  -- parseCompanyScope. Recheck ownership and content inside the database too.
  SELECT * INTO v_row FROM prospect_results.result_sets s
    WHERE s.id=(p_company_scope->>'_prepared_set_id')::uuid
      AND s.owner_id=p_company_scope->>'_prepared_owner'
      AND s.entity_type='company' AND s.client_scope='' AND s.company_scope='{}'::jsonb
      AND s.content_hash LIKE 'company-pivot-v1:%'
      AND s.search=coalesce(p_company_scope->>'search','')
      AND s.filters=coalesce(p_company_scope->'filters','[]'::jsonb)
      AND s.status='ready' AND s.expires_at>now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prepared company search is unavailable' USING errcode='P0002';
  END IF;
  IF v_row.version_vector IS DISTINCT FROM public.data_versions_v1(array['company']) THEN
    RAISE EXCEPTION 'Company data changed while preparing this search' USING errcode='40001';
  END IF;
  RETURN QUERY SELECT i.entity_id FROM prospect_results.result_set_items i
    WHERE i.result_set_id=v_row.id ORDER BY i.entity_id LIMIT v_limit;
END;
$_$;


ALTER FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: company_scoped_raw(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_scoped_raw(p_raw jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
  select coalesce(jsonb_object_agg(entry.key, entry.value), '{}'::jsonb)
  from jsonb_each_text(coalesce(p_raw, '{}'::jsonb)) entry(key, value)
  where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') like 'company%'
     or regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') in (
       'industry', 'website', 'domain', 'employees', 'employeecount', 'numberofemployees',
       'headcount', 'shortdescription', 'description', 'foundedyear', 'founded',
       'technologies', 'techstack', 'totalfunding', 'funding', 'annualrevenue', 'revenue'
     );
$$;


ALTER FUNCTION public.company_scoped_raw(p_raw jsonb) OWNER TO postgres;

--
-- Name: company_substring_probe_sql_v1(text[], text[], text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_substring_probe_sql_v1(p_columns text[], p_values text[], p_keyword_values text[] DEFAULT NULL::text[]) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public'
    AS $_$
declare
  branches text[] := array[]::text[];
  column_name text;
begin
  if cardinality(coalesce(p_values, array[]::text[])) = 0 then return null; end if;

  if cardinality(coalesce(p_keyword_values, array[]::text[])) > 0 then
    -- Tags are matched exactly, so the case the user typed must not decide it.
    branches := array_append(branches, format(
      'select p.id from public.companies p where p.keywords && %L::text[]',
      public.keyword_tag_variants_v1(p_keyword_values)));
  end if;

  foreach column_name in array coalesce(p_columns, array[]::text[]) loop
    branches := array_append(branches, format(
      $b$select p.id from unnest(%L::text[]) needle join public.companies p on p.%I ilike '%%' || needle || '%%'$b$,
      p_values, column_name));
  end loop;

  if cardinality(branches) = 0 then return null; end if;
  return 'c.id in (' || array_to_string(branches, ' union ') || ')';
end;
$_$;


ALTER FUNCTION public.company_substring_probe_sql_v1(p_columns text[], p_values text[], p_keyword_values text[]) OWNER TO postgres;

--
-- Name: company_technologies_text_v1(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.company_technologies_text_v1(p_technologies text[]) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ select array_to_string(p_technologies, ' | ') $$;


ALTER FUNCTION public.company_technologies_text_v1(p_technologies text[]) OWNER TO postgres;

--
-- Name: complete_company_import_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.complete_company_import_v1(p_import_id text) RETURNS TABLE(processed_rows integer, added_count integer, updated_count integer, skipped_count integer, indexed_rows integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  result_processed integer;
  result_added integer;
  result_updated integer;
  result_skipped integer;
  result_queued integer := 0;
begin
  -- The status predicate keeps a late chunk replay and a completion from
  -- interleaving into a wrong state; import_company_batch_v3 takes the same row
  -- for update and refuses unless it is still 'processing'.
  update public.company_imports ci
  set status = 'completed', completed_at = coalesce(ci.completed_at, now())
  where ci.id = p_import_id and ci.status = 'processing'
  returning ci.processed_rows, ci.added_count, ci.updated_count, ci.skipped_count
  into result_processed, result_added, result_updated, result_skipped;

  if not found then
    -- Already completed - by an earlier partial attempt, or by
    -- expire_abandoned_company_imports_v1. Completion is idempotent now:
    -- re-calling it has to be how a half-finished import is finished, so it
    -- must not raise. P0002 is reserved for an id that genuinely does not exist.
    select ci.processed_rows, ci.added_count, ci.updated_count, ci.skipped_count
      into result_processed, result_added, result_updated, result_skipped
      from public.company_imports ci
     where ci.id = p_import_id;
    if not found then
      raise exception 'Company import not found' using errcode = 'P0002';
    end if;
  end if;

  -- Queue the first slice inline so the common import needs no follow-up at
  -- all. The caller keeps calling queue_company_import_reindex_v1 for the rest.
  --
  -- The subtransaction is the point: the import is already decided above, and
  -- nothing about queueing may take that back. That was the original bug, in
  -- miniature - so it is handled rather than trusted.
  begin
    select q.queued into result_queued
      from public.queue_company_import_reindex_v1(p_import_id, '', 25000) q;
  exception when others then
    result_queued := 0;
  end;

  return query select result_processed, result_added, result_updated,
    result_skipped, result_queued;
end;
$$;


ALTER FUNCTION public.complete_company_import_v1(p_import_id text) OWNER TO postgres;

--
-- Name: consume_blocklist_share_rate_v1(uuid, text, integer, interval); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.consume_blocklist_share_rate_v1(p_share_id uuid, p_requester_hash text, p_limit integer DEFAULT 20, p_window interval DEFAULT '01:00:00'::interval) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '5s'
    AS $$
declare
  v_attempts integer;
begin
  insert into public.client_blocklist_share_limits
    (share_id, requester_hash, window_started_at, attempts)
  values (p_share_id, left(coalesce(p_requester_hash, ''), 128), now(), 1)
  on conflict (share_id, requester_hash) do update set
    window_started_at = case
      when client_blocklist_share_limits.window_started_at <= now() - p_window then now()
      else client_blocklist_share_limits.window_started_at
    end,
    attempts = case
      when client_blocklist_share_limits.window_started_at <= now() - p_window then 1
      else client_blocklist_share_limits.attempts + 1
    end
  returning attempts into v_attempts;
  return v_attempts <= greatest(1, least(coalesce(p_limit, 20), 100));
end;
$$;


ALTER FUNCTION public.consume_blocklist_share_rate_v1(p_share_id uuid, p_requester_hash text, p_limit integer, p_window interval) OWNER TO postgres;

--
-- Name: create_filter_set_v1(text, text, text, text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_filter_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[]) RETURNS TABLE(set_id uuid, content_hash text, value_count integer, reused boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_filters'
    SET statement_timeout TO '30s'
    AS $$
  select * from prospect_filters.create_set_v1(p_owner_id, p_entity_type, p_client_scope, p_field, p_values);
$$;


ALTER FUNCTION public.create_filter_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[]) OWNER TO postgres;

--
-- Name: dashboard_snapshot_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.dashboard_snapshot_v1(p_key text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '5s'
    AS $$
  select jsonb_build_object(
    'payload', s.payload,
    'computedAt', s.computed_at,
    -- Honest rather than reassuring: says whether anything has been written
    -- since this was computed, so the caller can show it as of a time.
    'current', s.data_version = public.data_versions_v1(array['prospect', 'company'])
  )
  from public.dashboard_snapshot s
  where s.key = p_key;
$$;


ALTER FUNCTION public.dashboard_snapshot_v1(p_key text) OWNER TO postgres;

--
-- Name: dashboard_workspace(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.dashboard_workspace() RETURNS TABLE(result jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_versions jsonb := public.data_versions_v1(array['prospect', 'company']);
  v_counts jsonb;
begin
  select s.payload into v_counts
  from public.dashboard_snapshot s
  where s.key = 'workspaceCounts' and s.data_version = v_versions;

  if v_counts is null then
    v_counts := jsonb_build_object(
      'prospects', (select count(*) from public.prospect_index),
      'companies', (select count(*) from public.companies));
    insert into public.dashboard_snapshot (key, payload, data_version, computed_at)
    values ('workspaceCounts', v_counts, v_versions, now())
    on conflict (key) do update
      set payload = excluded.payload,
          data_version = excluded.data_version,
          computed_at = excluded.computed_at;
  end if;

  return query
  select jsonb_build_object(
    'stats', jsonb_build_object(
      'prospects', (v_counts->>'prospects')::bigint,
      'companies', (v_counts->>'companies')::bigint,
      'clients', (select count(*) from public.clients),
      'lists', (select count(*) from public.lists),
      'rowsImported', (select coalesce(sum(processed_rows), 0) from public.imports),
      'duplicatesDetected', (select coalesce(sum(duplicates_linked), 0) from public.imports)
    ),
    'recentImports', coalesce((
      select jsonb_agg(to_jsonb(recent) order by recent.created_at desc)
      from (
        select *
        from (
          select i.id, 'prospects'::text as kind, i.file_name, i.data_source, i.status,
            i.processed_rows, i.unique_added, i.duplicates_linked, i.created_at,
            c.name as client_name, l.name as list_name,
            0::integer as added_count, 0::integer as updated_count, 0::integer as skipped_count
          from public.imports i
          left join public.clients c on c.id = i.client_id
          left join public.lists l on l.id = i.list_id
          where i.status = 'completed'

          union all

          select ci.id, 'companies'::text as kind, ci.file_name, ci.data_source, ci.status,
            ci.processed_rows, 0::integer as unique_added, 0::integer as duplicates_linked,
            ci.created_at, null::text as client_name, null::text as list_name,
            ci.added_count, ci.updated_count, ci.skipped_count
          from public.company_imports ci
          where ci.status = 'completed'
        ) all_imports
        order by created_at desc
        limit 6
      ) recent
    ), '[]'::jsonb)
  );
end;
$$;


ALTER FUNCTION public.dashboard_workspace() OWNER TO postgres;

--
-- Name: data_quality_overview(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.data_quality_overview() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '90s'
    AS $$
  select jsonb_build_object(
    'total', count(*),
    'missingEmail', count(*) filter (where trim(coalesce(p.work_email, '')) = '' and trim(coalesce(p.personal_email, '')) = ''),
    'missingTitle', count(*) filter (where trim(coalesce(p.title, '')) = ''),
    'missingLinkedin', count(*) filter (where trim(coalesce(p.linkedin_url, '')) = ''),
    'missingCompany', count(*) filter (where btrim(coalesce(c.name, '')) = ''),
    'missingDomain', count(*) filter (where trim(coalesce(c.domain, '')) = ''),
    'missingEmployees', count(*) filter (where c.employee_count_min is null and c.employee_count_max is null),
    'missingCompanyKeywords', count(*) filter (where btrim(coalesce(array_to_string(c.keywords, ' | '), '')) = ''),
    'missingCompanyDescription', count(*) filter (where btrim(coalesce(c.short_description, '')) = ''),
    'staleRecords', count(*) filter (where p.updated_at < now() - interval '180 days'),
    'companiesTotal', (select count(*) from public.companies),
    'companiesMissingDomain', (select count(*) from public.companies co where btrim(coalesce(co.domain, '')) = ''),
    'companiesMissingEmployees', (select count(*) from public.companies co where co.employee_count_min is null and co.employee_count_max is null),
    'companiesMissingKeywords', (select count(*) from public.companies co where btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''),
    'companiesMissingDescription', (select count(*) from public.companies co where btrim(coalesce(co.short_description, '')) = ''),
    'potentialDuplicateGroups', (
      select count(*) from (
        select lower(trim(p2.full_name)), coalesce(p2.company_id, '')
        from public.prospects p2 where trim(p2.full_name) <> '' and p2.company_id is not null
        group by lower(trim(p2.full_name)), p2.company_id having count(*) > 1
      ) duplicate_groups
    )
  )
  from public.prospects p left join public.companies c on c.id = p.company_id;
$$;


ALTER FUNCTION public.data_quality_overview() OWNER TO postgres;

--
-- Name: data_versions_v1(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.data_versions_v1(p_entities text[] DEFAULT ARRAY['prospect'::text, 'company'::text]) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select coalesce(jsonb_object_agg(requested.entity, requested.version), '{}'::jsonb)
  from (
    select 'prospect' as entity,
      coalesce(pg_sequence_last_value('public.data_version_prospect'::regclass), 0) as version
    where 'prospect' = any(coalesce(p_entities, array[]::text[]))
    union all
    select 'company',
      coalesce(pg_sequence_last_value('public.data_version_company'::regclass), 0)
    where 'company' = any(coalesce(p_entities, array[]::text[]))
  ) requested;
$$;


ALTER FUNCTION public.data_versions_v1(p_entities text[]) OWNER TO postgres;

--
-- Name: delete_client_and_reindex_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_client_and_reindex_v1(p_client_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  select coalesce(array_agg(distinct lm.prospect_id), array[]::text[]) into v_ids
  from public.list_memberships lm
  join public.lists l on l.id = lm.list_id
  where l.client_id = p_client_id and lm.prospect_id is not null;

  v_result := public.delete_client_with_cleanup(p_client_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.delete_client_and_reindex_v1(p_client_id text) OWNER TO postgres;

--
-- Name: delete_client_with_cleanup(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_client_with_cleanup(p_client_id text, p_delete_orphans boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  client_name_value text;
  list_count integer := 0;
  import_count integer := 0;
  membership_count integer := 0;
begin
  select c.name into client_name_value
  from public.clients c
  where c.id = p_client_id;

  if not found then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  select count(lm.prospect_id)::integer into membership_count
  from public.lists l
  left join public.list_memberships lm on lm.list_id = l.id
  where l.client_id = p_client_id;

  select count(*)::integer into list_count
  from public.lists l
  where l.client_id = p_client_id;

  select count(*)::integer into import_count
  from public.imports i
  where i.client_id = p_client_id;

  -- Cascades to lists, imports, list_memberships and list_rows. Never to prospects.
  delete from public.clients where id = p_client_id;

  return jsonb_build_object(
    'kind', 'client',
    'name', client_name_value,
    'clientsDeleted', 1,
    'listsDeleted', list_count,
    'importsDeleted', import_count,
    'membershipsDeleted', membership_count,
    'orphanedProspectsDeleted', 0,
    'orphanedCompaniesDeleted', 0
  );
end;
$$;


ALTER FUNCTION public.delete_client_with_cleanup(p_client_id text, p_delete_orphans boolean) OWNER TO postgres;

--
-- Name: delete_companies_by_ids_v1(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_companies_by_ids_v1(p_ids text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  affected_prospects text[];
  deleted integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;
  select coalesce(array_agg(p.id), '{}'::text[]) into affected_prospects
  from public.prospects p where p.company_id = any(p_ids);
  delete from public.companies where id = any(p_ids);
  get diagnostics deleted = row_count;
  perform public.reindex_prospects(affected_prospects);
  return deleted;
end;
$$;


ALTER FUNCTION public.delete_companies_by_ids_v1(p_ids text[]) OWNER TO postgres;

--
-- Name: delete_companies_matching_v1(text, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_companies_matching_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_excluded_ids text[] DEFAULT '{}'::text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '300s'
    AS $_$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_sql text;
  target_ids text[];
  affected_prospects text[];
  deleted integer;
begin
  v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || coalesce(public.company_filter_sql_v2(p_search, coalesce(p_filters, '[]'::jsonb)), format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));

  v_sql := format($q$
    select coalesce(array_agg(c.id), '{}'::text[])
    from public.companies c
    where (%s) and not (c.id = any($1))
  $q$, v_match_clause);

  execute v_sql using coalesce(p_excluded_ids, '{}'::text[]) into target_ids;
  if target_ids is null or array_length(target_ids, 1) is null then return 0; end if;

  select coalesce(array_agg(p.id), '{}'::text[]) into affected_prospects
  from public.prospects p where p.company_id = any(target_ids);

  delete from public.companies where id = any(target_ids);
  get diagnostics deleted = row_count;
  perform public.reindex_prospects(affected_prospects);
  return deleted;
end;
$_$;


ALTER FUNCTION public.delete_companies_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]) OWNER TO postgres;

--
-- Name: delete_import_and_reindex_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_import_and_reindex_v1(p_import_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  select coalesce(array_agg(distinct lr.prospect_id), array[]::text[]) into v_ids
  from public.list_rows lr
  where lr.import_id = p_import_id and lr.prospect_id is not null;

  v_result := public.delete_import_with_cleanup(p_import_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.delete_import_and_reindex_v1(p_import_id text) OWNER TO postgres;

--
-- Name: delete_import_with_cleanup(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_import_with_cleanup(p_import_id text, p_delete_orphans boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  import_name_value text;
  list_id_value text;
  membership_count integer := 0;
  list_deleted integer := 0;
begin
  select i.file_name, i.list_id into import_name_value, list_id_value
  from public.imports i
  where i.id = p_import_id;

  if not found then
    raise exception 'Import not found.' using errcode = 'P0002';
  end if;

  select count(*)::integer into membership_count
  from public.list_memberships lm
  where lm.import_id = p_import_id;

  delete from public.list_memberships where import_id = p_import_id;
  delete from public.imports where id = p_import_id;

  -- An emptied list is removed too; its prospects stay in the People database.
  if not exists (select 1 from public.imports i where i.list_id = list_id_value)
    and not exists (select 1 from public.list_memberships lm where lm.list_id = list_id_value) then
    delete from public.lists where id = list_id_value;
    get diagnostics list_deleted = row_count;
  end if;

  return jsonb_build_object(
    'kind', 'import',
    'name', import_name_value,
    'importsDeleted', 1,
    'listsDeleted', list_deleted,
    'membershipsDeleted', membership_count,
    'orphanedProspectsDeleted', 0,
    'orphanedCompaniesDeleted', 0
  );
end;
$$;


ALTER FUNCTION public.delete_import_with_cleanup(p_import_id text, p_delete_orphans boolean) OWNER TO postgres;

--
-- Name: delete_list_and_reindex_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_list_and_reindex_v1(p_list_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_result jsonb;
  v_reindex record;
begin
  select coalesce(array_agg(distinct lm.prospect_id), array[]::text[]) into v_ids
  from public.list_memberships lm
  where lm.list_id = p_list_id and lm.prospect_id is not null;

  v_result := public.delete_list_with_cleanup(p_list_id, false);
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  return v_result || jsonb_build_object('reindexed', v_reindex.reindexed, 'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.delete_list_and_reindex_v1(p_list_id text) OWNER TO postgres;

--
-- Name: delete_list_with_cleanup(text, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_list_with_cleanup(p_list_id text, p_delete_orphans boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  list_name_value text;
  membership_count integer := 0;
  import_count integer := 0;
begin
  select l.name into list_name_value
  from public.lists l
  where l.id = p_list_id;

  if not found then
    raise exception 'List not found.' using errcode = 'P0002';
  end if;

  select count(lm.prospect_id)::integer into membership_count
  from public.list_memberships lm
  where lm.list_id = p_list_id;

  select count(*)::integer into import_count
  from public.imports i
  where i.list_id = p_list_id;

  -- Cascades to imports, list_memberships and list_rows. Never to prospects.
  delete from public.lists where id = p_list_id;

  return jsonb_build_object(
    'kind', 'list',
    'name', list_name_value,
    'listsDeleted', 1,
    'importsDeleted', import_count,
    'membershipsDeleted', membership_count,
    'orphanedProspectsDeleted', 0,
    'orphanedCompaniesDeleted', 0
  );
end;
$$;


ALTER FUNCTION public.delete_list_with_cleanup(p_list_id text, p_delete_orphans boolean) OWNER TO postgres;

--
-- Name: delete_prospects_matching_v1(text, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_prospects_matching_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_excluded_ids text[] DEFAULT '{}'::text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_sql text;
  v_deleted integer;
begin
  v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || coalesce(public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb)), format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));

  v_sql := format($q$
    delete from public.prospects p
    where p.id in (select pi.id from public.prospect_index pi where %s)
      and not (p.id = any($1))
  $q$, v_match_clause);

  execute v_sql using coalesce(p_excluded_ids, '{}'::text[]);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$_$;


ALTER FUNCTION public.delete_prospects_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]) OWNER TO postgres;

--
-- Name: delete_prospects_matching_v2(text, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.delete_prospects_matching_v2(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_excluded_ids text[] DEFAULT NULL::text[]) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare v_deleted bigint;
begin
  if not exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company'
  ) then
    return public.delete_prospects_matching_v1(p_search, p_filters, p_excluded_ids);
  end if;
  with doomed as materialized (
    select candidate.prospect_id
    from public.prospect_capped_candidate_ids_v1(p_search, p_filters, null, '{}'::jsonb) candidate
    where not (candidate.prospect_id = any(coalesce(p_excluded_ids, array[]::text[])))
  ), deleted as (
    delete from public.prospects p using doomed
    where p.id = doomed.prospect_id
    returning p.id
  )
  select count(*)::bigint into v_deleted from deleted;
  return v_deleted;
end;
$$;


ALTER FUNCTION public.delete_prospects_matching_v2(p_search text, p_filters jsonb, p_excluded_ids text[]) OWNER TO postgres;

--
-- Name: divert_blocked_client_company_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.divert_blocked_client_company_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_reason text;
begin
  v_reason := public.client_company_block_reason_v1(new.client_id, new.company_id);
  if v_reason is null then
    return new;
  end if;
  insert into public.client_companies_blocked (client_id, company_id, added_at, added_by, blocked_reason)
  values (new.client_id, new.company_id, coalesce(new.added_at, now()), coalesce(new.added_by, ''), v_reason)
  on conflict (client_id, company_id) do nothing;
  return null;
end;
$$;


ALTER FUNCTION public.divert_blocked_client_company_v1() OWNER TO postgres;

--
-- Name: drain_reindex_backlog(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.drain_reindex_backlog(p_limit integer DEFAULT 2000) RETURNS TABLE(processed integer, remaining bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_ids text[];
  v_done integer := 0;
begin
  select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
  from (
    select prospect_id from public.reindex_backlog
    order by enqueued_at
    limit greatest(1, least(coalesce(p_limit, 2000), 10000))
    for update skip locked
  ) batch;

  if cardinality(v_ids) = 0 then
    processed := 0;
    remaining := 0;
    return next;
    return;
  end if;

  begin
    v_done := public.reindex_prospects(v_ids);
    delete from public.reindex_backlog where prospect_id = any(v_ids);
  exception when others then
    -- Leave the rows queued, record why, and let the next drain retry them.
    update public.reindex_backlog set
      attempts = attempts + 1,
      last_attempt_at = now(),
      last_error = left(sqlerrm, 500)
    where prospect_id = any(v_ids);
    v_done := 0;
  end;

  processed := v_done;
  select count(*) into remaining from public.reindex_backlog;
  return next;
end;
$$;


ALTER FUNCTION public.drain_reindex_backlog(p_limit integer) OWNER TO postgres;

--
-- Name: enforce_client_blocklist_reason_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enforce_client_blocklist_reason_v1() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  -- Historical free-text reasons remain readable and removable. Only a new
  -- value, or a reason change, must use the current product vocabulary.
  if (tg_op = 'INSERT' or new.reason is distinct from old.reason)
     and new.reason not in ('Client Provided', 'ICP Invalid', 'Campaign Reply') then
    raise exception 'Choose Client Provided, ICP Invalid, or Campaign Reply.' using errcode = '22023';
  end if;
  return new;
end;
$$;


ALTER FUNCTION public.enforce_client_blocklist_reason_v1() OWNER TO postgres;

--
-- Name: enqueue_blocklist_share_submission_v1(text, text, uuid, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enqueue_blocklist_share_submission_v1(p_token_hash text, p_requester_hash text, p_request_key uuid, p_domains text[], p_emails text[], p_reason text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '10s'
    AS $$
declare v_share public.client_blocklist_shares%rowtype; v_id uuid;
begin
  select * into v_share from public.client_blocklist_shares
  where token_hash = p_token_hash and revoked_at is null
    and (expires_at is null or expires_at > now()) for update;
  if not found then raise exception 'Share unavailable' using errcode = 'P0002'; end if;
  select id into v_id from public.client_blocklist_share_submissions
    where share_id = v_share.id and request_key = p_request_key;
  if v_id is not null then return v_id; end if;
  if p_reason not in ('Client Provided', 'ICP Invalid', 'Campaign Reply') then
    raise exception 'Invalid reason' using errcode = '22023';
  end if;
  if cardinality(coalesce(p_domains, array[]::text[])) + cardinality(coalesce(p_emails, array[]::text[])) > 200 then
    raise exception 'Too many entries' using errcode = '22023';
  end if;
  if not public.consume_blocklist_share_rate_v1(v_share.id, 'requester:' || p_requester_hash, 20, interval '1 hour')
     or not public.consume_blocklist_share_rate_v1(v_share.id, 'global', 200, interval '1 hour') then
    raise exception 'Rate limit' using errcode = 'P0003';
  end if;
  insert into public.client_blocklist_share_submissions
    (share_id, client_id, request_key, domains, emails, reason)
  values (v_share.id, v_share.client_id, p_request_key,
    coalesce(p_domains, array[]::text[]), coalesce(p_emails, array[]::text[]), p_reason)
  returning id into v_id;
  update public.client_blocklist_shares set last_submitted_at = now() where id = v_share.id;
  return v_id;
end;
$$;


ALTER FUNCTION public.enqueue_blocklist_share_submission_v1(p_token_hash text, p_requester_hash text, p_request_key uuid, p_domains text[], p_emails text[], p_reason text) OWNER TO postgres;

--
-- Name: enqueue_integration_job_v1(text, uuid, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enqueue_integration_job_v1(p_actor text, p_job uuid, p_allow_active boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare c public.integration_connections%rowtype; j prospect_integrations.jobs%rowtype;
begin
  select * into c from public.integration_connections where provider='smartlead' for share;
  select * into j from prospect_integrations.jobs where id=p_job and actor=p_actor for update;
  if not found then return false; end if;
  if j.status in ('queued','running','completed') then return true; end if;
  if j.status<>'draft' or j.mode<>'direct' or j.expires_at<=now() or j.preview_summary is null
    or not c.connected or j.connection_generation is distinct from c.generation then return false; end if;
  perform 1 from prospect_integrations.client_campaigns where client_id=j.client_id and campaign_id=j.campaign_id and enabled and generation=c.generation for share;
  if not found then return false; end if;
  update prospect_integrations.jobs set status='queued',allow_active=coalesce(p_allow_active,false) where id=p_job;
  return true;
end;
$$;


ALTER FUNCTION public.enqueue_integration_job_v1(p_actor text, p_job uuid, p_allow_active boolean) OWNER TO postgres;

--
-- Name: enqueue_operation_v1(text, uuid, text, text, text, text, jsonb, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enqueue_operation_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb DEFAULT '{}'::jsonb, p_excluded_ids text[] DEFAULT ARRAY[]::text[]) RETURNS TABLE(job_id uuid, status text, total_items bigint, applied_items bigint, result jsonb, reused boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '15s'
    AS $$
  select * from prospect_operations.enqueue_v1(p_actor, p_request_id, p_action, p_entity_type,
    p_client_scope, p_content_hash, p_version_vector, p_payload, p_excluded_ids);
$$;


ALTER FUNCTION public.enqueue_operation_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[]) OWNER TO postgres;

--
-- Name: enqueue_reindex(text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enqueue_reindex(p_ids text[], p_error text DEFAULT ''::text) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  insert into public.reindex_backlog (prospect_id, last_error)
  select distinct id, coalesce(left(p_error, 500), '')
  from unnest(coalesce(p_ids, array[]::text[])) as id
  where id is not null and id <> ''
  on conflict (prospect_id) do update set
    enqueued_at = least(public.reindex_backlog.enqueued_at, now()),
    last_error = coalesce(left(excluded.last_error, 500), '')
  returning 1;
$$;


ALTER FUNCTION public.enqueue_reindex(p_ids text[], p_error text) OWNER TO postgres;

--
-- Name: enrich_from_company_v1(text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enrich_from_company_v1(p_company_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_updated integer := 0;
  v_ids text[];
begin
  with sourced as (
    select
      c.id as company_id,
      max(nullif(p.city, '')) as city,
      max(nullif(p.state, '')) as state,
      max(nullif(p.country, '')) as country,
      max(nullif(p.location, '')) as location
    from public.companies c
    join public.prospects p on p.company_id = c.id
    where c.normalized_domain <> ''
      and (p_company_ids is null or c.id = any(p_company_ids))
    group by c.id
  ), applied as (
    update public.companies c set
      city = case when c.city = '' then coalesce(sourced.city, '') else c.city end,
      state = case when c.state = '' then coalesce(sourced.state, '') else c.state end,
      country = case when c.country = '' then coalesce(sourced.country, '') else c.country end,
      location = case when c.location = '' then coalesce(sourced.location, '') else c.location end,
      all_data = c.all_data || jsonb_build_object(
        '_enriched_from', 'company_records', '_enriched_at', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSZ')),
      updated_at = now()
    from sourced
    where c.id = sourced.company_id
      and (
        (c.city = '' and sourced.city is not null)
        or (c.state = '' and sourced.state is not null)
        or (c.country = '' and sourced.country is not null)
        or (c.location = '' and sourced.location is not null)
      )
    returning c.id
  )
  select count(*)::integer, coalesce(array_agg(id), array[]::text[]) into v_updated, v_ids from applied;

  if cardinality(v_ids) > 0 then
    perform public.reindex_scope_v1(p_company_ids => v_ids);
  end if;

  perform public.record_operation('enrich_from_company', null, p_actor,
    format('Filled company gaps on %s companies', v_updated), v_updated, array[]::text[]);

  return jsonb_build_object('companies', v_updated);
end;
$$;


ALTER FUNCTION public.enrich_from_company_v1(p_company_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: enrichment_preview_v1(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enrichment_preview_v1(p_limit integer DEFAULT 25) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
  with candidates as (
    select
      c.id as company_id,
      c.name as company_name,
      c.domain,
      -- The best available value for each company field, taken from whichever
      -- of this company's own records actually has one.
      nullif(c.industry, '') as industry,
      max(nullif(p.city, '')) filter (where c.city = '') as fill_city,
      max(nullif(p.state, '')) filter (where c.state = '') as fill_state,
      max(nullif(p.country, '')) filter (where c.country = '') as fill_country,
      max(nullif(p.location, '')) filter (where c.location = '') as fill_location
    from public.companies c
    join public.prospects p on p.company_id = c.id
    where c.normalized_domain <> ''
    group by c.id
  ), fillable as (
    select company_id, company_name, domain,
      (case when fill_city is not null then 1 else 0 end
       + case when fill_state is not null then 1 else 0 end
       + case when fill_country is not null then 1 else 0 end
       + case when fill_location is not null then 1 else 0 end) as fields
    from candidates
  )
  select jsonb_build_object(
    'companies', (select count(*) from fillable where fields > 0),
    'fields', (select coalesce(sum(fields), 0) from fillable where fields > 0),
    'sample', coalesce((
      select jsonb_agg(jsonb_build_object(
        'companyId', company_id, 'company', company_name, 'domain', domain, 'fields', fields)
        order by fields desc, company_name)
      from (select * from fillable where fields > 0 order by fields desc, company_name
            limit greatest(1, least(coalesce(p_limit, 25), 100))) top
    ), '[]'::jsonb)
  );
$$;


ALTER FUNCTION public.enrichment_preview_v1(p_limit integer) OWNER TO postgres;

--
-- Name: expire_abandoned_company_imports_v1(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.expire_abandoned_company_imports_v1(p_stale_hours integer DEFAULT 24, p_limit integer DEFAULT 50) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_hours integer := greatest(1, least(coalesce(p_stale_hours, 24), 24 * 30));
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 500));
  v_expired integer;
begin
  with stale as (
    select i.id,
           -- Last sign of life: the newest staging row, or the start if it never
           -- wrote one. A running import keeps this fresh by definition.
           greatest(i.created_at, coalesce(max(r.imported_at), i.created_at)) as last_activity,
           i.processed_rows, i.total_rows
    from public.company_imports i
    left join public.company_import_rows r on r.import_id = i.id
    where i.status = 'processing'
    group by i.id, i.created_at, i.processed_rows, i.total_rows
    having greatest(i.created_at, coalesce(max(r.imported_at), i.created_at))
           < now() - make_interval(hours => v_hours)
    limit v_limit
  )
  update public.company_imports i
  set status = case
        when coalesce(s.total_rows, 0) > 0 and coalesce(s.processed_rows, 0) >= s.total_rows
          then 'completed'
        else 'failed'
      end,
      completed_at = now()
  from stale s
  where i.id = s.id and i.status = 'processing';

  get diagnostics v_expired = row_count;
  return v_expired;
end;
$$;


ALTER FUNCTION public.expire_abandoned_company_imports_v1(p_stale_hours integer, p_limit integer) OWNER TO postgres;

--
-- Name: export_part_v1(uuid, text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.export_part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) RETURNS TABLE(rows jsonb, row_count integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports'
    SET statement_timeout TO '30s'
    AS $$
  select * from prospect_exports.part_v1(p_job_id, p_owner_id, p_token, p_part_index);
$$;


ALTER FUNCTION public.export_part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) OWNER TO postgres;

--
-- Name: export_parts_present_v1(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.export_parts_present_v1(p_job_id uuid) RETURNS boolean
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports'
    SET statement_timeout TO '15s'
    AS $$
  select prospect_exports.parts_present_v1(p_job_id);
$$;


ALTER FUNCTION public.export_parts_present_v1(p_job_id uuid) OWNER TO postgres;

--
-- Name: export_status_v1(uuid, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.export_status_v1(p_job_id uuid, p_owner_id text) RETURNS TABLE(job_id uuid, status text, row_count bigint, byte_count bigint, part_count integer, set_status text, set_rows bigint, entity_type text, file_base_name text, fields text[], download_token text, error text, expires_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports'
    SET statement_timeout TO '15s'
    AS $$
  select * from prospect_exports.status_v1(p_job_id, p_owner_id);
$$;


ALTER FUNCTION public.export_status_v1(p_job_id uuid, p_owner_id text) OWNER TO postgres;

--
-- Name: filter_companies_v3(text, text[], text[], text[], text[], text, jsonb, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.filter_companies_v3(p_search text DEFAULT ''::text, p_names text[] DEFAULT '{}'::text[], p_domains text[] DEFAULT '{}'::text[], p_seniority text[] DEFAULT '{}'::text[], p_locations text[] DEFAULT '{}'::text[], p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $$
  with base as (
    select c.id, c.name, c.domain, c.created_at
    from public.companies c
    where (coalesce(p_search, '') = '' or c.name ilike '%' || p_search || '%' or c.domain ilike '%' || p_search || '%')
      and (coalesce(cardinality(p_names), 0) = 0 or exists (select 1 from unnest(p_names) selected where c.name ilike '%' || selected || '%'))
      and (coalesce(cardinality(p_domains), 0) = 0 or c.normalized_domain = any(p_domains))
      and ((coalesce(cardinality(p_seniority), 0) = 0 and coalesce(cardinality(p_locations), 0) = 0) or exists (
        select 1 from public.prospect_index qualifier
        where qualifier.company_id = c.id
          and (p_client_id is null or qualifier.client_ids @> array[p_client_id])
          and (coalesce(cardinality(p_seniority), 0) = 0 or qualifier.seniority = any(p_seniority))
          and (coalesce(cardinality(p_locations), 0) = 0 or exists (
            select 1 from unnest(p_locations) loc where concat_ws(', ', nullif(qualifier.city, ''), nullif(qualifier.state, ''), nullif(qualifier.country, '')) ilike '%' || loc || '%'
          ))
      ))
      and (p_client_id is null or exists (select 1 from public.prospect_index scoped where scoped.company_id = c.id and scoped.client_ids @> array[p_client_id]))
      -- People-DB scope now resolves through the indexed helper (one pass) instead
      -- of a per-company correlated EXISTS over the opaque scalar matcher.
      and (p_people_scope is null or c.id in (select company_id from public.people_scope_company_ids_v1(p_client_id, p_people_scope)))
  ), agg as (
    select b.id, b.name, b.domain, b.created_at,
      coalesce(counts.prospect_count, 0) as prospect_count,
      coalesce(counts.client_count, 0) as client_count
    from base b
    left join lateral (
      select count(distinct pi.id)::integer as prospect_count, count(distinct client_id)::integer as client_count
      from public.prospect_index pi
      left join lateral unnest(pi.client_ids) client_id on true
      where pi.company_id = b.id and (p_client_id is null or pi.client_ids @> array[p_client_id])
    ) counts on true
  ), counted as (
    select count(*)::integer as total_count,
      count(*) filter (where prospect_count > 0)::integer as covered_count,
      coalesce(sum(prospect_count), 0)::integer as prospect_total
    from agg
  ), page as (
    select id, name, domain, created_at, prospect_count, client_count
    from agg order by prospect_count desc, lower(name), id
    offset greatest(coalesce(p_offset, 0), 0)
    limit greatest(1, least(coalesce(p_limit, 50), 5000))
  )
  select coalesce((select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id) from page), '[]'::jsonb),
    counted.total_count, counted.covered_count, counted.prospect_total
  from counted;
$$;


ALTER FUNCTION public.filter_companies_v3(p_search text, p_names text[], p_domains text[], p_seniority text[], p_locations text[], p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: filter_companies_v4(text, jsonb, text, jsonb, integer, integer, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.filter_companies_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_people_scope jsonb DEFAULT NULL::jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_known_versions jsonb DEFAULT NULL::jsonb) RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer, total_capped boolean, data_versions jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $_$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_counting_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 5000));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_ctes text[] := array[]::text[];
  v_cte_sql text;
  v_join text;
  v_prospect_expr text;
  v_client_expr text;
  v_where text;
  v_where_counting text;
  v_count_source text;
  v_count_pred text;
  v_scope_suffix text := '';
  v_complete text;
  v_versions jsonb;
  v_want_total boolean;
  v_sql text;
begin
  v_versions := public.data_versions_v1(array['company', 'prospect']);
  v_want_total := p_known_versions is null or p_known_versions <> v_versions;

  v_complete := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  -- The page always keeps the OR chain: it walks idx_companies_prospect_ranking
  -- and stops at fifty, which is fast at any selectivity. Only the counting scan
  -- may switch, and only when there is a count to take.
  v_counting_clause := v_match_clause;
  if v_want_total then
    v_counting_clause := coalesce(
      public.company_full_scan_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb)),
      v_match_clause);
  end if;

  if p_client_id is null then
    v_join := '';
    v_prospect_expr := 'c.prospect_count';
    v_client_expr := 'c.client_count';
  else
    -- The per-client prospect count is a stored column on the membership row,
    -- so there is no aggregate to build and the join is an index lookup. The
    -- join is inner because a company is in this client exactly when the
    -- membership row exists, which is what the scope suffix also says.
    v_join := format(' join public.client_companies k on k.company_id = c.id and k.client_id = %L', p_client_id);
    v_prospect_expr := 'k.prospect_count';
    -- client_count depends on how other clients link to the same prospects, so
    -- it is not a per-pair fact and is not stored. It is evaluated for the rows
    -- on the page only - fifty - rather than for every company in the client.
    v_client_expr := format($ce$(select count(distinct cid)::integer
      from public.prospect_index pi
      cross join lateral unnest(pi.client_ids) as cid
      where pi.company_id = c.id and pi.client_ids @> array[%L])$ce$, p_client_id);
  end if;

  if p_client_id is not null then
    -- Membership, not people. A company whose last person was removed from
    -- this client keeps its client_companies row and therefore keeps its place
    -- in the client Company DB; removing the COMPANY deletes that row and takes
    -- it out. client_companies is a strict superset of "has people here", so
    -- this widens the set without dropping anything from it, and answers from
    -- the primary key instead of probing prospect_index.
    v_scope_suffix := v_scope_suffix || format($e$ and exists (
      select 1 from public.client_companies retained
      where retained.company_id = c.id and retained.client_id = %L
    )$e$, p_client_id);
  end if;
  if p_people_scope is not null then
    v_ctes := array_append(v_ctes, format($s$scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb)
      )$s$, p_client_id, p_people_scope::text));
    v_scope_suffix := v_scope_suffix || ' and c.id in (select company_id from scope_ids)';
  end if;

  v_where := format('(%s)', v_match_clause) || v_scope_suffix;
  v_where_counting := format('(%s)', v_counting_clause) || v_scope_suffix;

  -- The count only needs public.companies when something in the query mentions
  -- it. Unfiltered, inside a client, it does not: the membership rows are the
  -- answer, and the foreign key guarantees each one has a company behind it.
  -- 977 ms of primary-key probes against 17 ms of index-only scan.
  v_count_source := 'public.companies c' || v_join;
  v_count_pred := v_where_counting;
  if p_client_id is not null
     and p_people_scope is null
     and btrim(v_counting_clause) = 'true' then
    v_count_source := 'public.client_companies k';
    v_count_pred := format('k.client_id = %L', p_client_id);
  end if;

  v_cte_sql := case when cardinality(v_ctes) > 0
    then array_to_string(v_ctes, ', ') || ', ' else '' end;

  v_sql := format($query$
    with %1$s page as (
      select c.id, c.name, c.domain, c.created_at,
        %2$s as prospect_count, %3$s as client_count
      from public.companies c%4$s
      where %5$s
      order by %2$s desc, lower(c.name), c.id
      offset %6$s limit %7$s
    ), counted as (
      select count(*)::integer as total_count,
        count(*) filter (where %2$s > 0)::integer as covered_count,
        coalesce(sum(%2$s), 0)::integer as prospect_total
      from %11$s
      where %12$s and %9$s
    )
    select coalesce((
        select jsonb_agg(to_jsonb(page) order by page.prospect_count desc, lower(page.name), page.id)
        from page
      ), '[]'::jsonb),
      case when %9$s then counted.total_count end,
      case when %9$s then counted.covered_count end,
      case when %9$s then counted.prospect_total end,
      false,
      %10$L::jsonb
    from counted
  $query$, v_cte_sql, v_prospect_expr, v_client_expr, v_join, v_where,
       v_offset::text, v_limit::text, v_where_counting, v_want_total::text, v_versions::text,
       v_count_source, v_count_pred);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.filter_companies_v4(p_search text, p_filters jsonb, p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer, p_known_versions jsonb) OWNER TO postgres;

--
-- Name: find_duplicate_candidates(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.find_duplicate_candidates(p_limit integer DEFAULT 100) RETURNS TABLE(result_rows jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 250));
  v_left text[];
  v_right text[];
  v_summaries jsonb;
begin
  with candidates as materialized (
    select pi.id, pi.company_id, lower(btrim(pi.full_name)) as k, pi.updated_at, pi.client_ids
    from public.prospect_index pi
    where btrim(coalesce(pi.full_name, '')) <> '' and pi.company_id is not null
  ),
  -- The whole saving: a name that occurs once inside its company cannot be a
  -- duplicate of anything, so 681,743 rows collapse to 45 groups before any
  -- pairing happens.
  grouped as (
    select k, company_id from candidates group by k, company_id having count(*) > 1
  ),
  members as (
    select c.* from candidates c join grouped g on g.k = c.k and g.company_id = c.company_id
  ),
  pairs as (
    select l.id as left_id, r.id as right_id, l.updated_at as left_updated
    from members l
    join members r on r.k = l.k and r.company_id = l.company_id and l.id < r.id
    -- Same person under two different clients is the thing worth surfacing.
    where exists (
      select 1 from unnest(l.client_ids) left_client(id)
      cross join unnest(r.client_ids) right_client(id)
      where left_client.id <> right_client.id
    )
  )
  select array_agg(left_id order by left_updated desc, left_id),
         array_agg(right_id order by left_updated desc, left_id)
  into v_left, v_right
  from (select left_id, right_id, left_updated from pairs order by left_updated desc, left_id limit v_limit) ranked;

  if v_left is null then
    return query select '[]'::jsonb;
    return;
  end if;

  -- `= any(array)` and not a join: the view pushes this down, and pushes a join
  -- down not at all.
  select coalesce(jsonb_object_agg(s.id, to_jsonb(s)), '{}'::jsonb)
  into v_summaries
  from public.prospect_summaries s
  where s.id = any(v_left || v_right);

  return query
  select coalesce(jsonb_agg(jsonb_build_object(
    'left', v_summaries -> v_left[i],
    'right', v_summaries -> v_right[i],
    'reason', 'Same person found in different clients',
    'confidence', 90
  ) order by i), '[]'::jsonb)
  -- Both sides must have hydrated, which is what the old inner join enforced.
  from generate_subscripts(v_left, 1) i
  where v_summaries ? v_left[i] and v_summaries ? v_right[i];
end;
$$;


ALTER FUNCTION public.find_duplicate_candidates(p_limit integer) OWNER TO postgres;

--
-- Name: finish_list_push_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.finish_list_push_v1(p_import_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare result_row record;
begin
  update public.imports set status = 'completed', completed_at = now()
  where id = p_import_id
  returning list_id, total_rows, processed_rows, duplicates_linked into result_row;

  if not found then
    raise exception 'Push not found' using errcode = 'P0002';
  end if;

  update public.lists l set
    uploaded_rows = uploaded_rows + result_row.total_rows,
    duplicates_linked = duplicates_linked + result_row.duplicates_linked
  where l.id = result_row.list_id;

  return jsonb_build_object(
    'importId', p_import_id,
    'listId', result_row.list_id,
    'pushed', result_row.total_rows,
    'alreadyPresent', result_row.duplicates_linked
  );
end;
$$;


ALTER FUNCTION public.finish_list_push_v1(p_import_id text) OWNER TO postgres;

--
-- Name: fixed_import_json_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fixed_import_json_v1(p_entity text, p_value jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select coalesce(jsonb_object_agg(mapped_key, value order by mapped_key), '{}'::jsonb)
  from (
    select distinct on (mapped_key) mapped_key, value
    from (
      select public.fixed_import_key_v1(p_entity, entry.key) as mapped_key,
        entry.key as source_key, entry.value
      from jsonb_each(case when jsonb_typeof(p_value) = 'object' then p_value else '{}'::jsonb end) entry
    ) candidates
    where mapped_key is not null
    -- Prefer an already-canonical key over an alias when both were retained in
    -- an old payload; otherwise choose deterministically.
    order by mapped_key, (value is not null and value <> 'null'::jsonb and value <> '""'::jsonb) desc,
      (source_key = mapped_key) desc, source_key
  ) mapped;
$$;


ALTER FUNCTION public.fixed_import_json_v1(p_entity text, p_value jsonb) OWNER TO postgres;

--
-- Name: fixed_import_key_v1(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fixed_import_key_v1(p_entity text, p_key text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select case
    -- Enrichment bookkeeping shares prospects.all_data with source payloads;
    -- it is system metadata, not an import column, and must survive cleanup.
    when lower(coalesce(p_entity, '')) = 'prospect'
      and p_key in ('_enriched_from', '_enriched_at') then p_key
    else case lower(coalesce(p_entity, ''))
    when 'prospect' then case regexp_replace(lower(coalesce(p_key, '')), '[^a-z0-9]+', '', 'g')
      when 'firstname' then 'First Name' when 'lastname' then 'Last Name'
      when 'jobtitle' then 'Job Title' when 'title' then 'Job Title'
      when 'email' then 'Email' when 'emailaddress' then 'Email' when 'workemail' then 'Email' when 'businessemail' then 'Email'
      when 'mobile' then 'Mobile Number' when 'mobilenumber' then 'Mobile Number' when 'phone' then 'Mobile Number' when 'phonenumber' then 'Mobile Number'
      when 'linkedin' then 'Personal LinkedIn URL' when 'linkedinurl' then 'Personal LinkedIn URL' when 'linkedinprofile' then 'Personal LinkedIn URL'
      when 'personlinkedinurl' then 'Personal LinkedIn URL' when 'personallinkedinurl' then 'Personal LinkedIn URL'
      when 'company' then 'Company Name' when 'companyname' then 'Company Name' when 'organization' then 'Company Name' when 'casualcompanyname' then 'Company Name'
      when 'website' then 'Website' when 'companywebsite' then 'Website' when 'domain' then 'Website' when 'companydomain' then 'Website'
      else null end
    when 'company' then case regexp_replace(lower(coalesce(p_key, '')), '[^a-z0-9]+', '', 'g')
      when 'company' then 'Company Name' when 'companyname' then 'Company Name' when 'name' then 'Company Name' when 'organization' then 'Company Name' when 'accountname' then 'Company Name'
      when 'website' then 'Website' when 'domain' then 'Website' when 'companywebsite' then 'Website' when 'companydomain' then 'Website' when 'url' then 'Website'
      when 'industry' then 'Industry' when 'companyindustry' then 'Industry'
      when 'keyword' then 'Keywords' when 'keywords' then 'Keywords' when 'companykeywords' then 'Keywords'
      when 'shortdescription' then 'Short Description' when 'description' then 'Short Description' when 'companydescription' then 'Short Description'
      when 'foundedyear' then 'Founded Year' when 'founded' then 'Founded Year' when 'yearfounded' then 'Founded Year'
      when 'employees' then '#employees' when 'employeecount' then '#employees' when 'employeescount' then '#employees' when 'numberofemployees' then '#employees' when 'headcount' then '#employees' when 'companyemployeecount' then '#employees' when 'companyemployees' then '#employees'
      when 'companycity' then 'Company City' when 'city' then 'Company City' when 'accountcity' then 'Company City' when 'hqcity' then 'Company City'
      when 'companystate' then 'Company State' when 'state' then 'Company State' when 'accountstate' then 'Company State' when 'hqstate' then 'Company State' when 'companyregion' then 'Company State'
      when 'companycountry' then 'Company Country' when 'country' then 'Company Country' when 'accountcountry' then 'Company Country' when 'hqcountry' then 'Company Country'
      when 'technology' then 'Technologies' when 'technologies' then 'Technologies' when 'techstack' then 'Technologies'
      when 'totalfunding' then 'Total Funding' when 'funding' then 'Total Funding' when 'totalfundingamount' then 'Total Funding'
      else null end
    else null end
  end;
$$;


ALTER FUNCTION public.fixed_import_key_v1(p_entity text, p_key text) OWNER TO postgres;

--
-- Name: freeze_operation_from_result_set_v1(uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.freeze_operation_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) RETURNS TABLE(total_items bigint, excluded_count bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '120s'
    AS $$
  select * from prospect_operations.freeze_from_result_set_v1(p_job_id, p_actor, p_result_set_id);
$$;


ALTER FUNCTION public.freeze_operation_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) OWNER TO postgres;

--
-- Name: freeze_operation_ids_v1(uuid, text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.freeze_operation_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) RETURNS TABLE(total_items bigint, excluded_count bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '60s'
    AS $$
  select * from prospect_operations.freeze_from_ids_v1(p_job_id, p_actor, p_ids);
$$;


ALTER FUNCTION public.freeze_operation_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) OWNER TO postgres;

--
-- Name: heartbeat_prospect_import_v1(text, text, integer, integer, bigint); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.heartbeat_prospect_import_v1(p_import_id text, p_worker_id text, p_lease_seconds integer DEFAULT 300, p_total_rows integer DEFAULT NULL::integer, p_processed_bytes bigint DEFAULT NULL::bigint) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '5s'
    AS $$
declare
  changed integer;
begin
  update public.imports
  set lease_expires_at = now() + make_interval(secs => greatest(30, least(p_lease_seconds, 1800))),
      heartbeat_at = now(),
      total_rows = coalesce(p_total_rows, total_rows),
      processed_bytes = greatest(processed_bytes, coalesce(p_processed_bytes, processed_bytes))
  where id = p_import_id
    and ingestion_mode = 'background'
    and status = 'processing'
    and worker_id = p_worker_id;
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;


ALTER FUNCTION public.heartbeat_prospect_import_v1(p_import_id text, p_worker_id text, p_lease_seconds integer, p_total_rows integer, p_processed_bytes bigint) OWNER TO postgres;

--
-- Name: import_company_batch_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_company_batch_v1(p_import_id text, p_rows jsonb) RETURNS TABLE(processed integer, added integer, updated integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  row_data jsonb;
  source_name text;
  company_id_value text;
  company_name_value text;
  normalized_name_value text;
  domain_value text;
  normalized_domain_value text;
  source_row_value integer;
  was_new boolean;
  row_inserted integer;
  processed_count integer := 0;
  added_count_value integer := 0;
  updated_count_value integer := 0;
  skipped_count_value integer := 0;
begin
  select data_source into source_name
  from public.company_imports
  where id = p_import_id and status = 'processing'
  for update;
  if source_name is null then raise exception 'Company import not found or already completed' using errcode = 'P0002'; end if;

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    source_row_value := greatest(2, coalesce((row_data->>'sourceRowNumber')::integer, 2));
    insert into public.company_import_rows(import_id, source_row_number, raw_data)
    values (p_import_id, source_row_value, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (import_id, source_row_number) do nothing;
    get diagnostics row_inserted = row_count;
    if row_inserted = 0 then continue; end if;

    processed_count := processed_count + 1;
    company_name_value := btrim(coalesce(row_data->>'name', ''));
    normalized_name_value := btrim(coalesce(row_data->>'normalizedName', ''));
    domain_value := btrim(coalesce(row_data->>'domain', ''));
    normalized_domain_value := btrim(coalesce(row_data->>'normalizedDomain', ''));
    if normalized_name_value = '' and normalized_domain_value = '' then
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    company_id_value := null;
    select c.id into company_id_value
    from public.companies c
    where (normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value)
       or (normalized_name_value <> '' and c.normalized_name = normalized_name_value
         and (normalized_domain_value = '' or c.normalized_domain = ''))
    order by case when normalized_domain_value <> '' and c.normalized_domain = normalized_domain_value then 0 else 1 end, c.created_at
    limit 1;
    was_new := company_id_value is null;
    if was_new then
      company_id_value := case when normalized_domain_value <> '' then 'domain:' || normalized_domain_value else 'name:' || normalized_name_value end;
    end if;

    insert into public.companies(id, name, normalized_name, domain, normalized_domain, all_data, updated_at)
    values (company_id_value, company_name_value, normalized_name_value, domain_value, normalized_domain_value, coalesce(row_data->'raw', '{}'::jsonb), now())
    on conflict (id) do update set
      name = case when excluded.name <> '' then excluded.name else public.companies.name end,
      normalized_name = case when excluded.normalized_name <> '' then excluded.normalized_name else public.companies.normalized_name end,
      domain = case when excluded.domain <> '' then excluded.domain else public.companies.domain end,
      normalized_domain = case when excluded.normalized_domain <> '' then excluded.normalized_domain else public.companies.normalized_domain end,
      all_data = public.companies.all_data || excluded.all_data,
      updated_at = now();

    insert into public.company_sources(company_id, data_source, last_import_id, last_seen_at)
    values (company_id_value, source_name, p_import_id, now())
    on conflict (company_id, data_source) do update set last_import_id = excluded.last_import_id, last_seen_at = now();
    update public.company_import_rows set company_id = company_id_value
    where import_id = p_import_id and source_row_number = source_row_value;
    if was_new then added_count_value := added_count_value + 1; else updated_count_value := updated_count_value + 1; end if;
  end loop;

  update public.company_imports set
    processed_rows = processed_rows + processed_count,
    added_count = added_count + added_count_value,
    updated_count = updated_count + updated_count_value,
    skipped_count = skipped_count + skipped_count_value
  where id = p_import_id;
  return query select processed_count, added_count_value, updated_count_value, skipped_count_value;
end;
$$;


ALTER FUNCTION public.import_company_batch_v1(p_import_id text, p_rows jsonb) OWNER TO postgres;

--
-- Name: import_company_batch_v2(text, jsonb, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_company_batch_v2(p_import_id text, p_rows jsonb, p_row_offset integer) RETURNS TABLE(processed integer, added integer, updated integer, skipped integer)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
  select * from public.import_company_batch_v3(p_import_id, p_rows, p_row_offset);
$$;


ALTER FUNCTION public.import_company_batch_v2(p_import_id text, p_rows jsonb, p_row_offset integer) OWNER TO postgres;

--
-- Name: import_company_batch_v3(text, jsonb, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_company_batch_v3(p_import_id text, p_rows jsonb, p_row_offset integer) RETURNS TABLE(processed integer, added integer, updated integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $$
declare
  row_data jsonb;
  source_name text;
  merge_mode_value text;
  committed_offset integer;
  batch_size integer := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  company_id_value text;
  company_name_value text;
  normalized_name_value text;
  domain_value text;
  normalized_domain_value text;
  location_value text;
  source_row_value integer;
  was_new boolean;
  row_inserted integer;
  processed_count integer := 0;
  added_count_value integer := 0;
  updated_count_value integer := 0;
  skipped_count_value integer := 0;
begin
  if p_row_offset is null or p_row_offset < 0 then
    raise exception 'A non-negative row offset is required' using errcode = '22023';
  end if;

  select ci.data_source, ci.committed_row_offset, ci.merge_mode
  into source_name, committed_offset, merge_mode_value
  from public.company_imports ci
  where ci.id = p_import_id and ci.status = 'processing'
  for update;

  if not found then
    raise exception 'Company import not found or already completed' using errcode = 'P0002';
  end if;

  merge_mode_value := coalesce(nullif(merge_mode_value, ''), 'enrich');

  -- Already-committed chunk replayed after a resume: acknowledge, do not re-apply.
  if p_row_offset + batch_size <= committed_offset then
    return query select batch_size, 0, 0, 0;
    return;
  end if;

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    source_row_value := greatest(2, coalesce((row_data->>'sourceRowNumber')::integer, 2));
    insert into public.company_import_rows(import_id, source_row_number, raw_data)
    values (p_import_id, source_row_value, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (import_id, source_row_number) do nothing;
    get diagnostics row_inserted = row_count;
    if row_inserted = 0 then continue; end if;

    processed_count := processed_count + 1;
    company_name_value := btrim(coalesce(row_data->>'name', ''));
    normalized_name_value := btrim(coalesce(row_data->>'normalizedName', ''));
    domain_value := btrim(coalesce(row_data->>'domain', ''));
    normalized_domain_value := btrim(coalesce(row_data->>'normalizedDomain', ''));
    -- A row is importable with a name OR a website; skip only when it has neither.
    if normalized_name_value = '' and normalized_domain_value = '' then
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    -- Geography arrives either as one Location column or as city/state/country,
    -- so prefer what the file actually carried and compose only as a fallback.
    -- Carried over from 20260825103139_fix_company_location_import_drift.sql,
    -- which this function supersedes: without it a file whose only geography is a
    -- single "Company Location" column silently imports a blank location.
    location_value := coalesce(
      nullif(btrim(coalesce(row_data->>'location', '')), ''),
      nullif(concat_ws(', ',
        nullif(btrim(coalesce(row_data->>'city', '')), ''),
        nullif(btrim(coalesce(row_data->>'state', '')), ''),
        nullif(btrim(coalesce(row_data->>'country', '')), '')), ''),
      '');

    company_id_value := null;
    -- By domain, then by name - never an index probe for a blank value.
    -- See 20260923130000.
    if normalized_domain_value <> '' then
      select c.id into company_id_value from public.companies c
      where c.normalized_domain = normalized_domain_value
      order by c.created_at
      limit 1;
    end if;
    if company_id_value is null and normalized_name_value <> '' then
      select c.id into company_id_value from public.companies c
      where c.normalized_name = normalized_name_value
        and (normalized_domain_value = '' or c.normalized_domain = '')
      order by c.created_at
      limit 1;
    end if;
    was_new := company_id_value is null;

    if not was_new and merge_mode_value = 'skip' then
      -- Record that this source saw the company, then leave the company alone.
      insert into public.company_sources(company_id, data_source, last_import_id, last_seen_at)
      values (company_id_value, source_name, p_import_id, now())
      on conflict (company_id, data_source) do update set last_import_id = excluded.last_import_id, last_seen_at = now();
      update public.company_import_rows set company_id = company_id_value
      where import_id = p_import_id and source_row_number = source_row_value;
      skipped_count_value := skipped_count_value + 1;
      continue;
    end if;

    if was_new then
      company_id_value := case when normalized_domain_value <> '' then 'domain:' || normalized_domain_value else 'name:' || normalized_name_value end;
    end if;

    insert into public.companies(
      id, name, normalized_name, domain, normalized_domain, all_data,
      employee_count_min, employee_count_max, industry, city, state, country,
      location, keywords, short_description, founded_year, technologies, total_funding, updated_at
    ) values (
      company_id_value, company_name_value, normalized_name_value, domain_value, normalized_domain_value,
      coalesce(row_data->'raw', '{}'::jsonb), nullif(row_data->>'employeeCountMin', '')::integer,
      nullif(row_data->>'employeeCountMax', '')::integer, btrim(coalesce(row_data->>'industry', '')),
      btrim(coalesce(row_data->>'city', '')), btrim(coalesce(row_data->>'state', '')), btrim(coalesce(row_data->>'country', '')),
      location_value,
      array(select jsonb_array_elements_text(coalesce(row_data->'keywords', '[]'::jsonb))),
      btrim(coalesce(row_data->>'shortDescription', '')), nullif(row_data->>'foundedYear', '')::integer,
      array(select jsonb_array_elements_text(coalesce(row_data->'technologies', '[]'::jsonb))),
      btrim(coalesce(row_data->>'totalFunding', '')), now()
    )
    on conflict (id) do update set
      -- overwrite: the uploaded value wins wherever the upload has one.
      -- enrich:    the stored value wins wherever the store has one.
      name = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.name, ''), public.companies.name)
        else coalesce(nullif(public.companies.name, ''), excluded.name) end,
      normalized_name = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.normalized_name, ''), public.companies.normalized_name)
        else coalesce(nullif(public.companies.normalized_name, ''), excluded.normalized_name) end,
      domain = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.domain, ''), public.companies.domain)
        else coalesce(nullif(public.companies.domain, ''), excluded.domain) end,
      normalized_domain = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.normalized_domain, ''), public.companies.normalized_domain)
        else coalesce(nullif(public.companies.normalized_domain, ''), excluded.normalized_domain) end,
      all_data = case when merge_mode_value = 'overwrite'
        then public.companies.all_data || excluded.all_data
        else excluded.all_data || public.companies.all_data end,
      employee_count_min = case when merge_mode_value = 'overwrite'
        then coalesce(excluded.employee_count_min, public.companies.employee_count_min)
        else coalesce(public.companies.employee_count_min, excluded.employee_count_min) end,
      employee_count_max = case when merge_mode_value = 'overwrite'
        then coalesce(excluded.employee_count_max, public.companies.employee_count_max)
        else coalesce(public.companies.employee_count_max, excluded.employee_count_max) end,
      industry = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.industry, ''), public.companies.industry)
        else coalesce(nullif(public.companies.industry, ''), excluded.industry) end,
      city = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.city, ''), public.companies.city)
        else coalesce(nullif(public.companies.city, ''), excluded.city) end,
      state = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.state, ''), public.companies.state)
        else coalesce(nullif(public.companies.state, ''), excluded.state) end,
      country = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.country, ''), public.companies.country)
        else coalesce(nullif(public.companies.country, ''), excluded.country) end,
      location = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.location, ''), public.companies.location)
        else coalesce(nullif(public.companies.location, ''), excluded.location) end,
      keywords = case
        when merge_mode_value = 'overwrite' and cardinality(excluded.keywords) > 0 then excluded.keywords
        when merge_mode_value = 'overwrite' then public.companies.keywords
        when cardinality(public.companies.keywords) > 0 then public.companies.keywords
        else excluded.keywords end,
      short_description = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.short_description, ''), public.companies.short_description)
        else coalesce(nullif(public.companies.short_description, ''), excluded.short_description) end,
      founded_year = case when merge_mode_value = 'overwrite'
        then coalesce(excluded.founded_year, public.companies.founded_year)
        else coalesce(public.companies.founded_year, excluded.founded_year) end,
      technologies = case
        when merge_mode_value = 'overwrite' and cardinality(excluded.technologies) > 0 then excluded.technologies
        when merge_mode_value = 'overwrite' then public.companies.technologies
        when cardinality(public.companies.technologies) > 0 then public.companies.technologies
        else excluded.technologies end,
      total_funding = case when merge_mode_value = 'overwrite'
        then coalesce(nullif(excluded.total_funding, ''), public.companies.total_funding)
        else coalesce(nullif(public.companies.total_funding, ''), excluded.total_funding) end,
      updated_at = now();

    insert into public.company_sources(company_id, data_source, last_import_id, last_seen_at)
    values (company_id_value, source_name, p_import_id, now())
    on conflict (company_id, data_source) do update set last_import_id = excluded.last_import_id, last_seen_at = now();
    update public.company_import_rows set company_id = company_id_value
    where import_id = p_import_id and source_row_number = source_row_value;
    if was_new then added_count_value := added_count_value + 1; else updated_count_value := updated_count_value + 1; end if;
  end loop;

  update public.company_imports set processed_rows = processed_rows + processed_count,
    added_count = added_count + added_count_value, updated_count = updated_count + updated_count_value,
    skipped_count = skipped_count + skipped_count_value,
    committed_row_offset = greatest(committed_row_offset, p_row_offset + batch_size)
  where id = p_import_id;
  return query select processed_count, added_count_value, updated_count_value, skipped_count_value;
end;
$$;


ALTER FUNCTION public.import_company_batch_v3(p_import_id text, p_rows jsonb, p_row_offset integer) OWNER TO postgres;

--
-- Name: import_prospect_batch(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_prospect_batch(p_import_id text, p_list_id text, p_rows jsonb) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  row_data jsonb;
  identifier jsonb;
  prospect_id_value text;
  company_id_value text;
  new_count integer := 0;
  duplicate_count integer := 0;
  skipped_count integer := 0;
begin
  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    if jsonb_array_length(coalesce(row_data->'identifiers', '[]'::jsonb)) = 0 then
      skipped_count := skipped_count + 1;
      continue;
    end if;

    prospect_id_value := null;
    select pi.prospect_id into prospect_id_value
    from jsonb_array_elements(row_data->'identifiers') as item(value)
    join public.prospect_identifiers pi
      on pi.type = item.value->>'type' and pi.value = item.value->>'value'
    order by case pi.type when 'work_email' then 1 when 'personal_email' then 2 when 'linkedin' then 3 else 4 end
    limit 1;

    company_id_value := nullif(row_data->>'companyId', '');
    if company_id_value is not null then
      insert into public.companies (id, name, normalized_name, domain, normalized_domain, all_data)
      values (
        company_id_value,
        coalesce(row_data->>'companyName', ''),
        coalesce(row_data->>'normalizedCompanyName', ''),
        coalesce(row_data->>'companyDomain', ''),
        coalesce(row_data->>'companyDomain', ''),
        coalesce(row_data->'raw', '{}'::jsonb)
      )
      on conflict (id) do update set
        name = case when companies.name = '' then excluded.name else companies.name end,
        domain = case when companies.domain = '' then excluded.domain else companies.domain end,
        all_data = excluded.all_data || companies.all_data,
        updated_at = now();
    end if;

    if prospect_id_value is null then
      prospect_id_value := gen_random_uuid()::text;
      insert into public.prospects (
        id, first_name, last_name, full_name, work_email, personal_email, mobile_number,
        linkedin_url, title, seniority, department, city, state, country, company_id, all_data
      ) values (
        prospect_id_value, coalesce(row_data->>'firstName', ''), coalesce(row_data->>'lastName', ''),
        coalesce(row_data->>'fullName', ''), coalesce(row_data->>'workEmail', ''),
        coalesce(row_data->>'personalEmail', ''), coalesce(row_data->>'mobileNumber', ''),
        coalesce(row_data->>'linkedinUrl', ''), coalesce(row_data->>'title', ''),
        coalesce(row_data->>'seniority', ''), coalesce(row_data->>'department', ''),
        coalesce(row_data->>'city', ''), coalesce(row_data->>'state', ''),
        coalesce(row_data->>'country', ''), company_id_value, coalesce(row_data->'raw', '{}'::jsonb)
      );
      new_count := new_count + 1;
    else
      update public.prospects set
        first_name = case when first_name = '' then coalesce(row_data->>'firstName', '') else first_name end,
        last_name = case when last_name = '' then coalesce(row_data->>'lastName', '') else last_name end,
        full_name = case when full_name = '' then coalesce(row_data->>'fullName', '') else full_name end,
        work_email = case when work_email = '' then coalesce(row_data->>'workEmail', '') else work_email end,
        personal_email = case when personal_email = '' then coalesce(row_data->>'personalEmail', '') else personal_email end,
        mobile_number = case when mobile_number = '' then coalesce(row_data->>'mobileNumber', '') else mobile_number end,
        linkedin_url = case when linkedin_url = '' then coalesce(row_data->>'linkedinUrl', '') else linkedin_url end,
        title = case when title = '' then coalesce(row_data->>'title', '') else title end,
        seniority = case when seniority = '' then coalesce(row_data->>'seniority', '') else seniority end,
        department = case when department = '' then coalesce(row_data->>'department', '') else department end,
        city = case when city = '' then coalesce(row_data->>'city', '') else city end,
        state = case when state = '' then coalesce(row_data->>'state', '') else state end,
        country = case when country = '' then coalesce(row_data->>'country', '') else country end,
        company_id = coalesce(company_id, company_id_value),
        all_data = coalesce(row_data->'raw', '{}'::jsonb) || all_data,
        updated_at = now()
      where id = prospect_id_value;
      duplicate_count := duplicate_count + 1;
    end if;

    for identifier in select value from jsonb_array_elements(row_data->'identifiers')
    loop
      insert into public.prospect_identifiers(type, value, prospect_id)
      values (identifier->>'type', identifier->>'value', prospect_id_value)
      on conflict (type, value) do nothing;
    end loop;

    insert into public.list_memberships(list_id, prospect_id, import_id, raw_data)
    values (p_list_id, prospect_id_value, p_import_id, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (list_id, prospect_id) do update set
      import_id = excluded.import_id,
      raw_data = excluded.raw_data,
      imported_at = now();
  end loop;

  processed := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  unique_added := new_count;
  duplicates_linked := duplicate_count;
  skipped := skipped_count;

  update public.imports set
    processed_rows = processed_rows + processed,
    unique_added = imports.unique_added + new_count,
    duplicates_linked = imports.duplicates_linked + duplicate_count
  where id = p_import_id;

  return next;
end;
$$;


ALTER FUNCTION public.import_prospect_batch(p_import_id text, p_list_id text, p_rows jsonb) OWNER TO postgres;

--
-- Name: import_prospect_batch_v2(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_prospect_batch_v2(p_import_id text, p_list_id text, p_rows jsonb) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  row_data jsonb;
  identifier jsonb;
  prospect_id_value text;
  company_id_value text;
  normalized_name_value text;
  normalized_domain_value text;
  source_row_number_value integer;
  location_value text;
  new_count integer := 0;
  duplicate_count integer := 0;
  skipped_count integer := 0;
  merge_mode_value text;
begin
  select coalesce(nullif(i.merge_mode, ''), 'enrich') into merge_mode_value
  from public.imports i where i.id = p_import_id;
  merge_mode_value := coalesce(merge_mode_value, 'enrich');

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    source_row_number_value := coalesce(nullif(row_data->>'sourceRowNumber', '')::integer, 0);
    if jsonb_array_length(coalesce(row_data->'identifiers', '[]'::jsonb)) = 0 then
      insert into public.list_rows(list_id, prospect_id, import_id, source_row_number, raw_data)
      values (p_list_id, null, p_import_id, source_row_number_value, coalesce(row_data->'raw', '{}'::jsonb))
      on conflict (import_id, source_row_number) do update set
        raw_data = excluded.raw_data,
        imported_at = now();
      skipped_count := skipped_count + 1;
      continue;
    end if;

    location_value := coalesce(nullif(btrim(coalesce(row_data->>'location', '')), ''), nullif(concat_ws(', ',
      nullif(btrim(coalesce(row_data->>'city', '')), ''),
      nullif(btrim(coalesce(row_data->>'state', '')), ''),
      nullif(btrim(coalesce(row_data->>'country', '')), '')
    ), ''), '');

    prospect_id_value := null;
    select pi.prospect_id into prospect_id_value
    from jsonb_array_elements(row_data->'identifiers') as item(value)
    join public.prospect_identifiers pi
      on pi.type = item.value->>'type' and pi.value = item.value->>'value'
    order by case pi.type
      when 'work_email' then 1 when 'personal_email' then 2 when 'linkedin' then 3
      when 'name_company' then 4 else 5 end
    limit 1;

    normalized_domain_value := btrim(coalesce(row_data->>'companyDomain', ''));
    normalized_name_value := btrim(coalesce(row_data->>'normalizedCompanyName', ''));
    company_id_value := null;
    if normalized_domain_value <> '' or normalized_name_value <> '' then
      -- By domain, then by name - never an index probe for a blank value.
      -- See 20260923130000.
      if normalized_domain_value <> '' then
        select c.id into company_id_value
        from public.companies c
        where c.normalized_domain = normalized_domain_value
        order by c.created_at
        limit 1;
      end if;
      if company_id_value is null and normalized_name_value <> '' then
        select c.id into company_id_value
        from public.companies c
        where c.normalized_name = normalized_name_value
          and (normalized_domain_value = '' or coalesce(c.normalized_domain, '') = '')
        order by c.created_at
        limit 1;
      end if;
      if company_id_value is null then
        company_id_value := case when normalized_domain_value <> ''
          then 'domain:' || normalized_domain_value
          else 'name:' || normalized_name_value end;
      end if;

      insert into public.companies (id, name, normalized_name, domain, normalized_domain, all_data)
      values (
        company_id_value,
        coalesce(row_data->>'companyName', ''),
        normalized_name_value,
        coalesce(row_data->>'companyDomain', ''),
        normalized_domain_value,
        -- Company-scoped keys only: this used to store the whole person row.
        public.company_scoped_raw(row_data->'raw')
      )
      on conflict (id) do update set
        name = coalesce(nullif(public.companies.name, ''), excluded.name),
        normalized_name = coalesce(nullif(public.companies.normalized_name, ''), excluded.normalized_name),
        domain = coalesce(nullif(public.companies.domain, ''), excluded.domain),
        normalized_domain = coalesce(nullif(public.companies.normalized_domain, ''), excluded.normalized_domain),
        all_data = excluded.all_data || public.companies.all_data,
        updated_at = now();
    end if;

    if prospect_id_value is null then
      prospect_id_value := gen_random_uuid()::text;
      insert into public.prospects (
        id, first_name, last_name, full_name, work_email, personal_email, mobile_number,
        linkedin_url, title, seniority, department, city, state, country, location,
        company_id, all_data
      ) values (
        prospect_id_value, coalesce(row_data->>'firstName', ''), coalesce(row_data->>'lastName', ''),
        coalesce(row_data->>'fullName', ''), coalesce(row_data->>'workEmail', ''),
        coalesce(row_data->>'personalEmail', ''), coalesce(row_data->>'mobileNumber', ''),
        coalesce(row_data->>'linkedinUrl', ''), coalesce(row_data->>'title', ''),
        coalesce(row_data->>'seniority', ''), coalesce(row_data->>'department', ''),
        coalesce(row_data->>'city', ''), coalesce(row_data->>'state', ''),
        coalesce(row_data->>'country', ''), location_value,
        company_id_value, coalesce(row_data->'raw', '{}'::jsonb)
      );
      new_count := new_count + 1;
    else
      if merge_mode_value <> 'skip' then
        update public.prospects set
          first_name = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'firstName', ''), first_name) else coalesce(nullif(first_name, ''), coalesce(row_data->>'firstName', '')) end,
          last_name = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'lastName', ''), last_name) else coalesce(nullif(last_name, ''), coalesce(row_data->>'lastName', '')) end,
          full_name = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'fullName', ''), full_name) else coalesce(nullif(full_name, ''), coalesce(row_data->>'fullName', '')) end,
          work_email = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'workEmail', ''), work_email) else coalesce(nullif(work_email, ''), coalesce(row_data->>'workEmail', '')) end,
          personal_email = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'personalEmail', ''), personal_email) else coalesce(nullif(personal_email, ''), coalesce(row_data->>'personalEmail', '')) end,
          mobile_number = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'mobileNumber', ''), mobile_number) else coalesce(nullif(mobile_number, ''), coalesce(row_data->>'mobileNumber', '')) end,
          linkedin_url = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'linkedinUrl', ''), linkedin_url) else coalesce(nullif(linkedin_url, ''), coalesce(row_data->>'linkedinUrl', '')) end,
          title = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'title', ''), title) else coalesce(nullif(title, ''), coalesce(row_data->>'title', '')) end,
          seniority = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'seniority', ''), seniority) else coalesce(nullif(seniority, ''), coalesce(row_data->>'seniority', '')) end,
          department = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'department', ''), department) else coalesce(nullif(department, ''), coalesce(row_data->>'department', '')) end,
          city = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'city', ''), city) else coalesce(nullif(city, ''), coalesce(row_data->>'city', '')) end,
          state = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'state', ''), state) else coalesce(nullif(state, ''), coalesce(row_data->>'state', '')) end,
          country = case when merge_mode_value = 'overwrite' then coalesce(nullif(row_data->>'country', ''), country) else coalesce(nullif(country, ''), coalesce(row_data->>'country', '')) end,
          location = case when merge_mode_value = 'overwrite' then coalesce(nullif(location_value, ''), location) else coalesce(nullif(location, ''), coalesce(location_value, '')) end,
          company_id = coalesce(company_id_value, company_id),
          all_data = case when merge_mode_value = 'overwrite' then all_data || coalesce(row_data->'raw', '{}'::jsonb) else coalesce(row_data->'raw', '{}'::jsonb) || all_data end,
          updated_at = now()
        where id = prospect_id_value;
      end if;
      duplicate_count := duplicate_count + 1;
    end if;

    for identifier in select value from jsonb_array_elements(row_data->'identifiers')
    loop
      insert into public.prospect_identifiers(type, value, prospect_id)
      values (identifier->>'type', identifier->>'value', prospect_id_value)
      on conflict (type, value) do nothing;
    end loop;

    insert into public.prospect_fields(field_name)
    select fields.field_name
    from jsonb_object_keys(coalesce(row_data->'raw', '{}'::jsonb)) as fields(field_name)
    where fields.field_name <> ''
    on conflict (field_name) do update set last_seen_at = now();

    -- The raw payload lives on list_rows (below) only; this link is now just a link.
    insert into public.list_memberships(list_id, prospect_id, import_id)
    values (p_list_id, prospect_id_value, p_import_id)
    on conflict (list_id, prospect_id) do update set
      import_id = excluded.import_id,
      imported_at = now();

    insert into public.list_rows(list_id, prospect_id, import_id, source_row_number, raw_data)
    values (p_list_id, prospect_id_value, p_import_id, source_row_number_value, coalesce(row_data->'raw', '{}'::jsonb))
    on conflict (import_id, source_row_number) do update set
      prospect_id = excluded.prospect_id,
      raw_data = excluded.raw_data,
      imported_at = now();
  end loop;

  processed := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  unique_added := new_count;
  duplicates_linked := duplicate_count;
  skipped := skipped_count;

  update public.imports set
    processed_rows = processed_rows + processed,
    unique_added = imports.unique_added + new_count,
    duplicates_linked = imports.duplicates_linked + duplicate_count
  where id = p_import_id;

  return next;
end;
$$;


ALTER FUNCTION public.import_prospect_batch_v2(p_import_id text, p_list_id text, p_rows jsonb) OWNER TO postgres;

--
-- Name: import_prospect_batch_v3(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_prospect_batch_v3(p_import_id text, p_list_id text, p_rows jsonb) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  base_result record;
  cross_client_duplicates integer := 0;
begin
  select * into base_result
  from public.import_prospect_batch_v2(p_import_id, p_list_id, p_rows);

  select count(*)::integer into cross_client_duplicates
  from public.list_rows lr
  join public.lists current_list on current_list.id = p_list_id
  where lr.import_id = p_import_id
    and lr.prospect_id is not null
    and lr.source_row_number in (
      select coalesce(nullif(item.value->>'sourceRowNumber', '')::integer, 0)
      from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) item(value)
    )
    and exists (
      select 1
      from public.list_memberships other_membership
      join public.lists other_list on other_list.id = other_membership.list_id
      where other_membership.prospect_id = lr.prospect_id
        and other_list.client_id <> current_list.client_id
        and other_membership.imported_at < lr.imported_at
    );

  update public.imports set
    duplicates_linked = greatest(0, imports.duplicates_linked - base_result.duplicates_linked + cross_client_duplicates)
  where id = p_import_id;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := cross_client_duplicates;
  skipped := base_result.skipped;
  return next;
end;
$$;


ALTER FUNCTION public.import_prospect_batch_v3(p_import_id text, p_list_id text, p_rows jsonb) OWNER TO postgres;

--
-- Name: import_prospect_batch_v4(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_prospect_batch_v4(p_import_id text, p_list_id text, p_rows jsonb) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  base_result record;
  row_data jsonb;
  prospect_id_value text;
begin
  select * into base_result
  from public.import_prospect_batch_v3(p_import_id, p_list_id, p_rows);

  for row_data in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    select lr.prospect_id into prospect_id_value
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.source_row_number = coalesce(nullif(row_data->>'sourceRowNumber', '')::integer, 0);

    if prospect_id_value is null then continue; end if;

    update public.prospects set
      keywords = (
        select coalesce(array_agg(minimum_value order by lower_value), '{}'::text[])
        from (
          select lower(value) as lower_value, min(value) as minimum_value
          from unnest(prospects.keywords || array(
            select jsonb_array_elements_text(coalesce(row_data->'keywords', '[]'::jsonb))
          )) value
          where btrim(value) <> ''
          group by lower(value)
        ) unique_keywords
      ),
      updated_at = now()
    where id = prospect_id_value;

    update public.companies set
      employee_count_min = coalesce(companies.employee_count_min, nullif(row_data->>'companyEmployeeCountMin', '')::integer),
      employee_count_max = case
        when companies.employee_count_min is not null then companies.employee_count_max
        else nullif(row_data->>'companyEmployeeCountMax', '')::integer
      end,
      -- An explicit Company Location column wins; otherwise compose it from the
      -- parts, so the single Location filter is always populated.
      location = case when companies.location = '' then coalesce(
        nullif(btrim(coalesce(row_data->>'companyLocation', '')), ''),
        nullif(concat_ws(', ',
          nullif(btrim(coalesce(row_data->>'companyCity', '')), ''),
          nullif(btrim(coalesce(row_data->>'companyState', '')), ''),
          nullif(btrim(coalesce(row_data->>'companyCountry', '')), '')), ''),
        '') else companies.location end,
      city = case when companies.city = '' then coalesce(row_data->>'companyCity', '') else companies.city end,
      state = case when companies.state = '' then coalesce(row_data->>'companyState', '') else companies.state end,
      country = case when companies.country = '' then coalesce(row_data->>'companyCountry', '') else companies.country end,
      updated_at = now()
    where id = (select company_id from public.prospects where id = prospect_id_value);
  end loop;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;


ALTER FUNCTION public.import_prospect_batch_v4(p_import_id text, p_list_id text, p_rows jsonb) OWNER TO postgres;

--
-- Name: import_prospect_batch_v5(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $$
declare
  base_result record;
begin
  select * into base_result
  from public.import_prospect_batch_v4(p_import_id, p_list_id, p_rows);

  -- Only the prospects touched by THIS chunk, not every row of the import.
  perform public.reindex_prospects(array(
    select distinct lr.prospect_id
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.prospect_id is not null
      and lr.source_row_number = any(
        select (elem->>'sourceRowNumber')::integer
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as elem
        where nullif(elem->>'sourceRowNumber', '') is not null
      )
  ));

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;


ALTER FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb) OWNER TO postgres;

--
-- Name: import_prospect_batch_v5(text, text, jsonb, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb, p_row_offset integer) RETURNS TABLE(processed integer, unique_added integer, duplicates_linked integer, skipped integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $$
declare
  base_result record;
  committed_offset integer;
  batch_size integer := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
begin
  if p_row_offset is null or p_row_offset < 0 then
    raise exception 'A non-negative row offset is required' using errcode = '22023';
  end if;

  select i.committed_row_offset
  into committed_offset
  from public.imports i
  where i.id = p_import_id
    and i.list_id = p_list_id
    and i.status = 'processing'
  for update;

  if not found then
    raise exception 'Import not found or already completed' using errcode = 'P0002';
  end if;

  if p_row_offset + batch_size <= committed_offset then
    return query select batch_size, 0, 0, 0;
    return;
  end if;

  select * into base_result
  from public.import_prospect_batch_v4(p_import_id, p_list_id, p_rows);

  -- Only the prospects touched by THIS chunk, not every row of the import.
  perform public.reindex_prospects(array(
    select distinct lr.prospect_id
    from public.list_rows lr
    where lr.import_id = p_import_id
      and lr.prospect_id is not null
      and lr.source_row_number = any(
        select (elem->>'sourceRowNumber')::integer
        from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as elem
        where nullif(elem->>'sourceRowNumber', '') is not null
      )
  ));

  update public.imports
  set committed_row_offset = greatest(committed_row_offset, p_row_offset + batch_size)
  where id = p_import_id and list_id = p_list_id;

  processed := base_result.processed;
  unique_added := base_result.unique_added;
  duplicates_linked := base_result.duplicates_linked;
  skipped := base_result.skipped;
  return next;
end;
$$;


ALTER FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb, p_row_offset integer) OWNER TO postgres;

--
-- Name: inherit_company_icp_validation_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.inherit_company_icp_validation_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_company_id text;
begin
  if new.icp_verified then return new; end if;

  select p.company_id into v_company_id
  from public.prospects p
  where p.id = new.prospect_id;

  if v_company_id is not null and exists (
    select 1
    from public.client_company_icp_validations validation
    where validation.client_id = new.client_id
      and validation.company_id = v_company_id
  ) then
    new.icp_verified := true;
    new.verified_at := now();
    new.verified_by := 'company:' || v_company_id;
  end if;

  return new;
end;
$$;


ALTER FUNCTION public.inherit_company_icp_validation_v1() OWNER TO postgres;

--
-- Name: integration_destinations_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.integration_destinations_v1() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select coalesce(jsonb_agg(to_jsonb(d)),'[]'::jsonb) from (
    select m.client_id,m.campaign_id,m.campaign_name,m.updated_at,
      (c.connected and c.generation=m.generation) as connection_current
    from prospect_integrations.client_campaigns m
    join public.integration_connections c on c.provider='smartlead'
    where m.enabled order by m.client_id,m.campaign_id
  ) d;
$$;


ALTER FUNCTION public.integration_destinations_v1() OWNER TO postgres;

--
-- Name: integration_job_status_v1(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.integration_job_status_v1(p_actor text, p_job uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select coalesce(jsonb_agg(to_jsonb(s)),'[]'::jsonb) from (
   select j.id,j.client_id,j.campaign_id,j.mode,j.status,j.created_at,j.expires_at,
     (select sum(jsonb_array_length(b.payload)) from prospect_integrations.batches b where b.job_id=j.id) as total,
     (select count(*) from prospect_integrations.batches b where b.job_id=j.id and b.status='completed') as completed_batches,
     (select count(*) from prospect_integrations.batches b where b.job_id=j.id) as batches
   from prospect_integrations.jobs j where j.actor=p_actor and (p_job is null or j.id=p_job)
   order by j.created_at desc limit 50
 ) s;
$$;


ALTER FUNCTION public.integration_job_status_v1(p_actor text, p_job uuid) OWNER TO postgres;

--
-- Name: integration_selection_v1(text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.integration_selection_v1(p_client text, p_ids text[]) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_result jsonb;
begin
  if p_ids is null or cardinality(p_ids) not between 1 and 400
    or exists(select 1 from unnest(p_ids) x where x is null or length(x) not between 1 and 200)
    or not exists(select 1 from public.clients where id=p_client) then
    raise exception 'Invalid selection' using errcode='22023'; end if;
  if (select count(*) from public.prospects where id=any(p_ids))<>(select count(distinct x) from unnest(p_ids) x) then
    raise exception 'Selection changed; reload prospects' using errcode='22023'; end if;
  if exists(select 1 from public.prospects where id=any(p_ids) and octet_length(all_data::text)>65536) then
    raise exception 'Source record exceeds preview size limit' using errcode='22023'; end if;
  select jsonb_agg(jsonb_build_object('id',p.id,'fields',jsonb_build_object(
    'first_name',p.first_name,'last_name',p.last_name,'work_email',p.work_email,'personal_email',p.personal_email,
    'company_name',coalesce(c.name,''),'website',coalesce(c.domain,''),'phone_number',p.mobile_number,
    'location',concat_ws(', ',nullif(p.city,''),nullif(p.state,''),nullif(p.country,'')),
    'linkedin_profile',p.linkedin_url,'title',p.title), 'custom',p.all_data,
    'suppressed',exists(select 1 from public.client_prospects cp where cp.client_id=p_client and cp.prospect_id=p.id and cp.status='blocked')
      or exists(select 1 from public.client_blocklist b where b.client_id=p_client and b.value<>'' and (
        (b.kind='email' and b.value in (lower(btrim(p.work_email)),lower(btrim(p.personal_email))))
        or (b.kind='domain' and b.value in (lower(coalesce(c.normalized_domain,'')),lower(split_part(p.work_email,'@',2)),lower(split_part(p.personal_email,'@',2))))))) order by p.id)
    into v_result from public.prospects p left join public.companies c on c.id=p.company_id where p.id=any(p_ids);
  if octet_length(v_result::text)>2097152 then raise exception 'Selection exceeds preview byte limit' using errcode='22023'; end if;
  return v_result;
end;
$$;


ALTER FUNCTION public.integration_selection_v1(p_client text, p_ids text[]) OWNER TO postgres;

--
-- Name: jsonb_project_v1(jsonb, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.jsonb_project_v1(p_row jsonb, p_keys text[]) RETURNS jsonb
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  select case
    when p_keys is null or cardinality(p_keys) = 0 then p_row
    else coalesce(
      (select jsonb_object_agg(entry.key, entry.value)
       from jsonb_each(p_row) entry
       where entry.key = any (p_keys)),
      '{}'::jsonb)
  end;
$$;


ALTER FUNCTION public.jsonb_project_v1(p_row jsonb, p_keys text[]) OWNER TO postgres;

--
-- Name: keyword_tag_variants_v1(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.keyword_tag_variants_v1(p_values text[]) RETURNS text[]
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    SET search_path TO 'public'
    AS $$
  select coalesce(array(
    select distinct value
    from (
      select unnest(p_values) as value
      union
      select lower(unnest(p_values))
    ) both_cases
    where value is not null and value <> ''
  ), array[]::text[]);
$$;


ALTER FUNCTION public.keyword_tag_variants_v1(p_values text[]) OWNER TO postgres;

--
-- Name: linked_prospect_total_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.linked_prospect_total_v1(p_search text DEFAULT ''::text) RETURNS bigint
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $$
declare
  v_search text := btrim(coalesce(p_search, ''));
begin
  -- No parameter in this predicate, so it plans as an index-only scan over
  -- idx_prospect_index_company_id (12MB) rather than the 1,332MB heap.
  if v_search = '' then
    return (
      select count(*)::bigint
      from public.prospect_index pi
      where pi.company_id is not null
    );
  end if;

  return (
    select count(*)::bigint
    from public.prospect_index pi
    where pi.company_id is not null
      and (pi.company_name ilike '%' || v_search || '%'
        or pi.company_domain ilike '%' || v_search || '%')
  );
end;
$$;


ALTER FUNCTION public.linked_prospect_total_v1(p_search text) OWNER TO postgres;

--
-- Name: list_workspace(text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.list_workspace(p_list_id text, p_search text DEFAULT ''::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    SET statement_timeout TO '30s'
    AS $_$
declare v_search text:=btrim(coalesce(p_search,'')); v_match text:='true';
begin
  if v_search<>'' then
    v_match:=format($where$
      (concat_ws(' ',pi.full_name,pi.work_email,pi.title,pi.company_name) ilike %1$L
       or exists(select 1 from public.list_rows lr
         where lr.list_id=lm.list_id and lr.prospect_id=lm.prospect_id and lr.import_id=lm.import_id
           and lr.raw_data::text ilike %1$L))
    $where$,'%'||v_search||'%');
  end if;
  return query execute format($sql$
    with matched as materialized (
      select lm.prospect_id,lm.import_id,lm.imported_at
      from public.list_memberships lm
      join public.prospect_index pi on pi.id=lm.prospect_id
      where lm.list_id=$1 and (%1$s)
    ), page as (
      select * from matched order by imported_at desc,prospect_id limit $2 offset $3
    ), hydrated as (
      select page.imported_at,page.prospect_id,
        to_jsonb(pi)||jsonb_build_object('list_data',coalesce(source.raw_data,'{}'::jsonb),
          'imported_at',page.imported_at,'client_date_contacted',cp.date_added,
          'last_contacted_at',cp.date_added::timestamp at time zone 'UTC',
          'next_eligible_at',cp.date_added+coalesce(settings.cooldown_days,90),
          'eligible',cp.date_added is null or cp.date_added+coalesce(settings.cooldown_days,90)<=(now() at time zone 'UTC')::date) as row_data
      from page join public.prospect_index pi on pi.id=page.prospect_id
      join public.lists l on l.id=$1
      left join public.client_prospects cp on cp.client_id=l.client_id and cp.prospect_id=page.prospect_id
      left join public.client_settings settings on settings.client_id=l.client_id
      left join lateral (
        select lr.raw_data from public.list_rows lr
        where lr.list_id=$1 and lr.prospect_id=page.prospect_id and lr.import_id=page.import_id
        order by lr.id desc limit 1
      ) source on true
    ) select coalesce((select jsonb_agg(row_data order by imported_at desc,prospect_id) from hydrated),'[]'::jsonb),
      (select count(*) from matched)
  $sql$,v_match) using p_list_id,greatest(1,least(coalesce(p_limit,50),100)),greatest(0,coalesce(p_offset,0));
end;
$_$;


ALTER FUNCTION public.list_workspace(p_list_id text, p_search text, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: merge_prospects(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.merge_prospects(p_keep_id text, p_merge_id text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
begin
  if p_keep_id = p_merge_id then raise exception 'Choose two different prospects.'; end if;
  if not exists (select 1 from public.prospects where id = p_keep_id) or not exists (select 1 from public.prospects where id = p_merge_id) then
    raise exception 'Prospect not found.';
  end if;

  update public.prospects as keep_record set
    first_name = coalesce(nullif(keep_record.first_name, ''), source_record.first_name),
    last_name = coalesce(nullif(keep_record.last_name, ''), source_record.last_name),
    full_name = coalesce(nullif(keep_record.full_name, ''), source_record.full_name),
    work_email = coalesce(nullif(keep_record.work_email, ''), source_record.work_email),
    personal_email = coalesce(nullif(keep_record.personal_email, ''), source_record.personal_email),
    mobile_number = coalesce(nullif(keep_record.mobile_number, ''), source_record.mobile_number),
    linkedin_url = coalesce(nullif(keep_record.linkedin_url, ''), source_record.linkedin_url),
    title = coalesce(nullif(keep_record.title, ''), source_record.title),
    seniority = coalesce(nullif(keep_record.seniority, ''), source_record.seniority),
    department = coalesce(nullif(keep_record.department, ''), source_record.department),
    city = coalesce(nullif(keep_record.city, ''), source_record.city),
    state = coalesce(nullif(keep_record.state, ''), source_record.state),
    country = coalesce(nullif(keep_record.country, ''), source_record.country),
    location = coalesce(nullif(keep_record.location, ''), source_record.location),
    company_id = coalesce(keep_record.company_id, source_record.company_id),
    all_data = source_record.all_data || keep_record.all_data,
    updated_at = now()
  from public.prospects as source_record
  where keep_record.id = p_keep_id and source_record.id = p_merge_id;

  insert into public.list_memberships(list_id, prospect_id, import_id, imported_at)
  select list_id, p_keep_id, import_id, imported_at from public.list_memberships where prospect_id = p_merge_id
  on conflict (list_id, prospect_id) do nothing;
  delete from public.list_memberships where prospect_id = p_merge_id;
  update public.list_rows set prospect_id = p_keep_id where prospect_id = p_merge_id;
  update public.prospect_identifiers set prospect_id = p_keep_id where prospect_id = p_merge_id;
  insert into public.prospect_tag_links(prospect_id, tag_id)
  select p_keep_id, tag_id from public.prospect_tag_links where prospect_id = p_merge_id on conflict do nothing;
  delete from public.prospect_tag_links where prospect_id = p_merge_id;
  update public.contact_events set prospect_id = p_keep_id where prospect_id = p_merge_id;
  delete from public.prospects where id = p_merge_id;
  return jsonb_build_object('kept', p_keep_id, 'merged', p_merge_id);
end;
$$;


ALTER FUNCTION public.merge_prospects(p_keep_id text, p_merge_id text) OWNER TO postgres;

--
-- Name: normalize_job_title_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.normalize_job_title_v1(p_title text) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.normalize_job_title_v1(p_title text) OWNER TO postgres;

--
-- Name: operation_status_v1(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.operation_status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb DEFAULT NULL::jsonb) RETURNS TABLE(status text, total_items bigint, applied_items bigint, excluded_count bigint, stale boolean, frozen_at timestamp with time zone, error text, result jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '10s'
    AS $$
declare
  v_result jsonb;
begin
  -- Read under the same (id, actor) predicate status_v1 uses, so a job that is
  -- not the caller's cannot leak its result through this column.
  select j.result into v_result from prospect_operations.operation_jobs j
  where j.id = p_job_id and j.actor = p_actor;
  return query
  select base.status, base.total_items, base.applied_items, base.excluded_count,
         base.stale, base.frozen_at, base.error, v_result
  from prospect_operations.status_v1(p_job_id, p_actor, p_version_vector) as base;
end;
$$;


ALTER FUNCTION public.operation_status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb) OWNER TO postgres;

--
-- Name: parse_employee_count_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.parse_employee_count_v1(p_value text) RETURNS TABLE(minimum integer, maximum integer)
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  with normalized as (
    select lower(replace(btrim(coalesce(p_value, '')), ',', '')) as value
  ), extracted as (
    select value, array_agg(least(2147483647::bigint, match[1]::bigint)::integer) as numbers
    from normalized
    left join lateral regexp_matches(value, '([0-9]+)', 'g') match on true
    group by value
  )
  select
    case when cardinality(numbers) > 0 then least(numbers[1], coalesce(numbers[2], numbers[1])) end,
    case
      when cardinality(numbers) = 0 then null
      when value like '%+%' or value ~ '(more|over|above)' then null
      else greatest(numbers[1], coalesce(numbers[2], numbers[1]))
    end
  from extracted;
$$;


ALTER FUNCTION public.parse_employee_count_v1(p_value text) OWNER TO postgres;

--
-- Name: people_scope_company_ids_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb) RETURNS TABLE(company_id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_search text := coalesce(p_scope->>'search', '');
  v_filters jsonb := coalesce(p_scope->'filters', '[]'::jsonb);
  v_limit integer := case
    when coalesce(p_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((p_scope->>'limit')::bigint, 250000))::integer
    else 250000 end;
  v_has_cap boolean := exists (
    select 1 from jsonb_array_elements(v_filters) item
    where item->>'field' = '__max_people_per_company');
  v_prefilter text;
  v_complete text;
  v_sql text := 'select distinct pi.company_id from public.prospect_index pi where pi.company_id is not null';
begin
  if p_scope is null then return; end if;
  if v_has_cap then
    return query
      select distinct pi.company_id
      from public.prospect_capped_candidate_ids_v1(v_search, v_filters, p_client_id, '{}'::jsonb) candidate
      join public.prospect_index pi on pi.id = candidate.prospect_id
      where pi.company_id is not null
      order by pi.company_id
      limit v_limit;
    return;
  end if;
  v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
  if p_client_id is not null then
    v_sql := v_sql || format(' and pi.client_ids @> array[%L]', p_client_id);
  end if;
  if v_prefilter <> 'true' then v_sql := v_sql || ' and (' || v_prefilter || ')'; end if;
  if btrim(v_search) <> '' or v_filters <> '[]'::jsonb then
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_sql := v_sql || ' and (' || coalesce(v_complete,
      format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  end if;
  v_sql := v_sql || format(' order by pi.company_id limit %s', v_limit);
  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb) OWNER TO postgres;

--
-- Name: prepare_company_scope_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prepare_company_scope_v1(p_owner_id text, p_scope jsonb) RETURNS TABLE(set_id uuid, status text, row_count bigint, error text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '5s'
    AS $$
DECLARE
  v_search text := coalesce(p_scope->>'search','');
  v_filters jsonb := coalesce(p_scope->'filters','[]'::jsonb);
  v_versions jsonb := public.data_versions_v1(array['company']);
  v_hash text;
  v_row prospect_results.result_sets%rowtype;
BEGIN
  IF coalesce(btrim(p_owner_id),'') = '' OR (btrim(v_search)='' AND v_filters='[]'::jsonb) THEN
    RAISE EXCEPTION 'An owner and company search are required' USING errcode='22023';
  END IF;
  -- Versions are in the identity, not merely an after-the-fact stale flag.
  -- The creation bucket keeps expired rows from conflicting with replacements.
  -- Reuse below is by full content and version for the entire 24-hour TTL,
  -- including builds that straddle an hour boundary.
  v_hash := 'company-pivot-v1:' || md5(jsonb_build_array(v_search,v_filters,v_versions,date_trunc('hour',now()))::text);
  -- Concurrent browser polls share one job. The lock is held only while
  -- enqueueing, never while the text search runs.
  PERFORM pg_advisory_xact_lock(hashtextextended('company-pivot-queue-v1',0));
  SELECT * INTO v_row FROM prospect_results.result_sets s
    WHERE s.owner_id=p_owner_id AND s.entity_type='company' AND s.client_scope=''
      AND s.content_hash LIKE 'company-pivot-v1:%' AND s.expires_at>now()
      AND s.search=v_search AND s.filters=v_filters AND s.version_vector=v_versions
    ORDER BY s.created_at DESC LIMIT 1;
  IF FOUND AND NOT (v_row.status='failed' AND v_row.completed_at < now()-interval '30 seconds') THEN
    RETURN QUERY SELECT v_row.id,v_row.status,v_row.row_count,v_row.error;
    RETURN;
  END IF;
  IF (SELECT count(*) FROM prospect_results.result_sets s WHERE s.owner_id=p_owner_id
        AND s.content_hash LIKE 'company-pivot-v1:%' AND s.status IN ('pending','building') AND s.expires_at>now()) >= 4
    OR (SELECT count(*) FROM prospect_results.result_sets s WHERE s.content_hash LIKE 'company-pivot-v1:%'
        AND s.status IN ('pending','building') AND s.expires_at>now()) >= 12 THEN
    RAISE EXCEPTION 'Several company searches are already being prepared. Please try again shortly.' USING errcode='53300';
  END IF;
  INSERT INTO prospect_results.result_sets
    (owner_id,entity_type,client_scope,content_hash,version_vector,search,filters,expires_at)
  VALUES(p_owner_id,'company','',v_hash,v_versions,v_search,v_filters,now()+interval '24 hours')
  RETURNING * INTO v_row;
  RETURN QUERY SELECT v_row.id,v_row.status,v_row.row_count,v_row.error;
END;
$$;


ALTER FUNCTION public.prepare_company_scope_v1(p_owner_id text, p_scope jsonb) OWNER TO postgres;

--
-- Name: prepare_company_scope_v2(text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prepare_company_scope_v2(p_owner_id text, p_scope jsonb, p_allow_enqueue boolean DEFAULT true) RETURNS TABLE(set_id uuid, status text, row_count bigint, error text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '5s'
    AS $$
DECLARE
  v_search text := coalesce(p_scope->>'search','');
  v_filters jsonb := coalesce(p_scope->'filters','[]'::jsonb);
  v_versions jsonb := public.data_versions_v1(array['company']);
  v_hash text;
  v_row prospect_results.result_sets%rowtype;
BEGIN
  IF coalesce(btrim(p_owner_id),'') = '' OR (btrim(v_search)='' AND v_filters='[]'::jsonb) THEN
    RAISE EXCEPTION 'An owner and company search are required' USING errcode='22023';
  END IF;
  -- Versions are in the identity, not merely an after-the-fact stale flag.
  -- The creation bucket keeps expired rows from conflicting with replacements.
  -- Reuse below is by full content and version for the entire 24-hour TTL,
  -- including builds that straddle an hour boundary.
  v_hash := 'company-pivot-v1:' || md5(jsonb_build_array(v_search,v_filters,v_versions,date_trunc('hour',now()))::text);
  -- Concurrent browser polls share one job. The lock is held only while
  -- enqueueing, never while the text search runs.
  PERFORM pg_advisory_xact_lock(hashtextextended('company-pivot-queue-v1',0));
  SELECT * INTO v_row FROM prospect_results.result_sets s
    WHERE s.owner_id=p_owner_id AND s.entity_type='company' AND s.client_scope=''
      AND s.content_hash LIKE 'company-pivot-v1:%' AND s.expires_at>now()
      AND s.search=v_search AND s.filters=v_filters AND s.version_vector=v_versions
    ORDER BY s.created_at DESC LIMIT 1;
  IF FOUND AND NOT (v_row.status='failed' AND v_row.completed_at < now()-interval '30 seconds') THEN
    RETURN QUERY SELECT v_row.id,v_row.status,v_row.row_count,v_row.error;
    RETURN;
  END IF;
  IF NOT coalesce(p_allow_enqueue,false) THEN
    RETURN QUERY SELECT NULL::uuid,'unavailable'::text,0::bigint,NULL::text;
    RETURN;
  END IF;
  IF (SELECT count(*) FROM prospect_results.result_sets s WHERE s.owner_id=p_owner_id
        AND s.content_hash LIKE 'company-pivot-v1:%' AND s.status IN ('pending','building') AND s.expires_at>now()) >= 4
    OR (SELECT count(*) FROM prospect_results.result_sets s WHERE s.content_hash LIKE 'company-pivot-v1:%'
        AND s.status IN ('pending','building') AND s.expires_at>now()) >= 12 THEN
    RAISE EXCEPTION 'Several company searches are already being prepared. Please try again shortly.' USING errcode='53300';
  END IF;
  INSERT INTO prospect_results.result_sets
    (owner_id,entity_type,client_scope,content_hash,version_vector,search,filters,expires_at)
  VALUES(p_owner_id,'company','',v_hash,v_versions,v_search,v_filters,now()+interval '24 hours')
  RETURNING * INTO v_row;
  RETURN QUERY SELECT v_row.id,v_row.status,v_row.row_count,v_row.error;
END;
$$;


ALTER FUNCTION public.prepare_company_scope_v2(p_owner_id text, p_scope jsonb, p_allow_enqueue boolean) OWNER TO postgres;

--
-- Name: prepared_company_listing_v1(text, uuid, text, jsonb, integer, integer, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prepared_company_listing_v1(p_owner_id text, p_set_id uuid, p_search text, p_filters jsonb, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_known_versions jsonb DEFAULT NULL::jsonb) RETURNS TABLE(result_rows jsonb, total_count integer, covered_count integer, prospect_total integer, total_capped boolean, data_versions jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '10s'
    AS $$
DECLARE v_row prospect_results.result_sets%rowtype; v_versions jsonb; v_count boolean;
BEGIN
  SELECT * INTO v_row FROM prospect_results.result_sets s WHERE s.id=p_set_id AND s.owner_id=p_owner_id
    AND s.entity_type='company' AND s.client_scope='' AND s.company_scope='{}'::jsonb
    AND s.content_hash LIKE 'company-pivot-v1:%' AND s.status='ready' AND s.expires_at>now()
    AND s.search=coalesce(p_search,'') AND s.filters=coalesce(p_filters,'[]'::jsonb);
  IF NOT FOUND THEN RAISE EXCEPTION 'Prepared company search is unavailable' USING errcode='P0002'; END IF;
  IF v_row.version_vector IS DISTINCT FROM public.data_versions_v1(array['company']) THEN
    RAISE EXCEPTION 'Company data changed while preparing this search' USING errcode='40001';
  END IF;
  v_versions := public.data_versions_v1(array['company','prospect']);
  v_count := p_known_versions IS NULL OR p_known_versions<>v_versions;
  RETURN QUERY
    WITH page AS (
      SELECT c.id,c.name,c.domain,c.created_at,c.prospect_count,c.client_count
      FROM public.companies c JOIN prospect_results.result_set_items i ON i.entity_id=c.id AND i.result_set_id=p_set_id
      ORDER BY c.prospect_count DESC,lower(c.name),c.id
      LIMIT greatest(1,least(coalesce(p_limit,50),5000)) OFFSET greatest(0,coalesce(p_offset,0))
    ), counted AS (
      SELECT count(*)::integer n,count(*) FILTER(WHERE c.prospect_count>0)::integer covered,
        coalesce(sum(c.prospect_count),0)::integer prospects
      FROM public.companies c JOIN prospect_results.result_set_items i ON i.entity_id=c.id AND i.result_set_id=p_set_id
      WHERE v_count
    ) SELECT coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY page.prospect_count DESC,lower(page.name),page.id) FROM page),'[]'::jsonb),
      CASE WHEN v_count THEN counted.n END,CASE WHEN v_count THEN counted.covered END,
      CASE WHEN v_count THEN counted.prospects END,false,v_versions FROM counted;
END;
$$;


ALTER FUNCTION public.prepared_company_listing_v1(p_owner_id text, p_set_id uuid, p_search text, p_filters jsonb, p_limit integer, p_offset integer, p_known_versions jsonb) OWNER TO postgres;

--
-- Name: prospect_capped_candidate_ids_v1(text, jsonb, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_capped_candidate_ids_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(prospect_id text, created_at timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_clean_filters jsonb;
  v_cap_items integer;
  v_cap_text text;
  v_cap integer;
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean;
  v_prefilter text;
  v_complete text;
  v_match text;
  v_scope_cte text := '';
  v_scope_join text := '';
  v_sql text;
begin
  if jsonb_typeof(v_filters) <> 'array' then
    raise exception 'Filters must be an array.' using errcode = '22023';
  end if;

  select count(*), min(item->'values'->>0)
    into v_cap_items, v_cap_text
  from jsonb_array_elements(v_filters) item
  where item->>'field' = '__max_people_per_company';

  if v_cap_items <> 1 or coalesce(v_cap_text, '') !~ '^[1-9][0-9]{0,3}$' then
    raise exception 'Max people per company must be one integer from 1 to 1000.' using errcode = '22023';
  end if;
  v_cap := v_cap_text::integer;
  if v_cap > 1000 then
    raise exception 'Max people per company must be one integer from 1 to 1000.' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(item order by ordinal), '[]'::jsonb)
    into v_clean_filters
  from jsonb_array_elements(v_filters) with ordinality entries(item, ordinal)
  where item->>'field' <> '__max_people_per_company';

  v_prefilter := public.prospect_prefilter_sql(coalesce(p_search, ''), v_clean_filters);
  v_complete := public.prospect_filter_sql_v1(coalesce(p_search, ''), v_clean_filters);
  v_match := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || '(' || coalesce(v_complete, format(
      'public.prospect_index_matches_v1(pi, %L, %L::jsonb)',
      coalesce(p_search, ''), v_clean_filters::text)) || ')';

  v_has_scope := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  if v_has_scope then
    v_scope_cte := format(
      'eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  end if;

  v_sql := format($sql$
    with %1$s matched as materialized (
      select pi.id, pi.created_at, pi.company_id
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L])
        and (%4$s)
    ), ranked as (
      select matched.id, matched.created_at,
        row_number() over (
          partition by coalesce(matched.company_id, '__person__:' || matched.id)
          order by matched.created_at desc, matched.id desc
        ) as company_rank
      from matched
    )
    select ranked.id, ranked.created_at
    from ranked
    where ranked.company_rank <= %5$s
  $sql$, v_scope_cte, v_scope_join, p_client_id, v_match, v_cap::text);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.prospect_capped_candidate_ids_v1(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: prospect_effective_filter_sql_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_effective_filter_sql_v1(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $$
declare
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
begin
  if v_complete is null then return null; end if;
  if v_prefilter <> 'true' then
    return '(' || v_prefilter || ') and (' || v_complete || ')';
  end if;
  return v_complete;
end;
$$;


ALTER FUNCTION public.prospect_effective_filter_sql_v1(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: prospect_filter_sql_v1(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_filter_sql_v1(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $_$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  candidate_expr text;
  raw_expr text;
  match_exprs text[];
  value_parts text[];
  raw_values text[];
  lowered text[];
  value_text text;
  company_expr text;
  company_contains_expr text;
  company_inner text;
  company_negate boolean;
  company_unknown boolean;
  range_min text;
  range_max text;
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    field_key := coalesce(filter_item->>'field', '');

    -- Every operator the row function implements is translated, so no filter set
    -- falls back wholesale because of one advanced filter among thirty.

    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    lowered := array(select lower(value) from unnest(raw_values) value);

    -- Client ICP tags. Values are tag ids: a tag knows its own client, so the
    -- predicate needs no join and no client argument.
    if field_key = '__client_tags' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format($t$(not exists (select 1 from public.prospect_tag_links ptl
          where ptl.prospect_id = pi.id and ptl.tag_id = any (%L::text[])))$t$, raw_values);
      else
        conjuncts := conjuncts || format($t$(exists (select 1 from public.prospect_tag_links ptl
          where ptl.prospect_id = pi.id and ptl.tag_id = any (%L::text[])))$t$, raw_values);
      end if;
      continue;
    end if;


    -- Include or exclude whole clients, by id. Names are display text and are
    -- editable; ids are what pi.client_ids holds and what the GIN index covers.
    if field_key = '__client_ids' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format('(not (pi.client_ids && %L::text[]))', raw_values);
      else
        conjuncts := conjuncts || format('(pi.client_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;

    -- Include or exclude whole lists, by id. Same shape as __client_ids and for
    -- the same reason: pi.list_ids is the identity array the GIN index covers.
    if field_key = '__list_ids' then
      if cardinality(raw_values) = 0 then continue; end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || format('(not (pi.list_ids && %L::text[]))', raw_values);
      else
        conjuncts := conjuncts || format('(pi.list_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;


    -- Client-scoped state. Values are client ids. contains/equals asks for the
    -- state, not_contains/not_equals for its complement.
    if field_key in ('__lead', '__contactable') then
      -- No values restricts nothing, which is what the row matcher does too.
      -- Returning null here would push every surface onto the row matcher for
      -- the whole query.
      if cardinality(raw_values) = 0 then continue; end if;
      if field_key = '__lead' then
        candidate_expr := format($lead$exists (select 1 from public.client_prospects cp
          where cp.prospect_id = pi.id and cp.is_lead and cp.client_id = any (%L::text[]))$lead$, raw_values);
      else
        candidate_expr := format($contact$exists (select 1 from public.client_prospects cp
          where cp.prospect_id = pi.id and cp.status = 'active' and cp.client_id = any (%L::text[])
            and (cp.date_added is null or cp.date_added <= ((now() at time zone 'UTC')::date
              - coalesce((select s.cooldown_days from public.client_settings s where s.client_id = cp.client_id), 90))))$contact$, raw_values);
      end if;
      if operator_key in ('not_contains', 'not_equals') then
        conjuncts := conjuncts || ('(not ' || candidate_expr || ')');
      else
        conjuncts := conjuncts || ('(' || candidate_expr || ')');
      end if;
      continue;
    end if;


    -- The company profile. Not carried on prospect_index - read from
    -- public.companies through pi.company_id, which every caller has. See the
    -- header of 20260916090000 for why, and for the measured plans.
    --
    -- Every operator resolves to ONE predicate evaluated against a single
    -- company row, wrapped in exists or not exists. That wrapping is what makes
    -- a prospect with NO company behave exactly as a prospect whose company has
    -- a blank field, which is what prospect_index_matches_v1 does with
    -- coalesce(..., '') and what the two have to agree about.
    if field_key = '__incomplete_company_profile' then
      conjuncts := array_append(conjuncts, 'exists (select 1 from public.companies co'
        || ' where co.id = pi.company_id'
        || ' and btrim(coalesce(array_to_string(co.keywords, '' | ''), '''')) = '''''
        || ' and btrim(coalesce(co.short_description, '''')) = '''')');
      continue;
    end if;

    if field_key in ('__company_industry', '__company_keywords', '__company_description',
                     '__company_technologies', '__company_founded_year', '__company_total_funding') then
      company_expr := case field_key
        when '__company_industry' then 'co.industry'
        when '__company_keywords' then public.company_keyword_expr_sql_v1(filter_item->'scopes', 'co')
        when '__company_description' then 'co.short_description'
        when '__company_technologies' then 'array_to_string(co.technologies, '' | '')'
        when '__company_founded_year' then 'co.founded_year::text'
        else 'co.total_funding'
      end;
      company_expr := format('coalesce(%s, %L)', company_expr, '');
      company_inner := null;
      company_negate := false;

      if operator_key = 'number_ranges' then
        -- Ranges read the typed column, not the text one. Funding parses bigint
        -- bounds: production's maximum is 178 billion, which overflows the
        -- ::integer casts the employee ranges share (20260915090000).
        value_parts := array[]::text[];
        company_unknown := false;
        foreach value_text in array raw_values loop
          if value_text = 'unknown' then company_unknown := true; continue; end if;
          if value_text !~ '^[0-9]+:[0-9]*$' then continue; end if;
          range_min := split_part(value_text, ':', 1);
          range_max := case when value_text ~ '^[0-9]+:[0-9]+$' then split_part(value_text, ':', 2) else null end;
          if field_key = '__company_founded_year' then
            value_parts := value_parts || format('(co.founded_year is not null and co.founded_year >= %s and (%s))',
              range_min, case when range_max is null then 'true' else format('co.founded_year <= %s', range_max) end);
          else
            value_parts := value_parts || format('(co.total_funding_amount is not null and co.total_funding_amount >= %s::bigint and (%s))',
              range_min, case when range_max is null then 'true' else format('co.total_funding_amount <= %s::bigint', range_max) end);
          end if;
        end loop;

        -- "Not known" has to hold for a prospect with no company at all, not
        -- only for a company with a null value - so it is a NOT EXISTS, and the
        -- two halves are OR-ed rather than folded into one subquery.
        company_inner := null;
        if cardinality(value_parts) > 0 then
          company_inner := format('exists (select 1 from public.companies co where co.id = pi.company_id and (%s))',
            array_to_string(value_parts, ' or '));
        end if;
        if company_unknown then
          company_expr := format('not exists (select 1 from public.companies co where co.id = pi.company_id and co.%s is not null)',
            case when field_key = '__company_founded_year' then 'founded_year' else 'total_funding_amount' end);
          company_inner := case when company_inner is null then company_expr
            else '(' || company_inner || ' or ' || company_expr || ')' end;
        end if;
        conjuncts := array_append(conjuncts, coalesce(company_inner, 'false'));
        continue;
      end if;

      if coalesce(filter_item->>'setId', '') <> '' then
        if operator_key <> 'equals' then
          raise exception 'A filter set supports the equals operator only, got %', operator_key
            using errcode = '22023';
        end if;
        company_inner := format(
          'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))',
          (filter_item->>'setId')::uuid, company_expr);
      elsif operator_key = 'empty' then
        company_inner := format('btrim(%s) <> %L', company_expr, '');
        company_negate := true;
      elsif operator_key = 'not_empty' then
        company_inner := format('btrim(%s) <> %L', company_expr, '');
      elsif cardinality(raw_values) = 0 then
        -- Same answer the generic path gives a value operator with no values.
        conjuncts := array_append(conjuncts, 'false');
        continue;
      elsif operator_key = 'boolean' then
        value_parts := array[]::text[];
        foreach value_text in array raw_values loop
          value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)',
            'simple', company_expr, 'simple', value_text);
        end loop;
        company_inner := '(' || array_to_string(value_parts, ' or ') || ')';
      elsif operator_key in ('equals', 'not_equals') then
        value_parts := array[format('lower(%s) = any (%L::text[])', company_expr, lowered)];
        -- A tag array is matched by membership, not by equalling the joined
        -- string, and && is what the GIN index serves. keyword_tag_variants_v1
        -- adds the lowercase spelling because the tag store is lowercase.
        if field_key = '__company_keywords'
           and public.company_keyword_scopes_v1(filter_item->'scopes') ? 'keywords' then
          value_parts := value_parts || format('co.keywords && %L::text[]', public.keyword_tag_variants_v1(raw_values));
        elsif field_key = '__company_technologies' then
          value_parts := value_parts || format('co.technologies && %L::text[]', public.keyword_tag_variants_v1(raw_values));
        end if;
        company_inner := '(' || array_to_string(value_parts, ' or ') || ')';
        company_negate := (operator_key = 'not_equals');
      else
        -- A tag array is matched by overlap, never by substring over a joined
        -- string: 33 ms against 2,983 ms measured on production. The text half
        -- keeps name and description, which are what substrings are for.
        if field_key = '__company_keywords' then
          company_contains_expr := public.company_keyword_text_expr_sql_v1(filter_item->'scopes', 'co');
        elsif field_key in ('__company_industry', '__company_description', '__company_technologies') then
          -- The bare column, so the trigram GIN on it can serve the ilike: a
          -- NULL fails the positive match exactly as coalesce(..., '') does.
          -- See 20260923100000.
          company_contains_expr := case field_key
            when '__company_industry' then 'co.industry'
            when '__company_technologies' then 'public.company_technologies_text_v1(co.technologies)'
            else 'co.short_description' end;
        else
          company_contains_expr := company_expr;
        end if;
        if cardinality(raw_values) > bulk_or_threshold then
          company_inner := format('exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')',
            raw_values, company_contains_expr);
        else
          value_parts := array[]::text[];
          foreach value_text in array raw_values loop
            value_parts := value_parts || format('%s ilike %L', company_contains_expr, '%' || value_text || '%');
          end loop;
          company_inner := '(' || array_to_string(value_parts, ' or ') || ')';
        end if;
        -- Appended rather than replacing the text half, so a search still finds
        -- a company by name or description as well as by tag.
        if field_key = '__company_keywords'
           and public.company_keyword_scopes_v1(filter_item->'scopes') ? 'keywords'
           and cardinality(raw_values) > 0 then
          company_inner := format('(%s or co.keywords && %L::text[])', company_inner,
            public.keyword_tag_variants_v1(raw_values));
        end if;
        company_negate := (operator_key = 'not_contains');
      end if;

      conjuncts := conjuncts || format('%sexists (select 1 from public.companies co where co.id = pi.company_id and (%s))',
        case when company_negate then 'not ' else '' end, company_inner);
      continue;
    end if;

    candidate_expr := case field_key
      when '__name' then 'pi.full_name'
      when '__first_name' then 'pi.first_name'
      when '__last_name' then 'pi.last_name'
      when '__company' then 'pi.company_name'
      when '__company_domain' then 'pi.company_domain' when '__website' then 'pi.company_domain'
      when '__email' then 'concat_ws('' '', pi.work_email, pi.personal_email)'
      when '__work_email' then 'pi.work_email'
      when '__personal_email' then 'pi.personal_email'
      when '__title' then 'pi.title'
      when '__keywords' then 'array_to_string(pi.keywords, '' | '')'
      when '__linkedin' then 'pi.linkedin_url'
      when '__city' then 'pi.city'
      when '__state' then 'pi.state'
      when '__country' then 'pi.country'
      when '__person_location' then 'coalesce(nullif(pi.location, ''''), concat_ws('', '', nullif(pi.city, ''''), nullif(pi.state, ''''), nullif(pi.country, '''')))'
      when '__company_location' then 'concat_ws('', '', nullif(pi.company_location, ''''), nullif(pi.company_city, ''''), nullif(pi.company_state, ''''), nullif(pi.company_country, ''''))'
      when '__company_city' then 'pi.company_city'
      when '__company_state' then 'pi.company_state'
      when '__company_country' then 'pi.company_country'
      when '__seniority' then 'pi.seniority'
      when '__department' then 'pi.department'
      when '__title_department' then 'pi.title_department'
      when '__title_sub_department' then 'pi.title_sub_department'
      when '__title_seniority_tier' then 'pi.title_seniority'
      when '__esp' then 'pi.esp'
      -- Two virtual fields the People panel offers: each concatenates the two
      -- underlying columns so one include/exclude matches either value.
      when '__title_seniority' then 'concat_ws('' '', pi.title, pi.seniority)'
      when '__esp_type' then 'concat_ws('' '', pi.esp, pi.email_provider_type)'
      when '__email_provider_type' then 'pi.email_provider_type'
      when '__icp_verified' then 'array_to_string(pi.icp_verified_client_ids, '' | '')'
      when '__tags' then 'pi.tag_text'
      when '__last_contacted' then 'pi.last_contacted_at::text'
      when '__lists' then 'array_to_string(pi.list_names, '' | '')'
      when '__clients' then 'array_to_string(pi.client_names, '' | '')'
      else case
        when field_key like 'custom:%' then format($c$coalesce((
          select string_agg(entry.value, ' | ' order by entry.key)
          from jsonb_each_text(pi.all_data) entry(key, value)
          where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = %L
        ), '')$c$, substring(field_key from 8))
        else quote_literal('')
      end
    end;
    -- The column as it stands, alongside the coalesce-wrapped form. Positive
    -- comparisons use the raw one: NULL ilike '%%v%%' and NULL = any(...) are both
    -- NULL, which excludes the row, and that is exactly what comparing '' does --
    -- a blank filter value never reaches here. The wrapper is not free, though.
    -- coalesce(pi.title, '') does not match idx_prospect_index_title_lower, so
    -- every equality and substring test was scanning the table past four
    -- perfectly good indexes. Measured on companies: 2,271 ms -> 4.2 ms.
    --
    -- The negative operators keep the wrapper, and must: not(NULL) excludes a
    -- null row where not('' = ...) includes it. Those are different answers, and
    -- the row function gives the second one.
    -- The two virtual fields whose candidate is a concatenation of two real
    -- columns. For a substring test the join is exactly right -- "contains
    -- google" should hit either half. For an EQUALITY test it is nonsense: the
    -- value is always "google workspace mailbox provider", so nothing a person
    -- could type ever equalled it, on 649,288 of 681,085 rows. The panel offers
    -- no suggestions for these two fields either (prospect_filter_values_v3
    -- returns nothing for them, against 10 values for __esp and 4 for
    -- __email_provider_type), so there was no way to discover the joined string
    -- and no saved view can be relying on it.
    --
    -- Equality therefore tests the underlying columns instead, which is what the
    -- filter's own description has always promised: "Matches the ESP or the
    -- email provider type". Substring tests keep the concatenation, because
    -- narrowing those WOULD lose matches that span the join.
    match_exprs := case field_key
      when '__esp_type' then array['pi.esp', 'pi.email_provider_type']
      when '__title_seniority' then array['pi.title', 'pi.seniority']
      else null
    end;
    raw_expr := candidate_expr;
    candidate_expr := format('coalesce(%s, %L)', candidate_expr, '');

    -- A durable filter set: the values are rows in prospect_filters, addressed
    -- by id, instead of thousands of literals inlined in this SQL. Ownership was
    -- already checked by public.resolve_filter_set_v1; this only compiles the
    -- membership test. The ::uuid cast is the injection guard - anything that is
    -- not a uuid raises here, before %L ever sees it.
    if coalesce(filter_item->>'setId', '') <> '' then
      if operator_key <> 'equals' then
        raise exception 'A filter set supports the equals operator only, got %', operator_key
          using errcode = '22023';
      end if;
      conjuncts := conjuncts || format(
        'exists (select 1 from prospect_filters.filter_set_values fsv where fsv.filter_set_id = %L::uuid and fsv.normalized_value = lower(%s))',
        (filter_item->>'setId')::uuid, candidate_expr);
      continue;
    end if;

    if operator_key = 'empty' then
      conjuncts := conjuncts || format('btrim(%s) = %L', candidate_expr, '');
      continue;
    elsif operator_key = 'not_empty' then
      conjuncts := conjuncts || format('btrim(%s) <> %L', candidate_expr, '');
      continue;
    end if;

    -- The row function evaluates its value operators against an empty list as
    -- "no value matched", which rejects the row. Reproduce that rather than
    -- treating a value-less filter as absent.
    if cardinality(raw_values) = 0 then
      conjuncts := array_append(conjuncts, 'false');
      continue;
    end if;

    if operator_key = 'boolean' then
      -- Exactly the row function's branch, inline: to_tsquery can raise on a
      -- malformed compiled query, and it raises there too, so behaviour matches.
      if cardinality(raw_values) > bulk_or_threshold then
        conjuncts := conjuncts || format(
          'exists (select 1 from unnest(%L::text[]) needle where to_tsvector(''simple'', %s) @@ to_tsquery(''simple'', needle))',
          raw_values, candidate_expr);
        continue;
      end if;

      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('to_tsvector(%L, %s) @@ to_tsquery(%L, %L)',
          'simple', candidate_expr, 'simple', value_text);
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
      continue;
    end if;

    if operator_key = 'number_ranges' then
      if field_key <> '__employee_count' then
        conjuncts := array_append(conjuncts, 'false');
        continue;
      end if;
      conjuncts := conjuncts || format($r$exists (
        select 1 from unnest(%L::text[]) as selected(value)
        cross join lateral (
          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
        ) selected_range
        where (selected.value = 'unknown' and pi.employee_count_min is null and pi.employee_count_max is null)
          or (selected.value <> 'unknown' and pi.employee_count_min is not null
            and (selected_range.maximum is null or pi.employee_count_min <= selected_range.maximum)
            and (pi.employee_count_max is null or pi.employee_count_max >= selected_range.minimum))
      )$r$, raw_values);
      continue;
    end if;

    if operator_key = 'equals' then
      -- __lists and __clients also match a whole array element, not only the
      -- joined string, so a list named "A | B" cannot be matched by accident.
      if field_key in ('__lists', '__clients') then
        conjuncts := conjuncts || format('(lower(%s) = any (%L::text[]) or %s && %L::text[])',
          raw_expr, lowered,
          case when field_key = '__lists' then 'pi.list_names' else 'pi.client_names' end,
          raw_values);
      elsif match_exprs is not null then
        conjuncts := conjuncts || ('(' || array_to_string(
          array(select format('lower(%s) = any (%L::text[])', col, lowered) from unnest(match_exprs) col),
          ' or ') || ')');
      else
        conjuncts := conjuncts || format('lower(%s) = any (%L::text[])', raw_expr, lowered);
      end if;
      continue;
    elsif operator_key = 'not_equals' then
      if match_exprs is not null then
        -- The exact negation of the branch above, so not_equals stays the
        -- complement of equals. coalesce is back: not(NULL = any(...)) would
        -- drop a row whose column is null, and the row function keeps it.
        conjuncts := conjuncts || ('(not (' || array_to_string(
          array(select format('lower(coalesce(%s, %L)) = any (%L::text[])', col, '', lowered) from unnest(match_exprs) col),
          ' or ') || '))');
      else
        conjuncts := conjuncts || format('not (lower(%s) = any (%L::text[]))', candidate_expr, lowered);
      end if;
      continue;
    end if;

    -- contains / not_contains: one ILIKE per value, exactly as the row function
    -- tests them. Patterns stay unescaped so behaviour is unchanged.
    -- One array literal and one copy of the candidate expression, rather than a
    -- copy per value. A custom: field's candidate is a whole jsonb subquery, so at
    -- a few thousand values an OR chain becomes megabytes of SQL and the planning
    -- cost alone dominates. Same predicate either way.
    if cardinality(raw_values) > bulk_or_threshold then
      conjuncts := conjuncts || format(
        case when operator_key = 'not_contains'
          then 'not exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')'
          else 'exists (select 1 from unnest(%L::text[]) needle where %s ilike ''%%'' || needle || ''%%'')' end,
        raw_values, case when operator_key = 'not_contains' then candidate_expr else raw_expr end);
      continue;
    end if;

    value_parts := array[]::text[];
    foreach value_text in array raw_values loop
      value_parts := value_parts || format('%s ilike %L',
        case when operator_key = 'not_contains' then candidate_expr else raw_expr end,
        '%' || value_text || '%');
    end loop;

    if operator_key = 'not_contains' then
      conjuncts := conjuncts || ('not (' || array_to_string(value_parts, ' or ') || ')');
    else
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$_$;


ALTER FUNCTION public.prospect_filter_sql_v1(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: prospect_filter_values_cached_v1(text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_filter_values_cached_v1(p_field text, p_client_id text DEFAULT NULL::text, p_limit integer DEFAULT 50) RETURNS TABLE(value text, match_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_client text := coalesce(nullif(btrim(coalesce(p_client_id, '')), ''), '');
  v_version bigint := coalesce((public.data_versions_v1(array['prospect'])->>'prospect')::bigint, 0);
  v_entries jsonb;
begin
  select c.entries into v_entries
  from public.prospect_filter_value_cache c
  where c.field = p_field and c.client_id = v_client and c.data_version = v_version;

  if v_entries is null then
    select coalesce(jsonb_agg(jsonb_build_object('value', v.value, 'count', v.match_count)), '[]'::jsonb)
    into v_entries
    from public.prospect_filter_values_v3(p_field, '', nullif(v_client, ''), 100) v;

    -- Two callers racing produce the same answer, so the loser overwriting the
    -- winner costs nothing and is cheaper than a lock.
    insert into public.prospect_filter_value_cache (field, client_id, data_version, entries, computed_at)
    values (p_field, v_client, v_version, v_entries, now())
    on conflict (field, client_id) do update
      set data_version = excluded.data_version,
          entries = excluded.entries,
          computed_at = excluded.computed_at;
  end if;

  -- jsonb_agg preserved v3's "most common first" ordering; ordinality keeps it.
  return query
  select entry->>'value', (entry->>'count')::bigint
  from jsonb_array_elements(v_entries) with ordinality as t(entry, ord)
  order by t.ord
  limit v_limit;
end;
$$;


ALTER FUNCTION public.prospect_filter_values_cached_v1(p_field text, p_client_id text, p_limit integer) OWNER TO postgres;

--
-- Name: prospect_filter_values_v3(text, text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_filter_values_v3(p_field text, p_search text DEFAULT ''::text, p_client_id text DEFAULT NULL::text, p_limit integer DEFAULT 50) RETURNS TABLE(value text, match_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $_$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_search text := btrim(coalesce(p_search, ''));
  v_from text := 'public.prospect_index ps';
  v_value_expr text;
  v_conditions text[] := array[]::text[];
  v_sql text;
begin
  -- One source expression, chosen here instead of unioned in the query.
  if p_field = '__keywords' then
    v_from := 'public.prospect_index ps cross join lateral unnest(ps.keywords) as item(raw)';
    v_value_expr := 'item.raw';
  elsif p_field = '__lists' then
    v_from := 'public.prospect_index ps cross join lateral unnest(ps.list_names) as item(raw)';
    v_value_expr := 'item.raw';
  elsif p_field = '__clients' then
    v_from := 'public.prospect_index ps cross join lateral unnest(ps.client_names) as item(raw)';
    v_value_expr := 'item.raw';
  elsif p_field = '__tags' then
    v_from := 'public.prospect_index ps'
      || ' join public.prospect_tag_links ptl on ptl.prospect_id = ps.id'
      || ' join public.prospect_tags pt on pt.id = ptl.tag_id'
      || case when p_client_id is null then ''
              else format(' and (pt.client_id is null or pt.client_id = %L)', p_client_id) end;
    v_value_expr := 'pt.name';
  elsif p_field = '__last_contacted' then
    v_value_expr := 'to_char(ps.last_contacted_at at time zone ''UTC'', ''YYYY-MM-DD'')';
    v_conditions := array_append(v_conditions, 'ps.last_contacted_at is not null');
  elsif p_field like 'custom:%' then
    v_value_expr := format($e$coalesce((
      select string_agg(entry.value, ' | ' order by entry.key)
      from jsonb_each_text(ps.all_data) entry(key, value)
      where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = %L
    ), '')$e$, substring(p_field from 8));
  else
    v_value_expr := case p_field
      when '__name' then 'ps.full_name'
      when '__first_name' then 'ps.first_name'
      when '__last_name' then 'ps.last_name'
      when '__company' then 'ps.company_name'
      when '__email' then 'concat_ws('' '', ps.work_email, ps.personal_email)'
      when '__work_email' then 'ps.work_email'
      when '__personal_email' then 'ps.personal_email'
      when '__title' then 'ps.title'
      when '__linkedin' then 'ps.linkedin_url'
      when '__city' then 'ps.city'
      when '__state' then 'ps.state'
      when '__country' then 'ps.country'
      when '__person_location' then 'coalesce(nullif(ps.location, ''''), concat_ws('', '', nullif(ps.city, ''''), nullif(ps.state, ''''), nullif(ps.country, '''')))'
      when '__company_location' then 'concat_ws('', '', nullif(ps.company_location, ''''), nullif(ps.company_city, ''''), nullif(ps.company_state, ''''), nullif(ps.company_country, ''''))'
      when '__company_city' then 'ps.company_city'
      when '__company_state' then 'ps.company_state'
      when '__company_country' then 'ps.company_country'
      when '__seniority' then 'ps.seniority'
      when '__department' then 'ps.department'
      when '__esp' then 'ps.esp'
      when '__email_provider_type' then 'ps.email_provider_type'
      else null
    end;
  end if;

  -- v3 produced '' for an unmapped field and then filtered it out, and had no
  -- branch at all for __employee_count. Both cases returned nothing; so does this.
  if v_value_expr is null then return; end if;

  if p_client_id is not null then
    v_conditions := v_conditions || format('ps.client_ids @> array[%L]::text[]', p_client_id);
  end if;

  -- Pushed into the scan so a trigram index can answer it, rather than being
  -- applied after every row's value has been computed.
  if v_search <> '' then
    v_conditions := v_conditions || format('(%s) ilike %L', v_value_expr, '%' || v_search || '%');
  end if;

  v_sql := format($q$
    select grouped.value, grouped.match_count
    from (
      select min(source.candidate) as value, count(distinct source.prospect_id) as match_count
      from (
        select btrim(%1$s) as candidate, ps.id as prospect_id
        from %2$s
        %3$s
      ) source
      where source.candidate <> ''
      group by lower(source.candidate)
    ) grouped
    order by grouped.match_count desc, lower(grouped.value)
    limit %4$s
  $q$,
    v_value_expr,
    v_from,
    case when cardinality(v_conditions) > 0
      then 'where ' || array_to_string(v_conditions, ' and ') else '' end,
    v_limit::text);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.prospect_filter_values_v3(p_field text, p_search text, p_client_id text, p_limit integer) OWNER TO postgres;

--
-- Name: prospect_filters_need_company_lookup_v1(jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_filters_need_company_lookup_v1(p_filters jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  select exists (
    select 1
    from jsonb_array_elements(case when jsonb_typeof(p_filters) = 'array' then p_filters else '[]'::jsonb end) as item
    where item->>'field' in (
      '__company_industry', '__company_keywords', '__company_description',
      '__company_technologies', '__company_founded_year', '__company_total_funding',
      '__incomplete_company_profile')
  );
$$;


ALTER FUNCTION public.prospect_filters_need_company_lookup_v1(p_filters jsonb) OWNER TO postgres;

--
-- Name: prospect_ids_matching_v1(text, jsonb, text[], integer, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_ids_matching_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_excluded_ids text[] DEFAULT '{}'::text[], p_limit integer DEFAULT 1000, p_after_id text DEFAULT ''::text) RETURNS TABLE(id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $_$
declare
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_sql text;
begin
  v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
    || coalesce(public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb)), format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text));

  v_sql := format($q$
    select pi.id from public.prospect_index pi
    where %s and not (pi.id = any($1)) and pi.id > $2
    order by pi.id
    limit %s
  $q$, v_match_clause, greatest(1, least(coalesce(p_limit, 1000), 5000)));

  return query execute v_sql using coalesce(p_excluded_ids, '{}'::text[]), coalesce(p_after_id, '');
end;
$_$;


ALTER FUNCTION public.prospect_ids_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[], p_limit integer, p_after_id text) OWNER TO postgres;

--
-- Name: prospect_ids_matching_v1(text, jsonb, text, text[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_ids_matching_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_excluded_ids text[] DEFAULT NULL::text[], p_limit integer DEFAULT 200000) RETURNS TABLE(prospect_id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_prefilter text := public.prospect_prefilter_sql(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb));
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_sql text := 'select pi.id from public.prospect_index pi where true';
begin
  if p_client_id is not null then
    v_sql := v_sql || format(' and pi.client_ids @> array[%L]', p_client_id);
  end if;
  if v_has_people then
    if v_prefilter <> 'true' then v_sql := v_sql || ' and (' || v_prefilter || ')'; end if;
    v_sql := v_sql || format(' and (%s)', coalesce(public.prospect_filter_sql_v1(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)), format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text)));
  end if;
  if p_excluded_ids is not null and cardinality(p_excluded_ids) > 0 then
    v_sql := v_sql || format(' and not (pi.id = any (%L::text[]))', p_excluded_ids);
  end if;
  v_sql := v_sql || format(' limit %s', greatest(1, least(coalesce(p_limit, 200000), 1000000)));
  return query execute v_sql;
end;
$$;


ALTER FUNCTION public.prospect_ids_matching_v1(p_search text, p_filters jsonb, p_client_id text, p_excluded_ids text[], p_limit integer) OWNER TO postgres;

--
-- Name: prospect_index_drift(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_index_drift() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '90s'
    AS $$
  select jsonb_build_object(
    'prospects', (select count(*) from public.prospects),
    'indexed', (select count(*) from public.prospect_index),
    'missingFromIndex', (
      select count(*) from (
        select 1 from public.prospects p
        where not exists (select 1 from public.prospect_index pi where pi.id = p.id)
        limit 10000
      ) sample
    ),
    'staleInIndex', (
      select count(*) from (
        select 1 from public.prospects p
        join public.prospect_index pi on pi.id = p.id
        where pi.updated_at < p.updated_at
        limit 10000
      ) sample
    ),
    'queued', (select count(*) from public.reindex_backlog),
    'queuedFailing', (select count(*) from public.reindex_backlog where attempts > 0),
    'oldestQueuedAt', (select min(enqueued_at) from public.reindex_backlog),
    'companies', (select count(*) from public.companies),
    'companyCountsSampled', 2000,
    -- Companies in the sample whose stored prospect_count or client_count differs
    -- from what recompute_company_counts_bulk would write for them right now.
    'companyCountsDrifted', (
      with sample as (
        select id, prospect_count, client_count
        from public.companies
        order by random()
        limit 2000
      )
      select count(*)
      from sample s
      left join lateral (
        select count(distinct pi.id)::integer as prospect_count,
          count(distinct cid)::integer as client_count
        from public.prospect_index pi
        left join lateral unnest(pi.client_ids) as cid on true
        where pi.company_id = s.id
      ) agg on true
      where s.prospect_count is distinct from coalesce(agg.prospect_count, 0)
         or s.client_count is distinct from coalesce(agg.client_count, 0)
    )
  );
$$;


ALTER FUNCTION public.prospect_index_drift() OWNER TO postgres;

--
-- Name: prospect_index_fill_title_class(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_index_fill_title_class() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.prospect_index_fill_title_class() OWNER TO postgres;

--
-- Name: prospect_index; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospect_index (
    id text NOT NULL,
    first_name text DEFAULT ''::text NOT NULL,
    last_name text DEFAULT ''::text NOT NULL,
    full_name text DEFAULT ''::text NOT NULL,
    work_email text DEFAULT ''::text NOT NULL,
    personal_email text DEFAULT ''::text NOT NULL,
    mobile_number text DEFAULT ''::text NOT NULL,
    linkedin_url text DEFAULT ''::text NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    seniority text DEFAULT ''::text NOT NULL,
    department text DEFAULT ''::text NOT NULL,
    city text DEFAULT ''::text NOT NULL,
    state text DEFAULT ''::text NOT NULL,
    country text DEFAULT ''::text NOT NULL,
    company_id text,
    company_name text DEFAULT ''::text NOT NULL,
    company_domain text DEFAULT ''::text NOT NULL,
    all_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    list_count integer DEFAULT 0 NOT NULL,
    client_count integer DEFAULT 0 NOT NULL,
    list_names text[] DEFAULT '{}'::text[] NOT NULL,
    client_names text[] DEFAULT '{}'::text[] NOT NULL,
    list_ids text[] DEFAULT '{}'::text[] NOT NULL,
    client_ids text[] DEFAULT '{}'::text[] NOT NULL,
    list_memberships jsonb DEFAULT '[]'::jsonb NOT NULL,
    esp text DEFAULT ''::text NOT NULL,
    email_provider_type text DEFAULT 'Unknown'::text NOT NULL,
    mx_records text[] DEFAULT '{}'::text[] NOT NULL,
    mx_status text,
    mx_checked_at timestamp with time zone,
    keywords text[] DEFAULT '{}'::text[] NOT NULL,
    employee_count_min integer,
    employee_count_max integer,
    company_location text DEFAULT ''::text NOT NULL,
    company_city text DEFAULT ''::text NOT NULL,
    company_state text DEFAULT ''::text NOT NULL,
    company_country text DEFAULT ''::text NOT NULL,
    tags jsonb DEFAULT '[]'::jsonb NOT NULL,
    tag_text text DEFAULT ''::text NOT NULL,
    last_contacted_at timestamp with time zone,
    contact_count integer DEFAULT 0 NOT NULL,
    search_text text DEFAULT ''::text NOT NULL,
    location text DEFAULT ''::text NOT NULL,
    icp_verified_client_ids text[] DEFAULT '{}'::text[] NOT NULL,
    blocked_client_ids text[] DEFAULT '{}'::text[] NOT NULL,
    title_seniority text DEFAULT ''::text NOT NULL,
    title_department text DEFAULT ''::text NOT NULL,
    title_sub_department text DEFAULT ''::text NOT NULL,
    title_is_former boolean DEFAULT false NOT NULL,
    title_normalized text DEFAULT ''::text NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_vacuum_insert_scale_factor='0.02', autovacuum_analyze_scale_factor='0.02');


ALTER TABLE public.prospect_index OWNER TO postgres;

--
-- Name: prospect_index_matches_v1(public.prospect_index, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_index_matches_v1(p_row public.prospect_index, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $_$
  select (
    btrim(coalesce(p_search, '')) = ''
    or (p_row).search_text ilike '%' || btrim(p_search) || '%'
  ) and not exists (
    select 1
    from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
    cross join lateral (
      select coalesce(case filter_item->>'field'
        when '__name' then (p_row).full_name
        when '__first_name' then (p_row).first_name
        when '__last_name' then (p_row).last_name
        when '__company' then (p_row).company_name
        when '__company_domain' then (p_row).company_domain when '__website' then (p_row).company_domain
        when '__email' then concat_ws(' ', (p_row).work_email, (p_row).personal_email)
        when '__work_email' then (p_row).work_email
        when '__personal_email' then (p_row).personal_email
        when '__title' then (p_row).title
        when '__keywords' then array_to_string((p_row).keywords, ' | ')
        when '__linkedin' then (p_row).linkedin_url
        when '__city' then (p_row).city
        when '__state' then (p_row).state
        when '__country' then (p_row).country
        when '__person_location' then coalesce(nullif((p_row).location, ''),
          concat_ws(', ', nullif((p_row).city, ''), nullif((p_row).state, ''), nullif((p_row).country, '')))
        when '__company_location' then concat_ws(', ', nullif((p_row).company_location, ''), nullif((p_row).company_city, ''), nullif((p_row).company_state, ''), nullif((p_row).company_country, ''))
        when '__company_city' then (p_row).company_city
        when '__company_state' then (p_row).company_state
        when '__company_country' then (p_row).company_country
        when '__incomplete_company_profile' then case when exists (
          select 1 from public.companies co
          where co.id = (p_row).company_id
            and btrim(coalesce(array_to_string(co.keywords, ' | '), '')) = ''
            and btrim(coalesce(co.short_description, '')) = ''
        ) then 'true' else '' end
        when '__company_industry' then (select co.industry from public.companies co where co.id = (p_row).company_id)
        when '__company_keywords' then (select concat_ws(' | ',
            case when public.company_keyword_scopes_v1(filter_item->'scopes') ? 'name' then nullif(co.name, '') end,
            case when public.company_keyword_scopes_v1(filter_item->'scopes') ? 'description' then nullif(co.short_description, '') end)
          from public.companies co where co.id = (p_row).company_id)
        when '__company_description' then (select co.short_description from public.companies co where co.id = (p_row).company_id)
        when '__company_technologies' then (select array_to_string(co.technologies, ' | ') from public.companies co where co.id = (p_row).company_id)
        when '__company_founded_year' then (select co.founded_year::text from public.companies co where co.id = (p_row).company_id)
        when '__company_total_funding' then (select co.total_funding from public.companies co where co.id = (p_row).company_id)
        when '__seniority' then (p_row).seniority
        when '__department' then (p_row).department when '__title_department' then (p_row).title_department when '__title_sub_department' then (p_row).title_sub_department when '__title_seniority_tier' then (p_row).title_seniority
        when '__esp' then (p_row).esp
        when '__title_seniority' then concat_ws(' ', (p_row).title, (p_row).seniority)
        when '__esp_type' then concat_ws(' ', (p_row).esp, (p_row).email_provider_type)
        when '__email_provider_type' then (p_row).email_provider_type
        when '__icp_verified' then array_to_string((p_row).icp_verified_client_ids, ' | ')
        when '__tags' then (p_row).tag_text
        when '__last_contacted' then (p_row).last_contacted_at::text
        when '__lists' then array_to_string((p_row).list_names, ' | ')
        when '__clients' then array_to_string((p_row).client_names, ' | ')
        else case when filter_item->>'field' like 'custom:%' then coalesce((
          select string_agg(entry.value, ' | ' order by entry.key)
          from jsonb_each_text((p_row).all_data) entry(key, value)
          where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
        ), '') else '' end
      end, '') as candidate_value,
      -- Non-null only for the virtual concat fields; see prospect_filter_sql_v1.
      -- Equality is answered against these instead of the joined string, and
      -- both functions have to agree or the grid and a bulk delete act on
      -- different sets.
      case filter_item->>'field'
        when '__esp_type' then array[coalesce((p_row).esp, ''), coalesce((p_row).email_provider_type, '')]
        when '__title_seniority' then array[coalesce((p_row).title, ''), coalesce((p_row).seniority, '')]
        else null::text[]
      end as candidate_parts
    ) candidate
    where not case
      when filter_item->>'field' = '__client_tags' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.prospect_tag_links ptl
                  where ptl.prospect_id = (p_row).id
                    and ptl.tag_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__client_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).client_ids && array(select value from jsonb_array_elements_text(filter_item->'values'))::text[]))
      )
      when filter_item->>'field' = '__list_ids' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> ((p_row).list_ids && array(select value from jsonb_array_elements_text(filter_item->'values'))::text[]))
      )
      when filter_item->>'field' = '__lead' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.client_prospects cp
                  where cp.prospect_id = (p_row).id and cp.is_lead
                    and cp.client_id = any (select value from jsonb_array_elements_text(filter_item->'values')))))
      )
      when filter_item->>'field' = '__contactable' then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) = 0
        or ((coalesce(filter_item->>'operator', 'contains') in ('not_contains', 'not_equals'))
            <> (exists (select 1 from public.client_prospects cp
                  where cp.prospect_id = (p_row).id and cp.status = 'active'
                    and cp.client_id = any (select value from jsonb_array_elements_text(filter_item->'values'))
                    and (cp.date_added is null or cp.date_added <= ((now() at time zone 'UTC')::date
                      - coalesce((select s.cooldown_days from public.client_settings s where s.client_id = cp.client_id), 90))))))
      )
      when filter_item->>'field' = '__company_keywords'
        and public.company_keyword_scopes_v1(filter_item->'scopes') ? 'keywords'
        and coalesce(filter_item->>'operator', 'contains') in ('contains', 'not_contains')
        and coalesce(jsonb_array_length(filter_item->'values'), 0) > 0 then (
        (coalesce(filter_item->>'operator', 'contains') = 'not_contains')
        <> (
          exists (select 1 from public.companies co
                   where co.id = (p_row).company_id
                     and co.keywords && public.keyword_tag_variants_v1(
                           array(select value from jsonb_array_elements_text(filter_item->'values') as picked(value))))
          or exists (
            select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
            where candidate.candidate_value ilike '%' || selected.value || '%')
        )
      )
      when filter_item->>'field' in ('__company_keywords', '__company_technologies')
        and (filter_item->>'field' = '__company_technologies'
             or public.company_keyword_scopes_v1(filter_item->'scopes') ? 'keywords')
        and coalesce(filter_item->>'operator', 'contains') in ('equals', 'not_equals') then (
        coalesce(jsonb_array_length(filter_item->'values'), 0) > 0
        and ((coalesce(filter_item->>'operator', 'contains') = 'not_equals')
          <> (exists (select 1 from public.companies co
                where co.id = (p_row).company_id
                  and (lower(coalesce(array_to_string(
                         case when filter_item->>'field' = '__company_keywords' then co.keywords else co.technologies end, ' | '), ''))
                       = any (array(select lower(value) from jsonb_array_elements_text(filter_item->'values') as picked(value)))
                    or (case when filter_item->>'field' = '__company_keywords' then co.keywords else co.technologies end)
                       && public.keyword_tag_variants_v1(
                            array(select value from jsonb_array_elements_text(filter_item->'values') as picked(value)))))))
      )
      else case coalesce(filter_item->>'operator', 'contains')
      when 'equals' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where (case when candidate.candidate_parts is null
                 then lower(candidate.candidate_value) = lower(selected.value)
                 else exists (select 1 from unnest(candidate.candidate_parts) part
                              where lower(part) = lower(selected.value)) end)
          or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
            case when filter_item->>'field' = '__lists' then (p_row).list_names else (p_row).client_names end
          ))
      )
      when 'not_equals' then not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where (case when candidate.candidate_parts is null
                 then lower(candidate.candidate_value) = lower(selected.value)
                 else exists (select 1 from unnest(candidate.candidate_parts) part
                              where lower(part) = lower(selected.value)) end)
      )
      when 'not_contains' then not exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
      when 'boolean' then exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where to_tsvector('simple', candidate.candidate_value) @@ to_tsquery('simple', selected.value)
      )
      when 'number_ranges' then exists (
        select 1
        from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        cross join lateral (
          select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::bigint end as minimum,
            case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::bigint end as maximum
        ) selected_range
        where (filter_item->>'field' = '__employee_count'
          and ((selected.value = 'unknown' and (p_row).employee_count_min is null and (p_row).employee_count_max is null)
            or (selected.value <> 'unknown' and (p_row).employee_count_min is not null
              and (selected_range.maximum is null or (p_row).employee_count_min <= selected_range.maximum)
              and ((p_row).employee_count_max is null or (p_row).employee_count_max >= selected_range.minimum))))
        or (filter_item->>'field' = '__company_founded_year'
          and ((selected.value = 'unknown' and not exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.founded_year is not null))
            or (selected.value <> 'unknown' and exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.founded_year is not null
                   and co.founded_year >= selected_range.minimum
                   and (selected_range.maximum is null or co.founded_year <= selected_range.maximum)))))
        or (filter_item->>'field' = '__company_total_funding'
          and ((selected.value = 'unknown' and not exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.total_funding_amount is not null))
            or (selected.value <> 'unknown' and exists (select 1 from public.companies co
                 where co.id = (p_row).company_id and co.total_funding_amount is not null
                   and co.total_funding_amount >= selected_range.minimum
                   and (selected_range.maximum is null or co.total_funding_amount <= selected_range.maximum)))))
      )
      when 'empty' then btrim(candidate.candidate_value) = ''
      when 'not_empty' then btrim(candidate.candidate_value) <> ''
      else exists (
        select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
        where candidate.candidate_value ilike '%' || selected.value || '%'
      )
    end end
  );
$_$;


ALTER FUNCTION public.prospect_index_matches_v1(p_row public.prospect_index, p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: prospect_prefilter_sql(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_prefilter_sql(p_search text, p_filters jsonb) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public'
    AS $_$
declare
  conjuncts text[] := array[]::text[];
  filter_item jsonb;
  field_key text;
  operator_key text;
  column_expr text;
  value_parts text[];
  raw_values text[];
  value_text text;
  -- Above this many values an OR chain costs more to plan than the index scan
  -- saves, so the pre-filter switches to an array predicate.
  bulk_or_threshold constant integer := 40;
begin
  if btrim(coalesce(p_search, '')) <> '' then
    conjuncts := conjuncts || format('pi.search_text ilike %L', '%' || btrim(p_search) || '%');
  end if;

  for filter_item in select value from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) loop
    operator_key := coalesce(filter_item->>'operator', 'contains');
    if operator_key not in ('contains', 'equals') then continue; end if;
    field_key := filter_item->>'field';
    if field_key = '__client_tags' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format($t$(exists (select 1 from public.prospect_tag_links ptl
          where ptl.prospect_id = pi.id and ptl.tag_id = any (%L::text[])))$t$, raw_values);
      end if;
      continue;
    end if;

    -- Array overlap on the GIN index rather than a column comparison, so it is
    -- answered before the column CASE. Only reached for contains/equals: the
    -- loop has already skipped every other operator above.
    if field_key = '__client_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(pi.client_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;

    if field_key = '__list_ids' then
      raw_values := array[]::text[];
      for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
        if btrim(value_text) = '' then continue; end if;
        raw_values := raw_values || value_text;
      end loop;
      if cardinality(raw_values) > 0 then
        conjuncts := conjuncts || format('(pi.list_ids && %L::text[])', raw_values);
      end if;
      continue;
    end if;

    column_expr := case field_key
      when '__name' then 'pi.full_name'
      when '__first_name' then 'pi.first_name'
      when '__last_name' then 'pi.last_name'
      when '__company' then 'pi.company_name'
      when '__company_domain' then 'pi.company_domain' when '__website' then 'pi.company_domain'
      when '__title' then 'pi.title'
      when '__seniority' then 'pi.seniority'
      when '__department' then 'pi.department' when '__title_department' then 'pi.title_department' when '__title_sub_department' then 'pi.title_sub_department' when '__title_seniority_tier' then 'pi.title_seniority'
      when '__work_email' then 'pi.work_email'
      when '__personal_email' then 'pi.personal_email'
      when '__linkedin' then 'pi.linkedin_url'
      when '__city' then 'pi.city'
      when '__state' then 'pi.state'
      when '__country' then 'pi.country'
      when '__person_location' then 'pi.location'
      when '__company_city' then 'pi.company_city'
      when '__company_state' then 'pi.company_state'
      when '__company_country' then 'pi.company_country'
      when '__esp' then 'pi.esp'
      when '__email_provider_type' then 'pi.email_provider_type'
      when '__tags' then 'pi.tag_text'
      else null
    end;
    if column_expr is null then continue; end if;

    -- Collect the raw values once, then choose a shape by size. All three shapes
    -- below are exactly equivalent to the OR-of-values the real predicate applies,
    -- so the pre-filter stays implied by it no matter which one is emitted.
    raw_values := array[]::text[];
    for value_text in select value from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) loop
      if btrim(value_text) = '' then continue; end if;
      raw_values := raw_values || value_text;
    end loop;
    if cardinality(raw_values) = 0 then continue; end if;

    if operator_key = 'equals' then
      -- Equality scales to any list size as a single array membership test.
      conjuncts := conjuncts || format('lower(%s) = any (%L::text[])',
        column_expr, array(select lower(value) from unnest(raw_values) value));
    elsif cardinality(raw_values) <= bulk_or_threshold then
      -- Few enough values that the planner can still BitmapOr the trigram index.
      value_parts := array[]::text[];
      foreach value_text in array raw_values loop
        value_parts := value_parts || format('%s ilike %L', column_expr, '%' || value_text || '%');
      end loop;
      conjuncts := conjuncts || ('(' || array_to_string(value_parts, ' or ') || ')');
    else
      -- A pasted column of hundreds of values: one lateral over the array beats a
      -- several-hundred-branch OR, which costs more to plan than it saves.
      -- Above this size the only substring form is a correlated lateral over
      -- the array, and no index can serve it because the pattern is built per
      -- row. Emitting it makes every candidate pay that scan twice, since the
      -- authoritative predicate tests the same thing again. A prefilter that
      -- cannot narrow is worse than none, so emit nothing and let the complete
      -- predicate do the work once.
      null;
    end if;
  end loop;

  if cardinality(conjuncts) = 0 then return 'true'; end if;
  return array_to_string(conjuncts, ' and ');
end;
$_$;


ALTER FUNCTION public.prospect_prefilter_sql(p_search text, p_filters jsonb) OWNER TO postgres;

--
-- Name: prospect_search_text(public.prospect_index); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_search_text(p_row public.prospect_index) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  select concat_ws(' ',
    (p_row).full_name, (p_row).work_email, (p_row).personal_email, (p_row).mobile_number,
    (p_row).title, (p_row).seniority, (p_row).department,
    array_to_string((p_row).keywords, ' '),
    (p_row).company_name, (p_row).company_domain, (p_row).linkedin_url,
    (p_row).location, (p_row).city, (p_row).state, (p_row).country,
    (p_row).company_location, (p_row).company_city, (p_row).company_state, (p_row).company_country,
    (p_row).esp, (p_row).email_provider_type,
    array_to_string((p_row).list_names, ' '), array_to_string((p_row).client_names, ' '),
    (p_row).tag_text
  );
$$;


ALTER FUNCTION public.prospect_search_text(p_row public.prospect_index) OWNER TO postgres;

--
-- Name: prospect_title_taxonomy_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospect_title_taxonomy_v1(p_client_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  -- MATERIALIZED is load-bearing. Three CTEs below read `counted`, and since
  -- PostgreSQL 12 a CTE referenced more than once is inlined by default - so the
  -- grouping scan ran three times and the function took 3.0s against the 1.0s
  -- the scan itself costs. Materialising it puts that back to one pass.
  with counted as materialized (
    select
      grouping(pi.title_seniority) as g_seniority,
      grouping(pi.title_department) as g_department,
      grouping(pi.title_sub_department) as g_sub,
      pi.title_seniority, pi.title_department, pi.title_sub_department,
      count(*) as n
    from public.prospect_index pi
    where nullif(btrim(coalesce(p_client_id, '')), '') is null
       or pi.client_ids @> array[p_client_id]
    group by grouping sets ((pi.title_seniority), (pi.title_department), (pi.title_sub_department))
  ),
  tier_counts as (
    select btrim(coalesce(title_seniority, '')) as key, sum(n) as n
    from counted where g_seniority = 0 group by 1
  ),
  department_counts as (
    select btrim(coalesce(title_department, '')) as key, sum(n) as n
    from counted where g_department = 0 group by 1
  ),
  sub_counts as (
    select btrim(coalesce(title_sub_department, '')) as key, sum(n) as n
    from counted where g_sub = 0 group by 1
  ),
  -- 'none' is the suppression tier: it consumes tokens and contributes no rank,
  -- so it is never a value anything carries and must not be offered.
  tiers as (
    select coalesce(jsonb_agg(jsonb_build_object('value', t.tier, 'count', coalesce(c.n, 0)) order by t.tier), '[]'::jsonb) as value
    from (select distinct tier from public.title_seniority_keywords where tier <> 'none') t
    left join tier_counts c on c.key = t.tier
  ),
  subs_by_department as (
    select k.department,
      jsonb_agg(jsonb_build_object('name', k.sub_department, 'count', coalesce(s.n, 0)) order by k.sub_department) as subs
    from (select distinct department, sub_department from public.title_department_keywords where btrim(coalesce(sub_department, '')) <> '') k
    left join sub_counts s on s.key = k.sub_department
    group by k.department
  ),
  departments as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'name', d.department,
      'count', coalesce(c.n, 0),
      'subs', coalesce(sd.subs, '[]'::jsonb)
    ) order by d.department), '[]'::jsonb) as value
    from (select distinct department from public.title_department_keywords) d
    left join department_counts c on c.key = d.department
    left join subs_by_department sd on sd.department = d.department
  )
  select jsonb_build_object(
    'tiers', (select value from tiers),
    'departments', (select value from departments),
    -- What the classifier could not place. Shown as its own row so the picker
    -- can offer it rather than leaving those people unreachable.
    'undefinedSeniority', (select coalesce(n, 0) from tier_counts where key = ''),
    'undefinedDepartment', (select coalesce(n, 0) from department_counts where key = '')
  );
$$;


ALTER FUNCTION public.prospect_title_taxonomy_v1(p_client_id text) OWNER TO postgres;

--
-- Name: prospects_classify_title(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prospects_classify_title() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


ALTER FUNCTION public.prospects_classify_title() OWNER TO postgres;

--
-- Name: purge_company_import_rows_v1(integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.purge_company_import_rows_v1(p_keep_days integer DEFAULT 3, p_batch_size integer DEFAULT 25000, p_max_batches integer DEFAULT 200) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_cutoff timestamptz := now() - make_interval(days => greatest(1, coalesce(p_keep_days, 3)));
  v_batch integer := greatest(1000, least(coalesce(p_batch_size, 25000), 100000));
  v_deleted integer := 0;
  v_round integer := 0;
  v_removed integer;
begin
  loop
    v_round := v_round + 1;
    exit when v_round > greatest(1, coalesce(p_max_batches, 200));

    -- Only rows whose import has actually finished. A row belonging to an
    -- import still in 'processing' is the resume point for that import and is
    -- never eligible, however old it is.
    with doomed as (
      select r.import_id, r.source_row_number
      from public.company_import_rows r
      join public.company_imports i on i.id = r.import_id
      where r.imported_at < v_cutoff
        and i.status <> 'processing'
      limit v_batch
    )
    delete from public.company_import_rows r
    using doomed d
    where r.import_id = d.import_id and r.source_row_number = d.source_row_number;

    get diagnostics v_removed = row_count;
    v_deleted := v_deleted + v_removed;
    exit when v_removed = 0;
  end loop;

  return v_deleted;
end;
$$;


ALTER FUNCTION public.purge_company_import_rows_v1(p_keep_days integer, p_batch_size integer, p_max_batches integer) OWNER TO postgres;

--
-- Name: purge_system_event_log_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.purge_system_event_log_v1() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO ''
    SET statement_timeout TO '60s'
    AS $$
  delete from public.system_event_log where created_at < now() - interval '30 days';
$$;


ALTER FUNCTION public.purge_system_event_log_v1() OWNER TO postgres;

--
-- Name: push_companies_to_client_v1(text, text[], text, jsonb, jsonb, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.push_companies_to_client_v1(p_client_id text, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare v_ids text[] := array[]::text[]; v_added integer := 0; v_existing integer := 0; v_blocked integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(null, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);
  select count(*)::integer into v_existing from public.client_companies
  where client_id = p_client_id and company_id = any(v_ids);
  insert into public.client_companies (client_id, company_id, added_by)
  select p_client_id, company_id, 'push:' || left(coalesce(p_actor, ''), 195)
  from unnest(v_ids) selected(company_id)
  on conflict (client_id, company_id) do update set added_by = excluded.added_by;
  -- Diverted by the client's blocklist on the way in (20260924090000).
  select count(*)::integer into v_blocked from public.client_companies_blocked
  where client_id = p_client_id and company_id = any(v_ids);
  v_added := greatest(0, cardinality(v_ids) - v_existing - v_blocked);
  return jsonb_build_object('selected', cardinality(v_ids), 'added', v_added, 'alreadyPresent', v_existing,
    'blocked', v_blocked);
end;
$$;


ALTER FUNCTION public.push_companies_to_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: push_companies_to_client_v2(text, text[], text, jsonb, jsonb, text[], text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.push_companies_to_client_v2(p_client_id text, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text, p_source_client_id text DEFAULT NULL::text, p_request_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_requested text[] := coalesce(p_company_ids, array[]::text[]);
  v_ids text[] := array[]::text[];
  v_added_ids text[] := array[]::text[];
  v_existing integer := 0;
  v_blocked integer := 0;
  v_source_name text;
begin
  v_requested := array(select requested.id from unnest(v_requested) requested(id)
    where not (requested.id = any(coalesce(p_excluded_ids, array[]::text[]))));
  if not exists (select 1 from public.clients where id = p_client_id and archived_at is null) then
    raise exception 'Destination client not found or archived.' using errcode = 'P0002';
  end if;
  if p_source_client_id is not null then
    if p_source_client_id = p_client_id then raise exception 'Choose a different destination client.' using errcode = '22023'; end if;
    select name into v_source_name from public.clients where id = p_source_client_id;
    if v_source_name is null then raise exception 'Source client not found.' using errcode = 'P0002'; end if;
    if cardinality(v_requested) > 0 and exists (
      select 1 from unnest(v_requested) requested(id)
      where not exists (select 1 from public.client_companies cc
        where cc.client_id = p_source_client_id and cc.company_id = requested.id)
    ) then
      raise exception 'One or more selected companies are not in the source client.' using errcode = '42501';
    end if;
  end if;

  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(
    p_source_client_id, case when cardinality(v_requested) > 0 then v_requested else null end,
    p_search, p_filters, p_people_scope, p_excluded_ids, 250001);
  if cardinality(v_ids) > 250000 then
    raise exception 'More than 250,000 companies match. Narrow the filters before pushing.' using errcode = '54000';
  end if;
  select count(*)::integer into v_existing from public.client_companies
    where client_id = p_client_id and company_id = any(v_ids);

  with inserted as (
    insert into public.client_companies (client_id, company_id, added_by)
    select p_client_id, company_id,
      case when p_source_client_id is null then 'push:master' else 'push:client:' || p_source_client_id end
    from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing
    returning company_id
  ) select coalesce(array_agg(company_id), array[]::text[]) into v_added_ids from inserted;

  select count(*)::integer into v_blocked from public.client_companies_blocked
    where client_id = p_client_id and company_id = any(v_ids);
  if cardinality(v_added_ids) > 0 then
    perform public.record_client_addition_batch_v1(
      p_client_id, 'companies', case when p_source_client_id is null then 'master' else 'client' end,
      coalesce(v_source_name, 'Master DB'), p_source_client_id,
      coalesce(nullif(p_request_id, ''), gen_random_uuid()::text), v_added_ids, p_actor);
  end if;
  return jsonb_build_object('selected', cardinality(v_ids), 'added', cardinality(v_added_ids),
    'alreadyPresent', v_existing, 'blocked', v_blocked);
end;
$$;


ALTER FUNCTION public.push_companies_to_client_v2(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text, p_source_client_id text, p_request_id text) OWNER TO postgres;

--
-- Name: push_prospects_to_client_v1(text, text, jsonb, text, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.push_prospects_to_client_v1(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_source_client_id text DEFAULT NULL::text, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_blocked integer := 0;
  v_added integer := 0;
  v_present integer := 0;
  v_reindex record;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_source_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('added', 0, 'alreadyPresent', 0, 'blocked', 0, 'queued', 0);
  end if;

  -- Never push a record this client has already blocked: the whole point of the
  -- blocklist is that it survives a later bulk action.
  select count(*)::integer into v_blocked
  from public.prospect_index pi
  join public.client_blocklist b on b.client_id = p_client_id
  where pi.id = any(v_ids)
    and (
      (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
      or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
    );

  select count(*)::integer into v_present
  from public.client_prospects cp
  where cp.client_id = p_client_id and cp.prospect_id = any(v_ids);

  with eligible as (
    select pi.id
    from public.prospect_index pi
    where pi.id = any(v_ids)
      and not exists (
        select 1 from public.client_blocklist b
        where b.client_id = p_client_id
          and (
            (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
            or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
          )
      )
  ), inserted as (
    insert into public.client_prospects (client_id, prospect_id, added_via)
    select p_client_id, eligible.id, 'push' from eligible
    on conflict (client_id, prospect_id) do nothing
    returning 1
  )
  select count(*)::integer into v_added from inserted;

  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    'push_to_client', p_client_id, p_actor,
    format('Pushed %s prospects into the client', v_added), v_added, v_ids);

  return jsonb_build_object(
    'added', v_added,
    'alreadyPresent', v_present,
    'blocked', v_blocked,
    'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.push_prospects_to_client_v1(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: push_prospects_to_client_v2(text, text, jsonb, text, text[], text[], text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.push_prospects_to_client_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_source_client_id text DEFAULT NULL::text, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text, p_request_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_requested text[] := coalesce(p_prospect_ids, array[]::text[]);
  v_blocked integer := 0;
  v_present integer := 0;
  v_added_ids text[] := array[]::text[];
  v_reindex record;
  v_source_name text;
  v_request_id text := coalesce(nullif(left(btrim(coalesce(p_request_id, '')), 180), ''), gen_random_uuid()::text);
begin
  v_requested := array(select requested.id from unnest(v_requested) requested(id)
    where not (requested.id = any(coalesce(p_excluded_ids, array[]::text[]))));
  if not exists (select 1 from public.clients where id = p_client_id and archived_at is null) then
    raise exception 'Destination client not found or archived.' using errcode = 'P0002';
  end if;
  if p_source_client_id is not null then
    if p_source_client_id = p_client_id then
      raise exception 'Choose a different destination client.' using errcode = '22023';
    end if;
    select name into v_source_name from public.clients where id = p_source_client_id;
    if v_source_name is null then raise exception 'Source client not found.' using errcode = 'P0002'; end if;
  end if;

  if cardinality(v_requested) > 0 then
    if p_source_client_id is not null and exists (
      select 1 from unnest(v_requested) requested(id)
      where not exists (select 1 from public.client_prospects cp
        where cp.client_id = p_source_client_id and cp.prospect_id = requested.id and cp.status = 'active')
    ) then
      raise exception 'One or more selected people are not in the source client.' using errcode = '42501';
    end if;
    v_ids := v_requested;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_source_client_id, p_excluded_ids, 250001);
    if cardinality(v_ids) > 250000 then
      raise exception 'More than 250,000 people match. Narrow the filters before pushing.' using errcode = '54000';
    end if;
  end if;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('added', 0, 'alreadyPresent', 0, 'blocked', 0, 'queued', 0);
  end if;

  select count(*)::integer into v_blocked
  from public.prospect_index pi
  where pi.id = any(v_ids) and exists (
    select 1 from public.client_blocklist b where b.client_id = p_client_id
      and ((b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value)))
  );
  select count(*)::integer into v_present from public.client_prospects cp
    where cp.client_id = p_client_id and cp.prospect_id = any(v_ids);

  with eligible as (
    select pi.id from public.prospect_index pi where pi.id = any(v_ids)
      and not exists (select 1 from public.client_blocklist b where b.client_id = p_client_id
        and ((b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
          or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))))
  ), inserted as (
    insert into public.client_prospects (
      client_id, prospect_id, added_via, source_push_request_id,
      source_push_client_id, source_push_label, source_push_actor
    )
    select p_client_id, eligible.id, 'push', v_request_id,
      p_source_client_id, coalesce(v_source_name, 'Master DB'), p_actor
    from eligible
    on conflict (client_id, prospect_id) do nothing returning prospect_id
  ) select coalesce(array_agg(prospect_id), array[]::text[]) into v_added_ids from inserted;

  if cardinality(v_added_ids) > 0 then
    perform public.record_client_addition_batch_v1(
      p_client_id, 'people', case when p_source_client_id is null then 'master' else 'client' end,
      coalesce(v_source_name, 'Master DB'), p_source_client_id,
      v_request_id, v_added_ids, p_actor);
  end if;
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation('push_to_client', p_client_id, p_actor,
    format('Pushed %s prospects into the client', cardinality(v_added_ids)), cardinality(v_added_ids), v_ids);
  return jsonb_build_object('added', cardinality(v_added_ids), 'alreadyPresent', v_present,
    'blocked', v_blocked, 'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.push_prospects_to_client_v2(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text, p_request_id text) OWNER TO postgres;

--
-- Name: queue_company_import_reindex_v1(text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.queue_company_import_reindex_v1(p_import_id text, p_after_prospect_id text DEFAULT ''::text, p_limit integer DEFAULT 25000) RETURNS TABLE(queued integer, last_prospect_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_ids text[];
begin
  select coalesce(array_agg(slice.id order by slice.id), array[]::text[])
    into v_ids
  from (
    select p.id
      from public.prospects p
     where p.id > coalesce(p_after_prospect_id, '')
       and p.company_id in (
         select cir.company_id
           from public.company_import_rows cir
          where cir.import_id = p_import_id
            and cir.company_id is not null)
     order by p.id
     limit greatest(1, least(coalesce(p_limit, 25000), 100000))
  ) slice;

  if cardinality(v_ids) = 0 then
    queued := 0;
    last_prospect_id := coalesce(p_after_prospect_id, '');
    return next;
    return;
  end if;

  insert into public.reindex_backlog (prospect_id, last_error)
  select id, 'company import ' || p_import_id
    from unnest(v_ids) as id
  on conflict (prospect_id) do update set
    enqueued_at = least(public.reindex_backlog.enqueued_at, now());

  queued := cardinality(v_ids);
  last_prospect_id := v_ids[cardinality(v_ids)];
  return next;
end;
$$;


ALTER FUNCTION public.queue_company_import_reindex_v1(p_import_id text, p_after_prospect_id text, p_limit integer) OWNER TO postgres;

--
-- Name: reclassify_prospect_titles_v1(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reclassify_prospect_titles_v1(p_limit integer DEFAULT 500) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
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

  update public.prospect_index pi set
      title_seniority=p.title_seniority,title_department=p.title_department,
      title_sub_department=p.title_sub_department,title_is_former=p.title_is_former,
      title_normalized=p.title_normalized
    from public.prospects p where pi.id=p.id and p.id=any(v_ids)
      and (pi.title_seniority,pi.title_department,pi.title_sub_department,pi.title_is_former,pi.title_normalized)
        is distinct from (p.title_seniority,p.title_department,p.title_sub_department,p.title_is_former,p.title_normalized);
    perform public.reindex_prospects(array(
      select id from unnest(v_ids) target(id)
      where not exists(select 1 from public.prospect_index pi where pi.id=target.id)
    ));
  return v_updated;
end;
$$;


ALTER FUNCTION public.reclassify_prospect_titles_v1(p_limit integer) OWNER TO postgres;

--
-- Name: recompute_client_company_counts_bulk(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.recompute_client_company_counts_bulk(p_company_ids text[]) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  update public.client_companies cc
  set prospect_count = coalesce(agg.n, 0)
  from public.client_companies target
  left join (
    select pi.company_id, cid as client_id, count(*)::integer as n
    from public.prospect_index pi
    cross join lateral unnest(pi.client_ids) as cid
    where pi.company_id = any(coalesce(p_company_ids, array[]::text[]))
    group by pi.company_id, cid
  ) agg on agg.company_id = target.company_id and agg.client_id = target.client_id
  where target.company_id = any(coalesce(p_company_ids, array[]::text[]))
    and cc.client_id = target.client_id
    and cc.company_id = target.company_id
    -- Unchanged pairs are not rewritten: a re-index of 131,819 prospects must
    -- not leave a dead row behind for every pair it did not actually change.
    and cc.prospect_count is distinct from coalesce(agg.n, 0);
$$;


ALTER FUNCTION public.recompute_client_company_counts_bulk(p_company_ids text[]) OWNER TO postgres;

--
-- Name: recompute_company_counts(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.recompute_company_counts(p_company_id text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  update public.companies c set
    prospect_count = coalesce((
      select count(*) from public.prospect_index pi where pi.company_id = p_company_id
    ), 0),
    client_count = coalesce((
      select count(distinct cid)
      from public.prospect_index pi
      cross join lateral unnest(pi.client_ids) as cid
      where pi.company_id = p_company_id
    ), 0)
  where c.id = p_company_id;
$$;


ALTER FUNCTION public.recompute_company_counts(p_company_id text) OWNER TO postgres;

--
-- Name: recompute_company_counts_bulk(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.recompute_company_counts_bulk(p_company_ids text[]) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  update public.companies c set
    prospect_count = coalesce(agg.prospect_count, 0),
    client_count = coalesce(agg.client_count, 0)
  from unnest(coalesce(p_company_ids, array[]::text[])) as target(company_id)
  left join (
    select pi.company_id,
      count(distinct pi.id)::integer as prospect_count,
      count(distinct cid)::integer as client_count
    from public.prospect_index pi
    left join lateral unnest(pi.client_ids) as cid on true
    where pi.company_id = any(coalesce(p_company_ids, array[]::text[]))
    group by pi.company_id
  ) agg on agg.company_id = target.company_id
  where c.id = target.company_id;
$$;


ALTER FUNCTION public.recompute_company_counts_bulk(p_company_ids text[]) OWNER TO postgres;

--
-- Name: reconcile_client_company_counts_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reconcile_client_company_counts_v1() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_drift integer;
begin
  create temporary table if not exists _ccc_truth (
    company_id text, client_id text, n integer
  ) on commit drop;
  delete from _ccc_truth;

  insert into _ccc_truth (company_id, client_id, n)
  select pi.company_id, cid, count(*)::integer
  from public.prospect_index pi
  cross join lateral unnest(pi.client_ids) as cid
  where pi.company_id is not null
  group by pi.company_id, cid;

  select count(*)::integer into v_drift
  from public.client_companies cc
  left join _ccc_truth t on t.company_id = cc.company_id and t.client_id = cc.client_id
  where cc.prospect_count is distinct from coalesce(t.n, 0);

  update public.client_companies cc
  set prospect_count = coalesce(t.n, 0)
  from public.client_companies target
  left join _ccc_truth t on t.company_id = target.company_id and t.client_id = target.client_id
  where cc.client_id = target.client_id
    and cc.company_id = target.company_id
    and cc.prospect_count is distinct from coalesce(t.n, 0);

  return v_drift;
end;
$$;


ALTER FUNCTION public.reconcile_client_company_counts_v1() OWNER TO postgres;

--
-- Name: record_client_addition_batch_v1(text, text, text, text, text, text, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_client_addition_batch_v1(p_client_id text, p_entity_type text, p_source_kind text, p_source_label text, p_source_client_id text, p_request_key text, p_entity_ids text[], p_actor text DEFAULT ''::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
declare
  v_batch_id uuid;
  v_key text := nullif(left(btrim(coalesce(p_request_key, '')), 200), '');
begin
  if p_entity_type not in ('people', 'companies') then
    raise exception 'Unknown batch entity type' using errcode = '22023';
  end if;
  if p_source_kind not in ('import', 'master', 'client') then
    raise exception 'Unknown batch source' using errcode = '22023';
  end if;
  if p_source_kind = 'client' and (p_source_client_id is null or p_source_client_id = p_client_id) then
    raise exception 'A client push needs a different source client' using errcode = '22023';
  end if;

  if v_key is not null then
    insert into public.client_addition_batches
      (client_id, entity_type, source_kind, source_label, source_client_id,
       request_key, created_by)
    values
      (p_client_id, p_entity_type, p_source_kind,
       left(coalesce(p_source_label, ''), 300),
       case when p_source_kind = 'client' then p_source_client_id else null end,
       v_key, left(coalesce(p_actor, ''), 200))
    on conflict (client_id, entity_type, request_key)
      where request_key is not null and request_key <> ''
    do update set source_label = excluded.source_label
    returning id into v_batch_id;
  else
    insert into public.client_addition_batches
      (client_id, entity_type, source_kind, source_label, source_client_id, created_by)
    values
      (p_client_id, p_entity_type, p_source_kind,
       left(coalesce(p_source_label, ''), 300),
       case when p_source_kind = 'client' then p_source_client_id else null end,
       left(coalesce(p_actor, ''), 200))
    returning id into v_batch_id;
  end if;

  insert into public.client_addition_batch_items (batch_id, entity_id)
  select v_batch_id, selected.id
  from unnest(coalesce(p_entity_ids, array[]::text[])) selected(id)
  where btrim(selected.id) <> ''
  on conflict (batch_id, entity_id) do nothing;

  update public.client_addition_batches
  set completed_at = coalesce(completed_at, now())
  where id = v_batch_id;
  return v_batch_id;
end;
$$;


ALTER FUNCTION public.record_client_addition_batch_v1(p_client_id text, p_entity_type text, p_source_kind text, p_source_label text, p_source_client_id text, p_request_key text, p_entity_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: record_completed_import_batch_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_completed_import_batch_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.status = 'completed' and old.status is distinct from new.status then
    update public.client_addition_batches
      set completed_at = coalesce(new.completed_at, now())
      where client_id = new.client_id and request_key = 'import:' || new.id
        and source_kind = 'import';
  end if;
  return new;
end;
$$;


ALTER FUNCTION public.record_completed_import_batch_v1() OWNER TO postgres;

--
-- Name: record_new_import_people_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_new_import_people_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_group record;
begin
  for v_group in
    select i.id as import_id, i.client_id, i.file_name,
      array_agg(n.prospect_id order by n.prospect_id) as ids
    from new_client_rows n join public.imports i on i.id = n.source_import_id
    where n.source_import_id is not null
    group by i.id, i.client_id, i.file_name
  loop
    perform public.record_client_addition_batch_v1(
      v_group.client_id, 'people', 'import', v_group.file_name, null,
      'import:' || v_group.import_id, v_group.ids, 'import-worker');
  end loop;
  return null;
end;
$$;


ALTER FUNCTION public.record_new_import_people_v1() OWNER TO postgres;

--
-- Name: record_operation(text, text, text, text, integer, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_operation(p_action text, p_client_id text, p_actor text, p_summary text, p_affected integer, p_ids text[]) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  insert into public.operation_log (action, client_id, actor, summary, affected, prospect_ids)
  values (
    left(coalesce(p_action, ''), 60), p_client_id, left(coalesce(p_actor, ''), 200),
    left(coalesce(p_summary, ''), 500), coalesce(p_affected, 0),
    coalesce(p_ids[1:50000], '{}'::text[])
  )
  returning id;
$$;


ALTER FUNCTION public.record_operation(p_action text, p_client_id text, p_actor text, p_summary text, p_affected integer, p_ids text[]) OWNER TO postgres;

--
-- Name: record_operation_result_v1(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.record_operation_result_v1(p_job_id uuid, p_actor text, p_result jsonb) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_operations'
    SET statement_timeout TO '15s'
    AS $$
  select prospect_operations.record_result_v1(p_job_id, p_actor, p_result);
$$;


ALTER FUNCTION public.record_operation_result_v1(p_job_id uuid, p_actor text, p_result jsonb) OWNER TO postgres;

--
-- Name: refresh_company_value_suggestions_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.refresh_company_value_suggestions_v1() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '600s'
    AS $$
declare
  v_rows integer;
begin
  create temporary table tmp_cvs on commit drop as
    select 'keywords'::text as kind, entry.val as value, count(*)::integer as company_count
    from public.companies c cross join lateral unnest(c.keywords) entry(val)
    where btrim(coalesce(entry.val, '')) <> ''
    group by entry.val
    union all
    select 'technologies'::text, entry.val, count(*)::integer
    from public.companies c cross join lateral unnest(c.technologies) entry(val)
    where btrim(coalesce(entry.val, '')) <> ''
    group by entry.val;

  delete from public.company_value_suggestions;
  insert into public.company_value_suggestions (kind, value, company_count)
    select kind, value, company_count from tmp_cvs;
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;


ALTER FUNCTION public.refresh_company_value_suggestions_v1() OWNER TO postgres;

--
-- Name: reindex_all(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reindex_all() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $$
  select public.reindex_prospects(array(select id from public.prospects));
$$;


ALTER FUNCTION public.reindex_all() OWNER TO postgres;

--
-- Name: reindex_prospects(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reindex_prospects(p_ids text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $$
declare affected integer;
begin
  if p_ids is null or array_length(p_ids, 1) is null then return 0; end if;

  with computed as (
    select
      p.id,
      p.first_name, p.last_name, p.full_name, p.work_email, p.personal_email,
      p.mobile_number, p.linkedin_url, p.title, p.seniority, p.department,
      p.city, p.state, p.country, p.company_id, p.all_data, p.created_at, p.updated_at,
      coalesce(nullif(p.location, ''), concat_ws(', ', nullif(p.city, ''), nullif(p.state, ''), nullif(p.country, ''))) as location,
      coalesce(co.name, '') as company_name,
      coalesce(co.domain, '') as company_domain,
      count(distinct lm.list_id)::integer as list_count,
      (select count(*)::integer from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'active') as client_count,
      coalesce(array_agg(distinct l.name order by l.name) filter (where l.id is not null), '{}'::text[]) as list_names,
      coalesce((select array_agg(distinct cl2.name order by cl2.name)
        from public.client_prospects cp join public.clients cl2 on cl2.id = cp.client_id
        where cp.prospect_id = p.id and cp.status = 'active'), '{}'::text[]) as client_names,
      coalesce(array_agg(distinct l.id order by l.id) filter (where l.id is not null), '{}'::text[]) as list_ids,
      coalesce((select array_agg(distinct cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'active'), '{}'::text[]) as client_ids,
      coalesce((select array_agg(cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'active' and cp.icp_verified), '{}'::text[]) as icp_verified_client_ids,
      coalesce((select array_agg(cp.client_id order by cp.client_id)
        from public.client_prospects cp where cp.prospect_id = p.id and cp.status = 'blocked'), '{}'::text[]) as blocked_client_ids,
      coalesce(jsonb_agg(distinct jsonb_build_object(
        'listId', l.id, 'listName', l.name, 'clientId', cl.id, 'clientName', cl.name
      )) filter (where l.id is not null), '[]'::jsonb) as list_memberships,
      coalesce(co.esp, '') as esp,
      coalesce(co.email_provider_type, 'Unknown') as email_provider_type,
      coalesce(co.mx_records, '{}'::text[]) as mx_records,
      co.mx_status, co.mx_checked_at,
      coalesce(p.keywords, '{}'::text[]) as keywords,
      co.employee_count_min, co.employee_count_max,
      coalesce(co.location, '') as company_location,
      coalesce(co.city, '') as company_city,
      coalesce(co.state, '') as company_state,
      coalesce(co.country, '') as company_country,
      coalesce((select jsonb_agg(jsonb_build_object('id', pt.id, 'name', pt.name, 'color', pt.color, 'clientId', pt.client_id) order by pt.name)
        from public.prospect_tag_links ptl join public.prospect_tags pt on pt.id = ptl.tag_id
        where ptl.prospect_id = p.id), '[]'::jsonb) as tags,
      coalesce((select string_agg(pt.name, ' ' order by pt.name)
        from public.prospect_tag_links ptl join public.prospect_tags pt on pt.id = ptl.tag_id
        where ptl.prospect_id = p.id), '') as tag_text,
      (select max(ce.contacted_at) from public.contact_events ce where ce.prospect_id = p.id) as last_contacted_at,
      coalesce((select count(*) from public.contact_events ce where ce.prospect_id = p.id), 0)::integer as contact_count
    from public.prospects p
    left join public.companies co on co.id = p.company_id
    left join public.list_memberships lm on lm.prospect_id = p.id
    left join public.lists l on l.id = lm.list_id
    left join public.clients cl on cl.id = l.client_id
    where p.id = any(p_ids)
    group by p.id, co.id
  ), upserted as (
    insert into public.prospect_index (
      id, first_name, last_name, full_name, work_email, personal_email, mobile_number,
      linkedin_url, title, seniority, department, city, state, country, location, company_id,
      company_name, company_domain, all_data, created_at, updated_at, list_count, client_count,
      list_names, client_names, list_ids, client_ids, list_memberships, esp, email_provider_type,
      mx_records, mx_status, mx_checked_at, keywords, employee_count_min, employee_count_max,
      company_location, company_city, company_state, company_country, tags, tag_text,
      last_contacted_at, contact_count, icp_verified_client_ids, blocked_client_ids, search_text
    )
    select
      c.id, c.first_name, c.last_name, c.full_name, c.work_email, c.personal_email, c.mobile_number,
      c.linkedin_url, c.title, c.seniority, c.department, c.city, c.state, c.country, c.location, c.company_id,
      c.company_name, c.company_domain, c.all_data, c.created_at, c.updated_at, c.list_count, c.client_count,
      c.list_names, c.client_names, c.list_ids, c.client_ids, c.list_memberships, c.esp, c.email_provider_type,
      c.mx_records, c.mx_status, c.mx_checked_at, c.keywords, c.employee_count_min, c.employee_count_max,
      c.company_location, c.company_city, c.company_state, c.company_country, c.tags, c.tag_text,
      c.last_contacted_at, c.contact_count, c.icp_verified_client_ids, c.blocked_client_ids,
      concat_ws(' ', c.full_name, c.work_email, c.personal_email, c.mobile_number,
        c.title, c.seniority, c.department, array_to_string(c.keywords, ' '),
        c.company_name, c.company_domain, c.linkedin_url, c.location, c.city, c.state, c.country,
        c.company_location, c.company_city, c.company_state, c.company_country, c.esp, c.email_provider_type,
        array_to_string(c.list_names, ' '), array_to_string(c.client_names, ' '), c.tag_text)
    from computed c
    on conflict (id) do update set
      first_name = excluded.first_name, last_name = excluded.last_name, full_name = excluded.full_name,
      work_email = excluded.work_email, personal_email = excluded.personal_email, mobile_number = excluded.mobile_number,
      linkedin_url = excluded.linkedin_url, title = excluded.title, seniority = excluded.seniority,
      department = excluded.department, city = excluded.city, state = excluded.state, country = excluded.country,
      location = excluded.location, company_id = excluded.company_id, company_name = excluded.company_name,
      company_domain = excluded.company_domain, all_data = excluded.all_data, created_at = excluded.created_at,
      updated_at = excluded.updated_at, list_count = excluded.list_count, client_count = excluded.client_count,
      list_names = excluded.list_names, client_names = excluded.client_names, list_ids = excluded.list_ids,
      client_ids = excluded.client_ids, list_memberships = excluded.list_memberships, esp = excluded.esp,
      email_provider_type = excluded.email_provider_type, mx_records = excluded.mx_records,
      mx_status = excluded.mx_status, mx_checked_at = excluded.mx_checked_at, keywords = excluded.keywords,
      employee_count_min = excluded.employee_count_min, employee_count_max = excluded.employee_count_max,
      company_location = excluded.company_location, company_city = excluded.company_city,
      company_state = excluded.company_state, company_country = excluded.company_country,
      tags = excluded.tags, tag_text = excluded.tag_text, last_contacted_at = excluded.last_contacted_at,
      contact_count = excluded.contact_count, icp_verified_client_ids = excluded.icp_verified_client_ids,
      blocked_client_ids = excluded.blocked_client_ids, search_text = excluded.search_text
    returning 1
  )
  select count(*)::integer into affected from upserted;
  return affected;
end;
$$;


ALTER FUNCTION public.reindex_prospects(p_ids text[]) OWNER TO postgres;

--
-- Name: reindex_prospects_of_companies(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reindex_prospects_of_companies(p_company_ids text[]) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select public.reindex_prospects(array(
    select p.id from public.prospects p where p.company_id = any(p_company_ids)
  ));
$$;


ALTER FUNCTION public.reindex_prospects_of_companies(p_company_ids text[]) OWNER TO postgres;

--
-- Name: reindex_prospects_of_lists(text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reindex_prospects_of_lists(p_list_ids text[]) RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select public.reindex_prospects(array(
    select distinct lm.prospect_id from public.list_memberships lm where lm.list_id = any(p_list_ids)
  ));
$$;


ALTER FUNCTION public.reindex_prospects_of_lists(p_list_ids text[]) OWNER TO postgres;

--
-- Name: reindex_scope_v1(text, text[], text[], text[], text[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reindex_scope_v1(p_client_id text DEFAULT NULL::text, p_list_ids text[] DEFAULT NULL::text[], p_import_ids text[] DEFAULT NULL::text[], p_company_ids text[] DEFAULT NULL::text[], p_prospect_ids text[] DEFAULT NULL::text[], p_batch integer DEFAULT 2000) RETURNS TABLE(reindexed integer, queued integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_ids text[];
  v_batch text[];
  v_size integer := greatest(100, least(coalesce(p_batch, 2000), 5000));
  v_offset integer := 0;
  v_done integer := 0;
  v_queued integer := 0;
begin
  select coalesce(array_agg(distinct target_id), array[]::text[]) into v_ids
  from (
    select lm.prospect_id as target_id
    from public.list_memberships lm
    join public.lists l on l.id = lm.list_id
    where p_client_id is not null and l.client_id = p_client_id
    union
    select lm.prospect_id
    from public.list_memberships lm
    where p_list_ids is not null and lm.list_id = any(p_list_ids)
    union
    select lr.prospect_id
    from public.list_rows lr
    where p_import_ids is not null and lr.import_id = any(p_import_ids) and lr.prospect_id is not null
    union
    select p.id
    from public.prospects p
    where p_company_ids is not null and p.company_id = any(p_company_ids)
    union
    select id
    from unnest(coalesce(p_prospect_ids, array[]::text[])) as id
  ) targets
  where target_id is not null;

  while v_offset < cardinality(v_ids) loop
    v_batch := v_ids[v_offset + 1 : v_offset + v_size];
    begin
      v_done := v_done + public.reindex_prospects(v_batch);
    exception when others then
      -- A batch that times out is remembered, not lost.
      perform public.enqueue_reindex(v_batch, sqlerrm);
      v_queued := v_queued + cardinality(v_batch);
    end;
    v_offset := v_offset + v_size;
  end loop;

  reindexed := v_done;
  queued := v_queued;
  return next;
end;
$$;


ALTER FUNCTION public.reindex_scope_v1(p_client_id text, p_list_ids text[], p_import_ids text[], p_company_ids text[], p_prospect_ids text[], p_batch integer) OWNER TO postgres;

--
-- Name: remove_client_blocklist_selection_v1(text, text[], boolean, text, text, date, date, text[], timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.remove_client_blocklist_selection_v1(p_client_id text, p_ids text[] DEFAULT NULL::text[], p_all_matching boolean DEFAULT false, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_excluded_ids text[] DEFAULT NULL::text[], p_selected_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare v_ids text[];
begin
  select coalesce(array_agg(entry_id), array[]::text[]) into v_ids
  from public.client_blocklist_selection_v1(p_client_id, p_ids, p_all_matching,
    p_search, p_kind, p_date_from, p_date_to, p_excluded_ids, p_selected_before, 250001);
  if cardinality(v_ids) > 250000 then
    raise exception 'More than 250,000 blocklist entries match. Narrow the filters before removing them.' using errcode = '54000';
  end if;
  if cardinality(v_ids) = 0 then
    return jsonb_build_object('removed', 0, 'restored', 0, 'companiesRestored', 0);
  end if;
  return public.remove_client_blocklist_v1(p_client_id, v_ids, p_actor);
end;
$$;


ALTER FUNCTION public.remove_client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text) OWNER TO postgres;

--
-- Name: remove_client_blocklist_v1(text, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.remove_client_blocklist_v1(p_client_id text, p_ids text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare
  v_removed integer := 0;
  v_ids text[];
  v_company_ids text[];
begin
  delete from public.client_blocklist
  where client_id = p_client_id and id = any(coalesce(p_ids, array[]::text[]));
  get diagnostics v_removed = row_count;

  -- Un-suppress anything no remaining entry still matches.
  with still_blocked as (
    select distinct cp.prospect_id
    from public.client_prospects cp
    join public.prospect_index pi on pi.id = cp.prospect_id
    join public.client_blocklist b on b.client_id = p_client_id
    where cp.client_id = p_client_id
      and (
        (b.kind = 'domain' and b.value <> '' and lower(pi.company_domain) = b.value)
        or (b.kind = 'email' and b.value <> '' and (lower(pi.work_email) = b.value or lower(pi.personal_email) = b.value))
      )
  ), restored as (
    update public.client_prospects cp set
      status = 'active', blocked_at = null, blocked_reason = ''
    where cp.client_id = p_client_id
      and cp.status = 'blocked'
      and cp.prospect_id not in (select prospect_id from still_blocked)
    returning cp.prospect_id
  )
  select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids from restored;

  perform public.reindex_scope_v1(p_prospect_ids => v_ids);
  -- Companies no remaining entry matches come back too (20260924090000).
  v_company_ids := public.restore_client_company_blocklist_v1(p_client_id);
  perform public.record_operation('blocklist_remove', p_client_id, p_actor,
    format('Removed %s blocklist entries, restoring %s records', v_removed, cardinality(v_ids)),
    cardinality(v_ids), v_ids);

  return jsonb_build_object('removed', v_removed, 'restored', cardinality(v_ids),
    'companiesRestored', cardinality(v_company_ids));
end;
$$;


ALTER FUNCTION public.remove_client_blocklist_v1(p_client_id text, p_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: remove_companies_from_client_v1(text, text[], text, jsonb, jsonb, text[], integer, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.remove_companies_from_client_v1(p_client_id text, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_max_people integer DEFAULT 50000, p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_company_ids text[] := array[]::text[];
  v_prospect_ids text[] := array[]::text[];
  v_people bigint := 0;
  v_removed_companies integer := 0;
  v_people_result jsonb := jsonb_build_object('removed', 0);
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;

  -- The same resolver every other company action uses, so "these three" and
  -- "everything matching this filter" cannot mean different things here than
  -- they do for push, ICP verification or tagging.
  select coalesce(array_agg(company_id), array[]::text[]) into v_company_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if cardinality(v_company_ids) = 0 then
    return jsonb_build_object('removedCompanies', 0, 'removedPeople', 0, 'masterRecordsPreserved', true);
  end if;

  -- This client's people at those companies. Scoped by client_ids, so another
  -- client's people at the same company are not in the set at all.
  select coalesce(array_agg(pi.id), array[]::text[]), count(*)
    into v_prospect_ids, v_people
  from public.prospect_index pi
  where pi.company_id = any(v_company_ids)
    and pi.client_ids @> array[p_client_id];

  -- Refused, not truncated. Removing 49,999 of 60,000 people and reporting
  -- success is the worst available outcome: it is neither what was asked for
  -- nor obviously wrong afterwards.
  if p_max_people is not null and v_people > p_max_people then
    raise exception using errcode = '54000',
      message = format('This would remove %s people from the client, above the %s limit. Narrow the selection.', v_people, p_max_people);
  end if;

  -- People first. Reused rather than reimplemented: that function also clears
  -- list_memberships, re-indexes and writes the audit row, and a second copy of
  -- that sequence is a second copy to keep in step.
  if cardinality(v_prospect_ids) > 0 then
    v_people_result := public.remove_prospects_from_client_v2(
      p_client_id => p_client_id,
      p_search => '', p_filters => '[]'::jsonb,
      p_prospect_ids => v_prospect_ids, p_excluded_ids => null, p_actor => p_actor);
  end if;

  -- Then the membership itself. Nothing removes this on its own -
  -- sync_client_company_membership does not fire on delete - so without this
  -- the company would still be listed in the client with no people behind it.
  delete from public.client_companies
   where client_id = p_client_id and company_id = any(v_company_ids);
  get diagnostics v_removed_companies = row_count;

  perform public.record_operation('remove_companies_from_client', p_client_id, p_actor,
    format('Removed %s companies and %s people from the client', v_removed_companies, coalesce((v_people_result ->> 'removed')::bigint, 0)),
    v_removed_companies, v_company_ids);

  return jsonb_build_object(
    'removedCompanies', v_removed_companies,
    'removedPeople', coalesce((v_people_result ->> 'removed')::bigint, 0),
    'selectedCompanies', cardinality(v_company_ids),
    'masterRecordsPreserved', true);
end;
$$;


ALTER FUNCTION public.remove_companies_from_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_max_people integer, p_actor text) OWNER TO postgres;

--
-- Name: remove_prospect_from_client_v1(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.remove_prospect_from_client_v1(p_client_id text, p_prospect_id text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare removed_count integer;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.prospects where id = p_prospect_id) then
    raise exception 'Prospect not found' using errcode = 'P0002';
  end if;

  delete from public.list_memberships lm
  using public.lists l
  where lm.list_id = l.id and l.client_id = p_client_id and lm.prospect_id = p_prospect_id;
  get diagnostics removed_count = row_count;

  -- The raw source row stays as the import's archive, but must stop pointing at
  -- a person who is no longer on this client's lists.
  update public.list_rows lr
  set prospect_id = null
  from public.lists l
  where lr.list_id = l.id and l.client_id = p_client_id and lr.prospect_id = p_prospect_id;

  -- The master record is untouched by design.
  return removed_count;
end;
$$;


ALTER FUNCTION public.remove_prospect_from_client_v1(p_client_id text, p_prospect_id text) OWNER TO postgres;

--
-- Name: remove_prospects_from_client_v2(text, text, jsonb, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.remove_prospects_from_client_v2(p_client_id text, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_removed integer := 0;
  v_linked_before bigint := 0;
  v_linked_after bigint := 0;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('removed', 0, 'masterProspectPreserved', true);
  end if;

  -- What this client actually holds, before anything is touched.
  select count(*) into v_linked_before
  from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);

  -- Drop the list links first so the membership trigger cannot re-add the row,
  -- then the membership itself (which covers pushed records with no list).
  delete from public.list_memberships lm
  using public.lists l
  where lm.list_id = l.id and l.client_id = p_client_id and lm.prospect_id = any(v_ids);

  delete from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);

  -- Not row_count: the delete above is usually a no-op because the list trigger
  -- has already cascaded. The honest measure is what is left.
  select count(*) into v_linked_after
  from public.client_prospects
  where client_id = p_client_id and prospect_id = any(v_ids);
  v_removed := greatest(0, v_linked_before - v_linked_after)::integer;

  perform public.reindex_scope_v1(p_prospect_ids => v_ids);
  perform public.record_operation('remove_from_client', p_client_id, p_actor,
    format('Removed %s prospects from the client', v_removed), v_removed, v_ids);

  return jsonb_build_object('removed', v_removed, 'masterProspectPreserved', true);
end;
$$;


ALTER FUNCTION public.remove_prospects_from_client_v2(p_client_id text, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: remove_prospects_from_list_v1(text, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.remove_prospects_from_list_v1(p_list_id text, p_prospect_ids text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare removed_count integer;
begin
  if p_prospect_ids is null or array_length(p_prospect_ids, 1) is null then return 0; end if;
  if not exists (select 1 from public.lists where id = p_list_id) then
    raise exception 'List not found' using errcode = 'P0002';
  end if;

  delete from public.list_memberships
  where list_id = p_list_id and prospect_id = any(p_prospect_ids);
  get diagnostics removed_count = row_count;

  update public.list_rows
  set prospect_id = null
  where list_id = p_list_id and prospect_id = any(p_prospect_ids);

  return removed_count;
end;
$$;


ALTER FUNCTION public.remove_prospects_from_list_v1(p_list_id text, p_prospect_ids text[]) OWNER TO postgres;

--
-- Name: request_export_v1(text, text, text, text, uuid, text[], text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.request_export_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[] DEFAULT '{}'::text[], p_keys text[] DEFAULT '{}'::text[], p_excluded_ids text[] DEFAULT '{}'::text[], p_file_base_name text DEFAULT 'export'::text) RETURNS TABLE(job_id uuid, status text, row_count bigint, download_token text, reused boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_exports'
    SET statement_timeout TO '15s'
    AS $$
  select * from prospect_exports.request_v1(
    p_owner_id, p_request_id, p_entity_type, p_client_scope, p_result_set_id,
    p_fields, p_keys, p_excluded_ids, p_file_base_name);
$$;


ALTER FUNCTION public.request_export_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text) OWNER TO postgres;

--
-- Name: request_result_set_v1(text, text, text, text, jsonb, text, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.request_result_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb DEFAULT NULL::jsonb, p_company_scope jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(set_id uuid, status text, row_count bigint, reused boolean, stale boolean)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
  select * from prospect_results.request_set_v1(
    p_owner_id, p_entity_type, p_client_scope, p_search, p_filters, p_content_hash,
    -- Still taken here rather than accepted from the browser: a client-supplied
    -- vector could only ever make a stale set look fresh (20260902000160).
    coalesce(p_version_vector, public.data_versions_v1(array[p_entity_type])),
    p_company_scope);
$$;


ALTER FUNCTION public.request_result_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: request_smartlead_campaign_v1(text, uuid, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.request_smartlead_campaign_v1(p_actor text, p_request uuid, p_client text, p_name text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare c public.integration_connections%rowtype; r prospect_integrations.campaign_requests%rowtype; result uuid;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_request is null or p_name is null or length(btrim(p_name)) not between 1 and 160 then
    raise exception 'Invalid campaign request' using errcode='22023'; end if;
  select * into c from public.integration_connections where provider='smartlead' for update;
  select * into r from prospect_integrations.campaign_requests where actor=p_actor and request_id=p_request;
  if found then
    if r.client_id<>p_client or r.name<>btrim(p_name) then raise exception 'Request identity conflict' using errcode='22023'; end if;
    return r.id;
  end if;
  if not c.connected then raise exception 'Connect Smartlead first' using errcode='22023'; end if;
  if (select count(*) from prospect_integrations.campaign_requests where status in ('queued','sending'))>=10
    or (select count(*) from prospect_integrations.campaign_requests)>=1000 then raise exception 'Campaign queue full' using errcode='53300'; end if;
  insert into prospect_integrations.campaign_requests(actor,request_id,client_id,name,generation)
    values(p_actor,p_request,p_client,btrim(p_name),c.generation) returning id into result;
  return result;
end;
$$;


ALTER FUNCTION public.request_smartlead_campaign_v1(p_actor text, p_request uuid, p_client text, p_name text) OWNER TO postgres;

--
-- Name: reserve_integration_read_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reserve_integration_read_v1(p_provider text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_token uuid;
begin
  update public.integration_connections
     set attempt_token=gen_random_uuid(), next_request_at=clock_timestamp()+interval '15 seconds'
   where provider=p_provider and next_request_at<=clock_timestamp()
   returning attempt_token into v_token;
  return v_token;
end;
$$;


ALTER FUNCTION public.reserve_integration_read_v1(p_provider text) OWNER TO postgres;

--
-- Name: resolve_client_company_selection_v1(text, text[], text[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.resolve_client_company_selection_v1(p_client_id text, p_domains text[] DEFAULT NULL::text[], p_names text[] DEFAULT NULL::text[], p_limit integer DEFAULT 50000) RETURNS TABLE(company_id text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $$
  select c.id
  from public.client_companies membership
  join public.companies c on c.id = membership.company_id
  where membership.client_id = p_client_id
    and (c.normalized_domain = any(coalesce(p_domains, array[]::text[]))
      or c.normalized_name = any(coalesce(p_names, array[]::text[])))
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 50000), 50000));
$$;


ALTER FUNCTION public.resolve_client_company_selection_v1(p_client_id text, p_domains text[], p_names text[], p_limit integer) OWNER TO postgres;

--
-- Name: resolve_company_action_selection_v1(text, text[], text, jsonb, jsonb, text[], integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.resolve_company_action_selection_v1(p_client_id text DEFAULT NULL::text, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_limit integer DEFAULT 250000) RETURNS TABLE(company_id text)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $_$
declare
  v_match text;
  v_limit text := greatest(1, least(coalesce(p_limit, 250000), 250000))::text;
  -- Everything except the match clause is identical between the two branches, so
  -- it is written once. The parameter numbering differs, which is why the two
  -- are executed separately rather than through one template with a gap in it.
  v_shell constant text := $q$
    select c.id
    from public.companies c
    where (%1$s is null or exists (
        select 1 from public.client_companies membership
        where membership.client_id = %1$s and membership.company_id = c.id
      ))
      and (%2$s)
      and (%3$s is null or c.id in (select company_id from public.people_scope_company_ids_v1(%1$s, %3$s)))
      and not (c.id = any(%4$s))
    order by c.id
    limit %5$s
  $q$;
begin
  -- An explicit id list never consults the filters at all, so it never pays for
  -- them either.
  if p_company_ids is not null then
    return query execute
      format(v_shell, '$1', 'c.id = any($2[1:50000])', '$3', '$4', v_limit)
      using p_client_id, p_company_ids, p_people_scope, coalesce(p_excluded_ids, array[]::text[]);
    return;
  end if;

  -- Every matching id is wanted, so there is no early exit: the full-scan
  -- chooser, the same one filter_companies_v4 and company_scope_ids_v2 ask.
  v_match := coalesce(
    public.company_full_scan_filter_sql_v1(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)),
    format('public.company_matches_filters_v1(c, %L, %L::jsonb)',
      coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text));

  return query execute
    format(v_shell, '$1', v_match, '$2', '$3', v_limit)
    using p_client_id, p_people_scope, coalesce(p_excluded_ids, array[]::text[]);
end;
$_$;


ALTER FUNCTION public.resolve_company_action_selection_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_limit integer) OWNER TO postgres;

--
-- Name: resolve_filter_set_v1(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.resolve_filter_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text DEFAULT ''::text) RETURNS TABLE(set_id uuid, content_hash text, value_count integer, field text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_filters'
    SET statement_timeout TO '10s'
    AS $$
  select * from prospect_filters.resolve_set_v1(p_set_id, p_owner_id, p_entity_type, p_client_scope);
$$;


ALTER FUNCTION public.resolve_filter_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text) OWNER TO postgres;

--
-- Name: restore_client_company_blocklist_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.restore_client_company_blocklist_v1(p_client_id text) RETURNS text[]
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_ids text[];
begin
  with released as (
    delete from public.client_companies_blocked ccb
    where ccb.client_id = p_client_id
      and public.client_company_block_reason_v1(ccb.client_id, ccb.company_id) is null
    returning ccb.client_id, ccb.company_id, ccb.added_at, ccb.added_by
  ), restored as (
    insert into public.client_companies (client_id, company_id, added_at, added_by)
    select client_id, company_id, added_at, added_by from released
    on conflict (client_id, company_id) do nothing
    returning company_id
  )
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids from restored;

  -- The count was not maintained while the company was out of the table.
  if cardinality(v_ids) > 0 then
    perform public.recompute_client_company_counts_bulk(v_ids);
  end if;
  return v_ids;
end;
$$;


ALTER FUNCTION public.restore_client_company_blocklist_v1(p_client_id text) OWNER TO postgres;

--
-- Name: result_set_page_v1(uuid, text, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.result_set_page_v1(p_set_id uuid, p_owner_id text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS TABLE(entity_id text, ordinal bigint)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '15s'
    AS $$
  select * from prospect_results.page_v1(p_set_id, p_owner_id, p_limit, p_offset);
$$;


ALTER FUNCTION public.result_set_page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer) OWNER TO postgres;

--
-- Name: result_set_status_v1(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.result_set_status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb DEFAULT NULL::jsonb) RETURNS TABLE(status text, row_count bigint, stale boolean, frozen_at timestamp with time zone, version_vector jsonb, error text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'prospect_results'
    SET statement_timeout TO '10s'
    AS $$
declare
  v_entity text;
  v_vector jsonb := p_version_vector;
begin
  -- status_v1 reports `stale` by comparing against the vector it is handed, so
  -- a null one makes it permanently false - the caller would poll a set to
  -- 'ready' and never learn the data had moved underneath it. Take the live
  -- vector here instead, for the same reason the request wrapper does.
  if v_vector is null then
    select rs.entity_type into v_entity from prospect_results.result_sets rs
    where rs.id = p_set_id and rs.owner_id = p_owner_id and rs.expires_at > now();
    if v_entity is not null then
      v_vector := public.data_versions_v1(array[v_entity]);
    end if;
    -- A set that was not found stays status_v1's decision to announce, so that
    -- "not yours" and "never existed" keep answering identically.
  end if;
  return query select * from prospect_results.status_v1(p_set_id, p_owner_id, v_vector);
end;
$$;


ALTER FUNCTION public.result_set_status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb) OWNER TO postgres;

--
-- Name: retry_prospect_import_v1(text, text, text, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.retry_prospect_import_v1(p_import_id text, p_worker_id text, p_error text, p_retry_seconds integer DEFAULT 30, p_max_attempts integer DEFAULT 10) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '5s'
    AS $$
declare
  next_status text;
begin
  update public.imports i
  set status = case when i.attempt_count >= greatest(1, p_max_attempts) then 'failed' else 'queued' end,
      next_attempt_at = now() + make_interval(secs => greatest(1, least(p_retry_seconds, 3600))),
      worker_id = null,
      lease_expires_at = null,
      last_error = left(coalesce(nullif(btrim(p_error), ''), 'Background import failed.'), 1000)
  where i.id = p_import_id
    and i.ingestion_mode = 'background'
    and i.status = 'processing'
    and i.worker_id = p_worker_id
  returning i.status into next_status;
  return next_status;
end;
$$;


ALTER FUNCTION public.retry_prospect_import_v1(p_import_id text, p_worker_id text, p_error text, p_retry_seconds integer, p_max_attempts integer) OWNER TO postgres;

--
-- Name: run_blocklist_share_submission_unit_v1(text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.run_blocklist_share_submission_unit_v1(p_worker text, p_match_limit integer DEFAULT 5000) RETURNS TABLE(job_id uuid, done boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare v_job public.client_blocklist_share_submissions%rowtype; v_result jsonb; v_done boolean;
begin
  if coalesce(btrim(p_worker), '') = '' or length(p_worker) > 200 then
    raise exception 'Invalid worker' using errcode = '22023';
  end if;
  if not pg_try_advisory_xact_lock(hashtextextended('prospect-background-unit-v1', 0)) then return; end if;
  delete from public.client_blocklist_share_limits where window_started_at < now() - interval '2 hours';
  delete from public.client_blocklist_share_submissions
    where status in ('completed','failed') and coalesce(completed_at, created_at) < now() - interval '30 days';
  select * into v_job from public.client_blocklist_share_submissions s
  where s.status = 'queued' or (s.status = 'running' and s.lease_expires_at <= now())
  order by s.created_at for update skip locked limit 1;
  if not found then return; end if;
  update public.client_blocklist_share_submissions set status = 'running', worker_id = p_worker,
    lease_expires_at = now() + interval '5 minutes' where id = v_job.id;
  begin
    v_result := public.add_client_blocklist_batch_v2(v_job.client_id, v_job.domains, v_job.emails,
      v_job.reason, 'client-share:' || v_job.share_id,
      v_job.request_key::text || ':' || v_job.attempts::text, p_match_limit);
    v_done := not coalesce((v_result ->> 'remaining')::boolean, false);
    update public.client_blocklist_share_submissions set attempts = attempts + 1,
      status = case when v_done then 'completed' else 'queued' end,
      worker_id = null, lease_expires_at = null,
      completed_at = case when v_done then now() else null end, last_error = null
    where id = v_job.id;
  exception when others or query_canceled then
    update public.client_blocklist_share_submissions set attempts = attempts + 1,
      status = case when attempts >= 4 then 'failed' else 'queued' end,
      worker_id = null, lease_expires_at = null,
      last_error = 'Submission processing failed (SQLSTATE ' || sqlstate || ').'
    where id = v_job.id;
    v_done := (v_job.attempts >= 4);
  end;
  return query select v_job.id, v_done;
end;
$$;


ALTER FUNCTION public.run_blocklist_share_submission_unit_v1(p_worker text, p_match_limit integer) OWNER TO postgres;

--
-- Name: run_title_classification_batch_v2(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.run_title_classification_batch_v2(p_limit integer DEFAULT 500) RETURNS TABLE(processed integer, remaining bigint, acquired boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    SET statement_timeout TO '60s'
    AS $$
declare
  v_updated_at timestamptz;
begin
  acquired := pg_try_advisory_xact_lock(hashtext('prospect-title-classifier-v2'));
  if not acquired then processed := 0; remaining := null; return next; return; end if;
  processed := public.reclassify_prospect_titles_v1(greatest(1, least(coalesce(p_limit, 500), 5000)));
  select s.keywords_updated_at into v_updated_at from public.title_classifier_state s where s.id;
  select count(*) into remaining from public.prospects p
  where p.title_classified_at is null or p.title_classified_at < v_updated_at;
  return next;
end;
$$;


ALTER FUNCTION public.run_title_classification_batch_v2(p_limit integer) OWNER TO postgres;

--
-- Name: sanitize_import_payloads_v1(text, text, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sanitize_import_payloads_v1(p_entity text, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 1000, p_apply boolean DEFAULT false) RETURNS TABLE(scanned integer, candidates integer, updated integer, next_after_id text, remaining boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit,1000),5000));
  v_ids text[];
  v_table text;
  v_column text;
  v_type text;
begin
  if p_entity = 'membership' then
    -- raw_data was removed from this table in 20260825030000. list_rows is
    -- the surviving source payload; do not scan or rewrite membership links.
    scanned := 0; candidates := 0; updated := 0; next_after_id := null; remaining := false;
    return next; return;
  elsif p_entity = 'prospect' then
    with batch as materialized (
      select p.id, p.all_data, p.personal_email, p.seniority, p.department,
        p.city, p.state, p.country, p.location, p.keywords,
        public.fixed_import_json_v1('prospect',p.all_data) || jsonb_strip_nulls(jsonb_build_object(
          'First Name',nullif(p.first_name,''),'Last Name',nullif(p.last_name,''),
          'Job Title',nullif(p.title,''),'Email',nullif(p.work_email,''),
          'Mobile Number',nullif(p.mobile_number,''),'Personal LinkedIn URL',nullif(p.linkedin_url,''),
          'Company Name',nullif(c.name,''),'Website',nullif(c.domain,''))) as sanitized
      from public.prospects p left join public.companies c on c.id=p.company_id
      where p.id > coalesce(p_after_id,'') order by p.id limit v_limit
    ), changed as materialized (
      select * from batch where all_data is distinct from sanitized
        or concat(personal_email,seniority,department,city,state,country,location) <> ''
        or coalesce(cardinality(keywords),0)>0
        or exists(select 1 from public.prospect_identifiers i where i.prospect_id=batch.id and i.type='personal_email')
    ), applied as (
      update public.prospects p set all_data=c.sanitized, personal_email='',
        seniority='',department='',city='',state='',country='',location='',keywords='{}'::text[]
      from changed c where p_apply and p.id=c.id returning p.id
    ) select (select count(*)::integer from batch),(select count(*)::integer from changed),
      count(*)::integer,(select max(id) from batch),array_agg(id)
      into scanned,candidates,updated,next_after_id,v_ids from applied;
    if p_apply and cardinality(v_ids)>0 then
      delete from public.prospect_identifiers where type='personal_email' and prospect_id=any(v_ids);
      perform public.reindex_prospects(v_ids);
    end if;
    remaining := next_after_id is not null and exists(select 1 from public.prospects p where p.id>next_after_id);
    return next; return;
  elsif p_entity = 'catalog' then
    with batch as materialized (
      select field_name from public.prospect_fields where field_name>coalesce(p_after_id,'') order by field_name limit v_limit
    ), changed as (
      select field_name from batch where field_name not in
        ('First Name','Last Name','Job Title','Email','Mobile Number','Personal LinkedIn URL','Company Name','Website')
    ), applied as (
      delete from public.prospect_fields f using changed c where p_apply and f.field_name=c.field_name returning f.field_name
    ) select (select count(*)::integer from batch),(select count(*)::integer from changed),
      (select count(*)::integer from applied),(select max(field_name) from batch)
      into scanned,candidates,updated,next_after_id;
    remaining := next_after_id is not null and exists(select 1 from public.prospect_fields f where f.field_name>next_after_id);
    return next; return;
  elsif p_entity in ('company','list_row') then
    v_table := case p_entity when 'company' then 'companies' else 'list_rows' end;
    v_column := case p_entity when 'company' then 'all_data' else 'raw_data' end;
    v_type := case p_entity when 'company' then 'text' else 'bigint' end;
    return query execute format($sql$
      with batch as materialized (
        select id,%1$I as payload,public.fixed_import_json_v1(%2$L,%1$I) as sanitized
        from public.%3$I where id>coalesce(nullif($1,'')::%4$s,%5$L::%4$s) order by id limit $2
      ), changed as (select * from batch where payload is distinct from sanitized), applied as (
        update public.%3$I t set %1$I=c.sanitized from changed c where $3 and t.id=c.id returning t.id
      ) select (select count(*)::integer from batch),(select count(*)::integer from changed),
        (select count(*)::integer from applied),(select max(id)::text from batch),
        exists(select 1 from public.%3$I where id>(select max(id) from batch))
    $sql$,v_column,case p_entity when 'company' then 'company' else 'prospect' end,v_table,v_type,
      case p_entity when 'company' then '' else '0' end) using p_after_id,v_limit,p_apply;
    return;
  end if;
  raise exception 'Unsupported cleanup entity' using errcode='22023';
end;
$_$;


ALTER FUNCTION public.sanitize_import_payloads_v1(p_entity text, p_after_id text, p_limit integer, p_apply boolean) OWNER TO postgres;

--
-- Name: search_company_export_v1(text, jsonb, jsonb, boolean, text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_company_export_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_websites_only boolean DEFAULT false, p_after_name text DEFAULT NULL::text, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000) RETURNS TABLE(result_rows jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $_$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_scope_cte text := '';
  v_where text;
  v_sql text;
begin
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  v_where := format('(%s)', v_match_clause);
  if coalesce(p_websites_only, false) then
    v_where := v_where || $w$ and btrim(coalesce(c.domain, '')) <> ''$w$;
  end if;
  if p_people_scope is not null then
    v_scope_cte := format($s$with scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(null::text, %L::jsonb)
      ) $s$, p_people_scope::text);
    v_where := v_where || ' and c.id in (select company_id from scope_ids)';
  end if;

  -- Keyset on (lower(name), id): total, indexed, and stable across pages even
  -- while companies are being inserted underneath it.
  v_sql := format($q$
    %1$s select coalesce((select jsonb_agg(
      jsonb_build_object('id', page.id, 'name', page.name, 'domain', page.domain, 'sort_name', page.sort_name)
      order by page.sort_name, page.id) from (
      select c.id, c.name, c.domain, lower(c.name) as sort_name
      from public.companies c
      where %2$s
        and (%3$L::text is null or (lower(c.name), c.id) > (%3$L::text, coalesce(%4$L, '')))
      order by lower(c.name), c.id
      limit %5$s
    ) page), '[]'::jsonb)
  $q$, v_scope_cte, v_where, p_after_name, p_after_id, v_limit::text);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_company_export_v1(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer) OWNER TO postgres;

--
-- Name: search_company_export_v2(text, jsonb, jsonb, boolean, text, text, integer, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_company_export_v2(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_websites_only boolean DEFAULT false, p_after_name text DEFAULT NULL::text, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_keys text[] DEFAULT '{}'::text[]) RETURNS TABLE(result_rows jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $_$
declare
  v_prefilter text := public.company_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_complete text := public.company_effective_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_scope_cte text := '';
  v_where text;
  v_columns text;
  v_select text;
  v_sql text;
begin
  if v_complete is not null then
    v_match_clause := v_complete;
  else
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.company_matches_filters_v1(c, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  end if;

  v_where := format('(%s)', v_match_clause);
  if coalesce(p_websites_only, false) then
    v_where := v_where || $w$ and btrim(coalesce(c.domain, '')) <> ''$w$;
  end if;
  if p_people_scope is not null then
    v_scope_cte := format($s$with scope_ids as materialized (
        select company_id from public.people_scope_company_ids_v1(null::text, %L::jsonb)
      ) $s$, p_people_scope::text);
    v_where := v_where || ' and c.id in (select company_id from scope_ids)';
  end if;

  -- Only real columns of public.companies survive this join, so nothing a
  -- caller invents can reach the statement, and %I quotes what does.
  select string_agg(format('c.%I', columns.column_name), ', ' order by columns.column_name)
    into v_columns
  from unnest(coalesce(p_keys, '{}'::text[])) as requested(name)
  join information_schema.columns columns
    on columns.table_schema = 'public'
   and columns.table_name = 'companies'
   and columns.column_name = requested.name
  where columns.column_name <> 'id';

  -- No keys means every column, which is what a caller with nothing to say
  -- meant and what v1 effectively did for the three it knew about.
  if coalesce(cardinality(p_keys), 0) = 0 then
    v_select := 'c.*, lower(c.name) as sort_name';
  else
    v_select := 'c.id, lower(c.name) as sort_name' || coalesce(', ' || v_columns, '');
  end if;

  -- Keyset on (lower(name), id): total, indexed by idx_companies_lower_name_id,
  -- and stable across pages even while companies are being inserted underneath
  -- it. sort_name travels with the row because the cursor has to be the value
  -- PostgreSQL sorted on - lower-casing it again in Node would be a different
  -- function under a different collation, and a cursor that disagrees with the
  -- ORDER BY skips or repeats rows.
  v_sql := format($q$
    %1$s select coalesce((select jsonb_agg(to_jsonb(page) order by page.sort_name, page.id) from (
      select %6$s
      from public.companies c
      where %2$s
        and (%3$L::text is null or (lower(c.name), c.id) > (%3$L::text, coalesce(%4$L, '')))
      order by lower(c.name), c.id
      limit %5$s
    ) page), '[]'::jsonb)
  $q$, v_scope_cte, v_where, p_after_name, p_after_id, v_limit::text, v_select);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_company_export_v2(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer, p_keys text[]) OWNER TO postgres;

--
-- Name: search_prospect_export_v1(text, jsonb, text, timestamp with time zone, text, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_export_v1(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_with_total boolean DEFAULT false) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $_$
  with filtered as (
    select ps.*
    from public.prospect_index ps
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
    and (
      btrim(coalesce(p_search, '')) = ''
      or ps.search_text ilike '%' || btrim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__first_name' then ps.first_name
          when '__last_name' then ps.last_name
          when '__company' then ps.company_name
          when '__email' then concat_ws(' ', ps.work_email, ps.personal_email)
          when '__work_email' then ps.work_email
          when '__personal_email' then ps.personal_email
          when '__title' then ps.title
          when '__keywords' then array_to_string(ps.keywords, ' | ')
          when '__linkedin' then ps.linkedin_url
          when '__city' then ps.city
          when '__state' then ps.state
          when '__country' then ps.country
          when '__person_location' then concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, ''))
          when '__company_location' then concat_ws(', ', nullif(ps.company_location, ''), nullif(ps.company_city, ''), nullif(ps.company_state, ''), nullif(ps.company_country, ''))
          when '__company_city' then ps.company_city
          when '__company_state' then ps.company_state
          when '__company_country' then ps.company_country
          when '__seniority' then ps.seniority
          when '__department' then ps.department when '__title_department' then ps.title_department when '__title_sub_department' then ps.title_sub_department when '__title_seniority_tier' then ps.title_seniority when '__title_seniority' then concat_ws(' ', ps.title, ps.seniority) when '__esp_type' then concat_ws(' ', ps.esp, ps.email_provider_type)
          when '__esp' then ps.esp
          when '__email_provider_type' then ps.email_provider_type
          when '__tags' then ps.tag_text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else case when filter_item->>'field' like 'custom:%' then coalesce((
            select string_agg(entry.value, ' | ' order by entry.key)
            from jsonb_each_text(ps.all_data) entry(key, value)
            where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
          ), '') else '' end
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
            ))
        )
        when 'not_equals' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'not_contains' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
        when 'boolean' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where to_tsvector('simple', candidate.candidate_value) @@ to_tsquery('simple', selected.value)
        )
        when 'number_ranges' then exists (
          select 1
          from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          cross join lateral (
            select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
              case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
          ) selected_range
          where filter_item->>'field' = '__employee_count'
            and (
              (selected.value = 'unknown' and ps.employee_count_min is null and ps.employee_count_max is null)
              or (selected.value <> 'unknown' and ps.employee_count_min is not null
                and (selected_range.maximum is null or ps.employee_count_min <= selected_range.maximum)
                and (ps.employee_count_max is null or ps.employee_count_max >= selected_range.minimum))
            )
        )
        when 'empty' then btrim(candidate.candidate_value) = ''
        when 'not_empty' then btrim(candidate.candidate_value) <> ''
        else exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
      end
    )
  ), page as (
    select * from filtered
    where p_after_created_at is null
      or (filtered.created_at, filtered.id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by filtered.created_at desc, filtered.id desc
    limit greatest(1, least(coalesce(p_limit, 5000), 50000))
  )
  select coalesce((
    select jsonb_agg(ordered.row_json order by ordered.created_at_key desc, ordered.id_key desc)
    from (select to_jsonb(page) as row_json, page.created_at as created_at_key, page.id as id_key from page) ordered
  ), '[]'::jsonb),
  case when p_with_total then (select count(*) from filtered) else null end;
$_$;


ALTER FUNCTION public.search_prospect_export_v1(p_search text, p_filters jsonb, p_client_id text, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) OWNER TO postgres;

--
-- Name: search_prospect_export_v3(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_export_v3(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_with_total boolean DEFAULT false) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
  with eligible_companies as materialized (
    select company_id from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
  ), filtered as materialized (
    select ps.* from public.prospect_index ps
    join eligible_companies eligible on eligible.company_id = ps.company_id
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and ((btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.prospect_index_matches_v1(ps, p_search, p_filters))
  ), page as (
    select * from filtered
    where p_after_created_at is null or (filtered.created_at, filtered.id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by filtered.created_at desc, filtered.id desc
    limit greatest(1, least(coalesce(p_limit, 5000), 50000))
  )
  select coalesce((select jsonb_agg(to_jsonb(page) order by page.created_at desc, page.id desc) from page), '[]'::jsonb),
    case when p_with_total then (select count(*) from filtered) else null end;
$$;


ALTER FUNCTION public.search_prospect_export_v3(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) OWNER TO postgres;

--
-- Name: search_prospect_export_v4(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_export_v4(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_with_total boolean DEFAULT false) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $_$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_complete text := public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_scope_cte text;
  v_scope_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  else
    v_scope_cte := '';
    v_scope_join := '';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched
      where %5$L::timestamptz is null or (matched.created_at, matched.id) < (%5$L::timestamptz, coalesce(%6$L, ''))
      order by matched.created_at desc, matched.id desc
      limit %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      case when %8$L then (select count(*) from matched) else null end
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause,
       p_after_created_at, p_after_id, v_limit::text, p_with_total);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_prospect_export_v4(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) OWNER TO postgres;

--
-- Name: search_prospect_export_v5(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_export_v5(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_with_total boolean DEFAULT false, p_keys text[] DEFAULT '{}'::text[]) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $_$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_complete text := public.prospect_filter_sql_v1(p_search, coalesce(p_filters, '[]'::jsonb));
  v_scope_cte text;
  v_scope_join text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
  v_keys text[] := coalesce(p_keys, '{}'::text[]);
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
  else
    v_scope_cte := '';
    v_scope_join := '';
  end if;

  v_sql := format($q$
    with %1$s matched as materialized (
      select pi.id, pi.created_at
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched
      where %5$L::timestamptz is null or (matched.created_at, matched.id) < (%5$L::timestamptz, coalesce(%6$L, ''))
      order by matched.created_at desc, matched.id desc
      limit %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_export_source pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(
             public.jsonb_project_v1(to_jsonb(hydrated) - 'page_order', %9$L::text[])
             order by page_order) from hydrated), '[]'::jsonb),
      case when %8$L then (select count(*) from matched) else null end
  $q$, v_scope_cte, v_scope_join, p_client_id, v_match_clause,
       p_after_created_at, p_after_id, v_limit::text, p_with_total, v_keys);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_prospect_export_v5(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]) OWNER TO postgres;

--
-- Name: search_prospect_export_v6(text, jsonb, text, jsonb, timestamp with time zone, text, integer, boolean, text[]); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_export_v6(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_after_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_after_id text DEFAULT NULL::text, p_limit integer DEFAULT 5000, p_with_total boolean DEFAULT false, p_keys text[] DEFAULT '{}'::text[]) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_has_cap boolean := exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company');
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 50000));
begin
  if not v_has_cap then
    return query select * from public.search_prospect_export_v5(
      p_search, p_filters, p_client_id, p_company_scope, p_after_created_at,
      p_after_id, p_limit, p_with_total, p_keys);
    return;
  end if;

  return query
  with candidates as materialized (
    select * from public.prospect_capped_candidate_ids_v1(
      p_search, p_filters, p_client_id, p_company_scope)
  ), ordered_page as (
    select candidate.prospect_id as id, candidate.created_at
    from candidates candidate
    where p_after_created_at is null
      or (candidate.created_at, candidate.prospect_id) < (p_after_created_at, coalesce(p_after_id, ''))
    order by candidate.created_at desc, candidate.prospect_id desc
    limit v_limit
  ), page as (
    select ordered_page.*, row_number() over (order by created_at desc, id desc) as page_order
    from ordered_page
  ), hydrated as (
    select pi.*, page.page_order
    from page join public.prospect_index pi on pi.id = page.id
  )
  select coalesce((select jsonb_agg(
      public.jsonb_project_v1(to_jsonb(hydrated) - 'page_order', coalesce(p_keys, '{}'::text[]))
      order by page_order) from hydrated), '[]'::jsonb),
    case when p_with_total then (select count(*)::bigint from candidates) else null::bigint end;
end;
$$;


ALTER FUNCTION public.search_prospect_export_v6(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]) OWNER TO postgres;

--
-- Name: search_prospect_workspace_v10(text, jsonb, text, text, integer, integer, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_workspace_v10(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $_$
declare
  v_has_people boolean := (btrim(coalesce(p_search, '')) <> '' or coalesce(p_filters, '[]'::jsonb) <> '[]'::jsonb);
  v_prefilter text := public.prospect_prefilter_sql(p_search, coalesce(p_filters, '[]'::jsonb));
  v_match_clause text;
  v_order text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sql text;
begin
  if v_has_people then
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', p_search, coalesce(p_filters, '[]'::jsonb)::text);
  else
    v_match_clause := 'true';
  end if;

  v_order := format($o$
    case when %1$L = 'name' and lower(%2$L) = 'asc' then lower(full_name) end asc,
    case when %1$L = 'name' and lower(%2$L) = 'desc' then lower(full_name) end desc,
    case when %1$L = 'company' and lower(%2$L) = 'asc' then lower(company_name) end asc,
    case when %1$L = 'company' and lower(%2$L) = 'desc' then lower(company_name) end desc,
    case when %1$L = 'title' and lower(%2$L) = 'asc' then lower(title) end asc,
    case when %1$L = 'title' and lower(%2$L) = 'desc' then lower(title) end desc,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'asc' then last_contacted_at end asc nulls first,
    case when %1$L = 'last_contacted' and lower(%2$L) = 'desc' then last_contacted_at end desc nulls last,
    case when %1$L = 'created_at' and lower(%2$L) = 'asc' then created_at end asc,
    created_at desc, id
  $o$, p_sort, p_direction);

  v_sql := format($q$
    with eligible_companies as materialized (
      select company_id from public.company_scope_ids_v2(%1$L, %2$L::jsonb)
    ), matched as materialized (
      select pi.id, pi.created_at, pi.full_name, pi.company_name, pi.title, pi.last_contacted_at
      from public.prospect_index pi
      join eligible_companies eligible on eligible.company_id = pi.company_id
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
    ), ordered_page as (
      select * from matched order by %5$s limit %6$s offset %7$s
    ), page as (
      select ordered_page.*, row_number() over (order by %5$s) as page_order from ordered_page
    ), hydrated as (
      select pi.*, page.page_order from page join public.prospect_index pi on pi.id = page.id
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      (select count(*) from matched)
  $q$, p_client_id, p_company_scope::text, p_client_id, v_match_clause, v_order, v_limit::text, v_offset::text);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_prospect_workspace_v10(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: search_prospect_workspace_v11(text, jsonb, text, text, integer, integer, text, jsonb, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_workspace_v11(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '15s'
    AS $_$
  with filtered as (
    select ps.*
    from public.prospect_index ps
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
    and (
      coalesce(p_company_scope, '{}'::jsonb) = '{}'::jsonb
      or ps.company_id in (
        select company_id
        from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
      )
    )
    and (
      btrim(coalesce(p_search, '')) = ''
      or ps.search_text ilike '%' || btrim(p_search) || '%'
    )
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) filter_item
      cross join lateral (
        select coalesce(case filter_item->>'field'
          when '__name' then ps.full_name
          when '__first_name' then ps.first_name
          when '__last_name' then ps.last_name
          when '__company' then ps.company_name
          when '__email' then concat_ws(' ', ps.work_email, ps.personal_email)
          when '__work_email' then ps.work_email
          when '__personal_email' then ps.personal_email
          when '__title' then ps.title
          when '__keywords' then array_to_string(ps.keywords, ' | ')
          when '__linkedin' then ps.linkedin_url
          when '__city' then ps.city
          when '__state' then ps.state
          when '__country' then ps.country
          when '__person_location' then concat_ws(', ', nullif(ps.city, ''), nullif(ps.state, ''), nullif(ps.country, ''))
          when '__company_location' then concat_ws(', ', nullif(ps.company_location, ''), nullif(ps.company_city, ''), nullif(ps.company_state, ''), nullif(ps.company_country, ''))
          when '__company_city' then ps.company_city
          when '__company_state' then ps.company_state
          when '__company_country' then ps.company_country
          when '__seniority' then ps.seniority
          when '__department' then ps.department when '__title_department' then ps.title_department when '__title_sub_department' then ps.title_sub_department when '__title_seniority_tier' then ps.title_seniority
          when '__esp' then ps.esp
          when '__email_provider_type' then ps.email_provider_type
          when '__tags' then ps.tag_text
          when '__last_contacted' then ps.last_contacted_at::text
          when '__lists' then array_to_string(ps.list_names, ' | ')
          when '__clients' then array_to_string(ps.client_names, ' | ')
          else case when filter_item->>'field' like 'custom:%' then coalesce((
            select string_agg(entry.value, ' | ' order by entry.key)
            from jsonb_each_text(ps.all_data) entry(key, value)
            where regexp_replace(lower(entry.key), '[^a-z0-9]+', '', 'g') = substring(filter_item->>'field' from 8)
          ), '') else '' end
        end, '') as candidate_value
      ) candidate
      where not case coalesce(filter_item->>'operator', 'contains')
        when 'equals' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
            or (filter_item->>'field' in ('__lists', '__clients') and selected.value = any(
              case when filter_item->>'field' = '__lists' then ps.list_names else ps.client_names end
            ))
        )
        when 'not_equals' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where lower(candidate.candidate_value) = lower(selected.value)
        )
        when 'not_contains' then not exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
        when 'boolean' then exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where to_tsvector('simple', candidate.candidate_value) @@ to_tsquery('simple', selected.value)
        )
        when 'number_ranges' then exists (
          select 1
          from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          cross join lateral (
            select case when selected.value ~ '^[0-9]+:[0-9]*$' then split_part(selected.value, ':', 1)::integer end as minimum,
              case when selected.value ~ '^[0-9]+:[0-9]+$' then split_part(selected.value, ':', 2)::integer end as maximum
          ) selected_range
          where filter_item->>'field' = '__employee_count'
            and (
              (selected.value = 'unknown' and ps.employee_count_min is null and ps.employee_count_max is null)
              or (selected.value <> 'unknown' and ps.employee_count_min is not null
                and (selected_range.maximum is null or ps.employee_count_min <= selected_range.maximum)
                and (ps.employee_count_max is null or ps.employee_count_max >= selected_range.minimum))
            )
        )
        when 'empty' then btrim(candidate.candidate_value) = ''
        when 'not_empty' then btrim(candidate.candidate_value) <> ''
        else exists (
          select 1 from jsonb_array_elements_text(coalesce(filter_item->'values', '[]'::jsonb)) selected(value)
          where candidate.candidate_value ilike '%' || selected.value || '%'
        )
      end
    )
  ), sorted as (
    select * from filtered
    order by
      case when p_sort = 'name' and lower(p_direction) = 'asc' then lower(full_name) end asc,
      case when p_sort = 'name' and lower(p_direction) = 'desc' then lower(full_name) end desc,
      case when p_sort = 'company' and lower(p_direction) = 'asc' then lower(company_name) end asc,
      case when p_sort = 'company' and lower(p_direction) = 'desc' then lower(company_name) end desc,
      case when p_sort = 'title' and lower(p_direction) = 'asc' then lower(title) end asc,
      case when p_sort = 'title' and lower(p_direction) = 'desc' then lower(title) end desc,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'asc' then last_contacted_at end asc nulls first,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'desc' then last_contacted_at end desc nulls last,
      case when p_sort = 'created_at' and lower(p_direction) = 'asc' then created_at end asc,
      created_at desc,
      id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
    offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb),
    case
      when not p_with_total then null
      when btrim(coalesce(p_search, '')) = ''
        and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb
        and p_client_id is null
        and coalesce(p_company_scope, '{}'::jsonb) = '{}'::jsonb
        then (
          select pg_class.reltuples::bigint
          from pg_class
          join pg_namespace on pg_namespace.oid = pg_class.relnamespace
          where pg_namespace.nspname = 'public' and pg_class.relname = 'prospect_index'
        )
      else (select count(*) from filtered)
    end;
$_$;


ALTER FUNCTION public.search_prospect_workspace_v11(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean) OWNER TO postgres;

--
-- Name: search_prospect_workspace_v12(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_workspace_v12(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true, p_known_versions jsonb DEFAULT NULL::jsonb) RETURNS TABLE(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean, data_versions jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '10s'
    AS $_$
declare
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_filters jsonb := coalesce(p_filters, '[]'::jsonb);
  v_search text := coalesce(p_search, '');
  v_has_scope boolean := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  -- Mirrors the clamp inside company_scope_ids_v2, so "did the scope hit its
  -- ceiling" is answered against the same number the scope actually used.
  v_scope_limit integer := case
    when coalesce(v_scope->>'limit', '') ~ '^[0-9]+$'
      then greatest(1000, least((v_scope->>'limit')::bigint, 250000))::integer
    else 250000
  end;
  v_has_people boolean := (btrim(v_search) <> '' or v_filters <> '[]'::jsonb);
  v_has_company_filter boolean := exists (
    select 1 from jsonb_array_elements(v_filters) item
    where item->>'field' = '__incomplete_company_profile'
  );
  v_unscoped boolean := (not v_has_people and p_client_id is null and not v_has_scope);
  v_prefilter text;
  v_match_clause text;
  v_complete text;
  v_scope_cte text;
  v_scope_join text;
  v_capped_expr text;
  v_sort_expr text;
  v_sort_dir text;
  v_sort_nulls text;
  v_order text;
  v_count_cte text;
  v_total_expr text;
  v_total_capped_expr text;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  -- The dependency-version vector this answer is valid at, and whether the
  -- caller's cached total was computed at the same one.
  v_versions jsonb;
  v_want_total boolean;
  v_sql text;
  v_ordered_cte text;
  v_client_members bigint;
begin
  if v_has_people then
    v_prefilter := public.prospect_prefilter_sql(v_search, v_filters);
    v_complete := public.prospect_filter_sql_v1(v_search, v_filters);
    v_match_clause := case when v_prefilter <> 'true' and v_prefilter is distinct from v_complete then '(' || v_prefilter || ') and ' else '' end
      || '(' || coalesce(v_complete,
        format('public.prospect_index_matches_v1(pi, %L, %L::jsonb)', v_search, v_filters::text)) || ')';
  else
    v_match_clause := 'true';
  end if;

  if v_has_scope then
    v_scope_cte := format('eligible_companies as materialized (select company_id from public.company_scope_ids_v2(%L, %L::jsonb)), ',
      p_client_id, v_scope::text);
    v_scope_join := ' join eligible_companies eligible on eligible.company_id = pi.company_id';
    v_capped_expr := format('((select count(*) from eligible_companies) >= %s)', v_scope_limit::text);
  else
    v_scope_cte := '';
    v_scope_join := '';
    v_capped_expr := 'false';
  end if;

  -- Static, allow-listed sort. p_sort and p_direction never reach the SQL as
  -- text; they choose a branch, and the branch is a constant. An unknown sort
  -- falls to created_at, which is what the previous CASE chain did too.
  v_sort_dir := case when lower(coalesce(p_direction, 'desc')) = 'asc' then 'asc' else 'desc' end;
  case coalesce(p_sort, 'created_at')
    when 'name' then
      v_sort_expr := 'lower(pi.full_name)';
      v_sort_nulls := '';
    when 'company' then
      v_sort_expr := 'lower(pi.company_name)';
      v_sort_nulls := '';
    when 'title' then
      v_sort_expr := 'lower(pi.title)';
      v_sort_nulls := '';
    when 'last_contacted' then
      v_sort_expr := 'pi.last_contacted_at';
      -- Matches idx_prospect_index_last_contacted (DESC NULLS LAST) forwards,
      -- and its exact reverse backwards, so both directions are index-served.
      v_sort_nulls := case when v_sort_dir = 'asc' then ' nulls first' else ' nulls last' end;
    else
      v_sort_expr := 'pi.created_at';
      v_sort_nulls := '';
  end case;
  v_order := format('%s %s%s, pi.id', v_sort_expr, v_sort_dir, v_sort_nulls);

  -- Which entity versions this query actually reads. A People query depends on
  -- the prospect version; one carrying a company scope reads public.companies
  -- through company_scope_ids_v2 and depends on the company version too. A
  -- single-entity query never carries a version it does not read, so a company
  -- import cannot invalidate every People count for no reason.
  v_versions := public.data_versions_v1(
    case when v_has_scope or v_has_company_filter
      then array['prospect', 'company'] else array['prospect'] end);

  -- The caller caches a total against the vector it was counted at. If any
  -- component has moved since, that total is stale and this call recounts
  -- whether or not it was asked to -- so a completed mutation cannot leave a
  -- stale count on screen waiting for some later page load to notice.
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;

  -- The count is still its own scan rather than the page's, but it no longer
  -- carries a LIMIT: the number on screen is the number of matching rows.
  if not v_want_total then
    v_count_cte := '';
    v_total_expr := 'null::bigint';
    v_total_capped_expr := 'false';
  elsif v_unscoped then
    -- The whole-database total, counted rather than estimated. reltuples read
    -- 681,304 against a true 681,085 on the day this was written: 219 people
    -- the header invented, and a number that could never be reconciled against
    -- an export. Counting it is an index-only scan of one column -- 175-234 ms
    -- warm against a 10 s ceiling, behind a version cache that skips it
    -- entirely until prospects actually move.
    v_count_cte := '';
    v_total_expr := '(select count(*)::bigint from public.prospect_index)';
    v_total_capped_expr := 'false';
  elsif public.prospect_filters_need_company_lookup_v1(p_filters) then
    -- Bounded: stop at 50,001 and report 50,000+ rather than scanning the whole
    -- table a second time for a number nobody can read past the first page.
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows from (
        select 1
        from public.prospect_index pi%s
        where (%L is null or pi.client_ids @> array[%L]) and (%s)
        limit 50001
      ) bounded
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause);
    v_total_expr := 'least((select counted.matched_rows from counted), 50000)';
    v_total_capped_expr := '((select counted.matched_rows from counted) > 50000)';
  else
    v_count_cte := format($c$counted as (
      select count(*)::bigint as matched_rows
      from public.prospect_index pi%s
      where (%L is null or pi.client_ids @> array[%L]) and (%s)
    ), $c$, v_scope_join, p_client_id, p_client_id, v_match_clause);
    v_total_expr := '(select counted.matched_rows from counted)';
    -- Retained in the result type, and permanently false. The column is what
    -- the API and the grid read to decide whether to print a "+", so dropping
    -- it would be a wire change for no gain; and if a cap ever has to come
    -- back, the branches that honour it are still there on both sides.
    v_total_capped_expr := 'false';
  end if;

  -- A small client is read through the client_ids GIN index and then sorted;
  -- the index walk in sort order is kept for everything else. See
  -- 20260923090000 for the measurements.
  if p_client_id is not null then
    select count(*) into v_client_members from (
      select 1 from public.client_prospects
      where client_id = p_client_id
      limit 50001
    ) members;
  end if;

  if p_client_id is not null and v_client_members <= 50000 then
    v_ordered_cte := format($o$client_rows as materialized (
      select pi.id, %1$s as sort_key
      from public.prospect_index pi%2$s
      where pi.client_ids @> array[%3$L] and (%4$s)
    ), ordered as (
      select client_rows.id, client_rows.sort_key
      from client_rows
      order by client_rows.sort_key %5$s%6$s, client_rows.id
      limit %7$s offset %8$s
    )$o$, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_sort_dir, v_sort_nulls, v_limit::text, v_offset::text);
  else
    v_ordered_cte := format($o$ordered as (
      select pi.id, %1$s as sort_key
      from public.prospect_index pi%2$s
      where (%3$L is null or pi.client_ids @> array[%3$L]) and (%4$s)
      order by %5$s
      limit %6$s offset %7$s
    )$o$, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_order, v_limit::text, v_offset::text);
  end if;

  v_sql := format($q$
    with %1$s%2$s%16$s, page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key %10$s%11$s, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %5$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order) from hydrated), '[]'::jsonb),
      %12$s,
      %13$s,
      %14$s,
      %15$L::jsonb
  $q$, v_scope_cte, v_count_cte, v_sort_expr, v_scope_join, p_client_id, v_match_clause,
       v_order, v_limit::text, v_offset::text, v_sort_dir, v_sort_nulls,
       v_total_expr, v_capped_expr, v_total_capped_expr, v_versions::text, v_ordered_cte);

  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_prospect_workspace_v12(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb) OWNER TO postgres;

--
-- Name: search_prospect_workspace_v13(text, jsonb, text, text, integer, integer, text, jsonb, boolean, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_workspace_v13(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb, p_with_total boolean DEFAULT true, p_known_versions jsonb DEFAULT NULL::jsonb) RETURNS TABLE(result_rows jsonb, total_count bigint, scope_capped boolean, total_capped boolean, data_versions jsonb)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '20s'
    AS $_$
declare
  v_has_cap boolean := exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__max_people_per_company');
  v_scope jsonb := coalesce(p_company_scope, '{}'::jsonb);
  v_has_scope boolean;
  v_has_company_filter boolean := exists (
    select 1 from jsonb_array_elements(coalesce(p_filters, '[]'::jsonb)) item
    where item->>'field' = '__incomplete_company_profile'
  );
  v_scope_limit integer;
  v_scope_capped boolean := false;
  v_versions jsonb;
  v_want_total boolean;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_sort_expr text;
  v_sort_dir text;
  v_sort_nulls text := '';
  v_order text;
  v_sql text;
begin
  if not v_has_cap then
    return query select * from public.search_prospect_workspace_v12(
      p_search, p_filters, p_sort, p_direction, p_limit, p_offset,
      p_client_id, p_company_scope, p_with_total, p_known_versions);
    return;
  end if;

  v_has_scope := v_scope <> '{}'::jsonb
    and (btrim(coalesce(v_scope->>'search', '')) <> ''
      or coalesce(v_scope->'filters', '[]'::jsonb) <> '[]'::jsonb);
  v_scope_limit := case when coalesce(v_scope->>'limit', '') ~ '^[0-9]+$'
    then greatest(1000, least((v_scope->>'limit')::bigint, 250000))::integer
    else 250000 end;
  if v_has_scope then
    select count(*) >= v_scope_limit into v_scope_capped
    from public.company_scope_ids_v2(p_client_id, v_scope);
  end if;

  v_versions := public.data_versions_v1(
    case when v_has_scope or v_has_company_filter
      then array['prospect', 'company'] else array['prospect'] end);
  v_want_total := p_with_total or p_known_versions is null or p_known_versions <> v_versions;
  v_sort_dir := case when lower(coalesce(p_direction, 'desc')) = 'asc' then 'asc' else 'desc' end;
  case coalesce(p_sort, 'created_at')
    when 'name' then v_sort_expr := 'lower(pi.full_name)';
    when 'company' then v_sort_expr := 'lower(pi.company_name)';
    when 'title' then v_sort_expr := 'lower(pi.title)';
    when 'last_contacted' then
      v_sort_expr := 'pi.last_contacted_at';
      v_sort_nulls := case when v_sort_dir = 'asc' then ' nulls first' else ' nulls last' end;
    else v_sort_expr := 'pi.created_at';
  end case;
  v_order := format('%s %s%s, pi.id', v_sort_expr, v_sort_dir, v_sort_nulls);

  v_sql := format($sql$
    with candidates as materialized (
      select * from public.prospect_capped_candidate_ids_v1(%1$L, %2$L::jsonb, %3$L, %4$L::jsonb)
    ), ordered as (
      select pi.id, %5$s as sort_key
      from candidates candidate
      join public.prospect_index pi on pi.id = candidate.prospect_id
      order by %6$s
      limit %7$s offset %8$s
    ), page as (
      select ordered.id,
        row_number() over (order by ordered.sort_key %9$s%10$s, ordered.id) as page_order
      from ordered
    ), hydrated as (
      select pi.*, cp.date_added as client_date_contacted,
        cp.date_added as client_date_added, page.page_order
      from page
      join public.prospect_index pi on pi.id = page.id
      left join public.client_prospects cp
        on cp.prospect_id = page.id and cp.client_id = %3$L
    )
    select coalesce((select jsonb_agg(to_jsonb(hydrated) - 'page_order' order by page_order)
      from hydrated), '[]'::jsonb),
      case when %11$L then (select count(*)::bigint from candidates) else null::bigint end,
      %12$L::boolean, false, %13$L::jsonb
  $sql$, coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text,
    p_client_id, v_scope::text, v_sort_expr, v_order, v_limit::text, v_offset::text,
    v_sort_dir, v_sort_nulls, v_want_total, v_scope_capped, v_versions::text);
  return query execute v_sql;
end;
$_$;


ALTER FUNCTION public.search_prospect_workspace_v13(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb) OWNER TO postgres;

--
-- Name: search_prospect_workspace_v9(text, jsonb, text, text, integer, integer, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.search_prospect_workspace_v9(p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_sort text DEFAULT 'created_at'::text, p_direction text DEFAULT 'desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_client_id text DEFAULT NULL::text, p_company_scope jsonb DEFAULT '{}'::jsonb) RETURNS TABLE(result_rows jsonb, total_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
  with eligible_companies as materialized (
    select company_id from public.company_scope_ids_v2(p_client_id, coalesce(p_company_scope, '{}'::jsonb))
  ), filtered as materialized (
    select ps.* from public.prospect_index ps
    join eligible_companies eligible on eligible.company_id = ps.company_id
    where (p_client_id is null or ps.client_ids @> array[p_client_id])
      and ((btrim(coalesce(p_search, '')) = '' and coalesce(p_filters, '[]'::jsonb) = '[]'::jsonb)
        or public.prospect_index_matches_v1(ps, p_search, p_filters))
  ), sorted as (
    select * from filtered order by
      case when p_sort = 'name' and lower(p_direction) = 'asc' then lower(full_name) end asc,
      case when p_sort = 'name' and lower(p_direction) = 'desc' then lower(full_name) end desc,
      case when p_sort = 'company' and lower(p_direction) = 'asc' then lower(company_name) end asc,
      case when p_sort = 'company' and lower(p_direction) = 'desc' then lower(company_name) end desc,
      case when p_sort = 'title' and lower(p_direction) = 'asc' then lower(title) end asc,
      case when p_sort = 'title' and lower(p_direction) = 'desc' then lower(title) end desc,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'asc' then last_contacted_at end asc nulls first,
      case when p_sort = 'last_contacted' and lower(p_direction) = 'desc' then last_contacted_at end desc nulls last,
      case when p_sort = 'created_at' and lower(p_direction) = 'asc' then created_at end asc,
      created_at desc, id
    limit greatest(1, least(coalesce(p_limit, 50), 100)) offset greatest(0, coalesce(p_offset, 0))
  )
  select coalesce((select jsonb_agg(to_jsonb(sorted)) from sorted), '[]'::jsonb), (select count(*) from filtered);
$$;


ALTER FUNCTION public.search_prospect_workspace_v9(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb) OWNER TO postgres;

--
-- Name: set_client_company_tag_v1(text, text, boolean, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_client_company_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_changed integer := 0;
begin
  if not exists (select 1 from public.prospect_tags t
                  where t.id = p_tag_id and (t.client_id = p_client_id or t.client_id is null)) then
    raise exception 'That tag does not belong to this client' using errcode = 'P0002';
  end if;
  if p_company_ids is null or cardinality(p_company_ids) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  if p_apply then
    insert into public.company_tag_links (company_id, tag_id)
    select id, p_tag_id from unnest(p_company_ids) as id
    on conflict (company_id, tag_id) do nothing;
    get diagnostics v_changed = row_count;
  else
    delete from public.company_tag_links
     where tag_id = p_tag_id and company_id = any(p_company_ids);
    get diagnostics v_changed = row_count;
  end if;

  -- Deliberately no re-index: prospect_index carries no company tags, so
  -- tagging a company changes nothing it holds.
  return jsonb_build_object('updated', v_changed, 'queued', 0);
end;
$$;


ALTER FUNCTION public.set_client_company_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_client_company_tag_v2(text, text, boolean, text[], text, jsonb, jsonb, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_client_company_tag_v2(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[] := array[]::text[];
  v_changed integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;

  -- The tag is checked against the client HERE, before anything is resolved, so
  -- a workspace cannot reach another client's tag by sending its id. Carried
  -- over from v1 unchanged; an agency-wide tag (client_id null) stays usable.
  if not exists (select 1 from public.prospect_tags t
                  where t.id = p_tag_id and (t.client_id = p_client_id or t.client_id is null)) then
    raise exception 'That tag does not belong to this client' using errcode = 'P0002';
  end if;

  -- The same resolver, with the same cap, that push and ICP verification use.
  -- It is what makes explicit ids and "everything matching this filter" one
  -- code path rather than two that drift.
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(
    p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('updated', 0, 'selected', 0, 'queued', 0);
  end if;

  if p_apply then
    insert into public.company_tag_links (company_id, tag_id)
    select id, p_tag_id from unnest(v_ids) as id
    on conflict (company_id, tag_id) do nothing;
    get diagnostics v_changed = row_count;
  else
    delete from public.company_tag_links
     where tag_id = p_tag_id and company_id = any(v_ids);
    get diagnostics v_changed = row_count;
  end if;

  -- 'selected' as well as 'updated', for the same reason set_company_icp_
  -- verified_v2 reports both: re-tagging 4,000 companies that already carry the
  -- tag legitimately updates 0, and without the selected count that reads as
  -- "nothing happened" rather than "nothing needed to".
  return jsonb_build_object('updated', v_changed, 'selected', cardinality(v_ids), 'queued', 0);
end;
$$;


ALTER FUNCTION public.set_client_company_tag_v2(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_client_date_contacted_v1(text, date, text, jsonb, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_client_date_contacted_v1(p_client_id text, p_date_contacted date, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_updated integer := 0;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception 'Client not found.' using errcode = 'P0002';
  end if;

  -- The browser submits its local calendar day; UTC may still be on the prior
  -- date in positive-offset timezones, so permit the next UTC date as the API does.
  if p_date_contacted is not null and (p_date_contacted < date '1900-01-01' or p_date_contacted > current_date + 1) then
    raise exception 'Date Contacted must be between 1900-01-01 and today.' using errcode = '22007';
  end if;

  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids[1:50000];
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0);
  end if;

  update public.client_prospects cp
  set date_added = p_date_contacted
  where cp.client_id = p_client_id
    and cp.prospect_id = any(v_ids)
    and cp.date_added is distinct from p_date_contacted;
  get diagnostics v_updated = row_count;

  perform public.record_operation(
    'set_date_contacted', p_client_id, p_actor,
    format('Updated Date Contacted for %s prospects', v_updated), v_updated, v_ids);

  return jsonb_build_object('updated', v_updated);
end;
$$;


ALTER FUNCTION public.set_client_date_contacted_v1(p_client_id text, p_date_contacted date, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_client_lead_v1(text, boolean, text, jsonb, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_client_lead_v1(p_client_id text, p_is_lead boolean, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_updated integer := 0;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  update public.client_prospects cp set
    is_lead = p_is_lead,
    lead_marked_at = case when p_is_lead then now() else null end,
    lead_marked_by = case when p_is_lead then left(coalesce(p_actor, ''), 200) else '' end
  where cp.client_id = p_client_id
    and cp.prospect_id = any(v_ids)
    and cp.is_lead is distinct from p_is_lead;
  get diagnostics v_updated = row_count;

  perform public.record_operation(
    case when p_is_lead then 'lead_mark' else 'lead_unmark' end,
    p_client_id, p_actor,
    format('Marked %s prospects %s', v_updated, case when p_is_lead then 'as leads' else 'not leads' end),
    v_updated, v_ids);

  return jsonb_build_object('updated', v_updated, 'queued', 0);
end;
$$;


ALTER FUNCTION public.set_client_lead_v1(p_client_id text, p_is_lead boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_client_prospect_tag_v1(text, text, boolean, text, jsonb, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_client_prospect_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_changed integer := 0;
  v_reindex record;
begin
  -- The tag must belong to this client (or be agency-wide). Without this a
  -- client workspace could apply another client's ICP tag.
  if not exists (select 1 from public.prospect_tags t
                  where t.id = p_tag_id and (t.client_id = p_client_id or t.client_id is null)) then
    raise exception 'That tag does not belong to this client' using errcode = 'P0002';
  end if;

  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  if p_apply then
    insert into public.prospect_tag_links (prospect_id, tag_id)
    select id, p_tag_id from unnest(v_ids) as id
    on conflict (prospect_id, tag_id) do nothing;
    get diagnostics v_changed = row_count;
  else
    delete from public.prospect_tag_links
     where tag_id = p_tag_id and prospect_id = any(v_ids);
    get diagnostics v_changed = row_count;
  end if;

  -- tag_text feeds search_text, so this is not optional.
  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    case when p_apply then 'tag_apply' else 'tag_remove' end,
    p_client_id, p_actor,
    format('%s tag on %s prospects', case when p_apply then 'Applied' else 'Removed' end, v_changed),
    v_changed, v_ids);

  return jsonb_build_object('updated', v_changed, 'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.set_client_prospect_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_company_icp_validated_v1(text, boolean, text[], text, jsonb, jsonb, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_company_icp_validated_v1(p_client_id text, p_validated boolean, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $_$
declare
  v_ids text[] := array[]::text[];
  v_updated integer := 0;
  v_prospects_updated integer := 0;
  v_prospect_ids text[] := array[]::text[];
  v_reindex record;
  v_queued integer := 0;
  v_prefilter text;
  v_match_clause text;
  v_excluded_clause text := '';
  v_people_clause text := '';
  v_sql text;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;

  if p_company_ids is not null and cardinality(p_company_ids) > 0 then
    select coalesce(array_agg(distinct requested.company_id order by requested.company_id), array[]::text[])
    into v_ids
    from unnest(p_company_ids[1:50000]) requested(company_id)
    where exists (
      select 1 from public.prospect_index pi
      where pi.company_id = requested.company_id and pi.client_ids @> array[p_client_id]
    );
  else
    v_prefilter := public.company_prefilter_sql(coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb));
    v_match_clause := case when v_prefilter <> 'true' then '(' || v_prefilter || ') and ' else '' end
      || coalesce(public.company_filter_sql_v2(p_search, coalesce(p_filters, '[]'::jsonb)), format('public.company_matches_filters_v1(c, %L, %L::jsonb)',
        coalesce(p_search, ''), coalesce(p_filters, '[]'::jsonb)::text));

    if p_excluded_ids is not null and cardinality(p_excluded_ids) > 0 then
      v_excluded_clause := format(' and not (c.id = any (%L::text[]))', p_excluded_ids);
    end if;
    if p_people_scope is not null then
      v_people_clause := format(
        ' and c.id in (select company_id from public.people_scope_company_ids_v1(%L, %L::jsonb))',
        p_client_id, p_people_scope::text
      );
    end if;

    v_sql := format($q$
      select coalesce(array_agg(selected.id order by selected.id), array[]::text[])
      from (
        select c.id
        from public.companies c
        where (%1$s)
          and exists (
            select 1 from public.prospect_index pi
            where pi.company_id = c.id and pi.client_ids @> array[%2$L]
          )%3$s%4$s
        order by c.id
        limit 250000
      ) selected
    $q$, v_match_clause, p_client_id, v_people_clause, v_excluded_clause);
    execute v_sql into v_ids;
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'selected', 0);
  end if;

  if p_validated then
    insert into public.client_company_icp_validations (client_id, company_id, validated_at, validated_by)
    select p_client_id, company_id, now(), left(coalesce(p_actor, ''), 200)
    from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing;
    get diagnostics v_updated = row_count;
  else
    delete from public.client_company_icp_validations validation
    where validation.client_id = p_client_id and validation.company_id = any(v_ids);
    get diagnostics v_updated = row_count;
  end if;

  select coalesce(array_agg(cp.prospect_id order by cp.prospect_id), array[]::text[])
  into v_prospect_ids
  from public.client_prospects cp
  join public.prospects p on p.id = cp.prospect_id
  where cp.client_id = p_client_id and p.company_id = any(v_ids);

  if p_validated then
    update public.client_prospects cp
    set icp_verified = true,
      verified_at = now(),
      verified_by = 'company:' || p.company_id
    from public.prospects p
    where p.id = cp.prospect_id
      and cp.client_id = p_client_id
      and p.company_id = any(v_ids)
      and not cp.icp_verified;
  else
    update public.client_prospects cp
    set icp_verified = false,
      verified_at = null,
      verified_by = ''
    from public.prospects p
    where p.id = cp.prospect_id
      and cp.client_id = p_client_id
      and p.company_id = any(v_ids)
      and cp.verified_by = 'company:' || p.company_id;
  end if;
  get diagnostics v_prospects_updated = row_count;

  if cardinality(v_prospect_ids) > 0 then
    select * into v_reindex
    from public.reindex_scope_v1(p_prospect_ids => v_prospect_ids);
    v_queued := coalesce(v_reindex.queued, 0);
  end if;

  return jsonb_build_object(
    'updated', v_updated,
    'selected', cardinality(v_ids),
    'eligibleProspects', cardinality(v_prospect_ids),
    'prospectsUpdated', v_prospects_updated,
    'queued', v_queued
  );
end;
$_$;


ALTER FUNCTION public.set_company_icp_validated_v1(p_client_id text, p_validated boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_company_icp_verified_v2(text, boolean, text[], text, jsonb, jsonb, text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_company_icp_verified_v2(p_client_id text, p_verified boolean, p_company_ids text[] DEFAULT NULL::text[], p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_people_scope jsonb DEFAULT NULL::jsonb, p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare v_ids text[] := array[]::text[]; v_updated integer := 0; v_existing jsonb := '{}'::jsonb;
begin
  if not exists (select 1 from public.clients where id = p_client_id) then
    raise exception using errcode = 'P0002', message = 'Client not found.';
  end if;
  select coalesce(array_agg(company_id), array[]::text[]) into v_ids
  from public.resolve_company_action_selection_v1(p_client_id, p_company_ids, p_search, p_filters, p_people_scope, p_excluded_ids, 250000);
  if p_verified then
    insert into public.client_company_icp_validations (client_id, company_id, validated_at, validated_by)
    select p_client_id, company_id, now(), left(coalesce(p_actor, ''), 200) from unnest(v_ids) selected(company_id)
    on conflict (client_id, company_id) do nothing;
  else
    delete from public.client_company_icp_validations validation
    where validation.client_id = p_client_id and validation.company_id = any(v_ids);
  end if;
  get diagnostics v_updated = row_count;
  if cardinality(v_ids) > 0 then
    v_existing := public.set_company_icp_validated_v1(p_client_id, p_verified, v_ids, '', '[]'::jsonb, null, null, p_actor);
  end if;
  return v_existing || jsonb_build_object('updated', v_updated, 'selected', cardinality(v_ids));
end;
$$;


ALTER FUNCTION public.set_company_icp_verified_v2(p_client_id text, p_verified boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_icp_verified_v1(text, boolean, text, jsonb, text[], text[], text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_icp_verified_v1(p_client_id text, p_verified boolean, p_search text DEFAULT ''::text, p_filters jsonb DEFAULT '[]'::jsonb, p_prospect_ids text[] DEFAULT NULL::text[], p_excluded_ids text[] DEFAULT NULL::text[], p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '120s'
    AS $$
declare
  v_ids text[];
  v_updated integer := 0;
  v_reindex record;
begin
  if p_prospect_ids is not null and cardinality(p_prospect_ids) > 0 then
    v_ids := p_prospect_ids;
  else
    select coalesce(array_agg(prospect_id), array[]::text[]) into v_ids
    from public.prospect_ids_matching_v1(p_search, p_filters, p_client_id, p_excluded_ids);
  end if;

  if cardinality(coalesce(v_ids, array[]::text[])) = 0 then
    return jsonb_build_object('updated', 0, 'queued', 0);
  end if;

  update public.client_prospects cp set
    icp_verified = p_verified,
    verified_at = case when p_verified then now() else null end,
    verified_by = case when p_verified then left(coalesce(p_actor, ''), 200) else '' end
  where cp.client_id = p_client_id
    and cp.prospect_id = any(v_ids)
    and cp.icp_verified is distinct from p_verified;
  get diagnostics v_updated = row_count;

  select * into v_reindex from public.reindex_scope_v1(p_prospect_ids => v_ids);

  perform public.record_operation(
    case when p_verified then 'icp_verify' else 'icp_unverify' end,
    p_client_id, p_actor,
    format('Marked %s prospects %s', v_updated, case when p_verified then 'ICP verified' else 'not verified' end),
    v_updated, v_ids);

  return jsonb_build_object('updated', v_updated, 'queued', v_reindex.queued);
end;
$$;


ALTER FUNCTION public.set_icp_verified_v1(p_client_id text, p_verified boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) OWNER TO postgres;

--
-- Name: set_integration_destination_v1(text, text, bigint, boolean); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_integration_destination_v1(p_actor text, p_client text, p_campaign bigint, p_enabled boolean) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_connection public.integration_connections%rowtype; v_campaign jsonb; v_owner text;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_client is null
    or p_campaign is null or p_campaign<=0 or p_enabled is null then
    raise exception 'Invalid destination' using errcode='22023'; end if;
  -- Serializes mapping changes against credential replacement/disconnect.
  select * into v_connection from public.integration_connections where provider='smartlead' for update;
  if not found then raise exception 'Connection missing' using errcode='22023'; end if;
  if not p_enabled then
    update prospect_integrations.client_campaigns set enabled=false,updated_by=p_actor,updated_at=now()
      where campaign_id=p_campaign and client_id=p_client and enabled;
    return found;
  end if;
  if not v_connection.connected or v_connection.checked_at is null
    or v_connection.checked_at<now()-interval '15 minutes' then
    raise exception 'Refresh Smartlead campaigns before mapping' using errcode='22023'; end if;
  select value into v_campaign from jsonb_array_elements(v_connection.campaigns)
    where value->>'id'=p_campaign::text;
  if not found then raise exception 'Campaign not in connected account' using errcode='22023'; end if;
  perform 1 from public.clients where id=p_client;
  if not found then raise exception 'Client not found' using errcode='22023'; end if;
  select client_id into v_owner from prospect_integrations.client_campaigns where campaign_id=p_campaign and enabled;
  if found and v_owner<>p_client then
    raise exception 'Campaign already assigned to another client' using errcode='22023'; end if;
  if (select count(*) from prospect_integrations.client_campaigns)>=10000
    and not exists(select 1 from prospect_integrations.client_campaigns where campaign_id=p_campaign) then
    raise exception 'Destination capacity reached' using errcode='53300'; end if;
  insert into prospect_integrations.client_campaigns(campaign_id,client_id,generation,campaign_name,updated_by)
    values(p_campaign,p_client,v_connection.generation,left(v_campaign->>'name',300),p_actor)
    on conflict(campaign_id) do update set client_id=excluded.client_id,generation=excluded.generation,
      campaign_name=excluded.campaign_name,enabled=true,updated_by=excluded.updated_by,updated_at=now();
  return true;
end;
$$;


ALTER FUNCTION public.set_integration_destination_v1(p_actor text, p_client text, p_campaign bigint, p_enabled boolean) OWNER TO postgres;

--
-- Name: smartlead_progress_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smartlead_progress_v1(p_actor text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
select jsonb_build_object('creations',coalesce((select jsonb_agg(to_jsonb(r)) from (
  select id,name,client_id,status,campaign_id,error_code,created_at from prospect_integrations.campaign_requests where actor=p_actor order by created_at desc limit 50) r),'[]'::jsonb),
  'deliveries',coalesce((select jsonb_agg(to_jsonb(r)) from (
    select j.id,j.status,j.error_code,j.campaign_id,
      coalesce(sum((b.outcome->>'addedCount')::integer),0) as added,
      coalesce(sum((b.outcome->>'skippedCount')::integer),0) as skipped,
      coalesce(sum(b.suppressed),0) as suppressed
    from prospect_integrations.jobs j left join prospect_integrations.batches b on b.job_id=j.id
    where j.actor=p_actor group by j.id order by j.created_at desc limit 50) r),'[]'::jsonb));
$$;


ALTER FUNCTION public.smartlead_progress_v1(p_actor text) OWNER TO postgres;

--
-- Name: smartlead_report_v1(text, uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.smartlead_report_v1(p_actor text, p_job uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select jsonb_agg(jsonb_build_object('status',b.status,'outcome',b.outcome,
    'emails',(select jsonb_agg(x->>'email') from jsonb_array_elements(b.payload) x),
    'dispatchEmails',case when b.dispatch_payload is null then null else coalesce((select jsonb_agg(x->>'email') from jsonb_array_elements(b.dispatch_payload) x),'[]'::jsonb) end))
  from prospect_integrations.jobs j join prospect_integrations.batches b on b.job_id=j.id where j.actor=p_actor and j.id=p_job;
$$;


ALTER FUNCTION public.smartlead_report_v1(p_actor text, p_job uuid) OWNER TO postgres;

--
-- Name: stage_integration_job_v1(text, uuid, text, text, bigint, text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.stage_integration_job_v1(p_actor text, p_request_id uuid, p_hash text, p_client text, p_campaign bigint, p_mode text, p_batches jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
declare v_id uuid; v_hash text; v_batch jsonb; v_total integer:=0; v_ordinal integer:=0;
begin
  if p_actor is null or length(p_actor) not between 1 and 300 or p_request_id is null or p_hash is null or p_hash !~ '^[a-f0-9]{64}$'
    or p_campaign is null or p_campaign<=0 or p_mode is null or p_mode not in ('direct','verify')
    or jsonb_typeof(p_batches) is distinct from 'array' or jsonb_array_length(p_batches) not between 1 and 50
    or octet_length(p_batches::text)>5242880 then raise exception 'Invalid integration snapshot' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('integration-admission-v1',0));
  select id,content_hash into v_id,v_hash from prospect_integrations.jobs where actor=p_actor and request_id=p_request_id;
  if found then
    if v_hash<>p_hash then raise exception 'Request identity conflict' using errcode='22023'; end if;
    return v_id;
  end if;
  if (select count(*) from prospect_integrations.jobs where status in ('draft','queued','running'))>=10
    or (select count(*) from prospect_integrations.jobs)>=1000
    or coalesce((select sum(payload_bytes) from prospect_integrations.batches),0)>=134217728 then
    raise exception 'Integration queue is full' using errcode='53300'; end if;
  insert into prospect_integrations.jobs(actor,request_id,content_hash,client_id,campaign_id,mode)
    values(p_actor,p_request_id,p_hash,p_client,p_campaign,p_mode) returning id into v_id;
  for v_batch in select value from jsonb_array_elements(p_batches) loop
    if jsonb_typeof(v_batch) is distinct from 'array' then raise exception 'Invalid batch' using errcode='22023'; end if;
    v_total:=v_total+jsonb_array_length(v_batch);
    if v_total>5000 then raise exception 'Snapshot exceeds 5000 leads' using errcode='22023'; end if;
    insert into prospect_integrations.batches(job_id,ordinal,payload) values(v_id,v_ordinal,v_batch);
    v_ordinal:=v_ordinal+1;
  end loop;
  return v_id;
end;
$_$;


ALTER FUNCTION public.stage_integration_job_v1(p_actor text, p_request_id uuid, p_hash text, p_client text, p_campaign bigint, p_mode text, p_batches jsonb) OWNER TO postgres;

--
-- Name: stage_mapped_integration_job_v1(text, uuid, text, text, bigint, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.stage_mapped_integration_job_v1(p_actor text, p_request uuid, p_hash text, p_client text, p_campaign bigint, p_batches jsonb, p_summary jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_generation uuid; v_job uuid;
begin
  select generation into v_generation from public.integration_connections where provider='smartlead' and connected for share;
  if not found then raise exception 'Connect Smartlead first' using errcode='22023'; end if;
  perform 1 from prospect_integrations.client_campaigns where campaign_id=p_campaign and client_id=p_client
    and enabled and generation=v_generation for share;
  if not found then raise exception 'Map this campaign to the client first' using errcode='22023'; end if;
  if p_summary is null or jsonb_typeof(p_summary)<>'object' or octet_length(p_summary::text)>262144 then
    raise exception 'Invalid preview summary' using errcode='22023'; end if;
  v_job:=public.stage_integration_job_v1(p_actor,p_request,p_hash,p_client,p_campaign,'direct',p_batches);
  update prospect_integrations.jobs set connection_generation=v_generation,preview_summary=p_summary
    where id=v_job and status='draft' and (connection_generation is null or connection_generation=v_generation);
  if not found then raise exception 'Preview is no longer editable' using errcode='22023'; end if;
  return v_job;
end;
$$;


ALTER FUNCTION public.stage_mapped_integration_job_v1(p_actor text, p_request uuid, p_hash text, p_client text, p_campaign bigint, p_batches jsonb, p_summary jsonb) OWNER TO postgres;

--
-- Name: start_list_push_v1(text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.start_list_push_v1(p_list_id text, p_label text DEFAULT 'Pushed from People database'::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  client_id_value text;
  import_id_value text := gen_random_uuid()::text;
begin
  select l.client_id into client_id_value from public.lists l where l.id = p_list_id;
  if not found then
    raise exception 'List not found' using errcode = 'P0002';
  end if;

  insert into public.imports(id, client_id, list_id, file_name, data_source, status, total_rows, processed_rows)
  values (import_id_value, client_id_value, p_list_id, coalesce(nullif(btrim(p_label), ''), 'Pushed from People database'), 'Master push', 'processing', 0, 0);

  return import_id_value;
end;
$$;


ALTER FUNCTION public.start_list_push_v1(p_list_id text, p_label text) OWNER TO postgres;

--
-- Name: sweep_client_company_blocklist_v1(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sweep_client_company_blocklist_v1(p_client_id text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_moved integer := 0;
begin
  with matched as (
    select cc.client_id, cc.company_id, cc.added_at, cc.added_by,
      coalesce(nullif(b.reason, ''), 'Matched client blocklist') as reason
    from public.client_blocklist b
    join public.companies co on co.normalized_domain = b.value
    join public.client_companies cc on cc.client_id = b.client_id and cc.company_id = co.id
    where b.client_id = p_client_id and b.kind = 'domain' and b.value <> ''
  ), moved as (
    delete from public.client_companies cc
    using matched m
    where cc.client_id = m.client_id and cc.company_id = m.company_id
    returning cc.client_id, cc.company_id
  ), kept as (
    insert into public.client_companies_blocked (client_id, company_id, added_at, added_by, blocked_reason)
    select m.client_id, m.company_id, m.added_at, m.added_by, m.reason
    from matched m
    join moved using (client_id, company_id)
    on conflict (client_id, company_id) do nothing
    returning 1
  )
  select count(*)::integer into v_moved from moved;
  return v_moved;
end;
$$;


ALTER FUNCTION public.sweep_client_company_blocklist_v1(p_client_id text) OWNER TO postgres;

--
-- Name: sync_changed_prospect_company_memberships_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_changed_prospect_company_memberships_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if new.company_id is not null and new.company_id is distinct from old.company_id then
    insert into public.client_companies (client_id, company_id, added_by)
    select cp.client_id, new.company_id, 'prospect-company-change'
    from public.client_prospects cp
    where cp.prospect_id = new.id
    on conflict (client_id, company_id) do nothing;
  end if;
  return new;
end;
$$;


ALTER FUNCTION public.sync_changed_prospect_company_memberships_v1() OWNER TO postgres;

--
-- Name: sync_client_company_membership_v1(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_client_company_membership_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare v_company_id text; v_added text; v_import public.imports%rowtype;
begin
  select p.company_id into v_company_id from public.prospects p where p.id = new.prospect_id;
  if v_company_id is not null then
    insert into public.client_companies (client_id, company_id, added_by)
    values (new.client_id, v_company_id, 'prospect-membership')
    on conflict (client_id, company_id) do nothing
    returning company_id into v_added;
    if v_added is not null and new.source_import_id is not null then
      select * into v_import from public.imports where id = new.source_import_id;
      if found then
        perform public.record_client_addition_batch_v1(
          new.client_id, 'companies', 'import', v_import.file_name, null,
          'import:' || v_import.id, array[v_added], 'import-worker');
      end if;
    end if;
    if v_added is not null and new.source_push_request_id is not null then
      perform public.record_client_addition_batch_v1(
        new.client_id, 'companies',
        case when new.source_push_client_id is null then 'master' else 'client' end,
        coalesce(nullif(new.source_push_label, ''), 'Master DB'),
        new.source_push_client_id,
        new.source_push_request_id || ':companies', array[v_added],
        coalesce(new.source_push_actor, ''));
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION public.sync_client_company_membership_v1() OWNER TO postgres;

--
-- Name: sync_client_prospects_from_lists(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_client_prospects_from_lists() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    with incoming as (
      select l.client_id, n.prospect_id, min(i.prospect_date_added) as date_added,
        (array_agg(n.import_id order by n.import_id) filter (where n.import_id is not null))[1] as source_import_id
      from new_rows n
      join public.lists l on l.id = n.list_id
      left join public.imports i on i.id = n.import_id
      where n.prospect_id is not null
      group by l.client_id, n.prospect_id
    )
    insert into public.client_prospects (
      client_id, prospect_id, added_via, date_added, source_import_id,
      status, blocked_reason, blocked_at
    )
    select incoming.client_id, incoming.prospect_id, 'import', incoming.date_added,
      incoming.source_import_id,
      case when block.reason is null then 'active' else 'blocked' end,
      coalesce(block.reason, ''), case when block.reason is null then null else now() end
    from incoming
    left join lateral (
      select public.client_block_reason_v1(incoming.client_id, incoming.prospect_id) as reason
    ) block on true
    on conflict (client_id, prospect_id) do update set
      date_added = case
        when excluded.date_added is null then public.client_prospects.date_added
        when public.client_prospects.date_added is null then excluded.date_added
        else least(public.client_prospects.date_added, excluded.date_added)
      end,
      status = case when excluded.status = 'blocked' then 'blocked' else public.client_prospects.status end,
      blocked_reason = case when excluded.status = 'blocked' then excluded.blocked_reason else public.client_prospects.blocked_reason end,
      blocked_at = case when excluded.status = 'blocked' then coalesce(public.client_prospects.blocked_at, excluded.blocked_at) else public.client_prospects.blocked_at end;
  end if;
  if tg_op in ('DELETE', 'UPDATE') then
    delete from public.client_prospects cp
    using (
      select distinct l.client_id, o.prospect_id from old_rows o
      join public.lists l on l.id = o.list_id where o.prospect_id is not null
    ) removed
    where cp.client_id = removed.client_id and cp.prospect_id = removed.prospect_id
      and cp.added_via = 'import'
      and not exists (
        select 1 from public.list_memberships lm join public.lists l2 on l2.id = lm.list_id
        where l2.client_id = cp.client_id and lm.prospect_id = cp.prospect_id
      );
  end if;
  return null;
end;
$$;


ALTER FUNCTION public.sync_client_prospects_from_lists() OWNER TO postgres;

--
-- Name: sync_company_counts_from_index(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_company_counts_from_index() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if tg_op in ('INSERT', 'UPDATE') and new.company_id is not null then
    perform public.recompute_company_counts(new.company_id);
  end if;
  if tg_op in ('DELETE', 'UPDATE') and old.company_id is not null
     and (tg_op = 'DELETE' or old.company_id is distinct from new.company_id) then
    perform public.recompute_company_counts(old.company_id);
  end if;
  return null;
end;
$$;


ALTER FUNCTION public.sync_company_counts_from_index() OWNER TO postgres;

--
-- Name: sync_company_counts_statement(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_company_counts_statement() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_ids text[];
begin
  if tg_op = 'INSERT' then
    select array_agg(distinct company_id) into v_ids
    from new_rows where company_id is not null;
  elsif tg_op = 'DELETE' then
    select array_agg(distinct company_id) into v_ids
    from old_rows where company_id is not null;
  else
    select array_agg(distinct company_id) into v_ids from (
      select company_id from new_rows where company_id is not null
      union
      select company_id from old_rows where company_id is not null
    ) touched;
  end if;

  if v_ids is not null and cardinality(v_ids) > 0 then
    perform public.recompute_company_counts_bulk(v_ids);
    -- Same ids, same statement: the per-client counts on client_companies are
    -- the same denormalisation one level down, and must not be computed from a
    -- different set than the company totals were.
    perform public.recompute_client_company_counts_bulk(v_ids);
  end if;
  return null;
end;
$$;


ALTER FUNCTION public.sync_company_counts_statement() OWNER TO postgres;

--
-- Name: sync_total_funding_amount(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_total_funding_amount() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
begin
  new.total_funding_amount := case
    when btrim(coalesce(new.total_funding, '')) <> '' and new.total_funding ~ '^[0-9]+(\.[0-9]+)?$'
      then floor(new.total_funding::numeric)::bigint
    else null
  end;
  return new;
end;
$_$;


ALTER FUNCTION public.sync_total_funding_amount() OWNER TO postgres;

--
-- Name: title_class_filter_values_v1(text, text, text, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.title_class_filter_values_v1(p_field text, p_search text DEFAULT ''::text, p_client_id text DEFAULT NULL::text, p_limit integer DEFAULT 50) RETURNS TABLE(value text, match_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '30s'
    AS $$
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


ALTER FUNCTION public.title_class_filter_values_v1(p_field text, p_search text, p_client_id text, p_limit integer) OWNER TO postgres;

--
-- Name: title_classification_gaps_v1(integer, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.title_classification_gaps_v1(p_limit integer DEFAULT 200, p_missing text DEFAULT 'any'::text) RETURNS TABLE(normalized_title text, sample_title text, occurrences bigint, missing_seniority boolean, missing_department boolean)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
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


ALTER FUNCTION public.title_classification_gaps_v1(p_limit integer, p_missing text) OWNER TO postgres;

--
-- Name: title_seniority_rank(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.title_seniority_rank(p_tier text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
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


ALTER FUNCTION public.title_seniority_rank(p_tier text) OWNER TO postgres;

--
-- Name: touch_title_classifier_state(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.touch_title_classifier_state() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update public.title_classifier_state set keywords_updated_at = now() where id;
  return null;
end;
$$;


ALTER FUNCTION public.touch_title_classifier_state() OWNER TO postgres;

--
-- Name: update_client_blocklist_reason_v1(text, text, text[], boolean, text, text, date, date, text[], timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_client_blocklist_reason_v1(p_client_id text, p_reason text, p_ids text[] DEFAULT NULL::text[], p_all_matching boolean DEFAULT false, p_search text DEFAULT ''::text, p_kind text DEFAULT ''::text, p_date_from date DEFAULT NULL::date, p_date_to date DEFAULT NULL::date, p_excluded_ids text[] DEFAULT NULL::text[], p_selected_before timestamp with time zone DEFAULT NULL::timestamp with time zone, p_actor text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    SET statement_timeout TO '60s'
    AS $$
declare v_ids text[]; v_updated integer := 0;
begin
  if p_reason not in ('Client Provided', 'ICP Invalid', 'Campaign Reply') then
    raise exception 'Choose an allowed blocklist reason' using errcode = '22023';
  end if;
  select coalesce(array_agg(entry_id), array[]::text[]) into v_ids
  from public.client_blocklist_selection_v1(p_client_id, p_ids, p_all_matching,
    p_search, p_kind, p_date_from, p_date_to, p_excluded_ids, p_selected_before, 250001);
  if cardinality(v_ids) > 250000 then
    raise exception 'More than 250,000 blocklist entries match. Narrow the filters before changing their reason.' using errcode = '54000';
  end if;
  update public.client_blocklist set reason = p_reason where client_id = p_client_id and id = any(v_ids);
  get diagnostics v_updated = row_count;
  perform public.record_operation('blocklist_reason_update', p_client_id, p_actor,
    format('Updated %s blocklist reasons', v_updated), v_updated, null);
  return jsonb_build_object('updated', v_updated);
end;
$$;


ALTER FUNCTION public.update_client_blocklist_reason_v1(p_client_id text, p_reason text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text) OWNER TO postgres;

--
-- Name: job_parts; Type: TABLE; Schema: prospect_exports; Owner: postgres
--

CREATE UNLOGGED TABLE prospect_exports.job_parts (
    job_id uuid NOT NULL,
    part_index integer NOT NULL,
    row_count integer NOT NULL,
    rows jsonb NOT NULL
);


ALTER TABLE prospect_exports.job_parts OWNER TO postgres;

--
-- Name: jobs; Type: TABLE; Schema: prospect_exports; Owner: postgres
--

CREATE TABLE prospect_exports.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner_id text NOT NULL,
    request_id text NOT NULL,
    entity_type text NOT NULL,
    client_scope text DEFAULT ''::text NOT NULL,
    result_set_id uuid NOT NULL,
    fields text[] DEFAULT '{}'::text[] NOT NULL,
    keys text[] DEFAULT '{}'::text[] NOT NULL,
    excluded_ids text[] DEFAULT '{}'::text[] NOT NULL,
    file_base_name text DEFAULT 'export'::text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    row_count bigint DEFAULT 0 NOT NULL,
    byte_count bigint DEFAULT 0 NOT NULL,
    part_count integer DEFAULT 0 NOT NULL,
    next_ordinal bigint DEFAULT 0 NOT NULL,
    download_token text NOT NULL,
    error text,
    worker_id text,
    lease_expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT jobs_entity_type_check CHECK ((entity_type = ANY (ARRAY['prospect'::text, 'company'::text]))),
    CONSTRAINT jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'building'::text, 'ready'::text, 'failed'::text])))
);


ALTER TABLE prospect_exports.jobs OWNER TO postgres;

--
-- Name: filter_set_values; Type: TABLE; Schema: prospect_filters; Owner: postgres
--

CREATE TABLE prospect_filters.filter_set_values (
    filter_set_id uuid NOT NULL,
    normalized_value text NOT NULL
);


ALTER TABLE prospect_filters.filter_set_values OWNER TO postgres;

--
-- Name: filter_sets; Type: TABLE; Schema: prospect_filters; Owner: postgres
--

CREATE TABLE prospect_filters.filter_sets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner_id text NOT NULL,
    entity_type text NOT NULL,
    client_scope text DEFAULT ''::text NOT NULL,
    field text NOT NULL,
    normalization_version integer NOT NULL,
    content_hash text NOT NULL,
    value_count integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT filter_sets_entity_type_check CHECK ((entity_type = ANY (ARRAY['prospect'::text, 'company'::text]))),
    CONSTRAINT filter_sets_value_count_check CHECK (((value_count >= 1) AND (value_count <= 10000)))
);


ALTER TABLE prospect_filters.filter_sets OWNER TO postgres;

--
-- Name: staged_rows; Type: TABLE; Schema: prospect_import; Owner: postgres
--

CREATE TABLE prospect_import.staged_rows (
    import_id text NOT NULL,
    row_offset integer NOT NULL,
    payload jsonb NOT NULL,
    CONSTRAINT staged_rows_row_offset_check CHECK ((row_offset >= 0))
);


ALTER TABLE prospect_import.staged_rows OWNER TO postgres;

--
-- Name: batches; Type: TABLE; Schema: prospect_integrations; Owner: postgres
--

CREATE TABLE prospect_integrations.batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    job_id uuid NOT NULL,
    ordinal integer NOT NULL,
    payload jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt_token uuid,
    attempts integer DEFAULT 0 NOT NULL,
    lease_until timestamp with time zone,
    outcome jsonb,
    dispatch_payload jsonb,
    suppressed integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    payload_bytes integer GENERATED ALWAYS AS ((octet_length((payload)::text) + COALESCE(octet_length((dispatch_payload)::text), 0))) STORED,
    CONSTRAINT batches_payload_check CHECK (((jsonb_typeof(payload) = 'array'::text) AND ((jsonb_array_length(payload) >= 1) AND (jsonb_array_length(payload) <= 400)))),
    CONSTRAINT batches_payload_check1 CHECK ((octet_length((payload)::text) <= 524288)),
    CONSTRAINT batches_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sending'::text, 'completed'::text, 'needs_review'::text, 'cancelled'::text])))
);


ALTER TABLE prospect_integrations.batches OWNER TO postgres;

--
-- Name: campaign_requests; Type: TABLE; Schema: prospect_integrations; Owner: postgres
--

CREATE TABLE prospect_integrations.campaign_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor text NOT NULL,
    request_id uuid NOT NULL,
    client_id text NOT NULL,
    name text NOT NULL,
    generation uuid NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    token uuid,
    lease_until timestamp with time zone,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    campaign_id bigint,
    error_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT campaign_requests_name_check CHECK (((length(name) >= 1) AND (length(name) <= 160))),
    CONSTRAINT campaign_requests_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'sending'::text, 'completed'::text, 'needs_review'::text, 'cancelled'::text])))
);


ALTER TABLE prospect_integrations.campaign_requests OWNER TO postgres;

--
-- Name: client_campaigns; Type: TABLE; Schema: prospect_integrations; Owner: postgres
--

CREATE TABLE prospect_integrations.client_campaigns (
    campaign_id bigint NOT NULL,
    client_id text NOT NULL,
    generation uuid NOT NULL,
    campaign_name text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    updated_by text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT client_campaigns_campaign_id_check CHECK ((campaign_id > 0))
);


ALTER TABLE prospect_integrations.client_campaigns OWNER TO postgres;

--
-- Name: jobs; Type: TABLE; Schema: prospect_integrations; Owner: postgres
--

CREATE TABLE prospect_integrations.jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor text NOT NULL,
    request_id uuid NOT NULL,
    content_hash text NOT NULL,
    client_id text NOT NULL,
    campaign_id bigint NOT NULL,
    mode text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '1 day'::interval) NOT NULL,
    connection_generation uuid,
    preview_summary jsonb,
    allow_active boolean DEFAULT false NOT NULL,
    error_code text,
    last_attempt_at timestamp with time zone,
    CONSTRAINT jobs_campaign_id_check CHECK ((campaign_id > 0)),
    CONSTRAINT jobs_mode_check CHECK ((mode = ANY (ARRAY['direct'::text, 'verify'::text]))),
    CONSTRAINT jobs_preview_summary_check CHECK ((octet_length((preview_summary)::text) <= 262144)),
    CONSTRAINT jobs_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'queued'::text, 'running'::text, 'completed'::text, 'needs_review'::text, 'cancelled'::text])))
);


ALTER TABLE prospect_integrations.jobs OWNER TO postgres;

--
-- Name: job_metrics; Type: TABLE; Schema: prospect_operations; Owner: postgres
--

CREATE TABLE prospect_operations.job_metrics (
    hour timestamp with time zone NOT NULL,
    kind text NOT NULL,
    outcome text NOT NULL,
    duration_bucket_ms integer NOT NULL,
    jobs bigint DEFAULT 0 NOT NULL,
    total_ms double precision DEFAULT 0 NOT NULL,
    max_ms double precision DEFAULT 0 NOT NULL,
    CONSTRAINT job_metrics_kind_check CHECK ((kind = ANY (ARRAY['search'::text, 'operation'::text, 'export'::text]))),
    CONSTRAINT job_metrics_outcome_check CHECK ((outcome = ANY (ARRAY['ready'::text, 'completed'::text, 'failed'::text])))
);


ALTER TABLE prospect_operations.job_metrics OWNER TO postgres;

--
-- Name: operation_job_items; Type: TABLE; Schema: prospect_operations; Owner: postgres
--

CREATE TABLE prospect_operations.operation_job_items (
    job_id uuid NOT NULL,
    ordinal bigint NOT NULL,
    entity_id text NOT NULL,
    applied_at timestamp with time zone
);


ALTER TABLE prospect_operations.operation_job_items OWNER TO postgres;

--
-- Name: operation_jobs; Type: TABLE; Schema: prospect_operations; Owner: postgres
--

CREATE TABLE prospect_operations.operation_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor text NOT NULL,
    action text NOT NULL,
    request_id uuid NOT NULL,
    entity_type text NOT NULL,
    client_scope text DEFAULT ''::text NOT NULL,
    content_hash text NOT NULL,
    authorization_scope text DEFAULT 'global:1'::text NOT NULL,
    version_vector jsonb NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    excluded_ids text[] DEFAULT ARRAY[]::text[] NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    total_items bigint DEFAULT 0 NOT NULL,
    applied_items bigint DEFAULT 0 NOT NULL,
    excluded_count bigint DEFAULT 0 NOT NULL,
    result jsonb,
    error text,
    worker_id text,
    lease_expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    frozen_at timestamp with time zone,
    completed_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT operation_jobs_entity_type_check CHECK ((entity_type = ANY (ARRAY['prospect'::text, 'company'::text]))),
    CONSTRAINT operation_jobs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'frozen'::text, 'running'::text, 'completed'::text, 'failed'::text])))
);


ALTER TABLE prospect_operations.operation_jobs OWNER TO postgres;

--
-- Name: result_set_items; Type: TABLE; Schema: prospect_results; Owner: postgres
--

CREATE TABLE prospect_results.result_set_items (
    result_set_id uuid NOT NULL,
    ordinal bigint NOT NULL,
    entity_id text NOT NULL
);


ALTER TABLE prospect_results.result_set_items OWNER TO postgres;

--
-- Name: result_sets; Type: TABLE; Schema: prospect_results; Owner: postgres
--

CREATE TABLE prospect_results.result_sets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    owner_id text NOT NULL,
    entity_type text NOT NULL,
    client_scope text DEFAULT ''::text NOT NULL,
    compiler_version integer DEFAULT 1 NOT NULL,
    content_hash text NOT NULL,
    authorization_scope text DEFAULT 'global:1'::text NOT NULL,
    version_vector jsonb NOT NULL,
    search text DEFAULT ''::text NOT NULL,
    filters jsonb DEFAULT '[]'::jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    row_count bigint DEFAULT 0 NOT NULL,
    cursor_created_at timestamp with time zone,
    cursor_id text,
    error text,
    worker_id text,
    lease_expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    expires_at timestamp with time zone NOT NULL,
    company_scope jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT result_sets_entity_type_check CHECK ((entity_type = ANY (ARRAY['prospect'::text, 'company'::text]))),
    CONSTRAINT result_sets_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'building'::text, 'ready'::text, 'failed'::text])))
);


ALTER TABLE prospect_results.result_sets OWNER TO postgres;

--
-- Name: client_addition_batch_items; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_addition_batch_items (
    batch_id uuid NOT NULL,
    entity_id text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.client_addition_batch_items OWNER TO postgres;

--
-- Name: client_addition_batches; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_addition_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id text NOT NULL,
    entity_type text NOT NULL,
    source_kind text NOT NULL,
    source_label text DEFAULT ''::text NOT NULL,
    source_client_id text,
    outcome_kind text DEFAULT 'new_memberships'::text NOT NULL,
    request_key text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    CONSTRAINT client_addition_batches_entity_type_check CHECK ((entity_type = ANY (ARRAY['people'::text, 'companies'::text]))),
    CONSTRAINT client_addition_batches_outcome_kind_check CHECK ((outcome_kind = ANY (ARRAY['new_memberships'::text, 'historical_import_rows'::text, 'historical_source_unavailable'::text]))),
    CONSTRAINT client_addition_batches_source_client CHECK ((((source_kind = 'client'::text) AND ((source_client_id IS NOT NULL) OR (btrim(source_label) <> ''::text))) OR ((source_kind <> 'client'::text) AND (source_client_id IS NULL)))),
    CONSTRAINT client_addition_batches_source_kind_check CHECK ((source_kind = ANY (ARRAY['import'::text, 'master'::text, 'client'::text])))
);


ALTER TABLE public.client_addition_batches OWNER TO postgres;

--
-- Name: client_blocklist; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_blocklist (
    id text DEFAULT (gen_random_uuid())::text NOT NULL,
    client_id text NOT NULL,
    kind text NOT NULL,
    value text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT client_blocklist_kind_check CHECK ((kind = ANY (ARRAY['domain'::text, 'email'::text])))
);


ALTER TABLE public.client_blocklist OWNER TO postgres;

--
-- Name: client_blocklist_batch_results; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_blocklist_batch_results (
    request_id text NOT NULL,
    client_id text NOT NULL,
    result jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.client_blocklist_batch_results OWNER TO postgres;

--
-- Name: client_blocklist_share_limits; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_blocklist_share_limits (
    share_id uuid NOT NULL,
    requester_hash text NOT NULL,
    window_started_at timestamp with time zone NOT NULL,
    attempts integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.client_blocklist_share_limits OWNER TO postgres;

--
-- Name: client_blocklist_share_submissions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_blocklist_share_submissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    share_id uuid NOT NULL,
    client_id text NOT NULL,
    request_key uuid NOT NULL,
    domains text[] DEFAULT ARRAY[]::text[] NOT NULL,
    emails text[] DEFAULT ARRAY[]::text[] NOT NULL,
    reason text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    worker_id text,
    lease_expires_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    CONSTRAINT client_blocklist_share_submissions_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'completed'::text, 'failed'::text])))
);


ALTER TABLE public.client_blocklist_share_submissions OWNER TO postgres;

--
-- Name: client_blocklist_shares; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_blocklist_shares (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_id text NOT NULL,
    token_hash text NOT NULL,
    label text DEFAULT ''::text NOT NULL,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone,
    revoked_at timestamp with time zone,
    last_submitted_at timestamp with time zone
);


ALTER TABLE public.client_blocklist_shares OWNER TO postgres;

--
-- Name: client_companies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_companies (
    client_id text NOT NULL,
    company_id text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    added_by text DEFAULT ''::text NOT NULL,
    prospect_count integer DEFAULT 0 NOT NULL
);


ALTER TABLE public.client_companies OWNER TO postgres;

--
-- Name: client_companies_blocked; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_companies_blocked (
    client_id text NOT NULL,
    company_id text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    added_by text DEFAULT ''::text NOT NULL,
    blocked_at timestamp with time zone DEFAULT now() NOT NULL,
    blocked_reason text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.client_companies_blocked OWNER TO postgres;

--
-- Name: client_company_icp_validations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_company_icp_validations (
    client_id text NOT NULL,
    company_id text NOT NULL,
    validated_at timestamp with time zone DEFAULT now() NOT NULL,
    validated_by text DEFAULT ''::text NOT NULL
);


ALTER TABLE public.client_company_icp_validations OWNER TO postgres;

--
-- Name: client_folders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_folders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT client_folders_name_present CHECK ((btrim(name) <> ''::text))
);


ALTER TABLE public.client_folders OWNER TO postgres;

--
-- Name: client_icp_profiles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_icp_profiles (
    id text NOT NULL,
    client_id text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    tag_id text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.client_icp_profiles OWNER TO postgres;

--
-- Name: client_prospects; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_prospects (
    client_id text NOT NULL,
    prospect_id text NOT NULL,
    icp_verified boolean DEFAULT false NOT NULL,
    verified_at timestamp with time zone,
    verified_by text DEFAULT ''::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    blocked_reason text DEFAULT ''::text NOT NULL,
    blocked_at timestamp with time zone,
    added_via text DEFAULT 'import'::text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    date_added date,
    is_lead boolean DEFAULT false NOT NULL,
    lead_marked_at timestamp with time zone,
    lead_marked_by text DEFAULT ''::text NOT NULL,
    source_import_id text,
    source_push_request_id text,
    source_push_client_id text,
    source_push_label text,
    source_push_actor text,
    CONSTRAINT client_prospects_added_via_check CHECK ((added_via = ANY (ARRAY['import'::text, 'push'::text, 'manual'::text]))),
    CONSTRAINT client_prospects_status_check CHECK ((status = ANY (ARRAY['active'::text, 'blocked'::text])))
)
WITH (autovacuum_vacuum_insert_scale_factor='0.05', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.client_prospects OWNER TO postgres;

--
-- Name: client_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.client_settings (
    client_id text NOT NULL,
    cooldown_days integer DEFAULT 90 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT client_settings_cooldown_days_check CHECK (((cooldown_days >= 0) AND (cooldown_days <= 730)))
);


ALTER TABLE public.client_settings OWNER TO postgres;

--
-- Name: clients; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.clients (
    id text NOT NULL,
    name text NOT NULL,
    normalized_name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    folder_id uuid,
    archived_at timestamp with time zone
);


ALTER TABLE public.clients OWNER TO postgres;

--
-- Name: lists; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.lists (
    id text NOT NULL,
    client_id text NOT NULL,
    name text NOT NULL,
    source_file_name text DEFAULT ''::text NOT NULL,
    uploaded_rows integer DEFAULT 0 NOT NULL,
    unique_added integer DEFAULT 0 NOT NULL,
    duplicates_linked integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    field_headers jsonb DEFAULT '[]'::jsonb NOT NULL,
    data_source text DEFAULT 'Legacy Import'::text NOT NULL,
    CONSTRAINT lists_data_source_required CHECK ((btrim(data_source) <> ''::text))
);


ALTER TABLE public.lists OWNER TO postgres;

--
-- Name: client_summaries; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.client_summaries AS
 SELECT c.id,
    c.name,
    c.created_at,
    ( SELECT (count(*))::integer AS count
           FROM public.lists l
          WHERE (l.client_id = c.id)) AS list_count,
    ( SELECT (count(*))::integer AS count
           FROM public.client_prospects cp
          WHERE ((cp.client_id = c.id) AND (cp.status = 'active'::text))) AS prospect_count,
    ( SELECT (count(*))::integer AS count
           FROM public.client_prospects cp
          WHERE ((cp.client_id = c.id) AND (cp.status = 'active'::text) AND cp.icp_verified)) AS icp_verified_count,
    ( SELECT (count(*))::integer AS count
           FROM public.client_prospects cp
          WHERE ((cp.client_id = c.id) AND (cp.status = 'blocked'::text))) AS blocked_count,
    ( SELECT (count(*))::integer AS count
           FROM public.client_companies cc
          WHERE (cc.client_id = c.id)) AS company_count,
    c.folder_id,
    c.archived_at
   FROM public.clients c;


ALTER TABLE public.client_summaries OWNER TO postgres;

--
-- Name: company_import_memberships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.company_import_memberships (
    import_id text NOT NULL,
    company_id text NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.company_import_memberships OWNER TO postgres;

--
-- Name: company_import_rows; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.company_import_rows (
    import_id text NOT NULL,
    source_row_number integer NOT NULL,
    company_id text,
    raw_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.company_import_rows OWNER TO postgres;

--
-- Name: company_imports; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.company_imports (
    id text NOT NULL,
    file_name text DEFAULT ''::text NOT NULL,
    data_source text NOT NULL,
    status text DEFAULT 'processing'::text NOT NULL,
    total_rows integer,
    processed_rows integer DEFAULT 0 NOT NULL,
    added_count integer DEFAULT 0 NOT NULL,
    updated_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    committed_row_offset integer DEFAULT 0 NOT NULL,
    field_headers jsonb DEFAULT '[]'::jsonb NOT NULL,
    field_map jsonb DEFAULT '{}'::jsonb NOT NULL,
    header_signature text DEFAULT ''::text NOT NULL,
    merge_mode text DEFAULT 'enrich'::text NOT NULL,
    CONSTRAINT company_imports_committed_row_offset_nonnegative CHECK ((committed_row_offset >= 0)),
    CONSTRAINT company_imports_data_source_check CHECK ((btrim(data_source) <> ''::text)),
    CONSTRAINT company_imports_merge_mode_check CHECK ((merge_mode = ANY (ARRAY['enrich'::text, 'overwrite'::text, 'skip'::text]))),
    CONSTRAINT company_imports_status_check CHECK ((status = ANY (ARRAY['processing'::text, 'completed'::text, 'failed'::text])))
);


ALTER TABLE public.company_imports OWNER TO postgres;

--
-- Name: company_sources; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.company_sources (
    company_id text NOT NULL,
    data_source text NOT NULL,
    last_import_id text,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT company_sources_data_source_check CHECK ((btrim(data_source) <> ''::text))
);


ALTER TABLE public.company_sources OWNER TO postgres;

--
-- Name: company_summaries; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.company_summaries AS
 SELECT c.id,
    c.name,
    c.domain,
    c.created_at,
    c.prospect_count,
    c.client_count
   FROM public.companies c;


ALTER TABLE public.company_summaries OWNER TO postgres;

--
-- Name: company_tag_links; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.company_tag_links (
    company_id text NOT NULL,
    tag_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.company_tag_links OWNER TO postgres;

--
-- Name: company_value_suggestions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.company_value_suggestions (
    kind text NOT NULL,
    value text NOT NULL,
    company_count integer NOT NULL,
    CONSTRAINT company_value_suggestions_kind_check CHECK ((kind = ANY (ARRAY['keywords'::text, 'technologies'::text])))
);


ALTER TABLE public.company_value_suggestions OWNER TO postgres;

--
-- Name: contact_events; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.contact_events (
    id text NOT NULL,
    prospect_id text NOT NULL,
    client_id text NOT NULL,
    contacted_at timestamp with time zone DEFAULT now() NOT NULL,
    channel text DEFAULT 'email'::text NOT NULL,
    campaign_name text DEFAULT ''::text NOT NULL,
    outcome text DEFAULT 'contacted'::text NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.contact_events OWNER TO postgres;

--
-- Name: dashboard_snapshot; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dashboard_snapshot (
    key text NOT NULL,
    payload jsonb NOT NULL,
    data_version jsonb NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL,
    duration_ms integer
);


ALTER TABLE public.dashboard_snapshot OWNER TO postgres;

--
-- Name: data_version_company; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.data_version_company
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.data_version_company OWNER TO postgres;

--
-- Name: data_version_prospect; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.data_version_prospect
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.data_version_prospect OWNER TO postgres;

--
-- Name: imports; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.imports (
    id text NOT NULL,
    client_id text NOT NULL,
    list_id text NOT NULL,
    file_name text NOT NULL,
    status text DEFAULT 'processing'::text NOT NULL,
    total_rows integer,
    processed_rows integer DEFAULT 0 NOT NULL,
    unique_added integer DEFAULT 0 NOT NULL,
    duplicates_linked integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    field_headers jsonb DEFAULT '[]'::jsonb NOT NULL,
    data_source text DEFAULT 'Legacy Import'::text NOT NULL,
    committed_row_offset integer DEFAULT 0 NOT NULL,
    field_map jsonb DEFAULT '{}'::jsonb NOT NULL,
    header_signature text DEFAULT ''::text NOT NULL,
    ingestion_mode text DEFAULT 'browser'::text NOT NULL,
    storage_object_path text,
    source_headers jsonb DEFAULT '[]'::jsonb NOT NULL,
    file_size_bytes bigint,
    processed_bytes bigint DEFAULT 0 NOT NULL,
    worker_id text,
    lease_expires_at timestamp with time zone,
    started_at timestamp with time zone,
    heartbeat_at timestamp with time zone,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_error text,
    prospect_date_added date,
    merge_mode text DEFAULT 'enrich'::text NOT NULL,
    CONSTRAINT imports_background_counters_nonnegative CHECK (((processed_bytes >= 0) AND (attempt_count >= 0) AND (COALESCE(file_size_bytes, (0)::bigint) >= 0))),
    CONSTRAINT imports_background_object_required CHECK (((ingestion_mode <> 'background'::text) OR (NULLIF(storage_object_path, ''::text) IS NOT NULL))),
    CONSTRAINT imports_committed_row_offset_nonnegative CHECK ((committed_row_offset >= 0)),
    CONSTRAINT imports_data_source_required CHECK ((btrim(data_source) <> ''::text)),
    CONSTRAINT imports_ingestion_mode_valid CHECK ((ingestion_mode = ANY (ARRAY['browser'::text, 'background'::text]))),
    CONSTRAINT imports_merge_mode_valid CHECK ((merge_mode = ANY (ARRAY['enrich'::text, 'overwrite'::text, 'skip'::text])))
);


ALTER TABLE public.imports OWNER TO postgres;

--
-- Name: integration_connections; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.integration_connections (
    provider text NOT NULL,
    credential_ciphertext text,
    connected boolean DEFAULT false NOT NULL,
    checked_at timestamp with time zone,
    updated_by text,
    attempt_token uuid,
    next_request_at timestamp with time zone DEFAULT '-infinity'::timestamp with time zone NOT NULL,
    generation uuid DEFAULT gen_random_uuid() NOT NULL,
    campaigns jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT integration_connections_campaigns_check CHECK (((jsonb_typeof(campaigns) = 'array'::text) AND (jsonb_array_length(campaigns) <= 10000) AND (octet_length((campaigns)::text) <= 4194304))),
    CONSTRAINT integration_connections_check CHECK (((NOT connected) OR (credential_ciphertext IS NOT NULL))),
    CONSTRAINT integration_connections_credential_ciphertext_check CHECK (((length(credential_ciphertext) >= 1) AND (length(credential_ciphertext) <= 8192))),
    CONSTRAINT integration_connections_provider_check CHECK ((provider = ANY (ARRAY['smartlead'::text, 'verifier'::text])))
);


ALTER TABLE public.integration_connections OWNER TO postgres;

--
-- Name: list_memberships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.list_memberships (
    list_id text NOT NULL,
    prospect_id text NOT NULL,
    import_id text NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL
)
WITH (autovacuum_vacuum_insert_scale_factor='0.05', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.list_memberships OWNER TO postgres;

--
-- Name: list_rows; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.list_rows (
    id bigint NOT NULL,
    list_id text NOT NULL,
    prospect_id text,
    import_id text NOT NULL,
    source_row_number integer NOT NULL,
    raw_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.05', autovacuum_vacuum_insert_scale_factor='0.05', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.list_rows OWNER TO postgres;

--
-- Name: list_membership_rows; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.list_membership_rows AS
 SELECT lm.list_id,
    lm.prospect_id,
    lm.import_id,
    lm.imported_at,
    COALESCE(lr.raw_data, '{}'::jsonb) AS raw_data
   FROM (public.list_memberships lm
     LEFT JOIN public.list_rows lr ON (((lr.import_id = lm.import_id) AND (lr.prospect_id = lm.prospect_id))));


ALTER TABLE public.list_membership_rows OWNER TO postgres;

--
-- Name: list_rows_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.list_rows ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.list_rows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: list_summaries; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.list_summaries AS
SELECT
    NULL::text AS id,
    NULL::text AS client_id,
    NULL::text AS name,
    NULL::text AS source_file_name,
    NULL::integer AS uploaded_rows,
    NULL::integer AS unique_added,
    NULL::integer AS duplicates_linked,
    NULL::timestamp with time zone AS created_at,
    NULL::integer AS prospect_count,
    NULL::jsonb AS field_headers,
    NULL::integer AS field_count,
    NULL::text AS data_source;


ALTER TABLE public.list_summaries OWNER TO postgres;

--
-- Name: operation_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.operation_log (
    id text DEFAULT (gen_random_uuid())::text NOT NULL,
    action text NOT NULL,
    client_id text,
    actor text DEFAULT ''::text NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    affected integer DEFAULT 0 NOT NULL,
    prospect_ids text[] DEFAULT '{}'::text[] NOT NULL,
    undone_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.operation_log OWNER TO postgres;

--
-- Name: prospect_export_source; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.prospect_export_source AS
 SELECT pi.id,
    pi.first_name,
    pi.last_name,
    pi.full_name,
    pi.work_email,
    pi.personal_email,
    pi.mobile_number,
    pi.linkedin_url,
    pi.title,
    pi.seniority,
    pi.department,
    pi.city,
    pi.state,
    pi.country,
    pi.company_id,
    pi.company_name,
    pi.company_domain,
    pi.all_data,
    pi.created_at,
    pi.updated_at,
    pi.list_count,
    pi.client_count,
    pi.list_names,
    pi.client_names,
    pi.list_ids,
    pi.client_ids,
    pi.list_memberships,
    pi.esp,
    pi.email_provider_type,
    pi.mx_records,
    pi.mx_status,
    pi.mx_checked_at,
    pi.keywords,
    pi.employee_count_min,
    pi.employee_count_max,
    pi.company_location,
    pi.company_city,
    pi.company_state,
    pi.company_country,
    pi.tags,
    pi.tag_text,
    pi.last_contacted_at,
    pi.contact_count,
    pi.search_text,
    pi.location,
    pi.icp_verified_client_ids,
    pi.blocked_client_ids,
    pi.title_seniority,
    pi.title_department,
    pi.title_sub_department,
    pi.title_is_former,
    pi.title_normalized,
    c.industry AS company_industry,
    c.keywords AS company_keywords,
    c.short_description AS company_short_description,
    c.founded_year AS company_founded_year,
    c.technologies AS company_technologies,
    c.total_funding AS company_total_funding
   FROM (public.prospect_index pi
     LEFT JOIN public.companies c ON ((c.id = pi.company_id)));


ALTER TABLE public.prospect_export_source OWNER TO postgres;

--
-- Name: prospect_fields; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospect_fields (
    field_name text NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.prospect_fields OWNER TO postgres;

--
-- Name: prospect_filter_value_cache; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospect_filter_value_cache (
    field text NOT NULL,
    client_id text DEFAULT ''::text NOT NULL,
    data_version bigint NOT NULL,
    entries jsonb NOT NULL,
    computed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.prospect_filter_value_cache OWNER TO postgres;

--
-- Name: prospect_identifiers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospect_identifiers (
    type text NOT NULL,
    value text NOT NULL,
    prospect_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
)
WITH (autovacuum_vacuum_insert_scale_factor='0.05', autovacuum_vacuum_scale_factor='0.05', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.prospect_identifiers OWNER TO postgres;

--
-- Name: prospect_summaries; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.prospect_summaries AS
SELECT
    NULL::text AS id,
    NULL::text AS first_name,
    NULL::text AS last_name,
    NULL::text AS full_name,
    NULL::text AS work_email,
    NULL::text AS personal_email,
    NULL::text AS mobile_number,
    NULL::text AS linkedin_url,
    NULL::text AS title,
    NULL::text AS seniority,
    NULL::text AS department,
    NULL::text AS city,
    NULL::text AS state,
    NULL::text AS country,
    NULL::text AS company_id,
    NULL::jsonb AS all_data,
    NULL::timestamp with time zone AS created_at,
    NULL::timestamp with time zone AS updated_at,
    NULL::text AS company_name,
    NULL::text AS company_domain,
    NULL::integer AS list_count,
    NULL::integer AS client_count,
    NULL::text[] AS list_names,
    NULL::text[] AS client_names,
    NULL::text[] AS list_ids,
    NULL::text[] AS client_ids,
    NULL::jsonb AS list_memberships,
    NULL::text AS esp,
    NULL::text AS email_provider_type,
    NULL::text[] AS mx_records,
    NULL::text AS mx_status,
    NULL::timestamp with time zone AS mx_checked_at,
    NULL::text[] AS keywords,
    NULL::integer AS employee_count_min,
    NULL::integer AS employee_count_max,
    NULL::text AS company_location,
    NULL::text AS company_city,
    NULL::text AS company_state,
    NULL::text AS company_country;


ALTER TABLE public.prospect_summaries OWNER TO postgres;

--
-- Name: prospect_tag_links; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospect_tag_links (
    prospect_id text NOT NULL,
    tag_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.prospect_tag_links OWNER TO postgres;

--
-- Name: prospect_tags; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospect_tags (
    id text NOT NULL,
    name text NOT NULL,
    color text DEFAULT 'blue'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    client_id text
);


ALTER TABLE public.prospect_tags OWNER TO postgres;

--
-- Name: prospects; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.prospects (
    id text NOT NULL,
    first_name text DEFAULT ''::text NOT NULL,
    last_name text DEFAULT ''::text NOT NULL,
    full_name text DEFAULT ''::text NOT NULL,
    work_email text DEFAULT ''::text NOT NULL,
    personal_email text DEFAULT ''::text NOT NULL,
    mobile_number text DEFAULT ''::text NOT NULL,
    linkedin_url text DEFAULT ''::text NOT NULL,
    title text DEFAULT ''::text NOT NULL,
    seniority text DEFAULT ''::text NOT NULL,
    department text DEFAULT ''::text NOT NULL,
    city text DEFAULT ''::text NOT NULL,
    state text DEFAULT ''::text NOT NULL,
    country text DEFAULT ''::text NOT NULL,
    company_id text,
    all_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    keywords text[] DEFAULT '{}'::text[] NOT NULL,
    location text DEFAULT ''::text NOT NULL,
    title_seniority text DEFAULT ''::text NOT NULL,
    title_department text DEFAULT ''::text NOT NULL,
    title_sub_department text DEFAULT ''::text NOT NULL,
    title_secondary_departments text[] DEFAULT '{}'::text[] NOT NULL,
    title_is_former boolean DEFAULT false NOT NULL,
    title_normalized text DEFAULT ''::text NOT NULL,
    title_classified_at timestamp with time zone
)
WITH (autovacuum_vacuum_scale_factor='0.05', autovacuum_vacuum_insert_scale_factor='0.05', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.prospects OWNER TO postgres;

--
-- Name: reindex_backlog; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.reindex_backlog (
    prospect_id text NOT NULL,
    enqueued_at timestamp with time zone DEFAULT now() NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text DEFAULT ''::text NOT NULL,
    last_attempt_at timestamp with time zone
);


ALTER TABLE public.reindex_backlog OWNER TO postgres;

--
-- Name: saved_views; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.saved_views (
    id text NOT NULL,
    name text NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.saved_views OWNER TO postgres;

--
-- Name: system_event_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.system_event_log (
    id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    level text NOT NULL,
    source text NOT NULL,
    route text,
    status_code integer,
    duration_ms integer,
    request_id text,
    message text NOT NULL,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT system_event_log_level_check CHECK ((level = ANY (ARRAY['info'::text, 'warn'::text, 'error'::text])))
);


ALTER TABLE public.system_event_log OWNER TO postgres;

--
-- Name: system_event_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.system_event_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.system_event_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: title_classifier_state; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.title_classifier_state (
    id boolean DEFAULT true NOT NULL,
    keywords_updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT title_classifier_state_singleton CHECK (id)
);


ALTER TABLE public.title_classifier_state OWNER TO postgres;

--
-- Name: title_department_keywords; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.title_department_keywords (
    keyword text NOT NULL,
    department text NOT NULL,
    sub_department text DEFAULT ''::text NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    token_count integer GENERATED ALWAYS AS (COALESCE(array_length(string_to_array(keyword, ' '::text), 1), 0)) STORED
);


ALTER TABLE public.title_department_keywords OWNER TO postgres;

--
-- Name: title_seniority_keywords; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.title_seniority_keywords (
    keyword text NOT NULL,
    tier text NOT NULL,
    notes text DEFAULT ''::text NOT NULL,
    token_count integer GENERATED ALWAYS AS (COALESCE(array_length(string_to_array(keyword, ' '::text), 1), 0)) STORED,
    CONSTRAINT title_seniority_keywords_tier_check CHECK ((tier = ANY (ARRAY['owner'::text, 'c_suite'::text, 'vp'::text, 'director'::text, 'manager'::text, 'senior_ic'::text, 'entry'::text, 'none'::text])))
);


ALTER TABLE public.title_seniority_keywords OWNER TO postgres;

--
-- Name: schema_migrations; Type: TABLE; Schema: supabase_migrations; Owner: postgres
--

CREATE TABLE supabase_migrations.schema_migrations (
    version text NOT NULL,
    statements text[],
    name text
);


ALTER TABLE supabase_migrations.schema_migrations OWNER TO postgres;

--
-- Name: job_parts job_parts_pkey; Type: CONSTRAINT; Schema: prospect_exports; Owner: postgres
--

ALTER TABLE ONLY prospect_exports.job_parts
    ADD CONSTRAINT job_parts_pkey PRIMARY KEY (job_id, part_index);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: prospect_exports; Owner: postgres
--

ALTER TABLE ONLY prospect_exports.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: filter_set_values filter_set_values_pkey; Type: CONSTRAINT; Schema: prospect_filters; Owner: postgres
--

ALTER TABLE ONLY prospect_filters.filter_set_values
    ADD CONSTRAINT filter_set_values_pkey PRIMARY KEY (filter_set_id, normalized_value);


--
-- Name: filter_sets filter_sets_pkey; Type: CONSTRAINT; Schema: prospect_filters; Owner: postgres
--

ALTER TABLE ONLY prospect_filters.filter_sets
    ADD CONSTRAINT filter_sets_pkey PRIMARY KEY (id);


--
-- Name: staged_rows staged_rows_pkey; Type: CONSTRAINT; Schema: prospect_import; Owner: postgres
--

ALTER TABLE ONLY prospect_import.staged_rows
    ADD CONSTRAINT staged_rows_pkey PRIMARY KEY (import_id, row_offset);


--
-- Name: batches batches_job_id_ordinal_key; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.batches
    ADD CONSTRAINT batches_job_id_ordinal_key UNIQUE (job_id, ordinal);


--
-- Name: batches batches_pkey; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.batches
    ADD CONSTRAINT batches_pkey PRIMARY KEY (id);


--
-- Name: campaign_requests campaign_requests_actor_request_id_key; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.campaign_requests
    ADD CONSTRAINT campaign_requests_actor_request_id_key UNIQUE (actor, request_id);


--
-- Name: campaign_requests campaign_requests_pkey; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.campaign_requests
    ADD CONSTRAINT campaign_requests_pkey PRIMARY KEY (id);


--
-- Name: client_campaigns client_campaigns_pkey; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.client_campaigns
    ADD CONSTRAINT client_campaigns_pkey PRIMARY KEY (campaign_id);


--
-- Name: jobs jobs_actor_request_id_key; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.jobs
    ADD CONSTRAINT jobs_actor_request_id_key UNIQUE (actor, request_id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);


--
-- Name: job_metrics job_metrics_pkey; Type: CONSTRAINT; Schema: prospect_operations; Owner: postgres
--

ALTER TABLE ONLY prospect_operations.job_metrics
    ADD CONSTRAINT job_metrics_pkey PRIMARY KEY (hour, kind, outcome, duration_bucket_ms);


--
-- Name: operation_job_items operation_job_items_pkey; Type: CONSTRAINT; Schema: prospect_operations; Owner: postgres
--

ALTER TABLE ONLY prospect_operations.operation_job_items
    ADD CONSTRAINT operation_job_items_pkey PRIMARY KEY (job_id, entity_id);


--
-- Name: operation_jobs operation_jobs_pkey; Type: CONSTRAINT; Schema: prospect_operations; Owner: postgres
--

ALTER TABLE ONLY prospect_operations.operation_jobs
    ADD CONSTRAINT operation_jobs_pkey PRIMARY KEY (id);


--
-- Name: result_set_items result_set_items_pkey; Type: CONSTRAINT; Schema: prospect_results; Owner: postgres
--

ALTER TABLE ONLY prospect_results.result_set_items
    ADD CONSTRAINT result_set_items_pkey PRIMARY KEY (result_set_id, entity_id);


--
-- Name: result_sets result_sets_pkey; Type: CONSTRAINT; Schema: prospect_results; Owner: postgres
--

ALTER TABLE ONLY prospect_results.result_sets
    ADD CONSTRAINT result_sets_pkey PRIMARY KEY (id);


--
-- Name: client_addition_batch_items client_addition_batch_items_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_addition_batch_items
    ADD CONSTRAINT client_addition_batch_items_pkey PRIMARY KEY (batch_id, entity_id);


--
-- Name: client_addition_batches client_addition_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_addition_batches
    ADD CONSTRAINT client_addition_batches_pkey PRIMARY KEY (id);


--
-- Name: client_blocklist_batch_results client_blocklist_batch_results_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_batch_results
    ADD CONSTRAINT client_blocklist_batch_results_pkey PRIMARY KEY (request_id);


--
-- Name: client_blocklist client_blocklist_client_id_kind_value_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist
    ADD CONSTRAINT client_blocklist_client_id_kind_value_key UNIQUE (client_id, kind, value);


--
-- Name: client_blocklist client_blocklist_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist
    ADD CONSTRAINT client_blocklist_pkey PRIMARY KEY (id);


--
-- Name: client_blocklist_share_limits client_blocklist_share_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_share_limits
    ADD CONSTRAINT client_blocklist_share_limits_pkey PRIMARY KEY (share_id, requester_hash);


--
-- Name: client_blocklist_share_submissions client_blocklist_share_submissions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_share_submissions
    ADD CONSTRAINT client_blocklist_share_submissions_pkey PRIMARY KEY (id);


--
-- Name: client_blocklist_share_submissions client_blocklist_share_submissions_share_id_request_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_share_submissions
    ADD CONSTRAINT client_blocklist_share_submissions_share_id_request_key_key UNIQUE (share_id, request_key);


--
-- Name: client_blocklist_shares client_blocklist_shares_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_shares
    ADD CONSTRAINT client_blocklist_shares_pkey PRIMARY KEY (id);


--
-- Name: client_blocklist_shares client_blocklist_shares_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_shares
    ADD CONSTRAINT client_blocklist_shares_token_hash_key UNIQUE (token_hash);


--
-- Name: client_companies_blocked client_companies_blocked_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_companies_blocked
    ADD CONSTRAINT client_companies_blocked_pkey PRIMARY KEY (client_id, company_id);


--
-- Name: client_companies client_companies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_companies
    ADD CONSTRAINT client_companies_pkey PRIMARY KEY (client_id, company_id);


--
-- Name: client_company_icp_validations client_company_icp_validations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_company_icp_validations
    ADD CONSTRAINT client_company_icp_validations_pkey PRIMARY KEY (client_id, company_id);


--
-- Name: client_folders client_folders_normalized_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_folders
    ADD CONSTRAINT client_folders_normalized_name_key UNIQUE (normalized_name);


--
-- Name: client_folders client_folders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_folders
    ADD CONSTRAINT client_folders_pkey PRIMARY KEY (id);


--
-- Name: client_icp_profiles client_icp_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_icp_profiles
    ADD CONSTRAINT client_icp_profiles_pkey PRIMARY KEY (id);


--
-- Name: client_prospects client_prospects_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_prospects
    ADD CONSTRAINT client_prospects_pkey PRIMARY KEY (client_id, prospect_id);


--
-- Name: client_settings client_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_settings
    ADD CONSTRAINT client_settings_pkey PRIMARY KEY (client_id);


--
-- Name: clients clients_normalized_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_normalized_name_key UNIQUE (normalized_name);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: companies companies_domain_is_normalized; Type: CHECK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE public.companies
    ADD CONSTRAINT companies_domain_is_normalized CHECK (((domain IS NULL) OR (normalized_domain IS NULL) OR (lower(domain) = normalized_domain))) NOT VALID;


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: company_import_memberships company_import_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_import_memberships
    ADD CONSTRAINT company_import_memberships_pkey PRIMARY KEY (import_id, company_id);


--
-- Name: company_import_rows company_import_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_import_rows
    ADD CONSTRAINT company_import_rows_pkey PRIMARY KEY (import_id, source_row_number);


--
-- Name: company_imports company_imports_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_imports
    ADD CONSTRAINT company_imports_pkey PRIMARY KEY (id);


--
-- Name: company_sources company_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_sources
    ADD CONSTRAINT company_sources_pkey PRIMARY KEY (company_id, data_source);


--
-- Name: company_tag_links company_tag_links_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_tag_links
    ADD CONSTRAINT company_tag_links_pkey PRIMARY KEY (company_id, tag_id);


--
-- Name: company_value_suggestions company_value_suggestions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_value_suggestions
    ADD CONSTRAINT company_value_suggestions_pkey PRIMARY KEY (kind, value);


--
-- Name: contact_events contact_events_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_events
    ADD CONSTRAINT contact_events_pkey PRIMARY KEY (id);


--
-- Name: dashboard_snapshot dashboard_snapshot_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dashboard_snapshot
    ADD CONSTRAINT dashboard_snapshot_pkey PRIMARY KEY (key);


--
-- Name: imports imports_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.imports
    ADD CONSTRAINT imports_pkey PRIMARY KEY (id);


--
-- Name: integration_connections integration_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.integration_connections
    ADD CONSTRAINT integration_connections_pkey PRIMARY KEY (provider);


--
-- Name: list_memberships list_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_memberships
    ADD CONSTRAINT list_memberships_pkey PRIMARY KEY (list_id, prospect_id);


--
-- Name: list_rows list_rows_import_id_source_row_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_rows
    ADD CONSTRAINT list_rows_import_id_source_row_number_key UNIQUE (import_id, source_row_number);


--
-- Name: list_rows list_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_rows
    ADD CONSTRAINT list_rows_pkey PRIMARY KEY (id);


--
-- Name: lists lists_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_pkey PRIMARY KEY (id);


--
-- Name: operation_log operation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.operation_log
    ADD CONSTRAINT operation_log_pkey PRIMARY KEY (id);


--
-- Name: prospect_fields prospect_fields_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_fields
    ADD CONSTRAINT prospect_fields_pkey PRIMARY KEY (field_name);


--
-- Name: prospect_filter_value_cache prospect_filter_value_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_filter_value_cache
    ADD CONSTRAINT prospect_filter_value_cache_pkey PRIMARY KEY (field, client_id);


--
-- Name: prospect_identifiers prospect_identifiers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_identifiers
    ADD CONSTRAINT prospect_identifiers_pkey PRIMARY KEY (type, value);


--
-- Name: prospect_index prospect_index_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_index
    ADD CONSTRAINT prospect_index_pkey PRIMARY KEY (id);


--
-- Name: prospect_tag_links prospect_tag_links_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_tag_links
    ADD CONSTRAINT prospect_tag_links_pkey PRIMARY KEY (prospect_id, tag_id);


--
-- Name: prospect_tags prospect_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_tags
    ADD CONSTRAINT prospect_tags_pkey PRIMARY KEY (id);


--
-- Name: prospects prospects_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospects
    ADD CONSTRAINT prospects_pkey PRIMARY KEY (id);


--
-- Name: reindex_backlog reindex_backlog_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.reindex_backlog
    ADD CONSTRAINT reindex_backlog_pkey PRIMARY KEY (prospect_id);


--
-- Name: saved_views saved_views_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.saved_views
    ADD CONSTRAINT saved_views_pkey PRIMARY KEY (id);


--
-- Name: system_event_log system_event_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.system_event_log
    ADD CONSTRAINT system_event_log_pkey PRIMARY KEY (id);


--
-- Name: title_classifier_state title_classifier_state_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.title_classifier_state
    ADD CONSTRAINT title_classifier_state_pkey PRIMARY KEY (id);


--
-- Name: title_department_keywords title_department_keywords_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.title_department_keywords
    ADD CONSTRAINT title_department_keywords_pkey PRIMARY KEY (keyword);


--
-- Name: title_seniority_keywords title_seniority_keywords_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.title_seniority_keywords
    ADD CONSTRAINT title_seniority_keywords_pkey PRIMARY KEY (keyword);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: supabase_migrations; Owner: postgres
--

ALTER TABLE ONLY supabase_migrations.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: idx_export_jobs_expires_at; Type: INDEX; Schema: prospect_exports; Owner: postgres
--

CREATE INDEX idx_export_jobs_expires_at ON prospect_exports.jobs USING btree (expires_at);


--
-- Name: idx_export_jobs_queued; Type: INDEX; Schema: prospect_exports; Owner: postgres
--

CREATE INDEX idx_export_jobs_queued ON prospect_exports.jobs USING btree (created_at) WHERE (status = ANY (ARRAY['queued'::text, 'building'::text]));


--
-- Name: uq_export_jobs_request; Type: INDEX; Schema: prospect_exports; Owner: postgres
--

CREATE UNIQUE INDEX uq_export_jobs_request ON prospect_exports.jobs USING btree (owner_id, request_id);


--
-- Name: idx_filter_sets_expires_at; Type: INDEX; Schema: prospect_filters; Owner: postgres
--

CREATE INDEX idx_filter_sets_expires_at ON prospect_filters.filter_sets USING btree (expires_at);


--
-- Name: uq_filter_sets_identity; Type: INDEX; Schema: prospect_filters; Owner: postgres
--

CREATE UNIQUE INDEX uq_filter_sets_identity ON prospect_filters.filter_sets USING btree (owner_id, entity_type, client_scope, field, normalization_version, content_hash);


--
-- Name: integration_batches_work; Type: INDEX; Schema: prospect_integrations; Owner: postgres
--

CREATE INDEX integration_batches_work ON prospect_integrations.batches USING btree (job_id, ordinal) WHERE (status = ANY (ARRAY['pending'::text, 'sending'::text]));


--
-- Name: integration_campaign_client; Type: INDEX; Schema: prospect_integrations; Owner: postgres
--

CREATE INDEX integration_campaign_client ON prospect_integrations.client_campaigns USING btree (client_id) WHERE enabled;


--
-- Name: integration_creation_queue; Type: INDEX; Schema: prospect_integrations; Owner: postgres
--

CREATE INDEX integration_creation_queue ON prospect_integrations.campaign_requests USING btree (next_attempt_at, created_at) WHERE (status = 'queued'::text);


--
-- Name: integration_inflight_lease; Type: INDEX; Schema: prospect_integrations; Owner: postgres
--

CREATE INDEX integration_inflight_lease ON prospect_integrations.batches USING btree (lease_until) WHERE (status = 'sending'::text);


--
-- Name: integration_jobs_actor; Type: INDEX; Schema: prospect_integrations; Owner: postgres
--

CREATE INDEX integration_jobs_actor ON prospect_integrations.jobs USING btree (actor, created_at DESC);


--
-- Name: integration_jobs_queue; Type: INDEX; Schema: prospect_integrations; Owner: postgres
--

CREATE INDEX integration_jobs_queue ON prospect_integrations.jobs USING btree (created_at) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));


--
-- Name: idx_operation_job_items_pending; Type: INDEX; Schema: prospect_operations; Owner: postgres
--

CREATE INDEX idx_operation_job_items_pending ON prospect_operations.operation_job_items USING btree (job_id, ordinal) WHERE (applied_at IS NULL);


--
-- Name: idx_operation_jobs_claimable; Type: INDEX; Schema: prospect_operations; Owner: postgres
--

CREATE INDEX idx_operation_jobs_claimable ON prospect_operations.operation_jobs USING btree (created_at) WHERE (status = ANY (ARRAY['frozen'::text, 'running'::text]));


--
-- Name: idx_operation_jobs_expires_at; Type: INDEX; Schema: prospect_operations; Owner: postgres
--

CREATE INDEX idx_operation_jobs_expires_at ON prospect_operations.operation_jobs USING btree (expires_at);


--
-- Name: uq_operation_job_items_ordinal; Type: INDEX; Schema: prospect_operations; Owner: postgres
--

CREATE UNIQUE INDEX uq_operation_job_items_ordinal ON prospect_operations.operation_job_items USING btree (job_id, ordinal);


--
-- Name: uq_operation_jobs_request; Type: INDEX; Schema: prospect_operations; Owner: postgres
--

CREATE UNIQUE INDEX uq_operation_jobs_request ON prospect_operations.operation_jobs USING btree (actor, action, request_id);


--
-- Name: idx_result_sets_expires_at; Type: INDEX; Schema: prospect_results; Owner: postgres
--

CREATE INDEX idx_result_sets_expires_at ON prospect_results.result_sets USING btree (expires_at);


--
-- Name: idx_result_sets_pending; Type: INDEX; Schema: prospect_results; Owner: postgres
--

CREATE INDEX idx_result_sets_pending ON prospect_results.result_sets USING btree (created_at) WHERE (status = 'pending'::text);


--
-- Name: uq_result_set_items_ordinal; Type: INDEX; Schema: prospect_results; Owner: postgres
--

CREATE UNIQUE INDEX uq_result_set_items_ordinal ON prospect_results.result_set_items USING btree (result_set_id, ordinal);


--
-- Name: uq_result_sets_identity; Type: INDEX; Schema: prospect_results; Owner: postgres
--

CREATE UNIQUE INDEX uq_result_sets_identity ON prospect_results.result_sets USING btree (owner_id, entity_type, client_scope, authorization_scope, content_hash, md5((company_scope)::text)) WHERE (status = ANY (ARRAY['pending'::text, 'building'::text, 'ready'::text]));


--
-- Name: idx_client_addition_batch_items_entity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_addition_batch_items_entity ON public.client_addition_batch_items USING btree (entity_id, batch_id);


--
-- Name: idx_client_addition_batches_recent; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_addition_batches_recent ON public.client_addition_batches USING btree (client_id, created_at DESC, id);


--
-- Name: idx_client_blocklist_batch_results_client_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_blocklist_batch_results_client_created ON public.client_blocklist_batch_results USING btree (client_id, created_at DESC);


--
-- Name: idx_client_blocklist_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_blocklist_lookup ON public.client_blocklist USING btree (client_id, kind, value);


--
-- Name: idx_client_blocklist_share_submissions_queue; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_blocklist_share_submissions_queue ON public.client_blocklist_share_submissions USING btree (created_at) WHERE (status = ANY (ARRAY['queued'::text, 'running'::text]));


--
-- Name: idx_client_blocklist_shares_client; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_blocklist_shares_client ON public.client_blocklist_shares USING btree (client_id, created_at DESC);


--
-- Name: idx_client_companies_added_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_companies_added_at ON public.client_companies USING btree (client_id, added_at DESC);


--
-- Name: idx_client_companies_blocked_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_companies_blocked_company ON public.client_companies_blocked USING btree (company_id, client_id);


--
-- Name: idx_client_companies_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_companies_company ON public.client_companies USING btree (company_id, client_id);


--
-- Name: idx_client_companies_ranking; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_companies_ranking ON public.client_companies USING btree (client_id, prospect_count DESC, company_id);


--
-- Name: idx_client_company_icp_validations_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_company_icp_validations_company ON public.client_company_icp_validations USING btree (company_id, client_id);


--
-- Name: idx_client_company_icp_validations_company_client; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_company_icp_validations_company_client ON public.client_company_icp_validations USING btree (company_id, client_id);


--
-- Name: idx_client_icp_profiles_client; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_icp_profiles_client ON public.client_icp_profiles USING btree (client_id, sort_order, id);


--
-- Name: idx_client_prospects_added_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_prospects_added_at ON public.client_prospects USING btree (client_id, added_at DESC);


--
-- Name: idx_client_prospects_date_added; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_prospects_date_added ON public.client_prospects USING btree (client_id, date_added DESC, prospect_id);


--
-- Name: idx_client_prospects_lead; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_prospects_lead ON public.client_prospects USING btree (client_id, prospect_id) WHERE is_lead;


--
-- Name: idx_client_prospects_prospect; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_prospects_prospect ON public.client_prospects USING btree (prospect_id);


--
-- Name: idx_client_prospects_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_prospects_status ON public.client_prospects USING btree (client_id, status);


--
-- Name: idx_client_prospects_verified; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_client_prospects_verified ON public.client_prospects USING btree (client_id, icp_verified);


--
-- Name: idx_clients_archived; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_clients_archived ON public.clients USING btree (archived_at DESC, name) WHERE (archived_at IS NOT NULL);


--
-- Name: idx_clients_folder_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_clients_folder_active ON public.clients USING btree (folder_id, name) WHERE (archived_at IS NULL);


--
-- Name: idx_companies_blank_domain_name_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_blank_domain_name_created ON public.companies USING btree (normalized_name, created_at) WHERE ((COALESCE(normalized_domain, ''::text) = ''::text) AND (normalized_name <> ''::text));


--
-- Name: idx_companies_city_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_city_trgm ON public.companies USING gin (city public.gin_trgm_ops);


--
-- Name: idx_companies_country_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_country_trgm ON public.companies USING gin (country public.gin_trgm_ops);


--
-- Name: idx_companies_domain_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_domain_trgm ON public.companies USING gin (domain public.gin_trgm_ops);


--
-- Name: idx_companies_employee_count; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_employee_count ON public.companies USING btree (employee_count_min, employee_count_max);


--
-- Name: idx_companies_employee_count_min; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_employee_count_min ON public.companies USING btree (employee_count_min);


--
-- Name: idx_companies_founded_year; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_founded_year ON public.companies USING btree (founded_year);


--
-- Name: idx_companies_industry_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_industry_lower ON public.companies USING btree (lower(industry));


--
-- Name: idx_companies_industry_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_industry_trgm ON public.companies USING gin (industry public.gin_trgm_ops);


--
-- Name: idx_companies_keywords_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_keywords_gin ON public.companies USING gin (keywords);


--
-- Name: idx_companies_location; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_location ON public.companies USING btree (lower(country), lower(state), lower(city));


--
-- Name: idx_companies_location_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_location_trgm ON public.companies USING gin (location public.gin_trgm_ops);


--
-- Name: idx_companies_lower_name_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_lower_name_id ON public.companies USING btree (lower(name), id);


--
-- Name: idx_companies_name_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_name_trgm ON public.companies USING gin (name public.gin_trgm_ops);


--
-- Name: idx_companies_normalized_domain; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_normalized_domain ON public.companies USING btree (normalized_domain);


--
-- Name: idx_companies_normalized_domain_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_normalized_domain_created ON public.companies USING btree (normalized_domain, created_at) WHERE (normalized_domain <> ''::text);


--
-- Name: idx_companies_normalized_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_normalized_name ON public.companies USING btree (normalized_name);


--
-- Name: idx_companies_pending_mx_scan; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_pending_mx_scan ON public.companies USING btree (id) WHERE ((normalized_domain <> ''::text) AND (mx_checked_at IS NULL));


--
-- Name: idx_companies_prospect_ranking; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_prospect_ranking ON public.companies USING btree (prospect_count DESC, name) INCLUDE (id, domain, created_at, client_count);


--
-- Name: idx_companies_short_description_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_short_description_trgm ON public.companies USING gin (short_description public.gin_trgm_ops);


--
-- Name: idx_companies_state_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_state_trgm ON public.companies USING gin (state public.gin_trgm_ops);


--
-- Name: idx_companies_technologies_gin; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_technologies_gin ON public.companies USING gin (technologies);


--
-- Name: idx_companies_technologies_text_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_technologies_text_trgm ON public.companies USING gin (public.company_technologies_text_v1(technologies) public.gin_trgm_ops);


--
-- Name: idx_companies_total_funding_amount; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_total_funding_amount ON public.companies USING btree (total_funding_amount) WHERE (total_funding_amount IS NOT NULL);


--
-- Name: idx_companies_total_funding_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_companies_total_funding_trgm ON public.companies USING gin (total_funding public.gin_trgm_ops);


--
-- Name: idx_company_import_memberships_company; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_import_memberships_company ON public.company_import_memberships USING btree (company_id, import_id);


--
-- Name: idx_company_import_rows_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_import_rows_company_id ON public.company_import_rows USING btree (company_id);


--
-- Name: idx_company_imports_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_imports_created_at ON public.company_imports USING btree (created_at DESC);


--
-- Name: idx_company_sources_data_source; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_sources_data_source ON public.company_sources USING btree (data_source, company_id);


--
-- Name: idx_company_sources_last_import_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_sources_last_import_id ON public.company_sources USING btree (last_import_id);


--
-- Name: idx_company_tag_links_tag; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_tag_links_tag ON public.company_tag_links USING btree (tag_id, company_id);


--
-- Name: idx_company_value_suggestions_rank; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_value_suggestions_rank ON public.company_value_suggestions USING btree (kind, company_count DESC);


--
-- Name: idx_company_value_suggestions_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_company_value_suggestions_trgm ON public.company_value_suggestions USING gin (value public.gin_trgm_ops);


--
-- Name: idx_contact_events_client; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contact_events_client ON public.contact_events USING btree (client_id, contacted_at DESC);


--
-- Name: idx_contact_events_prospect; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_contact_events_prospect ON public.contact_events USING btree (prospect_id, contacted_at DESC);


--
-- Name: idx_identifiers_prospect_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_identifiers_prospect_id ON public.prospect_identifiers USING btree (prospect_id);


--
-- Name: idx_imports_background_queue; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_imports_background_queue ON public.imports USING btree (next_attempt_at, created_at) WHERE ((ingestion_mode = 'background'::text) AND (status = ANY (ARRAY['queued'::text, 'processing'::text])));


--
-- Name: idx_imports_client_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_imports_client_id ON public.imports USING btree (client_id);


--
-- Name: idx_imports_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_imports_created_at ON public.imports USING btree (created_at DESC);


--
-- Name: idx_imports_list_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_imports_list_id ON public.imports USING btree (list_id);


--
-- Name: idx_list_rows_list_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_list_rows_list_id ON public.list_rows USING btree (list_id);


--
-- Name: idx_list_rows_list_prospect; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_list_rows_list_prospect ON public.list_rows USING btree (list_id, prospect_id);


--
-- Name: idx_list_rows_prospect_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_list_rows_prospect_id ON public.list_rows USING btree (prospect_id);


--
-- Name: idx_lists_client_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_lists_client_id ON public.lists USING btree (client_id);


--
-- Name: idx_memberships_import_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_memberships_import_id ON public.list_memberships USING btree (import_id);


--
-- Name: idx_memberships_prospect_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_memberships_prospect_id ON public.list_memberships USING btree (prospect_id);


--
-- Name: idx_operation_log_client; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_operation_log_client ON public.operation_log USING btree (client_id, created_at DESC);


--
-- Name: idx_operation_log_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_operation_log_created ON public.operation_log USING btree (created_at DESC);


--
-- Name: idx_prospect_index_blocked; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_blocked ON public.prospect_index USING gin (blocked_client_ids);


--
-- Name: idx_prospect_index_city_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_city_trgm ON public.prospect_index USING gin (city public.gin_trgm_ops);


--
-- Name: idx_prospect_index_client_ids; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_client_ids ON public.prospect_index USING gin (client_ids);


--
-- Name: idx_prospect_index_client_names; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_client_names ON public.prospect_index USING gin (client_names);


--
-- Name: idx_prospect_index_company_country_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_country_trgm ON public.prospect_index USING gin (company_country public.gin_trgm_ops);


--
-- Name: idx_prospect_index_company_created_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_created_id ON public.prospect_index USING btree (company_id, created_at DESC, id DESC);


--
-- Name: idx_prospect_index_company_domain_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_domain_lower ON public.prospect_index USING btree (lower(company_domain));


--
-- Name: idx_prospect_index_company_domain_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_domain_trgm ON public.prospect_index USING gin (company_domain public.gin_trgm_ops);


--
-- Name: idx_prospect_index_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_id ON public.prospect_index USING btree (company_id);


--
-- Name: idx_prospect_index_company_name_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_name_lower ON public.prospect_index USING btree (lower(company_name));


--
-- Name: idx_prospect_index_company_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_company_trgm ON public.prospect_index USING gin (company_name public.gin_trgm_ops);


--
-- Name: idx_prospect_index_country_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_country_trgm ON public.prospect_index USING gin (country public.gin_trgm_ops);


--
-- Name: idx_prospect_index_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_created_at ON public.prospect_index USING btree (created_at DESC, id);


--
-- Name: idx_prospect_index_department_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_department_lower ON public.prospect_index USING btree (lower(department));


--
-- Name: idx_prospect_index_department_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_department_trgm ON public.prospect_index USING gin (department public.gin_trgm_ops);


--
-- Name: idx_prospect_index_email_provider_type_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_email_provider_type_lower ON public.prospect_index USING btree (lower(email_provider_type));


--
-- Name: idx_prospect_index_employees; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_employees ON public.prospect_index USING btree (employee_count_min, employee_count_max);


--
-- Name: idx_prospect_index_esp_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_esp_lower ON public.prospect_index USING btree (lower(esp));


--
-- Name: idx_prospect_index_first_name_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_first_name_trgm ON public.prospect_index USING gin (first_name public.gin_trgm_ops);


--
-- Name: idx_prospect_index_full_name_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_full_name_lower ON public.prospect_index USING btree (lower(full_name));


--
-- Name: idx_prospect_index_full_name_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_full_name_trgm ON public.prospect_index USING gin (full_name public.gin_trgm_ops);


--
-- Name: idx_prospect_index_icp_verified; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_icp_verified ON public.prospect_index USING gin (icp_verified_client_ids);


--
-- Name: idx_prospect_index_keywords; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_keywords ON public.prospect_index USING gin (keywords);


--
-- Name: idx_prospect_index_last_contacted; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_last_contacted ON public.prospect_index USING btree (last_contacted_at DESC NULLS LAST);


--
-- Name: idx_prospect_index_last_name_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_last_name_trgm ON public.prospect_index USING gin (last_name public.gin_trgm_ops);


--
-- Name: idx_prospect_index_linkedin_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_linkedin_trgm ON public.prospect_index USING gin (linkedin_url public.gin_trgm_ops);


--
-- Name: idx_prospect_index_list_ids; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_list_ids ON public.prospect_index USING gin (list_ids);


--
-- Name: idx_prospect_index_list_names; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_list_names ON public.prospect_index USING gin (list_names);


--
-- Name: idx_prospect_index_location_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_location_trgm ON public.prospect_index USING gin (location public.gin_trgm_ops);


--
-- Name: idx_prospect_index_personal_email_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_personal_email_trgm ON public.prospect_index USING gin (personal_email public.gin_trgm_ops);


--
-- Name: idx_prospect_index_search_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_search_trgm ON public.prospect_index USING gin (search_text public.gin_trgm_ops);


--
-- Name: idx_prospect_index_seniority_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_seniority_lower ON public.prospect_index USING btree (lower(seniority));


--
-- Name: idx_prospect_index_seniority_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_seniority_trgm ON public.prospect_index USING gin (seniority public.gin_trgm_ops);


--
-- Name: idx_prospect_index_state_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_state_trgm ON public.prospect_index USING gin (state public.gin_trgm_ops);


--
-- Name: idx_prospect_index_tag_text_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_tag_text_trgm ON public.prospect_index USING gin (tag_text public.gin_trgm_ops);


--
-- Name: idx_prospect_index_title_department; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_department ON public.prospect_index USING btree (title_department) WHERE (title_department <> ''::text);


--
-- Name: idx_prospect_index_title_department_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_department_lower ON public.prospect_index USING btree (lower(title_department));


--
-- Name: idx_prospect_index_title_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_lower ON public.prospect_index USING btree (lower(title));


--
-- Name: idx_prospect_index_title_seniority; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_seniority ON public.prospect_index USING btree (title_seniority) WHERE (title_seniority <> ''::text);


--
-- Name: idx_prospect_index_title_seniority_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_seniority_lower ON public.prospect_index USING btree (lower(title_seniority));


--
-- Name: idx_prospect_index_title_sub_department; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_sub_department ON public.prospect_index USING btree (title_sub_department) WHERE (title_sub_department <> ''::text);


--
-- Name: idx_prospect_index_title_sub_department_lower; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_sub_department_lower ON public.prospect_index USING btree (lower(title_sub_department));


--
-- Name: idx_prospect_index_title_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_title_trgm ON public.prospect_index USING gin (title public.gin_trgm_ops);


--
-- Name: idx_prospect_index_work_email_trgm; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospect_index_work_email_trgm ON public.prospect_index USING gin (work_email public.gin_trgm_ops);


--
-- Name: idx_prospect_tags_client_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_prospect_tags_client_name ON public.prospect_tags USING btree (client_id, lower(name)) WHERE (client_id IS NOT NULL);


--
-- Name: idx_prospect_tags_global_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_prospect_tags_global_name ON public.prospect_tags USING btree (lower(name)) WHERE (client_id IS NULL);


--
-- Name: idx_prospects_company_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_company_id ON public.prospects USING btree (company_id);


--
-- Name: idx_prospects_full_name; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_full_name ON public.prospects USING btree (full_name);


--
-- Name: idx_prospects_keywords; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_keywords ON public.prospects USING gin (keywords);


--
-- Name: idx_prospects_title_classified_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_title_classified_at ON public.prospects USING btree (title_classified_at NULLS FIRST);


--
-- Name: idx_prospects_unclassified_titles; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_prospects_unclassified_titles ON public.prospects USING btree (title_normalized) WHERE ((title_seniority = ''::text) OR (title_department = ''::text));


--
-- Name: idx_reindex_backlog_enqueued; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_reindex_backlog_enqueued ON public.reindex_backlog USING btree (enqueued_at);


--
-- Name: idx_system_event_log_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_system_event_log_created_at ON public.system_event_log USING btree (created_at DESC);


--
-- Name: idx_system_event_log_level; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_system_event_log_level ON public.system_event_log USING btree (level, created_at DESC);


--
-- Name: idx_system_event_log_source; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_system_event_log_source ON public.system_event_log USING btree (source, created_at DESC);


--
-- Name: idx_tag_links_tag; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_tag_links_tag ON public.prospect_tag_links USING btree (tag_id, prospect_id);


--
-- Name: idx_title_department_keywords_tokens; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_title_department_keywords_tokens ON public.title_department_keywords USING btree (token_count DESC);


--
-- Name: idx_title_seniority_keywords_tokens; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_title_seniority_keywords_tokens ON public.title_seniority_keywords USING btree (token_count DESC);


--
-- Name: uq_client_addition_batch_request; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_client_addition_batch_request ON public.client_addition_batches USING btree (client_id, entity_type, request_key) WHERE ((request_key IS NOT NULL) AND (request_key <> ''::text));


--
-- Name: list_summaries _RETURN; Type: RULE; Schema: public; Owner: postgres
--

CREATE OR REPLACE VIEW public.list_summaries AS
 SELECT l.id,
    l.client_id,
    l.name,
    l.source_file_name,
    l.uploaded_rows,
    l.unique_added,
    l.duplicates_linked,
    l.created_at,
    (count(lm.prospect_id))::integer AS prospect_count,
    l.field_headers,
    jsonb_array_length(l.field_headers) AS field_count,
    l.data_source
   FROM (public.lists l
     LEFT JOIN public.list_memberships lm ON ((lm.list_id = l.id)))
  GROUP BY l.id;


--
-- Name: prospect_summaries _RETURN; Type: RULE; Schema: public; Owner: postgres
--

CREATE OR REPLACE VIEW public.prospect_summaries AS
 SELECT p.id,
    p.first_name,
    p.last_name,
    p.full_name,
    p.work_email,
    p.personal_email,
    p.mobile_number,
    p.linkedin_url,
    p.title,
    p.seniority,
    p.department,
    p.city,
    p.state,
    p.country,
    p.company_id,
    p.all_data,
    p.created_at,
    p.updated_at,
    co.name AS company_name,
    co.domain AS company_domain,
    (count(DISTINCT lm.list_id))::integer AS list_count,
    (count(DISTINCT l.client_id))::integer AS client_count,
    COALESCE(array_agg(DISTINCT l.name ORDER BY l.name) FILTER (WHERE (l.id IS NOT NULL)), '{}'::text[]) AS list_names,
    COALESCE(array_agg(DISTINCT cl.name ORDER BY cl.name) FILTER (WHERE (cl.id IS NOT NULL)), '{}'::text[]) AS client_names,
    COALESCE(array_agg(DISTINCT l.id ORDER BY l.id) FILTER (WHERE (l.id IS NOT NULL)), '{}'::text[]) AS list_ids,
    COALESCE(array_agg(DISTINCT cl.id ORDER BY cl.id) FILTER (WHERE (cl.id IS NOT NULL)), '{}'::text[]) AS client_ids,
    COALESCE(jsonb_agg(DISTINCT jsonb_build_object('listId', l.id, 'listName', l.name, 'clientId', cl.id, 'clientName', cl.name)) FILTER (WHERE (l.id IS NOT NULL)), '[]'::jsonb) AS list_memberships,
    COALESCE(co.esp, ''::text) AS esp,
    COALESCE(co.email_provider_type, 'Unknown'::text) AS email_provider_type,
    COALESCE(co.mx_records, '{}'::text[]) AS mx_records,
    co.mx_status,
    co.mx_checked_at,
    p.keywords,
    co.employee_count_min,
    co.employee_count_max,
    co.location AS company_location,
    co.city AS company_city,
    co.state AS company_state,
    co.country AS company_country
   FROM ((((public.prospects p
     LEFT JOIN public.companies co ON ((co.id = p.company_id)))
     LEFT JOIN public.list_memberships lm ON ((lm.prospect_id = p.id)))
     LEFT JOIN public.lists l ON ((l.id = lm.list_id)))
     LEFT JOIN public.clients cl ON ((cl.id = l.client_id)))
  GROUP BY p.id, co.id;


--
-- Name: jobs export_job_metric; Type: TRIGGER; Schema: prospect_exports; Owner: postgres
--

CREATE TRIGGER export_job_metric AFTER UPDATE OF status ON prospect_exports.jobs FOR EACH ROW EXECUTE FUNCTION prospect_operations.record_job_metric_v1();


--
-- Name: operation_jobs operation_job_metric; Type: TRIGGER; Schema: prospect_operations; Owner: postgres
--

CREATE TRIGGER operation_job_metric AFTER UPDATE OF status ON prospect_operations.operation_jobs FOR EACH ROW EXECUTE FUNCTION prospect_operations.record_job_metric_v1();


--
-- Name: result_sets result_job_metric; Type: TRIGGER; Schema: prospect_results; Owner: postgres
--

CREATE TRIGGER result_job_metric AFTER UPDATE OF status ON prospect_results.result_sets FOR EACH ROW EXECUTE FUNCTION prospect_operations.record_job_metric_v1();


--
-- Name: companies block_company_on_domain_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER block_company_on_domain_change AFTER UPDATE OF normalized_domain ON public.companies FOR EACH ROW WHEN (((old.normalized_domain IS DISTINCT FROM new.normalized_domain) AND (new.normalized_domain <> ''::text))) EXECUTE FUNCTION public.block_company_on_domain_change_v1();


--
-- Name: prospects block_prospect_on_identity_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER block_prospect_on_identity_change AFTER UPDATE OF work_email, personal_email, company_id ON public.prospects FOR EACH ROW WHEN (((old.work_email IS DISTINCT FROM new.work_email) OR (old.personal_email IS DISTINCT FROM new.personal_email) OR (old.company_id IS DISTINCT FROM new.company_id))) EXECUTE FUNCTION public.block_prospect_on_identity_change_v1();


--
-- Name: client_prospects client_prospects_record_import_people_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER client_prospects_record_import_people_v1 AFTER INSERT ON public.client_prospects REFERENCING NEW TABLE AS new_client_rows FOR EACH STATEMENT EXECUTE FUNCTION public.record_new_import_people_v1();


--
-- Name: companies companies_total_funding_amount_sync; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER companies_total_funding_amount_sync BEFORE INSERT OR UPDATE OF total_funding ON public.companies FOR EACH ROW EXECUTE FUNCTION public.sync_total_funding_amount();


--
-- Name: company_import_rows company_import_rows_capture_membership_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER company_import_rows_capture_membership_v1 AFTER INSERT OR UPDATE OF company_id ON public.company_import_rows FOR EACH ROW EXECUTE FUNCTION public.capture_company_import_membership_v1();


--
-- Name: client_companies divert_blocked_client_company; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER divert_blocked_client_company BEFORE INSERT ON public.client_companies FOR EACH ROW EXECUTE FUNCTION public.divert_blocked_client_company_v1();


--
-- Name: imports imports_record_completed_batch_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER imports_record_completed_batch_v1 AFTER UPDATE OF status ON public.imports FOR EACH ROW EXECUTE FUNCTION public.record_completed_import_batch_v1();


--
-- Name: client_prospects inherit_company_icp_validation; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER inherit_company_icp_validation BEFORE INSERT OR UPDATE OF client_id, prospect_id, icp_verified ON public.client_prospects FOR EACH ROW EXECUTE FUNCTION public.inherit_company_icp_validation_v1();


--
-- Name: prospects sync_changed_prospect_company_memberships; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER sync_changed_prospect_company_memberships AFTER UPDATE OF company_id ON public.prospects FOR EACH ROW EXECUTE FUNCTION public.sync_changed_prospect_company_memberships_v1();


--
-- Name: client_prospects sync_client_company_membership; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER sync_client_company_membership AFTER INSERT OR UPDATE OF client_id, prospect_id ON public.client_prospects FOR EACH ROW EXECUTE FUNCTION public.sync_client_company_membership_v1();


--
-- Name: client_blocklist trg_client_blocklist_reason; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_client_blocklist_reason BEFORE INSERT OR UPDATE OF reason ON public.client_blocklist FOR EACH ROW EXECUTE FUNCTION public.enforce_client_blocklist_reason_v1();


--
-- Name: list_memberships trg_client_prospects_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_client_prospects_delete AFTER DELETE ON public.list_memberships REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.sync_client_prospects_from_lists();


--
-- Name: list_memberships trg_client_prospects_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_client_prospects_insert AFTER INSERT ON public.list_memberships REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.sync_client_prospects_from_lists();


--
-- Name: list_memberships trg_client_prospects_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_client_prospects_update AFTER UPDATE ON public.list_memberships REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.sync_client_prospects_from_lists();


--
-- Name: companies trg_data_version_company_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_data_version_company_delete AFTER DELETE ON public.companies REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.bump_data_version_company();


--
-- Name: companies trg_data_version_company_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_data_version_company_insert AFTER INSERT ON public.companies REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.bump_data_version_company();


--
-- Name: companies trg_data_version_company_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_data_version_company_update AFTER UPDATE ON public.companies REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.bump_data_version_company();


--
-- Name: prospect_index trg_data_version_prospect_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_data_version_prospect_delete AFTER DELETE ON public.prospect_index REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.bump_data_version_prospect();


--
-- Name: prospect_index trg_data_version_prospect_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_data_version_prospect_insert AFTER INSERT ON public.prospect_index REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.bump_data_version_prospect();


--
-- Name: prospect_index trg_data_version_prospect_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_data_version_prospect_update AFTER UPDATE ON public.prospect_index REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.bump_data_version_prospect();


--
-- Name: prospect_index trg_prospect_index_fill_title_class; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_prospect_index_fill_title_class BEFORE INSERT OR UPDATE ON public.prospect_index FOR EACH ROW EXECUTE FUNCTION public.prospect_index_fill_title_class();


--
-- Name: prospects trg_prospects_classify_title_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_prospects_classify_title_insert BEFORE INSERT ON public.prospects FOR EACH ROW EXECUTE FUNCTION public.prospects_classify_title();


--
-- Name: prospects trg_prospects_classify_title_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_prospects_classify_title_update BEFORE UPDATE ON public.prospects FOR EACH ROW WHEN (((old.title IS DISTINCT FROM new.title) OR (old.company_id IS DISTINCT FROM new.company_id))) EXECUTE FUNCTION public.prospects_classify_title();


--
-- Name: prospect_index trg_sync_company_counts_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync_company_counts_delete AFTER DELETE ON public.prospect_index REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION public.sync_company_counts_statement();


--
-- Name: prospect_index trg_sync_company_counts_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync_company_counts_insert AFTER INSERT ON public.prospect_index REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.sync_company_counts_statement();


--
-- Name: prospect_index trg_sync_company_counts_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync_company_counts_update AFTER UPDATE ON public.prospect_index REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION public.sync_company_counts_statement();


--
-- Name: title_department_keywords trg_touch_classifier_state_department; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_touch_classifier_state_department AFTER INSERT OR DELETE OR UPDATE ON public.title_department_keywords FOR EACH STATEMENT EXECUTE FUNCTION public.touch_title_classifier_state();


--
-- Name: title_seniority_keywords trg_touch_classifier_state_seniority; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_touch_classifier_state_seniority AFTER INSERT OR DELETE OR UPDATE ON public.title_seniority_keywords FOR EACH STATEMENT EXECUTE FUNCTION public.touch_title_classifier_state();


--
-- Name: job_parts job_parts_job_id_fkey; Type: FK CONSTRAINT; Schema: prospect_exports; Owner: postgres
--

ALTER TABLE ONLY prospect_exports.job_parts
    ADD CONSTRAINT job_parts_job_id_fkey FOREIGN KEY (job_id) REFERENCES prospect_exports.jobs(id) ON DELETE CASCADE;


--
-- Name: filter_set_values filter_set_values_filter_set_id_fkey; Type: FK CONSTRAINT; Schema: prospect_filters; Owner: postgres
--

ALTER TABLE ONLY prospect_filters.filter_set_values
    ADD CONSTRAINT filter_set_values_filter_set_id_fkey FOREIGN KEY (filter_set_id) REFERENCES prospect_filters.filter_sets(id) ON DELETE CASCADE;


--
-- Name: staged_rows staged_rows_import_id_fkey; Type: FK CONSTRAINT; Schema: prospect_import; Owner: postgres
--

ALTER TABLE ONLY prospect_import.staged_rows
    ADD CONSTRAINT staged_rows_import_id_fkey FOREIGN KEY (import_id) REFERENCES public.imports(id) ON DELETE CASCADE;


--
-- Name: batches batches_job_id_fkey; Type: FK CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.batches
    ADD CONSTRAINT batches_job_id_fkey FOREIGN KEY (job_id) REFERENCES prospect_integrations.jobs(id);


--
-- Name: campaign_requests campaign_requests_client_id_fkey; Type: FK CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.campaign_requests
    ADD CONSTRAINT campaign_requests_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id);


--
-- Name: client_campaigns client_campaigns_client_id_fkey; Type: FK CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.client_campaigns
    ADD CONSTRAINT client_campaigns_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id);


--
-- Name: jobs jobs_client_id_fkey; Type: FK CONSTRAINT; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE ONLY prospect_integrations.jobs
    ADD CONSTRAINT jobs_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id);


--
-- Name: operation_job_items operation_job_items_job_id_fkey; Type: FK CONSTRAINT; Schema: prospect_operations; Owner: postgres
--

ALTER TABLE ONLY prospect_operations.operation_job_items
    ADD CONSTRAINT operation_job_items_job_id_fkey FOREIGN KEY (job_id) REFERENCES prospect_operations.operation_jobs(id) ON DELETE CASCADE;


--
-- Name: result_set_items result_set_items_result_set_id_fkey; Type: FK CONSTRAINT; Schema: prospect_results; Owner: postgres
--

ALTER TABLE ONLY prospect_results.result_set_items
    ADD CONSTRAINT result_set_items_result_set_id_fkey FOREIGN KEY (result_set_id) REFERENCES prospect_results.result_sets(id) ON DELETE CASCADE;


--
-- Name: client_addition_batch_items client_addition_batch_items_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_addition_batch_items
    ADD CONSTRAINT client_addition_batch_items_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.client_addition_batches(id) ON DELETE CASCADE;


--
-- Name: client_addition_batches client_addition_batches_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_addition_batches
    ADD CONSTRAINT client_addition_batches_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_addition_batches client_addition_batches_source_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_addition_batches
    ADD CONSTRAINT client_addition_batches_source_client_id_fkey FOREIGN KEY (source_client_id) REFERENCES public.clients(id) ON DELETE SET NULL;


--
-- Name: client_blocklist_batch_results client_blocklist_batch_results_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_batch_results
    ADD CONSTRAINT client_blocklist_batch_results_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_blocklist client_blocklist_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist
    ADD CONSTRAINT client_blocklist_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_blocklist_share_limits client_blocklist_share_limits_share_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_share_limits
    ADD CONSTRAINT client_blocklist_share_limits_share_id_fkey FOREIGN KEY (share_id) REFERENCES public.client_blocklist_shares(id) ON DELETE CASCADE;


--
-- Name: client_blocklist_share_submissions client_blocklist_share_submissions_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_share_submissions
    ADD CONSTRAINT client_blocklist_share_submissions_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_blocklist_share_submissions client_blocklist_share_submissions_share_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_share_submissions
    ADD CONSTRAINT client_blocklist_share_submissions_share_id_fkey FOREIGN KEY (share_id) REFERENCES public.client_blocklist_shares(id) ON DELETE CASCADE;


--
-- Name: client_blocklist_shares client_blocklist_shares_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_blocklist_shares
    ADD CONSTRAINT client_blocklist_shares_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_companies_blocked client_companies_blocked_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_companies_blocked
    ADD CONSTRAINT client_companies_blocked_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_companies_blocked client_companies_blocked_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_companies_blocked
    ADD CONSTRAINT client_companies_blocked_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: client_companies client_companies_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_companies
    ADD CONSTRAINT client_companies_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_companies client_companies_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_companies
    ADD CONSTRAINT client_companies_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: client_company_icp_validations client_company_icp_validations_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_company_icp_validations
    ADD CONSTRAINT client_company_icp_validations_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_company_icp_validations client_company_icp_validations_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_company_icp_validations
    ADD CONSTRAINT client_company_icp_validations_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: client_icp_profiles client_icp_profiles_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_icp_profiles
    ADD CONSTRAINT client_icp_profiles_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_icp_profiles client_icp_profiles_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_icp_profiles
    ADD CONSTRAINT client_icp_profiles_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.prospect_tags(id) ON DELETE SET NULL;


--
-- Name: client_prospects client_prospects_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_prospects
    ADD CONSTRAINT client_prospects_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: client_prospects client_prospects_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_prospects
    ADD CONSTRAINT client_prospects_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.prospects(id) ON DELETE CASCADE;


--
-- Name: client_prospects client_prospects_source_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_prospects
    ADD CONSTRAINT client_prospects_source_import_id_fkey FOREIGN KEY (source_import_id) REFERENCES public.imports(id) ON DELETE SET NULL;


--
-- Name: client_prospects client_prospects_source_push_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_prospects
    ADD CONSTRAINT client_prospects_source_push_client_id_fkey FOREIGN KEY (source_push_client_id) REFERENCES public.clients(id) ON DELETE SET NULL;


--
-- Name: client_settings client_settings_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.client_settings
    ADD CONSTRAINT client_settings_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: clients clients_folder_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_folder_id_fkey FOREIGN KEY (folder_id) REFERENCES public.client_folders(id) ON DELETE SET NULL;


--
-- Name: company_import_memberships company_import_memberships_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_import_memberships
    ADD CONSTRAINT company_import_memberships_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_import_memberships company_import_memberships_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_import_memberships
    ADD CONSTRAINT company_import_memberships_import_id_fkey FOREIGN KEY (import_id) REFERENCES public.company_imports(id) ON DELETE CASCADE;


--
-- Name: company_import_rows company_import_rows_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_import_rows
    ADD CONSTRAINT company_import_rows_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: company_import_rows company_import_rows_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_import_rows
    ADD CONSTRAINT company_import_rows_import_id_fkey FOREIGN KEY (import_id) REFERENCES public.company_imports(id) ON DELETE CASCADE;


--
-- Name: company_sources company_sources_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_sources
    ADD CONSTRAINT company_sources_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_sources company_sources_last_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_sources
    ADD CONSTRAINT company_sources_last_import_id_fkey FOREIGN KEY (last_import_id) REFERENCES public.company_imports(id) ON DELETE SET NULL;


--
-- Name: company_tag_links company_tag_links_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_tag_links
    ADD CONSTRAINT company_tag_links_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: company_tag_links company_tag_links_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.company_tag_links
    ADD CONSTRAINT company_tag_links_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.prospect_tags(id) ON DELETE CASCADE;


--
-- Name: contact_events contact_events_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_events
    ADD CONSTRAINT contact_events_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: contact_events contact_events_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.contact_events
    ADD CONSTRAINT contact_events_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.prospects(id) ON DELETE CASCADE;


--
-- Name: imports imports_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.imports
    ADD CONSTRAINT imports_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: imports imports_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.imports
    ADD CONSTRAINT imports_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;


--
-- Name: list_memberships list_memberships_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_memberships
    ADD CONSTRAINT list_memberships_import_id_fkey FOREIGN KEY (import_id) REFERENCES public.imports(id) ON DELETE CASCADE;


--
-- Name: list_memberships list_memberships_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_memberships
    ADD CONSTRAINT list_memberships_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;


--
-- Name: list_memberships list_memberships_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_memberships
    ADD CONSTRAINT list_memberships_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.prospects(id) ON DELETE CASCADE;


--
-- Name: list_rows list_rows_import_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_rows
    ADD CONSTRAINT list_rows_import_id_fkey FOREIGN KEY (import_id) REFERENCES public.imports(id) ON DELETE CASCADE;


--
-- Name: list_rows list_rows_list_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_rows
    ADD CONSTRAINT list_rows_list_id_fkey FOREIGN KEY (list_id) REFERENCES public.lists(id) ON DELETE CASCADE;


--
-- Name: list_rows list_rows_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.list_rows
    ADD CONSTRAINT list_rows_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.prospects(id) ON DELETE SET NULL;


--
-- Name: lists lists_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: operation_log operation_log_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.operation_log
    ADD CONSTRAINT operation_log_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE SET NULL;


--
-- Name: prospect_identifiers prospect_identifiers_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_identifiers
    ADD CONSTRAINT prospect_identifiers_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.prospects(id) ON DELETE CASCADE;


--
-- Name: prospect_index prospect_index_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_index
    ADD CONSTRAINT prospect_index_id_fkey FOREIGN KEY (id) REFERENCES public.prospects(id) ON DELETE CASCADE;


--
-- Name: prospect_tag_links prospect_tag_links_prospect_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_tag_links
    ADD CONSTRAINT prospect_tag_links_prospect_id_fkey FOREIGN KEY (prospect_id) REFERENCES public.prospects(id) ON DELETE CASCADE;


--
-- Name: prospect_tag_links prospect_tag_links_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_tag_links
    ADD CONSTRAINT prospect_tag_links_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.prospect_tags(id) ON DELETE CASCADE;


--
-- Name: prospect_tags prospect_tags_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospect_tags
    ADD CONSTRAINT prospect_tags_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: prospects prospects_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.prospects
    ADD CONSTRAINT prospects_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL;


--
-- Name: batches; Type: ROW SECURITY; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE prospect_integrations.batches ENABLE ROW LEVEL SECURITY;

--
-- Name: campaign_requests; Type: ROW SECURITY; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE prospect_integrations.campaign_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: client_campaigns; Type: ROW SECURITY; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE prospect_integrations.client_campaigns ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs; Type: ROW SECURITY; Schema: prospect_integrations; Owner: postgres
--

ALTER TABLE prospect_integrations.jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: job_metrics; Type: ROW SECURITY; Schema: prospect_operations; Owner: postgres
--

ALTER TABLE prospect_operations.job_metrics ENABLE ROW LEVEL SECURITY;

--
-- Name: client_addition_batch_items; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_addition_batch_items ENABLE ROW LEVEL SECURITY;

--
-- Name: client_addition_batches; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_addition_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: client_blocklist; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_blocklist ENABLE ROW LEVEL SECURITY;

--
-- Name: client_blocklist_batch_results; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_blocklist_batch_results ENABLE ROW LEVEL SECURITY;

--
-- Name: client_blocklist_share_limits; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_blocklist_share_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: client_blocklist_share_submissions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_blocklist_share_submissions ENABLE ROW LEVEL SECURITY;

--
-- Name: client_blocklist_shares; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_blocklist_shares ENABLE ROW LEVEL SECURITY;

--
-- Name: client_companies; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_companies ENABLE ROW LEVEL SECURITY;

--
-- Name: client_companies_blocked; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_companies_blocked ENABLE ROW LEVEL SECURITY;

--
-- Name: client_company_icp_validations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_company_icp_validations ENABLE ROW LEVEL SECURITY;

--
-- Name: client_folders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_folders ENABLE ROW LEVEL SECURITY;

--
-- Name: client_icp_profiles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_icp_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: client_prospects; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_prospects ENABLE ROW LEVEL SECURITY;

--
-- Name: client_settings; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.client_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: clients; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;

--
-- Name: companies; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

--
-- Name: company_import_memberships; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.company_import_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: company_import_rows; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.company_import_rows ENABLE ROW LEVEL SECURITY;

--
-- Name: company_imports; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.company_imports ENABLE ROW LEVEL SECURITY;

--
-- Name: company_sources; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.company_sources ENABLE ROW LEVEL SECURITY;

--
-- Name: company_tag_links; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.company_tag_links ENABLE ROW LEVEL SECURITY;

--
-- Name: company_value_suggestions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.company_value_suggestions ENABLE ROW LEVEL SECURITY;

--
-- Name: contact_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.contact_events ENABLE ROW LEVEL SECURITY;

--
-- Name: dashboard_snapshot; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.dashboard_snapshot ENABLE ROW LEVEL SECURITY;

--
-- Name: imports; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.imports ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_connections; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.integration_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: list_memberships; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.list_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: list_rows; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.list_rows ENABLE ROW LEVEL SECURITY;

--
-- Name: lists; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.lists ENABLE ROW LEVEL SECURITY;

--
-- Name: operation_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.operation_log ENABLE ROW LEVEL SECURITY;

--
-- Name: prospect_fields; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospect_fields ENABLE ROW LEVEL SECURITY;

--
-- Name: prospect_filter_value_cache; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospect_filter_value_cache ENABLE ROW LEVEL SECURITY;

--
-- Name: prospect_identifiers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospect_identifiers ENABLE ROW LEVEL SECURITY;

--
-- Name: prospect_index; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospect_index ENABLE ROW LEVEL SECURITY;

--
-- Name: prospect_tag_links; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospect_tag_links ENABLE ROW LEVEL SECURITY;

--
-- Name: prospect_tags; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospect_tags ENABLE ROW LEVEL SECURITY;

--
-- Name: prospects; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.prospects ENABLE ROW LEVEL SECURITY;

--
-- Name: reindex_backlog; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.reindex_backlog ENABLE ROW LEVEL SECURITY;

--
-- Name: saved_views; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.saved_views ENABLE ROW LEVEL SECURITY;

--
-- Name: system_event_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.system_event_log ENABLE ROW LEVEL SECURITY;

--
-- Name: title_classifier_state; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.title_classifier_state ENABLE ROW LEVEL SECURITY;

--
-- Name: title_department_keywords; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.title_department_keywords ENABLE ROW LEVEL SECURITY;

--
-- Name: title_seniority_keywords; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.title_seniority_keywords ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA prospect_exports; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA prospect_exports TO prospect_operator;


--
-- Name: SCHEMA prospect_filters; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA prospect_filters TO service_role;
GRANT USAGE ON SCHEMA prospect_filters TO prospect_operator;


--
-- Name: SCHEMA prospect_import; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA prospect_import TO prospect_importer;


--
-- Name: SCHEMA prospect_integrations; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA prospect_integrations TO prospect_integrator;


--
-- Name: SCHEMA prospect_operations; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA prospect_operations TO service_role;
GRANT USAGE ON SCHEMA prospect_operations TO prospect_operator;


--
-- Name: SCHEMA prospect_results; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA prospect_results TO service_role;
GRANT USAGE ON SCHEMA prospect_results TO prospect_operator;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION build_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.build_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_exports.build_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) TO prospect_operator;


--
-- Name: FUNCTION claim_next_v1(p_worker_id text, p_lease_seconds integer); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.claim_next_v1(p_worker_id text, p_lease_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_exports.claim_next_v1(p_worker_id text, p_lease_seconds integer) TO prospect_operator;


--
-- Name: FUNCTION expire_jobs_v1(); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.expire_jobs_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_exports.expire_jobs_v1() TO prospect_operator;


--
-- Name: FUNCTION fail_v1(p_job_id uuid, p_error text); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.fail_v1(p_job_id uuid, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_exports.fail_v1(p_job_id uuid, p_error text) TO prospect_operator;


--
-- Name: FUNCTION part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) FROM PUBLIC;


--
-- Name: FUNCTION parts_present_v1(p_job_id uuid); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.parts_present_v1(p_job_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION request_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text, p_ttl interval); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.request_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text, p_ttl interval) FROM PUBLIC;


--
-- Name: FUNCTION status_v1(p_job_id uuid, p_owner_id text); Type: ACL; Schema: prospect_exports; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_exports.status_v1(p_job_id uuid, p_owner_id text) FROM PUBLIC;


--
-- Name: FUNCTION create_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[], p_ttl interval); Type: ACL; Schema: prospect_filters; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_filters.create_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[], p_ttl interval) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_filters.create_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[], p_ttl interval) TO service_role;


--
-- Name: FUNCTION expire_sets_v1(); Type: ACL; Schema: prospect_filters; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_filters.expire_sets_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_filters.expire_sets_v1() TO service_role;
GRANT ALL ON FUNCTION prospect_filters.expire_sets_v1() TO prospect_operator;


--
-- Name: FUNCTION resolve_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text); Type: ACL; Schema: prospect_filters; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_filters.resolve_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_filters.resolve_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text) TO service_role;


--
-- Name: FUNCTION usage_v1(); Type: ACL; Schema: prospect_filters; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_filters.usage_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_filters.usage_v1() TO service_role;
GRANT ALL ON FUNCTION prospect_filters.usage_v1() TO prospect_operator;


--
-- Name: FUNCTION process_staged_batch_v1(p_import_id text, p_list_id text, p_row_offset integer, p_batch_size integer); Type: ACL; Schema: prospect_import; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_import.process_staged_batch_v1(p_import_id text, p_list_id text, p_row_offset integer, p_batch_size integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_import.process_staged_batch_v1(p_import_id text, p_list_id text, p_row_offset integer, p_batch_size integer) TO prospect_importer;


--
-- Name: FUNCTION claim_v1(p_kind text); Type: ACL; Schema: prospect_integrations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_integrations.claim_v1(p_kind text) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_integrations.claim_v1(p_kind text) TO prospect_integrator;


--
-- Name: FUNCTION cleanup_v1(); Type: ACL; Schema: prospect_integrations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_integrations.cleanup_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_integrations.cleanup_v1() TO prospect_integrator;


--
-- Name: FUNCTION finish_v1(p_kind text, p_id uuid, p_token uuid, p_state text, p_result jsonb, p_delay integer); Type: ACL; Schema: prospect_integrations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_integrations.finish_v1(p_kind text, p_id uuid, p_token uuid, p_state text, p_result jsonb, p_delay integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_integrations.finish_v1(p_kind text, p_id uuid, p_token uuid, p_state text, p_result jsonb, p_delay integer) TO prospect_integrator;


--
-- Name: FUNCTION prepare_upload_v1(p_batch uuid, p_token uuid); Type: ACL; Schema: prospect_integrations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_integrations.prepare_upload_v1(p_batch uuid, p_token uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_integrations.prepare_upload_v1(p_batch uuid, p_token uuid) TO prospect_integrator;


--
-- Name: FUNCTION apply_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.apply_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.apply_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) TO service_role;
GRANT ALL ON FUNCTION prospect_operations.apply_batch_v1(p_job_id uuid, p_batch_size integer, p_lease_seconds integer) TO prospect_operator;


--
-- Name: FUNCTION claim_next_v1(p_worker_id text, p_lease_seconds integer); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.claim_next_v1(p_worker_id text, p_lease_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.claim_next_v1(p_worker_id text, p_lease_seconds integer) TO prospect_operator;


--
-- Name: FUNCTION enqueue_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[], p_ttl interval); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.enqueue_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[], p_ttl interval) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.enqueue_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[], p_ttl interval) TO service_role;


--
-- Name: FUNCTION expire_jobs_v1(); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.expire_jobs_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.expire_jobs_v1() TO prospect_operator;


--
-- Name: FUNCTION fail_v1(p_job_id uuid, p_error text); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.fail_v1(p_job_id uuid, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.fail_v1(p_job_id uuid, p_error text) TO prospect_operator;


--
-- Name: FUNCTION freeze_from_ids_v1(p_job_id uuid, p_actor text, p_ids text[]); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.freeze_from_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.freeze_from_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) TO service_role;


--
-- Name: FUNCTION freeze_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.freeze_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.freeze_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) TO service_role;


--
-- Name: FUNCTION mark_applied_v1(p_job_id uuid, p_ids text[]); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.mark_applied_v1(p_job_id uuid, p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.mark_applied_v1(p_job_id uuid, p_ids text[]) TO service_role;


--
-- Name: FUNCTION merge_result_v1(p_current jsonb, p_batch jsonb); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.merge_result_v1(p_current jsonb, p_batch jsonb) FROM PUBLIC;


--
-- Name: FUNCTION next_batch_v1(p_job_id uuid, p_batch_size integer); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.next_batch_v1(p_job_id uuid, p_batch_size integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.next_batch_v1(p_job_id uuid, p_batch_size integer) TO service_role;


--
-- Name: FUNCTION prune_metrics_v1(); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.prune_metrics_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.prune_metrics_v1() TO prospect_operator;


--
-- Name: FUNCTION reclaim_unit_v1(p_kind text, p_limit integer); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.reclaim_unit_v1(p_kind text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.reclaim_unit_v1(p_kind text, p_limit integer) TO prospect_operator;


--
-- Name: FUNCTION record_job_metric_v1(); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.record_job_metric_v1() FROM PUBLIC;


--
-- Name: FUNCTION record_result_v1(p_job_id uuid, p_actor text, p_result jsonb); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.record_result_v1(p_job_id uuid, p_actor text, p_result jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.record_result_v1(p_job_id uuid, p_actor text, p_result jsonb) TO service_role;


--
-- Name: FUNCTION refresh_dashboard_snapshots_v1(); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.refresh_dashboard_snapshots_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.refresh_dashboard_snapshots_v1() TO prospect_operator;
GRANT ALL ON FUNCTION prospect_operations.refresh_dashboard_snapshots_v1() TO service_role;


--
-- Name: FUNCTION run_queue_unit_v1(p_kind text, p_worker text, p_batch integer); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.run_queue_unit_v1(p_kind text, p_worker text, p_batch integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.run_queue_unit_v1(p_kind text, p_worker text, p_batch integer) TO prospect_operator;


--
-- Name: FUNCTION status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb); Type: ACL; Schema: prospect_operations; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_operations.status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_operations.status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb) TO service_role;


--
-- Name: FUNCTION build_batch_v1(p_set_id uuid, p_batch_size integer); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.build_batch_v1(p_set_id uuid, p_batch_size integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.build_batch_v1(p_set_id uuid, p_batch_size integer) TO service_role;
GRANT ALL ON FUNCTION prospect_results.build_batch_v1(p_set_id uuid, p_batch_size integer) TO prospect_operator;


--
-- Name: FUNCTION build_regular_batch_v1(p_set_id uuid, p_batch_size integer); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.build_regular_batch_v1(p_set_id uuid, p_batch_size integer) FROM PUBLIC;


--
-- Name: FUNCTION build_regular_batch_v2(p_set_id uuid, p_batch_size integer); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.build_regular_batch_v2(p_set_id uuid, p_batch_size integer) FROM PUBLIC;


--
-- Name: FUNCTION claim_next_v1(p_worker_id text, p_lease_seconds integer); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.claim_next_v1(p_worker_id text, p_lease_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.claim_next_v1(p_worker_id text, p_lease_seconds integer) TO service_role;
GRANT ALL ON FUNCTION prospect_results.claim_next_v1(p_worker_id text, p_lease_seconds integer) TO prospect_operator;


--
-- Name: FUNCTION expire_sets_v1(); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.expire_sets_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.expire_sets_v1() TO service_role;
GRANT ALL ON FUNCTION prospect_results.expire_sets_v1() TO prospect_operator;


--
-- Name: FUNCTION fail_set_v1(p_set_id uuid, p_error text); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.fail_set_v1(p_set_id uuid, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.fail_set_v1(p_set_id uuid, p_error text) TO service_role;
GRANT ALL ON FUNCTION prospect_results.fail_set_v1(p_set_id uuid, p_error text) TO prospect_operator;


--
-- Name: FUNCTION page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION request_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb, p_ttl interval); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.request_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb, p_ttl interval) FROM PUBLIC;


--
-- Name: FUNCTION status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb) TO service_role;


--
-- Name: FUNCTION uncached_company_scope_ids_v1(p_client_id text, p_company_scope jsonb); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.uncached_company_scope_ids_v1(p_client_id text, p_company_scope jsonb) FROM PUBLIC;


--
-- Name: FUNCTION usage_v1(); Type: ACL; Schema: prospect_results; Owner: postgres
--

REVOKE ALL ON FUNCTION prospect_results.usage_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION prospect_results.usage_v1() TO service_role;
GRANT ALL ON FUNCTION prospect_results.usage_v1() TO prospect_operator;


--
-- Name: FUNCTION add_client_blocklist_batch_v2(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text, p_request_id text, p_match_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.add_client_blocklist_batch_v2(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text, p_request_id text, p_match_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_client_blocklist_batch_v2(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text, p_request_id text, p_match_limit integer) TO service_role;


--
-- Name: FUNCTION add_client_blocklist_v1(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.add_client_blocklist_v1(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_client_blocklist_v1(p_client_id text, p_domains text[], p_emails text[], p_reason text, p_actor text) TO service_role;


--
-- Name: FUNCTION add_prospects_to_list_v1(p_list_id text, p_import_id text, p_prospect_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.add_prospects_to_list_v1(p_list_id text, p_import_id text, p_prospect_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_prospects_to_list_v1(p_list_id text, p_import_id text, p_prospect_ids text[]) TO service_role;


--
-- Name: FUNCTION analyze_prospect_index(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.analyze_prospect_index() FROM PUBLIC;
GRANT ALL ON FUNCTION public.analyze_prospect_index() TO service_role;


--
-- Name: FUNCTION apply_client_blocklist_v1(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.apply_client_blocklist_v1(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_client_blocklist_v1(p_client_id text) TO service_role;


--
-- Name: FUNCTION apply_email_provider_scan_v1(p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.apply_email_provider_scan_v1(p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_email_provider_scan_v1(p_rows jsonb) TO service_role;


--
-- Name: FUNCTION background_health_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.background_health_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.background_health_v1() TO service_role;


--
-- Name: FUNCTION block_company_on_domain_change_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.block_company_on_domain_change_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.block_company_on_domain_change_v1() TO service_role;


--
-- Name: FUNCTION block_prospect_on_identity_change_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.block_prospect_on_identity_change_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.block_prospect_on_identity_change_v1() TO service_role;


--
-- Name: FUNCTION bump_data_version_company(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.bump_data_version_company() FROM PUBLIC;
GRANT ALL ON FUNCTION public.bump_data_version_company() TO service_role;


--
-- Name: FUNCTION bump_data_version_prospect(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.bump_data_version_prospect() FROM PUBLIC;
GRANT ALL ON FUNCTION public.bump_data_version_prospect() TO service_role;


--
-- Name: FUNCTION cancel_integration_job_v1(p_actor text, p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.cancel_integration_job_v1(p_actor text, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_integration_job_v1(p_actor text, p_job uuid) TO service_role;


--
-- Name: FUNCTION capture_company_import_membership_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.capture_company_import_membership_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.capture_company_import_membership_v1() TO service_role;


--
-- Name: FUNCTION claim_next_prospect_import_v1(p_worker_id text, p_lease_seconds integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.claim_next_prospect_import_v1(p_worker_id text, p_lease_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_next_prospect_import_v1(p_worker_id text, p_lease_seconds integer) TO service_role;


--
-- Name: FUNCTION classify_job_title_v1(p_title text, p_company_name text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.classify_job_title_v1(p_title text, p_company_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.classify_job_title_v1(p_title text, p_company_name text) TO service_role;


--
-- Name: FUNCTION client_addition_batch_records_v1(p_client_id text, p_batch_id uuid, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_addition_batch_records_v1(p_client_id text, p_batch_id uuid, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_addition_batch_records_v1(p_client_id text, p_batch_id uuid, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION client_block_reason_v1(p_client_id text, p_prospect_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_block_reason_v1(p_client_id text, p_prospect_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_block_reason_v1(p_client_id text, p_prospect_id text) TO service_role;


--
-- Name: FUNCTION client_blocked_prospect_ids(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_blocked_prospect_ids(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_blocked_prospect_ids(p_client_id text) TO service_role;


--
-- Name: FUNCTION client_blocklist_export_page_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_blocklist_export_page_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_blocklist_export_page_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer) TO service_role;


--
-- Name: FUNCTION client_blocklist_selection_count_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_blocklist_selection_count_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_blocklist_selection_count_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone) TO service_role;


--
-- Name: FUNCTION client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_limit integer) TO service_role;


--
-- Name: FUNCTION client_company_block_reason_v1(p_client_id text, p_company_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_company_block_reason_v1(p_client_id text, p_company_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_company_block_reason_v1(p_client_id text, p_company_id text) TO service_role;


--
-- Name: FUNCTION client_company_prospects(p_client_id text, p_company_id text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_company_prospects(p_client_id text, p_company_id text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_company_prospects(p_client_id text, p_company_id text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION client_company_removal_preview_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_company_removal_preview_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_company_removal_preview_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[]) TO service_role;


--
-- Name: FUNCTION client_company_workspace(p_client_id text, p_search text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_company_workspace(p_client_id text, p_search text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_company_workspace(p_client_id text, p_search text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION client_company_workspace_v2(p_client_id text, p_search text, p_filters jsonb, p_people_scope jsonb, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text, p_filters jsonb, p_people_scope jsonb, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_company_workspace_v2(p_client_id text, p_search text, p_filters jsonb, p_people_scope jsonb, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION client_icp_tag_counts_v1(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_icp_tag_counts_v1(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_icp_tag_counts_v1(p_client_id text) TO service_role;


--
-- Name: FUNCTION client_recent_batches_v1(p_client_id text, p_search text, p_entity text, p_hours integer, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_recent_batches_v1(p_client_id text, p_search text, p_entity text, p_hours integer, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_recent_batches_v1(p_client_id text, p_search text, p_entity text, p_hours integer, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION client_recently_added_v1(p_client_id text, p_entity text, p_hours integer, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.client_recently_added_v1(p_client_id text, p_entity text, p_hours integer, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.client_recently_added_v1(p_client_id text, p_entity text, p_hours integer, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION company_effective_filter_sql_v1(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_effective_filter_sql_v1(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_effective_filter_sql_v1(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION company_export_field_names_v1(p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_export_field_names_v1(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_export_field_names_v1(p_limit integer) TO service_role;


--
-- Name: FUNCTION company_filter_is_probed_v1(p_field text, p_scopes jsonb, p_operator text, p_values text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_filter_is_probed_v1(p_field text, p_scopes jsonb, p_operator text, p_values text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_filter_is_probed_v1(p_field text, p_scopes jsonb, p_operator text, p_values text[]) TO service_role;


--
-- Name: FUNCTION company_filter_sql_v2(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_filter_sql_v2(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_filter_sql_v2(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_filter_sql_v3(p_search text, p_filters jsonb, p_probe boolean) TO service_role;


--
-- Name: FUNCTION company_filter_values_v1(p_field text, p_search text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_filter_values_v1(p_field text, p_search text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_filter_values_v1(p_field text, p_search text, p_limit integer) TO service_role;


--
-- Name: FUNCTION company_full_scan_filter_sql_v1(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_full_scan_filter_sql_v1(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_full_scan_filter_sql_v1(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text) TO anon;
GRANT ALL ON FUNCTION public.company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text) TO authenticated;
GRANT ALL ON FUNCTION public.company_keyword_expr_sql_v1(p_scopes jsonb, p_alias text) TO service_role;


--
-- Name: FUNCTION company_keyword_scopes_v1(p_scopes jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.company_keyword_scopes_v1(p_scopes jsonb) TO anon;
GRANT ALL ON FUNCTION public.company_keyword_scopes_v1(p_scopes jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.company_keyword_scopes_v1(p_scopes jsonb) TO service_role;


--
-- Name: FUNCTION company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text) TO anon;
GRANT ALL ON FUNCTION public.company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text) TO authenticated;
GRANT ALL ON FUNCTION public.company_keyword_text_expr_sql_v1(p_scopes jsonb, p_alias text) TO service_role;


--
-- Name: TABLE companies; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.companies TO service_role;


--
-- Name: FUNCTION company_matches_filters_v1(p_row public.companies, p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_matches_filters_v1(p_row public.companies, p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_matches_filters_v1(p_row public.companies, p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION company_matches_scope_v1(p_company_id text, p_client_id text, p_company_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_matches_scope_v1(p_company_id text, p_client_id text, p_company_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_matches_scope_v1(p_company_id text, p_client_id text, p_company_scope jsonb) TO service_role;


--
-- Name: FUNCTION company_prefilter_sql(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_prefilter_sql(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_prefilter_sql(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION company_probe_columns_v1(p_field text, p_scopes jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_probe_columns_v1(p_field text, p_scopes jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_probe_columns_v1(p_field text, p_scopes jsonb) TO service_role;


--
-- Name: FUNCTION company_probe_filter_sql_v1(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_probe_filter_sql_v1(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_probe_filter_sql_v1(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION company_scope_ids_v2(p_client_id text, p_company_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_scope_ids_v2(p_client_id text, p_company_scope jsonb) TO service_role;


--
-- Name: FUNCTION company_scoped_raw(p_raw jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_scoped_raw(p_raw jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_scoped_raw(p_raw jsonb) TO service_role;


--
-- Name: FUNCTION company_substring_probe_sql_v1(p_columns text[], p_values text[], p_keyword_values text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.company_substring_probe_sql_v1(p_columns text[], p_values text[], p_keyword_values text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.company_substring_probe_sql_v1(p_columns text[], p_values text[], p_keyword_values text[]) TO service_role;


--
-- Name: FUNCTION company_technologies_text_v1(p_technologies text[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.company_technologies_text_v1(p_technologies text[]) TO anon;
GRANT ALL ON FUNCTION public.company_technologies_text_v1(p_technologies text[]) TO authenticated;
GRANT ALL ON FUNCTION public.company_technologies_text_v1(p_technologies text[]) TO service_role;


--
-- Name: FUNCTION complete_company_import_v1(p_import_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.complete_company_import_v1(p_import_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_company_import_v1(p_import_id text) TO service_role;


--
-- Name: FUNCTION consume_blocklist_share_rate_v1(p_share_id uuid, p_requester_hash text, p_limit integer, p_window interval); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.consume_blocklist_share_rate_v1(p_share_id uuid, p_requester_hash text, p_limit integer, p_window interval) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consume_blocklist_share_rate_v1(p_share_id uuid, p_requester_hash text, p_limit integer, p_window interval) TO service_role;


--
-- Name: FUNCTION create_filter_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.create_filter_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_filter_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_field text, p_values text[]) TO service_role;


--
-- Name: FUNCTION dashboard_snapshot_v1(p_key text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.dashboard_snapshot_v1(p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dashboard_snapshot_v1(p_key text) TO service_role;


--
-- Name: FUNCTION dashboard_workspace(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.dashboard_workspace() FROM PUBLIC;
GRANT ALL ON FUNCTION public.dashboard_workspace() TO service_role;


--
-- Name: FUNCTION data_quality_overview(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.data_quality_overview() FROM PUBLIC;
GRANT ALL ON FUNCTION public.data_quality_overview() TO service_role;


--
-- Name: FUNCTION data_versions_v1(p_entities text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.data_versions_v1(p_entities text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.data_versions_v1(p_entities text[]) TO service_role;


--
-- Name: FUNCTION delete_client_and_reindex_v1(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_client_and_reindex_v1(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_client_and_reindex_v1(p_client_id text) TO service_role;


--
-- Name: FUNCTION delete_client_with_cleanup(p_client_id text, p_delete_orphans boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_client_with_cleanup(p_client_id text, p_delete_orphans boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_client_with_cleanup(p_client_id text, p_delete_orphans boolean) TO service_role;


--
-- Name: FUNCTION delete_companies_by_ids_v1(p_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_companies_by_ids_v1(p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_companies_by_ids_v1(p_ids text[]) TO service_role;


--
-- Name: FUNCTION delete_companies_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_companies_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_companies_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]) TO service_role;


--
-- Name: FUNCTION delete_import_and_reindex_v1(p_import_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_import_and_reindex_v1(p_import_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_import_and_reindex_v1(p_import_id text) TO service_role;


--
-- Name: FUNCTION delete_import_with_cleanup(p_import_id text, p_delete_orphans boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_import_with_cleanup(p_import_id text, p_delete_orphans boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_import_with_cleanup(p_import_id text, p_delete_orphans boolean) TO service_role;


--
-- Name: FUNCTION delete_list_and_reindex_v1(p_list_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_list_and_reindex_v1(p_list_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_list_and_reindex_v1(p_list_id text) TO service_role;


--
-- Name: FUNCTION delete_list_with_cleanup(p_list_id text, p_delete_orphans boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_list_with_cleanup(p_list_id text, p_delete_orphans boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_list_with_cleanup(p_list_id text, p_delete_orphans boolean) TO service_role;


--
-- Name: FUNCTION delete_prospects_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_prospects_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_prospects_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[]) TO service_role;


--
-- Name: FUNCTION delete_prospects_matching_v2(p_search text, p_filters jsonb, p_excluded_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.delete_prospects_matching_v2(p_search text, p_filters jsonb, p_excluded_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_prospects_matching_v2(p_search text, p_filters jsonb, p_excluded_ids text[]) TO service_role;


--
-- Name: FUNCTION divert_blocked_client_company_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.divert_blocked_client_company_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.divert_blocked_client_company_v1() TO service_role;


--
-- Name: FUNCTION drain_reindex_backlog(p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.drain_reindex_backlog(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.drain_reindex_backlog(p_limit integer) TO service_role;
GRANT ALL ON FUNCTION public.drain_reindex_backlog(p_limit integer) TO prospect_operator;


--
-- Name: FUNCTION enforce_client_blocklist_reason_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enforce_client_blocklist_reason_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_client_blocklist_reason_v1() TO service_role;


--
-- Name: FUNCTION enqueue_blocklist_share_submission_v1(p_token_hash text, p_requester_hash text, p_request_key uuid, p_domains text[], p_emails text[], p_reason text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enqueue_blocklist_share_submission_v1(p_token_hash text, p_requester_hash text, p_request_key uuid, p_domains text[], p_emails text[], p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enqueue_blocklist_share_submission_v1(p_token_hash text, p_requester_hash text, p_request_key uuid, p_domains text[], p_emails text[], p_reason text) TO service_role;


--
-- Name: FUNCTION enqueue_integration_job_v1(p_actor text, p_job uuid, p_allow_active boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enqueue_integration_job_v1(p_actor text, p_job uuid, p_allow_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enqueue_integration_job_v1(p_actor text, p_job uuid, p_allow_active boolean) TO service_role;


--
-- Name: FUNCTION enqueue_operation_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enqueue_operation_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enqueue_operation_v1(p_actor text, p_request_id uuid, p_action text, p_entity_type text, p_client_scope text, p_content_hash text, p_version_vector jsonb, p_payload jsonb, p_excluded_ids text[]) TO service_role;


--
-- Name: FUNCTION enqueue_reindex(p_ids text[], p_error text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enqueue_reindex(p_ids text[], p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enqueue_reindex(p_ids text[], p_error text) TO service_role;


--
-- Name: FUNCTION enrich_from_company_v1(p_company_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enrich_from_company_v1(p_company_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enrich_from_company_v1(p_company_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION enrichment_preview_v1(p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.enrichment_preview_v1(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enrichment_preview_v1(p_limit integer) TO service_role;


--
-- Name: FUNCTION expire_abandoned_company_imports_v1(p_stale_hours integer, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.expire_abandoned_company_imports_v1(p_stale_hours integer, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.expire_abandoned_company_imports_v1(p_stale_hours integer, p_limit integer) TO service_role;
GRANT ALL ON FUNCTION public.expire_abandoned_company_imports_v1(p_stale_hours integer, p_limit integer) TO prospect_operator;


--
-- Name: FUNCTION export_part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.export_part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.export_part_v1(p_job_id uuid, p_owner_id text, p_token text, p_part_index integer) TO service_role;


--
-- Name: FUNCTION export_parts_present_v1(p_job_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.export_parts_present_v1(p_job_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.export_parts_present_v1(p_job_id uuid) TO service_role;


--
-- Name: FUNCTION export_status_v1(p_job_id uuid, p_owner_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.export_status_v1(p_job_id uuid, p_owner_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.export_status_v1(p_job_id uuid, p_owner_id text) TO service_role;


--
-- Name: FUNCTION filter_companies_v3(p_search text, p_names text[], p_domains text[], p_seniority text[], p_locations text[], p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.filter_companies_v3(p_search text, p_names text[], p_domains text[], p_seniority text[], p_locations text[], p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.filter_companies_v3(p_search text, p_names text[], p_domains text[], p_seniority text[], p_locations text[], p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION filter_companies_v4(p_search text, p_filters jsonb, p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer, p_known_versions jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.filter_companies_v4(p_search text, p_filters jsonb, p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer, p_known_versions jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.filter_companies_v4(p_search text, p_filters jsonb, p_client_id text, p_people_scope jsonb, p_limit integer, p_offset integer, p_known_versions jsonb) TO service_role;


--
-- Name: FUNCTION find_duplicate_candidates(p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.find_duplicate_candidates(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.find_duplicate_candidates(p_limit integer) TO service_role;


--
-- Name: FUNCTION finish_list_push_v1(p_import_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.finish_list_push_v1(p_import_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_list_push_v1(p_import_id text) TO service_role;


--
-- Name: FUNCTION fixed_import_json_v1(p_entity text, p_value jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fixed_import_json_v1(p_entity text, p_value jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fixed_import_json_v1(p_entity text, p_value jsonb) TO service_role;


--
-- Name: FUNCTION fixed_import_key_v1(p_entity text, p_key text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fixed_import_key_v1(p_entity text, p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fixed_import_key_v1(p_entity text, p_key text) TO service_role;


--
-- Name: FUNCTION freeze_operation_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.freeze_operation_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.freeze_operation_from_result_set_v1(p_job_id uuid, p_actor text, p_result_set_id uuid) TO service_role;


--
-- Name: FUNCTION freeze_operation_ids_v1(p_job_id uuid, p_actor text, p_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.freeze_operation_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.freeze_operation_ids_v1(p_job_id uuid, p_actor text, p_ids text[]) TO service_role;


--
-- Name: FUNCTION heartbeat_prospect_import_v1(p_import_id text, p_worker_id text, p_lease_seconds integer, p_total_rows integer, p_processed_bytes bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.heartbeat_prospect_import_v1(p_import_id text, p_worker_id text, p_lease_seconds integer, p_total_rows integer, p_processed_bytes bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.heartbeat_prospect_import_v1(p_import_id text, p_worker_id text, p_lease_seconds integer, p_total_rows integer, p_processed_bytes bigint) TO service_role;


--
-- Name: FUNCTION import_company_batch_v1(p_import_id text, p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_company_batch_v1(p_import_id text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_company_batch_v1(p_import_id text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION import_company_batch_v2(p_import_id text, p_rows jsonb, p_row_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_company_batch_v2(p_import_id text, p_rows jsonb, p_row_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_company_batch_v2(p_import_id text, p_rows jsonb, p_row_offset integer) TO service_role;


--
-- Name: FUNCTION import_company_batch_v3(p_import_id text, p_rows jsonb, p_row_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_company_batch_v3(p_import_id text, p_rows jsonb, p_row_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_company_batch_v3(p_import_id text, p_rows jsonb, p_row_offset integer) TO service_role;


--
-- Name: FUNCTION import_prospect_batch(p_import_id text, p_list_id text, p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_prospect_batch(p_import_id text, p_list_id text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_prospect_batch(p_import_id text, p_list_id text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION import_prospect_batch_v2(p_import_id text, p_list_id text, p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_prospect_batch_v2(p_import_id text, p_list_id text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_prospect_batch_v2(p_import_id text, p_list_id text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION import_prospect_batch_v3(p_import_id text, p_list_id text, p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_prospect_batch_v3(p_import_id text, p_list_id text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_prospect_batch_v3(p_import_id text, p_list_id text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION import_prospect_batch_v4(p_import_id text, p_list_id text, p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_prospect_batch_v4(p_import_id text, p_list_id text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_prospect_batch_v4(p_import_id text, p_list_id text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb, p_row_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb, p_row_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_prospect_batch_v5(p_import_id text, p_list_id text, p_rows jsonb, p_row_offset integer) TO service_role;


--
-- Name: FUNCTION inherit_company_icp_validation_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.inherit_company_icp_validation_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.inherit_company_icp_validation_v1() TO service_role;


--
-- Name: FUNCTION integration_destinations_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.integration_destinations_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.integration_destinations_v1() TO service_role;


--
-- Name: FUNCTION integration_job_status_v1(p_actor text, p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.integration_job_status_v1(p_actor text, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.integration_job_status_v1(p_actor text, p_job uuid) TO service_role;


--
-- Name: FUNCTION integration_selection_v1(p_client text, p_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.integration_selection_v1(p_client text, p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.integration_selection_v1(p_client text, p_ids text[]) TO service_role;


--
-- Name: FUNCTION jsonb_project_v1(p_row jsonb, p_keys text[]); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.jsonb_project_v1(p_row jsonb, p_keys text[]) TO anon;
GRANT ALL ON FUNCTION public.jsonb_project_v1(p_row jsonb, p_keys text[]) TO authenticated;
GRANT ALL ON FUNCTION public.jsonb_project_v1(p_row jsonb, p_keys text[]) TO service_role;


--
-- Name: FUNCTION keyword_tag_variants_v1(p_values text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.keyword_tag_variants_v1(p_values text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.keyword_tag_variants_v1(p_values text[]) TO service_role;


--
-- Name: FUNCTION linked_prospect_total_v1(p_search text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.linked_prospect_total_v1(p_search text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.linked_prospect_total_v1(p_search text) TO service_role;


--
-- Name: FUNCTION list_workspace(p_list_id text, p_search text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.list_workspace(p_list_id text, p_search text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_workspace(p_list_id text, p_search text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION merge_prospects(p_keep_id text, p_merge_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.merge_prospects(p_keep_id text, p_merge_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.merge_prospects(p_keep_id text, p_merge_id text) TO service_role;


--
-- Name: FUNCTION normalize_job_title_v1(p_title text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.normalize_job_title_v1(p_title text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.normalize_job_title_v1(p_title text) TO service_role;


--
-- Name: FUNCTION operation_status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.operation_status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.operation_status_v1(p_job_id uuid, p_actor text, p_version_vector jsonb) TO service_role;


--
-- Name: FUNCTION parse_employee_count_v1(p_value text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.parse_employee_count_v1(p_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.parse_employee_count_v1(p_value text) TO service_role;


--
-- Name: FUNCTION people_scope_company_ids_v1(p_client_id text, p_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.people_scope_company_ids_v1(p_client_id text, p_scope jsonb) TO service_role;


--
-- Name: FUNCTION prepare_company_scope_v1(p_owner_id text, p_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prepare_company_scope_v1(p_owner_id text, p_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prepare_company_scope_v1(p_owner_id text, p_scope jsonb) TO service_role;


--
-- Name: FUNCTION prepare_company_scope_v2(p_owner_id text, p_scope jsonb, p_allow_enqueue boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prepare_company_scope_v2(p_owner_id text, p_scope jsonb, p_allow_enqueue boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prepare_company_scope_v2(p_owner_id text, p_scope jsonb, p_allow_enqueue boolean) TO service_role;


--
-- Name: FUNCTION prepared_company_listing_v1(p_owner_id text, p_set_id uuid, p_search text, p_filters jsonb, p_limit integer, p_offset integer, p_known_versions jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prepared_company_listing_v1(p_owner_id text, p_set_id uuid, p_search text, p_filters jsonb, p_limit integer, p_offset integer, p_known_versions jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prepared_company_listing_v1(p_owner_id text, p_set_id uuid, p_search text, p_filters jsonb, p_limit integer, p_offset integer, p_known_versions jsonb) TO service_role;


--
-- Name: FUNCTION prospect_capped_candidate_ids_v1(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_capped_candidate_ids_v1(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_capped_candidate_ids_v1(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb) TO service_role;


--
-- Name: FUNCTION prospect_effective_filter_sql_v1(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.prospect_effective_filter_sql_v1(p_search text, p_filters jsonb) TO anon;
GRANT ALL ON FUNCTION public.prospect_effective_filter_sql_v1(p_search text, p_filters jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.prospect_effective_filter_sql_v1(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION prospect_filter_sql_v1(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_filter_sql_v1(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_filter_sql_v1(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION prospect_filter_values_cached_v1(p_field text, p_client_id text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_filter_values_cached_v1(p_field text, p_client_id text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_filter_values_cached_v1(p_field text, p_client_id text, p_limit integer) TO service_role;


--
-- Name: FUNCTION prospect_filter_values_v3(p_field text, p_search text, p_client_id text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_filter_values_v3(p_field text, p_search text, p_client_id text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_filter_values_v3(p_field text, p_search text, p_client_id text, p_limit integer) TO service_role;


--
-- Name: FUNCTION prospect_filters_need_company_lookup_v1(p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.prospect_filters_need_company_lookup_v1(p_filters jsonb) TO anon;
GRANT ALL ON FUNCTION public.prospect_filters_need_company_lookup_v1(p_filters jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.prospect_filters_need_company_lookup_v1(p_filters jsonb) TO service_role;


--
-- Name: FUNCTION prospect_ids_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[], p_limit integer, p_after_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_ids_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[], p_limit integer, p_after_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_ids_matching_v1(p_search text, p_filters jsonb, p_excluded_ids text[], p_limit integer, p_after_id text) TO service_role;


--
-- Name: FUNCTION prospect_ids_matching_v1(p_search text, p_filters jsonb, p_client_id text, p_excluded_ids text[], p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_ids_matching_v1(p_search text, p_filters jsonb, p_client_id text, p_excluded_ids text[], p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_ids_matching_v1(p_search text, p_filters jsonb, p_client_id text, p_excluded_ids text[], p_limit integer) TO service_role;


--
-- Name: FUNCTION prospect_index_drift(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_index_drift() FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_index_drift() TO service_role;


--
-- Name: FUNCTION prospect_index_fill_title_class(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_index_fill_title_class() FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_index_fill_title_class() TO service_role;


--
-- Name: TABLE prospect_index; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_index TO service_role;


--
-- Name: FUNCTION prospect_index_matches_v1(p_row public.prospect_index, p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_index_matches_v1(p_row public.prospect_index, p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_index_matches_v1(p_row public.prospect_index, p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION prospect_prefilter_sql(p_search text, p_filters jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_prefilter_sql(p_search text, p_filters jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_prefilter_sql(p_search text, p_filters jsonb) TO service_role;


--
-- Name: FUNCTION prospect_search_text(p_row public.prospect_index); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_search_text(p_row public.prospect_index) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_search_text(p_row public.prospect_index) TO service_role;


--
-- Name: FUNCTION prospect_title_taxonomy_v1(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospect_title_taxonomy_v1(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospect_title_taxonomy_v1(p_client_id text) TO service_role;


--
-- Name: FUNCTION prospects_classify_title(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.prospects_classify_title() FROM PUBLIC;
GRANT ALL ON FUNCTION public.prospects_classify_title() TO service_role;


--
-- Name: FUNCTION purge_company_import_rows_v1(p_keep_days integer, p_batch_size integer, p_max_batches integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.purge_company_import_rows_v1(p_keep_days integer, p_batch_size integer, p_max_batches integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.purge_company_import_rows_v1(p_keep_days integer, p_batch_size integer, p_max_batches integer) TO service_role;


--
-- Name: FUNCTION purge_system_event_log_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.purge_system_event_log_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.purge_system_event_log_v1() TO service_role;


--
-- Name: FUNCTION push_companies_to_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.push_companies_to_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.push_companies_to_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION push_companies_to_client_v2(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text, p_source_client_id text, p_request_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.push_companies_to_client_v2(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text, p_source_client_id text, p_request_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.push_companies_to_client_v2(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text, p_source_client_id text, p_request_id text) TO service_role;


--
-- Name: FUNCTION push_prospects_to_client_v1(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.push_prospects_to_client_v1(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.push_prospects_to_client_v1(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION push_prospects_to_client_v2(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text, p_request_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.push_prospects_to_client_v2(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text, p_request_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.push_prospects_to_client_v2(p_client_id text, p_search text, p_filters jsonb, p_source_client_id text, p_prospect_ids text[], p_excluded_ids text[], p_actor text, p_request_id text) TO service_role;


--
-- Name: FUNCTION queue_company_import_reindex_v1(p_import_id text, p_after_prospect_id text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.queue_company_import_reindex_v1(p_import_id text, p_after_prospect_id text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_company_import_reindex_v1(p_import_id text, p_after_prospect_id text, p_limit integer) TO service_role;


--
-- Name: FUNCTION reclassify_prospect_titles_v1(p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reclassify_prospect_titles_v1(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reclassify_prospect_titles_v1(p_limit integer) TO service_role;


--
-- Name: FUNCTION recompute_client_company_counts_bulk(p_company_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.recompute_client_company_counts_bulk(p_company_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recompute_client_company_counts_bulk(p_company_ids text[]) TO service_role;


--
-- Name: FUNCTION recompute_company_counts(p_company_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.recompute_company_counts(p_company_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recompute_company_counts(p_company_id text) TO service_role;


--
-- Name: FUNCTION recompute_company_counts_bulk(p_company_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.recompute_company_counts_bulk(p_company_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recompute_company_counts_bulk(p_company_ids text[]) TO service_role;


--
-- Name: FUNCTION reconcile_client_company_counts_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reconcile_client_company_counts_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.reconcile_client_company_counts_v1() TO service_role;


--
-- Name: FUNCTION record_client_addition_batch_v1(p_client_id text, p_entity_type text, p_source_kind text, p_source_label text, p_source_client_id text, p_request_key text, p_entity_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_client_addition_batch_v1(p_client_id text, p_entity_type text, p_source_kind text, p_source_label text, p_source_client_id text, p_request_key text, p_entity_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_client_addition_batch_v1(p_client_id text, p_entity_type text, p_source_kind text, p_source_label text, p_source_client_id text, p_request_key text, p_entity_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION record_completed_import_batch_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_completed_import_batch_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_completed_import_batch_v1() TO service_role;


--
-- Name: FUNCTION record_new_import_people_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_new_import_people_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_new_import_people_v1() TO service_role;


--
-- Name: FUNCTION record_operation(p_action text, p_client_id text, p_actor text, p_summary text, p_affected integer, p_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_operation(p_action text, p_client_id text, p_actor text, p_summary text, p_affected integer, p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_operation(p_action text, p_client_id text, p_actor text, p_summary text, p_affected integer, p_ids text[]) TO service_role;


--
-- Name: FUNCTION record_operation_result_v1(p_job_id uuid, p_actor text, p_result jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.record_operation_result_v1(p_job_id uuid, p_actor text, p_result jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_operation_result_v1(p_job_id uuid, p_actor text, p_result jsonb) TO service_role;


--
-- Name: FUNCTION refresh_company_value_suggestions_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.refresh_company_value_suggestions_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.refresh_company_value_suggestions_v1() TO service_role;


--
-- Name: FUNCTION reindex_all(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reindex_all() FROM PUBLIC;
GRANT ALL ON FUNCTION public.reindex_all() TO service_role;


--
-- Name: FUNCTION reindex_prospects(p_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reindex_prospects(p_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reindex_prospects(p_ids text[]) TO service_role;


--
-- Name: FUNCTION reindex_prospects_of_companies(p_company_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reindex_prospects_of_companies(p_company_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reindex_prospects_of_companies(p_company_ids text[]) TO service_role;


--
-- Name: FUNCTION reindex_prospects_of_lists(p_list_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reindex_prospects_of_lists(p_list_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reindex_prospects_of_lists(p_list_ids text[]) TO service_role;


--
-- Name: FUNCTION reindex_scope_v1(p_client_id text, p_list_ids text[], p_import_ids text[], p_company_ids text[], p_prospect_ids text[], p_batch integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reindex_scope_v1(p_client_id text, p_list_ids text[], p_import_ids text[], p_company_ids text[], p_prospect_ids text[], p_batch integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reindex_scope_v1(p_client_id text, p_list_ids text[], p_import_ids text[], p_company_ids text[], p_prospect_ids text[], p_batch integer) TO service_role;


--
-- Name: FUNCTION remove_client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.remove_client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_client_blocklist_selection_v1(p_client_id text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text) TO service_role;


--
-- Name: FUNCTION remove_client_blocklist_v1(p_client_id text, p_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.remove_client_blocklist_v1(p_client_id text, p_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_client_blocklist_v1(p_client_id text, p_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION remove_companies_from_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_max_people integer, p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.remove_companies_from_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_max_people integer, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_companies_from_client_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_max_people integer, p_actor text) TO service_role;


--
-- Name: FUNCTION remove_prospect_from_client_v1(p_client_id text, p_prospect_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.remove_prospect_from_client_v1(p_client_id text, p_prospect_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_prospect_from_client_v1(p_client_id text, p_prospect_id text) TO service_role;


--
-- Name: FUNCTION remove_prospects_from_client_v2(p_client_id text, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.remove_prospects_from_client_v2(p_client_id text, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_prospects_from_client_v2(p_client_id text, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION remove_prospects_from_list_v1(p_list_id text, p_prospect_ids text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.remove_prospects_from_list_v1(p_list_id text, p_prospect_ids text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_prospects_from_list_v1(p_list_id text, p_prospect_ids text[]) TO service_role;


--
-- Name: FUNCTION request_export_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.request_export_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_export_v1(p_owner_id text, p_request_id text, p_entity_type text, p_client_scope text, p_result_set_id uuid, p_fields text[], p_keys text[], p_excluded_ids text[], p_file_base_name text) TO service_role;


--
-- Name: FUNCTION request_result_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.request_result_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_result_set_v1(p_owner_id text, p_entity_type text, p_client_scope text, p_search text, p_filters jsonb, p_content_hash text, p_version_vector jsonb, p_company_scope jsonb) TO service_role;


--
-- Name: FUNCTION request_smartlead_campaign_v1(p_actor text, p_request uuid, p_client text, p_name text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.request_smartlead_campaign_v1(p_actor text, p_request uuid, p_client text, p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.request_smartlead_campaign_v1(p_actor text, p_request uuid, p_client text, p_name text) TO service_role;


--
-- Name: FUNCTION reserve_integration_read_v1(p_provider text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.reserve_integration_read_v1(p_provider text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reserve_integration_read_v1(p_provider text) TO service_role;


--
-- Name: FUNCTION resolve_client_company_selection_v1(p_client_id text, p_domains text[], p_names text[], p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.resolve_client_company_selection_v1(p_client_id text, p_domains text[], p_names text[], p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_client_company_selection_v1(p_client_id text, p_domains text[], p_names text[], p_limit integer) TO service_role;


--
-- Name: FUNCTION resolve_company_action_selection_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.resolve_company_action_selection_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_company_action_selection_v1(p_client_id text, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_limit integer) TO service_role;


--
-- Name: FUNCTION resolve_filter_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.resolve_filter_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_filter_set_v1(p_set_id uuid, p_owner_id text, p_entity_type text, p_client_scope text) TO service_role;


--
-- Name: FUNCTION restore_client_company_blocklist_v1(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.restore_client_company_blocklist_v1(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.restore_client_company_blocklist_v1(p_client_id text) TO service_role;


--
-- Name: FUNCTION result_set_page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.result_set_page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.result_set_page_v1(p_set_id uuid, p_owner_id text, p_limit integer, p_offset integer) TO service_role;


--
-- Name: FUNCTION result_set_status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.result_set_status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.result_set_status_v1(p_set_id uuid, p_owner_id text, p_version_vector jsonb) TO service_role;


--
-- Name: FUNCTION retry_prospect_import_v1(p_import_id text, p_worker_id text, p_error text, p_retry_seconds integer, p_max_attempts integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.retry_prospect_import_v1(p_import_id text, p_worker_id text, p_error text, p_retry_seconds integer, p_max_attempts integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.retry_prospect_import_v1(p_import_id text, p_worker_id text, p_error text, p_retry_seconds integer, p_max_attempts integer) TO service_role;


--
-- Name: FUNCTION run_blocklist_share_submission_unit_v1(p_worker text, p_match_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.run_blocklist_share_submission_unit_v1(p_worker text, p_match_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.run_blocklist_share_submission_unit_v1(p_worker text, p_match_limit integer) TO prospect_operator;


--
-- Name: FUNCTION run_title_classification_batch_v2(p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.run_title_classification_batch_v2(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.run_title_classification_batch_v2(p_limit integer) TO service_role;


--
-- Name: FUNCTION sanitize_import_payloads_v1(p_entity text, p_after_id text, p_limit integer, p_apply boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sanitize_import_payloads_v1(p_entity text, p_after_id text, p_limit integer, p_apply boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sanitize_import_payloads_v1(p_entity text, p_after_id text, p_limit integer, p_apply boolean) TO service_role;


--
-- Name: FUNCTION search_company_export_v1(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_company_export_v1(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_company_export_v1(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer) TO service_role;


--
-- Name: FUNCTION search_company_export_v2(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer, p_keys text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_company_export_v2(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer, p_keys text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_company_export_v2(p_search text, p_filters jsonb, p_people_scope jsonb, p_websites_only boolean, p_after_name text, p_after_id text, p_limit integer, p_keys text[]) TO service_role;


--
-- Name: FUNCTION search_prospect_export_v1(p_search text, p_filters jsonb, p_client_id text, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_export_v1(p_search text, p_filters jsonb, p_client_id text, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_export_v1(p_search text, p_filters jsonb, p_client_id text, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) TO service_role;


--
-- Name: FUNCTION search_prospect_export_v3(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_export_v3(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_export_v3(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) TO service_role;


--
-- Name: FUNCTION search_prospect_export_v4(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_export_v4(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_export_v4(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean) TO service_role;


--
-- Name: FUNCTION search_prospect_export_v5(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_export_v5(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_export_v5(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]) TO service_role;


--
-- Name: FUNCTION search_prospect_export_v6(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_export_v6(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_export_v6(p_search text, p_filters jsonb, p_client_id text, p_company_scope jsonb, p_after_created_at timestamp with time zone, p_after_id text, p_limit integer, p_with_total boolean, p_keys text[]) TO service_role;


--
-- Name: FUNCTION search_prospect_workspace_v10(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_workspace_v10(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_workspace_v10(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb) TO service_role;


--
-- Name: FUNCTION search_prospect_workspace_v11(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_workspace_v11(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_workspace_v11(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean) TO service_role;


--
-- Name: FUNCTION search_prospect_workspace_v12(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_workspace_v12(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_workspace_v12(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb) TO service_role;


--
-- Name: FUNCTION search_prospect_workspace_v13(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_workspace_v13(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_workspace_v13(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb, p_with_total boolean, p_known_versions jsonb) TO service_role;


--
-- Name: FUNCTION search_prospect_workspace_v9(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.search_prospect_workspace_v9(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_prospect_workspace_v9(p_search text, p_filters jsonb, p_sort text, p_direction text, p_limit integer, p_offset integer, p_client_id text, p_company_scope jsonb) TO service_role;


--
-- Name: FUNCTION set_client_company_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_client_company_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_client_company_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_client_company_tag_v2(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_client_company_tag_v2(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_client_company_tag_v2(p_client_id text, p_tag_id text, p_apply boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_client_date_contacted_v1(p_client_id text, p_date_contacted date, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_client_date_contacted_v1(p_client_id text, p_date_contacted date, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_client_date_contacted_v1(p_client_id text, p_date_contacted date, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_client_lead_v1(p_client_id text, p_is_lead boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_client_lead_v1(p_client_id text, p_is_lead boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_client_lead_v1(p_client_id text, p_is_lead boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_client_prospect_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_client_prospect_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_client_prospect_tag_v1(p_client_id text, p_tag_id text, p_apply boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_company_icp_validated_v1(p_client_id text, p_validated boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_company_icp_validated_v1(p_client_id text, p_validated boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_icp_validated_v1(p_client_id text, p_validated boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_company_icp_verified_v2(p_client_id text, p_verified boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_company_icp_verified_v2(p_client_id text, p_verified boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_company_icp_verified_v2(p_client_id text, p_verified boolean, p_company_ids text[], p_search text, p_filters jsonb, p_people_scope jsonb, p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_icp_verified_v1(p_client_id text, p_verified boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_icp_verified_v1(p_client_id text, p_verified boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_icp_verified_v1(p_client_id text, p_verified boolean, p_search text, p_filters jsonb, p_prospect_ids text[], p_excluded_ids text[], p_actor text) TO service_role;


--
-- Name: FUNCTION set_integration_destination_v1(p_actor text, p_client text, p_campaign bigint, p_enabled boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.set_integration_destination_v1(p_actor text, p_client text, p_campaign bigint, p_enabled boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_integration_destination_v1(p_actor text, p_client text, p_campaign bigint, p_enabled boolean) TO service_role;


--
-- Name: FUNCTION smartlead_progress_v1(p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.smartlead_progress_v1(p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.smartlead_progress_v1(p_actor text) TO service_role;


--
-- Name: FUNCTION smartlead_report_v1(p_actor text, p_job uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.smartlead_report_v1(p_actor text, p_job uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.smartlead_report_v1(p_actor text, p_job uuid) TO service_role;


--
-- Name: FUNCTION stage_integration_job_v1(p_actor text, p_request_id uuid, p_hash text, p_client text, p_campaign bigint, p_mode text, p_batches jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.stage_integration_job_v1(p_actor text, p_request_id uuid, p_hash text, p_client text, p_campaign bigint, p_mode text, p_batches jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stage_integration_job_v1(p_actor text, p_request_id uuid, p_hash text, p_client text, p_campaign bigint, p_mode text, p_batches jsonb) TO service_role;


--
-- Name: FUNCTION stage_mapped_integration_job_v1(p_actor text, p_request uuid, p_hash text, p_client text, p_campaign bigint, p_batches jsonb, p_summary jsonb); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.stage_mapped_integration_job_v1(p_actor text, p_request uuid, p_hash text, p_client text, p_campaign bigint, p_batches jsonb, p_summary jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.stage_mapped_integration_job_v1(p_actor text, p_request uuid, p_hash text, p_client text, p_campaign bigint, p_batches jsonb, p_summary jsonb) TO service_role;


--
-- Name: FUNCTION start_list_push_v1(p_list_id text, p_label text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.start_list_push_v1(p_list_id text, p_label text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_list_push_v1(p_list_id text, p_label text) TO service_role;


--
-- Name: FUNCTION sweep_client_company_blocklist_v1(p_client_id text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sweep_client_company_blocklist_v1(p_client_id text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sweep_client_company_blocklist_v1(p_client_id text) TO service_role;


--
-- Name: FUNCTION sync_changed_prospect_company_memberships_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sync_changed_prospect_company_memberships_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_changed_prospect_company_memberships_v1() TO service_role;


--
-- Name: FUNCTION sync_client_company_membership_v1(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sync_client_company_membership_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_client_company_membership_v1() TO service_role;


--
-- Name: FUNCTION sync_client_prospects_from_lists(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sync_client_prospects_from_lists() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_client_prospects_from_lists() TO service_role;


--
-- Name: FUNCTION sync_company_counts_from_index(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sync_company_counts_from_index() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_company_counts_from_index() TO service_role;


--
-- Name: FUNCTION sync_company_counts_statement(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sync_company_counts_statement() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_company_counts_statement() TO service_role;


--
-- Name: FUNCTION sync_total_funding_amount(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sync_total_funding_amount() TO anon;
GRANT ALL ON FUNCTION public.sync_total_funding_amount() TO authenticated;
GRANT ALL ON FUNCTION public.sync_total_funding_amount() TO service_role;


--
-- Name: FUNCTION title_class_filter_values_v1(p_field text, p_search text, p_client_id text, p_limit integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.title_class_filter_values_v1(p_field text, p_search text, p_client_id text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.title_class_filter_values_v1(p_field text, p_search text, p_client_id text, p_limit integer) TO service_role;


--
-- Name: FUNCTION title_classification_gaps_v1(p_limit integer, p_missing text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.title_classification_gaps_v1(p_limit integer, p_missing text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.title_classification_gaps_v1(p_limit integer, p_missing text) TO service_role;


--
-- Name: FUNCTION title_seniority_rank(p_tier text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.title_seniority_rank(p_tier text) TO anon;
GRANT ALL ON FUNCTION public.title_seniority_rank(p_tier text) TO authenticated;
GRANT ALL ON FUNCTION public.title_seniority_rank(p_tier text) TO service_role;


--
-- Name: FUNCTION touch_title_classifier_state(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.touch_title_classifier_state() FROM PUBLIC;
GRANT ALL ON FUNCTION public.touch_title_classifier_state() TO service_role;


--
-- Name: FUNCTION update_client_blocklist_reason_v1(p_client_id text, p_reason text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.update_client_blocklist_reason_v1(p_client_id text, p_reason text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_client_blocklist_reason_v1(p_client_id text, p_reason text, p_ids text[], p_all_matching boolean, p_search text, p_kind text, p_date_from date, p_date_to date, p_excluded_ids text[], p_selected_before timestamp with time zone, p_actor text) TO service_role;


--
-- Name: TABLE staged_rows; Type: ACL; Schema: prospect_import; Owner: postgres
--

GRANT SELECT,INSERT,DELETE ON TABLE prospect_import.staged_rows TO prospect_importer;


--
-- Name: TABLE client_addition_batch_items; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_addition_batch_items TO service_role;


--
-- Name: TABLE client_addition_batches; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_addition_batches TO service_role;


--
-- Name: TABLE client_blocklist; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_blocklist TO service_role;


--
-- Name: TABLE client_blocklist_batch_results; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_blocklist_batch_results TO service_role;


--
-- Name: TABLE client_blocklist_share_limits; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_blocklist_share_limits TO service_role;


--
-- Name: TABLE client_blocklist_share_submissions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_blocklist_share_submissions TO service_role;


--
-- Name: TABLE client_blocklist_shares; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_blocklist_shares TO service_role;


--
-- Name: TABLE client_companies; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_companies TO service_role;


--
-- Name: TABLE client_companies_blocked; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_companies_blocked TO service_role;


--
-- Name: TABLE client_company_icp_validations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_company_icp_validations TO service_role;


--
-- Name: TABLE client_folders; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_folders TO service_role;


--
-- Name: TABLE client_icp_profiles; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_icp_profiles TO service_role;


--
-- Name: TABLE client_prospects; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_prospects TO service_role;


--
-- Name: TABLE client_settings; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_settings TO service_role;


--
-- Name: TABLE clients; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.clients TO service_role;


--
-- Name: TABLE lists; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.lists TO service_role;


--
-- Name: TABLE client_summaries; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.client_summaries TO service_role;


--
-- Name: TABLE company_import_memberships; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_import_memberships TO service_role;


--
-- Name: TABLE company_import_rows; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_import_rows TO service_role;


--
-- Name: TABLE company_imports; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_imports TO service_role;


--
-- Name: TABLE company_sources; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_sources TO service_role;


--
-- Name: TABLE company_summaries; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_summaries TO service_role;


--
-- Name: TABLE company_tag_links; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_tag_links TO service_role;


--
-- Name: TABLE company_value_suggestions; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.company_value_suggestions TO service_role;


--
-- Name: TABLE contact_events; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.contact_events TO service_role;


--
-- Name: TABLE dashboard_snapshot; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.dashboard_snapshot TO service_role;


--
-- Name: SEQUENCE data_version_company; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.data_version_company TO anon;
GRANT ALL ON SEQUENCE public.data_version_company TO authenticated;
GRANT ALL ON SEQUENCE public.data_version_company TO service_role;


--
-- Name: SEQUENCE data_version_prospect; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.data_version_prospect TO anon;
GRANT ALL ON SEQUENCE public.data_version_prospect TO authenticated;
GRANT ALL ON SEQUENCE public.data_version_prospect TO service_role;


--
-- Name: TABLE imports; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.imports TO service_role;


--
-- Name: TABLE integration_connections; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.integration_connections TO service_role;


--
-- Name: TABLE list_memberships; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.list_memberships TO service_role;


--
-- Name: TABLE list_rows; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.list_rows TO service_role;


--
-- Name: TABLE list_membership_rows; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.list_membership_rows TO service_role;


--
-- Name: SEQUENCE list_rows_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.list_rows_id_seq TO anon;
GRANT ALL ON SEQUENCE public.list_rows_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.list_rows_id_seq TO service_role;


--
-- Name: TABLE list_summaries; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.list_summaries TO service_role;


--
-- Name: TABLE operation_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.operation_log TO service_role;


--
-- Name: TABLE prospect_export_source; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_export_source TO service_role;


--
-- Name: TABLE prospect_fields; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_fields TO service_role;


--
-- Name: TABLE prospect_filter_value_cache; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_filter_value_cache TO service_role;


--
-- Name: TABLE prospect_identifiers; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_identifiers TO service_role;


--
-- Name: TABLE prospect_summaries; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_summaries TO service_role;


--
-- Name: TABLE prospect_tag_links; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_tag_links TO service_role;


--
-- Name: TABLE prospect_tags; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospect_tags TO service_role;


--
-- Name: TABLE prospects; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.prospects TO service_role;


--
-- Name: TABLE reindex_backlog; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.reindex_backlog TO service_role;


--
-- Name: TABLE saved_views; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.saved_views TO service_role;


--
-- Name: TABLE system_event_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.system_event_log TO service_role;


--
-- Name: SEQUENCE system_event_log_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.system_event_log_id_seq TO anon;
GRANT ALL ON SEQUENCE public.system_event_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.system_event_log_id_seq TO service_role;


--
-- Name: TABLE title_classifier_state; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.title_classifier_state TO service_role;


--
-- Name: TABLE title_department_keywords; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.title_department_keywords TO service_role;


--
-- Name: TABLE title_seniority_keywords; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.title_seniority_keywords TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES  TO service_role;


--
-- PostgreSQL database dump complete
--
