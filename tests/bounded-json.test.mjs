import test from 'node:test';
import assert from 'node:assert/strict';
import { readBoundedJson } from '../lib/bounded-json.ts';
import { configuredInteger } from '../lib/bounded-admission.ts';

test('invalid configured admission budgets fail startup instead of silently changing policy', () => {
  assert.equal(configuredInteger('X', undefined, 8, 1, 8), 8);
  for (const value of ['NaN', 'Infinity', '-1', '0', '9', '1.5']) assert.throws(() => configuredInteger('X', value, 8, 1, 8));
});

const limits = { bytes: 128, depth: 4, timeoutMs: 100 };
const request = (body, headers = {}) => new Request('https://example.test', { method: 'POST', body, headers, duplex: 'half' });
test('JSON body preserves valid values and ignores brackets inside strings', async () => {
  const value = { a: ['é', '{[[[[[[', 'escaped " bracket ['] };
  assert.deepEqual((await readBoundedJson(request(JSON.stringify(value)), limits)).value, value);
});
test('body limits count actual UTF-8 bytes with no Content-Length', async () => {
  const answer = await readBoundedJson(request(JSON.stringify('é'.repeat(70))), limits);
  assert.equal(answer.response.status, 413);
});
test('a false small Content-Length cannot bypass actual byte limits', async () => {
  assert.equal((await readBoundedJson(request(' '.repeat(129), { 'content-length': '1' }), limits)).response.status, 413);
});
test('declared oversized bodies are rejected before consumption', async () => {
  let consumed = false;
  const req = { headers: new Headers({ 'content-length': '999' }), get body() { consumed = true; throw new Error(); } };
  assert.equal((await readBoundedJson(req, limits)).response.status, 413);
  assert.equal(consumed, false);
});
test('too-deep and malformed payloads cannot reach consumers', async () => {
  assert.equal((await readBoundedJson(request('[[[[[0]]]]]'), limits)).response.status, 413);
  assert.equal((await readBoundedJson(request('{bad'), limits)).response.status, 400);
});
test('chunked overflow cancels rather than buffering the remaining upload', async () => {
  let cancelled = false;
  const stream = new ReadableStream({ pull(controller) { controller.enqueue(new Uint8Array(100)); }, cancel() { cancelled = true; } });
  assert.equal((await readBoundedJson(request(stream), limits)).response.status, 413);
  assert.equal(cancelled, true);
});
test('stalled streams and aborted callers have bounded outcomes', async () => {
  const stream = new ReadableStream({});
  assert.equal((await readBoundedJson(request(stream), { ...limits, timeoutMs: 10 })).response.status, 408);
  const controller = new AbortController();
  controller.abort();
  const req = new Request('https://example.test', { method: 'POST', body: new ReadableStream({}), duplex: 'half', signal: controller.signal });
  assert.equal((await readBoundedJson(req, limits)).response.status, 408);
});
