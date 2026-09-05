-- Session-local search projection experiment. No permanent tables or functions.
-- Run after the filter-variable preamble in company-description-study.sql.
SET LOCAL maintenance_work_mem = '256MB';
CREATE TEMP TABLE description_search (id text PRIMARY KEY, short_description text);
ALTER TABLE description_search ALTER COLUMN short_description SET STORAGE EXTERNAL;
INSERT INTO description_search SELECT id,short_description FROM public.companies;
CREATE INDEX ON description_search USING gin (short_description gin_trgm_ops);
ANALYZE description_search;
SELECT pg_size_pretty(pg_total_relation_size('description_search')) AS projection_size;
SELECT format('EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) SELECT count(*) FROM public.companies c WHERE %s',
  replace(public.company_probe_filter_sql_v1('', :'filters'::jsonb),'join public.companies p on p.short_description','join pg_temp.description_search p on p.short_description')) \gexec
SELECT format('SELECT count(*) AS company_count,md5(string_agg(c.id, chr(10) ORDER BY c.id)) AS membership_digest FROM public.companies c WHERE %s',
  replace(public.company_probe_filter_sql_v1('', :'filters'::jsonb),'join public.companies p on p.short_description','join pg_temp.description_search p on p.short_description')) \gexec
ROLLBACK;
