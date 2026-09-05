import assert from 'node:assert/strict';
import test from 'node:test';
import { createOperationsHealthProbe } from '../lib/operations-health.ts';

test('worker health probes singleflight concurrent polls and reuse a short cache', async () => {
  let calls = 0;
  let resolve;
  const probe = createOperationsHealthProbe(async (_url, options) => {
    calls++; assert.equal(options.cache, 'no-store'); assert.ok(options.signal);
    await new Promise(r => { resolve = r; });
    return Response.json({ status: 'ok' });
  });
  const first = probe('http://worker/health');
  const next = probe('http://worker/health');
  assert.equal(calls, 1);
  resolve();
  assert.deepEqual(await first, { status: 'ok' });
  assert.deepEqual(await next, { status: 'ok' });
  await probe('http://worker/health');
  assert.equal(calls, 1);
});
test('unconfigured, unhealthy, malformed and failed workers fail closed', async () => {
  assert.deepEqual(await createOperationsHealthProbe()(undefined), { status: 'not_configured' });
  for (const result of [() => Response.json({ status: 'stale' }), () => new Response('', { status: 503 }),
    () => new Response('bad json'), () => { throw new Error('offline'); }]) {
    const probe = createOperationsHealthProbe(async () => result());
    assert.deepEqual(await probe('http://worker/health'), { status: 'unavailable' });
  }
});
test('health cache expires and observes recovery', async () => {
  let calls = 0;
  const probe = createOperationsHealthProbe(async () => Response.json({ status: ++calls === 1 ? 'stale' : 'ok' }), 0);
  assert.equal((await probe('http://worker/health')).status, 'unavailable');
  assert.equal((await probe('http://worker/health')).status, 'ok');
});
