-- The 2,000,000-row scale model of prospect_index is dropped.
--
-- WHAT IT WAS. audit_2m.prospect_index: a copy of the real prospect_index at
-- 2,000,000 rows with its full index set mirrored under audit2m_* names, built
-- 2026-09-14 to see what the query plans would look like at roughly three times
-- production volume. Nothing in the application, the repository, the docs or
-- any database object refers to it.
--
-- WHY IT GOES, MEASURED 2026-09-18:
--
--   total size                  1,958 MB  (895 MB heap, ~1,063 MB indexes)
--   share of a 13 GB database        15%
--   n_tup_ins                  2,000,000
--   n_tup_upd / n_tup_del            0 / 0
--   seq_scan                            20
--   idx_scan, summed over all 8 indexes  0
--   last_analyze              2026-09-14, none since
--
-- Inserted once, read twenty times, never updated, never deleted from, and not
-- one of its indexes has ever been used - the audit read plans rather than
-- running them. It has been inert for four days and costs 15% of the database
-- plus ~895 MB of every nightly pg_dump, which has no --exclude-schema.
--
-- RECOVERABLE, IF IT TURNS OUT TO BE WANTED. pg_dump takes the whole database,
-- so the schema is in every snapshot taken since it was created. The manifest of
-- /var/backups/prospect/20260917T031731Z lists thirteen audit_2m entries,
-- including TABLE DATA. Restoring it selectively is:
--
--   pg_restore --schema=audit_2m -d postgres database.dump
--
-- That holds only while those snapshots are inside the retention window, which
-- is the honest limit on this being undoable.
--
-- THE GUARDS BELOW REFUSE RATHER THAN DROP BLINDLY. A scratch schema that has
-- quietly acquired a dependent, or grown an object the audit never created, is
-- not the schema this migration was written for, and dropping it cascade would
-- take the dependent with it.
-- ---------------------------------------------------------------------------

do $$
declare
  v_size text;
  v_relations integer;
  v_unexpected text;
  v_routines integer;
  v_dependents text;
begin
  if not exists (select 1 from pg_namespace where nspname = 'audit_2m') then
    raise notice 'audit_2m is not present; nothing to drop';
    return;
  end if;

  select pg_size_pretty(sum(pg_total_relation_size(c.oid))) into v_size
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'audit_2m' and c.relkind in ('r', 'm');

  -- It must contain exactly what the audit built: one ordinary table called
  -- prospect_index, and indexes. Anything else and this is not that schema.
  select count(*) into v_relations
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'audit_2m' and c.relkind = 'r';

  -- relkind is "char", not text: concatenating it without a cast is ambiguous.
  select string_agg(c.relname || ' (' || c.relkind::text || ')', ', ') into v_unexpected
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'audit_2m'
    and c.relkind not in ('i', 'I')
    and not (c.relkind = 'r' and c.relname = 'prospect_index');

  if v_unexpected is not null then
    raise exception 'audit_2m holds objects this migration did not expect (%); refusing to drop it cascade', v_unexpected;
  end if;
  if v_relations <> 1 then
    raise exception 'audit_2m holds % tables, expected exactly one', v_relations;
  end if;

  select count(*) into v_routines
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'audit_2m';
  if v_routines > 0 then
    raise exception 'audit_2m defines % routines; refusing to drop it cascade', v_routines;
  end if;

  -- Nothing outside the schema may depend on it. A view or constraint in public
  -- pointing here would be taken out by the cascade without further warning.
  select string_agg(distinct dependent_ns.nspname || '.' || dependent.relname, ', ')
    into v_dependents
  from pg_depend d
  join pg_class source on source.oid = d.refobjid
  join pg_namespace source_ns on source_ns.oid = source.relnamespace
  join pg_rewrite rw on rw.oid = d.objid
  join pg_class dependent on dependent.oid = rw.ev_class
  join pg_namespace dependent_ns on dependent_ns.oid = dependent.relnamespace
  where source_ns.nspname = 'audit_2m'
    and dependent_ns.nspname <> 'audit_2m';

  if v_dependents is not null then
    raise exception 'objects outside audit_2m depend on it (%); the cascade would take them too', v_dependents;
  end if;

  raise notice 'dropping audit_2m, reclaiming %', v_size;
end $$;

drop schema if exists audit_2m cascade;

-- ---------------------------------------------------------------------------
-- It is gone, and nothing that was not meant to go went with it.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'audit_2m') then
    raise exception 'audit_2m survived the drop';
  end if;
  -- The real one is untouched. Named explicitly because the dropped table had
  -- the same relname, and a mistake here would be the expensive kind.
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'prospect_index' and c.relkind = 'r'
  ) then
    raise exception 'public.prospect_index is missing after dropping audit_2m';
  end if;
end $$;
