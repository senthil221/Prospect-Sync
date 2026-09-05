-- Synthetic contract fixture ONLY. Refuse an application database, even if
-- explicitly enabled accidentally. No production data is needed or copied.
DO $$ BEGIN
  IF to_regclass('public.prospects') IS NOT NULL OR to_regnamespace('prospect_results') IS NOT NULL THEN
    RAISE EXCEPTION 'Refusing atomic-unit fixture on an application database';
  END IF;
END $$;
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE ROLE prospect_operator;
CREATE ROLE prospect_ops_worker;
GRANT prospect_operator TO prospect_ops_worker;
CREATE TABLE public.prospect_index(id text);
CREATE SCHEMA unit_results;
CREATE SCHEMA unit_operations;
CREATE SCHEMA unit_exports;
CREATE TABLE unit_results.result_sets (
  id uuid PRIMARY KEY, status text DEFAULT 'pending', row_count bigint DEFAULT 0,
  worker_id text, lease_expires_at timestamptz, completed_at timestamptz,
  should_fail boolean DEFAULT false
);
CREATE TABLE unit_operations.operation_jobs (LIKE unit_results.result_sets INCLUDING ALL);
CREATE TABLE unit_exports.jobs (LIKE unit_results.result_sets INCLUDING ALL);
CREATE TABLE public.unit_effects(kind text, id uuid);

CREATE FUNCTION unit_results.claim_next_v1(text,integer) RETURNS TABLE(set_id uuid)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY UPDATE unit_results.result_sets SET status='building',worker_id=$1
    WHERE id=(SELECT s.id FROM unit_results.result_sets s WHERE s.status='pending' ORDER BY s.id FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING id;
END $$;
CREATE FUNCTION unit_operations.claim_next_v1(text,integer) RETURNS TABLE(job_id uuid)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY UPDATE unit_operations.operation_jobs SET status='running',worker_id=$1
    WHERE id=(SELECT j.id FROM unit_operations.operation_jobs j WHERE j.status='frozen' ORDER BY j.id FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING id;
END $$;
CREATE FUNCTION unit_exports.claim_next_v1(text,integer) RETURNS TABLE(job_id uuid)
LANGUAGE plpgsql AS $$ BEGIN
  RETURN QUERY UPDATE unit_exports.jobs SET status='building',worker_id=$1
    WHERE id=(SELECT j.id FROM unit_exports.jobs j WHERE j.status='queued' ORDER BY j.id FOR UPDATE SKIP LOCKED LIMIT 1)
    RETURNING id;
END $$;

CREATE FUNCTION unit_results.build_batch_v1(uuid,integer) RETURNS TABLE(total bigint,done boolean)
LANGUAGE plpgsql AS $$ DECLARE v_count bigint; BEGIN
  INSERT INTO public.unit_effects VALUES('search',$1);
  IF (SELECT should_fail FROM unit_results.result_sets WHERE id=$1) THEN RAISE EXCEPTION 'fixture failure'; END IF;
  UPDATE unit_results.result_sets SET row_count=row_count+1 WHERE id=$1 RETURNING row_count INTO v_count;
  IF v_count=2 THEN UPDATE unit_results.result_sets SET status='ready' WHERE id=$1; END IF;
  RETURN QUERY SELECT v_count,v_count=2;
END $$;
CREATE FUNCTION unit_operations.apply_batch_v1(uuid,integer,integer) RETURNS TABLE(applied_items bigint,done boolean)
LANGUAGE plpgsql AS $$ DECLARE v_count bigint; BEGIN
  INSERT INTO public.unit_effects VALUES('operation',$1);
  IF (SELECT should_fail FROM unit_operations.operation_jobs WHERE id=$1) THEN RAISE EXCEPTION 'fixture failure'; END IF;
  UPDATE unit_operations.operation_jobs SET row_count=row_count+1 WHERE id=$1 RETURNING row_count INTO v_count;
  IF v_count=2 THEN UPDATE unit_operations.operation_jobs SET status='completed' WHERE id=$1; END IF;
  RETURN QUERY SELECT v_count,v_count=2;
END $$;
CREATE FUNCTION unit_exports.build_batch_v1(uuid,integer,integer) RETURNS TABLE(total_rows bigint,done boolean)
LANGUAGE plpgsql AS $$ DECLARE v_count bigint; BEGIN
  INSERT INTO public.unit_effects VALUES('export',$1);
  IF (SELECT should_fail FROM unit_exports.jobs WHERE id=$1) THEN RAISE EXCEPTION 'fixture failure'; END IF;
  UPDATE unit_exports.jobs SET row_count=row_count+1 WHERE id=$1 RETURNING row_count INTO v_count;
  IF v_count=2 THEN UPDATE unit_exports.jobs SET status='ready' WHERE id=$1; END IF;
  RETURN QUERY SELECT v_count,v_count=2;
END $$;
CREATE FUNCTION unit_results.fail_set_v1(uuid,text) RETURNS void LANGUAGE sql AS $$ UPDATE unit_results.result_sets SET status='failed',worker_id=NULL WHERE id=$1 $$;
CREATE FUNCTION unit_operations.fail_v1(uuid,text) RETURNS void LANGUAGE sql AS $$ UPDATE unit_operations.operation_jobs SET status='failed',worker_id=NULL WHERE id=$1 $$;
CREATE FUNCTION unit_exports.fail_v1(uuid,text) RETURNS void LANGUAGE sql AS $$ UPDATE unit_exports.jobs SET status='failed',worker_id=NULL WHERE id=$1 $$;
