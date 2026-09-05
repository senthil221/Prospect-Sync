import assert from 'node:assert/strict';
import test from 'node:test';
import { getEventListeners } from 'node:events';
import { boundedInteger, createAdmissionQueue } from '../lib/bounded-admission.ts';

test('invalid environment limits cannot disable admission protection', () => {
  for (const value of ['NaN', 'Infinity', '-1', '0', '9', '1.5', '']) assert.equal(boundedInteger(value, 8, 1, 8), 8);
  assert.equal(boundedInteger('3', 8, 1, 8), 3);
  assert.throws(() => createAdmissionQueue(0, 1, 1), RangeError);
});
test('waiting is bounded and a released slot transfers FIFO exactly once', async () => {
  const queue = createAdmissionQueue(1, 1, 1000);
  const first = await queue.acquire();
  const second = queue.acquire();
  assert.equal(queue.state().waiting, 1);
  assert.equal(await queue.acquire(), null);
  first(); first();
  const next = await second;
  assert.equal(queue.state().inFlight, 1);
  next(); next();
  assert.equal(queue.state().inFlight, 0);
});
test('abort and timeout clean up timers, listeners and waiting positions', async () => {
  for (const mode of ['abort', 'timeout', 'admit']) {
    const queue = createAdmissionQueue(1, 1, 5);
    const first = await queue.acquire();
    const controller = new AbortController();
    const pending = queue.acquire(controller.signal);
    assert.equal(getEventListeners(controller.signal, 'abort').length, 1);
    if (mode === 'abort') controller.abort();
    if (mode === 'admit') first();
    const next = await pending;
    assert.equal(queue.state().waiting, 0);
    assert.equal(getEventListeners(controller.signal, 'abort').length, 0);
    if (mode === 'admit') next(); else { assert.equal(next, null); first(); }
    assert.equal(queue.state().inFlight, 0);
  }
});
test('abort racing with a slot transfer does not leak capacity', async () => {
  const queue = createAdmissionQueue(1, 1, 100);
  const first = await queue.acquire();
  const controller = new AbortController();
  const pending = queue.acquire(controller.signal);
  first(); controller.abort();
  assert.equal(await pending, null);
  assert.equal(queue.state().inFlight, 0);
});
