import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { prepareCompanyScope } from '../lib/prepare-company-scope.ts';
const scope = { search: 'software', filters: [], limit: 250000 };
const health = status => async () => ({ status });
function database(row, calls) {
  return { rpc: (name, args) => { calls.push({ name, args }); return { abortSignal: async signal => {
    assert.ok(signal); return { data: [row], error: null };
  } }; } };
}
test('a worker outage cannot enqueue work, but ready owner-scoped results are still served', async () => {
  for (const status of ['unavailable', 'not_configured']) {
    const calls = [];
    const ready = await prepareCompanyScope(database({ set_id: 'ready-id', status: 'ready' }, calls), 'owner', scope, undefined, health(status));
    assert.equal(calls[0].name, 'prepare_company_scope_v2');
    assert.equal(calls[0].args.p_allow_enqueue, false);
    assert.equal(ready.scope._prepared_owner, 'owner');
    const pending = await prepareCompanyScope(database({ set_id: 'pending-id', status: 'pending' }, calls), 'owner', scope, undefined, health(status));
    assert.equal(pending.response.status, 503);
    assert.equal((await pending.response.json()).code, 'worker_unavailable');
  }
});
test('healthy preparation preserves pending and ready response contracts', async () => {
  const calls = [];
  const pending = await prepareCompanyScope(database({ set_id: 'new-id', status: 'pending' }, calls), 'owner', scope, undefined, health('ok'));
  assert.equal(calls[0].args.p_allow_enqueue, true);
  assert.equal(pending.response.status, 202);
  assert.equal(pending.response.headers.get('Cache-Control'), 'no-store');
});
test('worker URLs remain nested under the app environment in Compose', async () => {
  const compose = await readFile(new URL('../deploy/docker-compose.yml', import.meta.url), 'utf8');
  for (const variable of ['IMPORT_WORKER_HEALTH_URL', 'OPERATIONS_WORKER_HEALTH_URL']) {
    assert.match(compose, new RegExp(`^    ${variable}: http:`, 'm'));
  }
});
test('maintenance never falls back to blocking reindex or erases query evidence', async () => {
  const source = await readFile(new URL('../deploy/scripts/maintenance.sh', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /reindex table public\./i);
  assert.doesNotMatch(source, /pg_stat_statements_reset\(/);
  assert.match(source, /MAINTENANCE_REINDEX:-0/);
});
