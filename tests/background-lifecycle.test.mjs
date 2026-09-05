import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runMaintenanceUnit } from '../worker/maintenance-unit.mjs';
import { backgroundAlerts } from '../lib/background-health.ts';

test('cleanup starts its deadline before work and restores the connection settings', async () => {
  const calls = [];
  const client = { query: async (sql, args) => { calls.push([sql,args]); return {rows:[{items_removed:3}]}; } };
  assert.equal((await runMaintenanceUnit(client,'search')).items_removed,3);
  assert.deepEqual(calls.map(c=>c[0]), ['BEGIN',"SET LOCAL statement_timeout = '3s'","SET LOCAL lock_timeout = '250ms'",'select * from prospect_operations.reclaim_unit_v1($1,5000)','COMMIT']);
  assert.deepEqual(calls[3][1], ['search']);
});

test('cleanup failure rolls back before the worker can run another class', async () => {
  const calls=[];
  const client={query:async sql=>{calls.push(sql); if(sql.includes('reclaim_unit')) throw new Error('cancelled'); return {rows:[]};}};
  await assert.rejects(runMaintenanceUnit(client,'export'),/cancelled/);
  assert.equal(calls.at(-1),'ROLLBACK');
  assert.equal(calls.includes('COMMIT'),false);
  await assert.rejects(runMaintenanceUnit(client,'arbitrary'),/Invalid/);
});

test('queue and storage alerts use bounded labels and do not invent low-volume percentages', () => {
  assert.deepEqual(backgroundAlerts(null),['telemetry_unavailable']);
  assert.deepEqual(backgroundAlerts({queues:[],recentJobs:[],searchBytes:0}),[]);
  const warning=backgroundAlerts({queues:[{oldest_seconds:61}],searchBytes:3*1024**3,recentJobs:[{outcome:'failed',jobs:1}]});
  assert.deepEqual(warning,['background_queue_delayed','search_storage_soft_threshold','background_failures_present']);
  assert.ok(backgroundAlerts({recentJobs:[{outcome:'ready',jobs:98},{outcome:'failed',jobs:2}]}).includes('background_failure_rate'));
});

test('the retention contract protects dependents and bounds child deletion before parents', async () => {
  const sql=await readFile(new URL('../supabase/migrations/20260905230936_bounded_background_lifecycle.sql',import.meta.url),'utf8');
  assert.match(sql,/j.result_set_id=s.id AND j.status IN/);
  assert.match(sql,/FOR UPDATE OF s SKIP LOCKED/);
  assert.match(sql,/IF NOT v_remaining THEN/);
  assert.match(sql,/p_limit := least\(p_limit,2\)/);
  assert.match(sql,/s.status IN \(''completed'',''failed''\)/);
  assert.match(sql,/ALTER TABLE prospect_operations.job_metrics ENABLE ROW LEVEL SECURITY/);
  assert.match(sql,/LIMIT 1000/);
});
