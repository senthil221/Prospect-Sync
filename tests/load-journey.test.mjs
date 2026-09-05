import assert from 'node:assert/strict';
import test from 'node:test';
import { expectedStatus, runReadJourney, validateLoadTarget } from '../scripts/load-journey.mjs';
test('202 polling measures the whole journey until real results', async () => {
  let clock = 0, calls = 0;
  const result = await runReadJourney(async timeout => {
    assert.ok(timeout > 0); clock += 100; calls++;
    return { status: () => calls <= 2 ? 202 : 200, json: async () => ({ preparation: { status: 'building' } }), headers: () => ({ 'retry-after': '2' }) };
  }, { now: () => clock, pause: async ms => { clock += ms; } });
  assert.equal(result.status, 200); assert.equal(result.pendingResponses, 2); assert.equal(result.durationMs, 4300);
});
test('pending cannot become a false success at the journey deadline', async () => {
  let clock = 0;
  const result = await runReadJourney(async () => ({ status: () => 202, json: async () => ({ preparation: { status: 'pending' } }), headers: () => ({}) }),
    { deadlineMs: 10, now: () => clock, pause: async ms => { clock += ms; } });
  assert.equal(result.deadlineExceeded, true); assert.equal(result.status, 0);
});
test('503 fails normal-load gates, is allowed only in explicit overload tests', () => {
  assert.equal(expectedStatus(503), false); assert.equal(expectedStatus(503, 200, true), true);
  assert.equal(expectedStatus(202), false); assert.equal(expectedStatus(413, 413), true);
  assert.throws(() => validateLoadTarget('https://production.example.com', false), /LOAD_ALLOW_REMOTE/);
  validateLoadTarget('http://127.0.0.1:3000', false);
});
