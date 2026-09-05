import test from 'node:test';
import assert from 'node:assert/strict';
import { createFairScheduler, integerSetting } from '../worker/fair-scheduler.mjs';
test('sustained work receives one unit per class, without concurrent database work', async () => {
  const calls = []; let active = 0;
  const round = createFairScheduler({ classes: ['search', 'operation', 'export'],
    runUnit: async kind => { assert.equal(active++, 0); calls.push(kind); await Promise.resolve(); active--; return true; },
    onError: error => { throw error; },
  });
  for (let i = 0; i < 100; i++) assert.equal(await round(), true);
  assert.deepEqual(calls, Array.from({length:100}, () => ['search','operation','export']).flat());
});
test('a failing or empty class cannot starve other classes', async () => {
  const calls = [], errors = [];
  const round = createFairScheduler({ classes: ['search', 'operation', 'export'],
    runUnit: async kind => { calls.push(kind); if (kind === 'search') throw new Error('connection'); return kind === 'export'; },
    onError: async kind => { errors.push(kind); },
  });
  assert.equal(await round(), true);
  assert.deepEqual(calls, ['search','operation','export']);
  assert.deepEqual(errors, ['search']);
});
test('shutdown stops at the committed unit boundary and empty rounds request backoff', async () => {
  let stopping = false; const calls = [];
  const round = createFairScheduler({ classes: ['search','operation','export'], stopping: () => stopping,
    runUnit: async kind => { calls.push(kind); stopping = true; return true; }, onError: () => {} });
  await round(); assert.deepEqual(calls, ['search']);
  const idle = createFairScheduler({ classes: ['search','operation','export'], runUnit: async () => false, onError: () => {} });
  assert.equal(await idle(), false);
});
test('worker configuration fails startup for non-finite, fractional and out-of-bound values', () => {
  assert.equal(integerSetting(undefined, 5, 1, 10, 'X'), 5);
  assert.equal(integerSetting('3', 5, 1, 10, 'X'), 3);
  for (const value of ['NaN','Infinity','0','11','1.5']) assert.throws(() => integerSetting(value, 5, 1, 10, 'X'));
});
