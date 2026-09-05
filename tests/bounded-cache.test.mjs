import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundedCache } from '../lib/bounded-cache.ts';
import { api, clearApiCache } from '../lib/dashboard-api.ts';
import { backgroundAdmissionResponse } from '../lib/operations-health.ts';
test('cache bounds both entry count and payload estimate and preserves recent use', () => {
  const cache = new BoundedCache(2, 100);
  cache.set('a', 1).set('b', 2); cache.get('a'); cache.set('c', 3);
  assert.equal(cache.get('b'), undefined); assert.equal(cache.get('a'), 1);
  cache.set('huge', 'x'.repeat(100)); assert.equal(cache.size, 2);
  cache.set('a', 'x'.repeat(25)); assert.ok(cache.estimatedBytes <= 100);
  cache.clear(); assert.equal(cache.size, 0); assert.equal(cache.estimatedBytes, 0);
});

test('new background jobs fail closed while ready-result GET paths remain independent', async () => {
  assert.equal(await backgroundAdmissionResponse(async () => ({ status: 'ok' })), null);
  const unavailable = await backgroundAdmissionResponse(async () => ({ status: 'unavailable' }));
  assert.equal(unavailable.status, 503);
  assert.equal(unavailable.headers.get('retry-after'), '5');
});

test('aborting during backpressure cancels the timer and does not send another request', async () => {
  const original = globalThis.fetch; let calls = 0;
  const controller = new AbortController();
  globalThis.fetch = async () => { calls++; return new Response('{}', { status: 503, headers: { 'Retry-After': '30' } }); };
  try {
    const promise = api('/api/abort-retry', { signal: controller.signal });
    setTimeout(() => controller.abort(), 10);
    await assert.rejects(promise, { name: 'AbortError' });
    assert.equal(calls, 1);
  } finally { globalThis.fetch = original; }
});
test('an in-flight pre-mutation read cannot repopulate the invalidated cache or remove a successor request', async () => {
  const original = globalThis.fetch; const pending = [];
  globalThis.fetch = async () => new Promise(resolve => pending.push(resolve));
  try {
    clearApiCache();
    const old = api('/api/test-cache');
    clearApiCache();
    const newer = api('/api/test-cache');
    pending[0](Response.json({ generation: 'old' })); await old;
    const shared = api('/api/test-cache');
    assert.equal(pending.length, 2, 'old finally must not delete the new request');
    pending[1](Response.json({ generation: 'new' }));
    assert.deepEqual(await newer, { generation: 'new' });
    assert.deepEqual(await shared, { generation: 'new' });
    assert.deepEqual(await api('/api/test-cache'), { generation: 'new' });
    assert.equal(pending.length, 2);
  } finally { clearApiCache(); globalThis.fetch = original; }
});
