import test from 'node:test';
import assert from 'node:assert/strict';
import { filterPayloadWithSets, forgetFilterSets, knownFilterSetCount } from '../lib/filter-set-client.ts';

const filters = (prefix) => [{ field: '__website', operator: 'equals', values: Array.from({length: 500}, (_, i) => `${prefix}-${i}.example`) }];
test('durable-filter client cache is bounded and an evicted set is safely re-resolved', async () => {
  const original = globalThis.fetch; let calls = 0;
  globalThis.fetch = async () => { calls++; return Response.json({setId: `set-${calls}`}); };
  try {
    forgetFilterSets();
    for (let i = 0; i < 45; i++) await filterPayloadWithSets(filters(i), 'company');
    assert.ok(knownFilterSetCount() <= 40);
    await filterPayloadWithSets(filters(44), 'company');
    assert.equal(calls, 45);
    await filterPayloadWithSets(filters(0), 'company');
    assert.equal(calls, 46);
  } finally { forgetFilterSets(); globalThis.fetch = original; }
});

test('a forgotten in-flight filter set does not repopulate the invalidated cache', async () => {
  const original = globalThis.fetch; let resolve;
  globalThis.fetch = async () => new Promise(done => { resolve = done; });
  try {
    forgetFilterSets();
    const request = filterPayloadWithSets(filters('stale'), 'company');
    forgetFilterSets();
    resolve(Response.json({setId: 'old'}));
    await request;
    assert.equal(knownFilterSetCount(), 0);
  } finally { forgetFilterSets(); globalThis.fetch = original; }
});
