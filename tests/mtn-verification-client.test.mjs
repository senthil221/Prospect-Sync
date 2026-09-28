import test from 'node:test';
import assert from 'node:assert/strict';
import { classifyMtnResult, MtnRequestError, normalizeMtnKey, retryAfterMilliseconds, verifyWithMtn } from '../worker/mtn-client.mjs';
import { claimDelayMilliseconds, fillDispatchSlots } from '../worker/verification-scheduler.mjs';

const response = (body, status = 200, headers = {}) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json', ...headers },
});

test('MTN classification follows code while account and Limited messages override it', () => {
  assert.deepEqual(classifyMtnResult('ok', 'Accepted'), { kind: 'result', status: 'valid', reason: 'Accepted' });
  assert.deepEqual(classifyMtnResult('ko', 'Rejected'), { kind: 'result', status: 'invalid', reason: 'Rejected' });
  assert.deepEqual(classifyMtnResult('ko', 'No MX'), { kind: 'result', status: 'invalid', reason: 'No MX' });
  assert.deepEqual(classifyMtnResult('mb', 'Catch-All'), { kind: 'result', status: 'catch_all', reason: 'Catch-All' });
  assert.equal(classifyMtnResult('ok', 'Limited').kind, 'transient');
  assert.equal(classifyMtnResult('ok', 'Disabled Key').kind, 'account');
  for (const message of ['MX Error', 'Timeout', 'SPAM Block']) assert.equal(classifyMtnResult('mb', message).kind, 'transient');
});

test('client normalizes decorated key and validates returned email', async () => {
  let requested;
  const result = await verifyWithMtn(' User@Example.com ', {
    apiKey: ' {secret-value} ',
    fetchImpl: async url => { requested = url; return response({ email: 'user@example.com', code: 'ok', message: 'Accepted' }); },
  });
  assert.equal(result.status, 'valid');
  assert.equal(normalizeMtnKey(' {secret-value} '), 'secret-value');
  assert.equal(requested.origin + requested.pathname, 'https://happy.mailtester.ninja/ninja');
  assert.equal(requested.searchParams.get('key'), 'secret-value');
  await assert.rejects(() => verifyWithMtn('a@example.com', {
    apiKey: 'secret-value', fetchImpl: async () => response({ email: 'b@example.com', code: 'ok', message: 'Accepted' }),
  }), error => error instanceof MtnRequestError && error.code === 'email_mismatch');
  await assert.rejects(() => verifyWithMtn('a b@example.com', {
    apiKey: 'secret-value', fetchImpl: async () => response({ email: 'a b@example.com', code: 'ok', message: 'Accepted' }),
  }), error => error instanceof MtnRequestError && error.code === 'malformed_address');
});

test('429 honors seconds and HTTP-date Retry-After', async () => {
  await assert.rejects(() => verifyWithMtn('a@example.com', {
    apiKey: 'secret', fetchImpl: async () => response({}, 429, { 'retry-after': '7' }),
  }), error => error.code === 'rate_limited' && error.retryAfterMs === 7000);
  assert.equal(retryAfterMilliseconds(new Date(12_000).toUTCString(), 2_000), 10_000);
});

test('auth, quota-shaped body, malformed JSON and timeouts never become invalid results', async () => {
  await assert.rejects(() => verifyWithMtn('a@example.com', { apiKey: 'secret', fetchImpl: async () => response({}, 401) }),
    error => error.code === 'auth' && error.providerPauseMs > 0);
  await assert.rejects(() => verifyWithMtn('a@example.com', {
    apiKey: 'secret', fetchImpl: async () => response({ code: 'ok', message: 'Quota Exceeded' }),
  }), error => error.code === 'account');
  await assert.rejects(() => verifyWithMtn('a@example.com', {
    apiKey: 'secret', fetchImpl: async () => new Response('{', { status: 200 }),
  }), error => error.code === 'malformed');
  await assert.rejects(() => verifyWithMtn('a@example.com', {
    apiKey: 'secret', fetchImpl: async () => { const error = new Error('secret URL should never escape'); error.name = 'TimeoutError'; throw error; },
  }), error => error.code === 'timeout' && !error.message.includes('secret'));
});

test('claim pacing waits only for the provider start gap', () => {
  assert.equal(claimDelayMilliseconds(0, 10_000), 0);
  assert.equal(claimDelayMilliseconds(10_000, 10_100), 400);
  assert.equal(claimDelayMilliseconds(10_000, 10_499), 1);
  assert.equal(claimDelayMilliseconds(10_000, 10_500), 0);
  assert.equal(claimDelayMilliseconds(10_000, 12_000), 0);
});

test('fast provider completions cannot starve the outer maintenance cadence', async () => {
  let clock = 10_000;
  let claims = 0;
  let inFlight = 0;
  const delays = [];
  const result = await fillDispatchSlots({
    maxStarts: 8,
    concurrency: 8,
    inFlightSize: () => inFlight,
    claim: async () => ({ id: ++claims }),
    start: () => { inFlight += 1; inFlight -= 1; }, // provider settles synchronously
    wait: async delay => { delays.push(delay); clock += delay; },
    now: () => clock,
  });
  assert.equal(result.started, 8);
  assert.equal(claims, 8, 'one outer tick has a hard dispatch budget even when slots instantly reopen');
  assert.deepEqual(delays, [500, 500, 500, 500, 500, 500, 500]);
});

test('errors and source contain no provider key, email, alternate provider, or raw URL', async () => {
  const secret = 'never-log-this-key';
  const email = 'private-person@example.com';
  let caught;
  try { await verifyWithMtn(email, { apiKey: secret, fetchImpl: async () => { throw new Error(`fetch failed https://example/?key=${secret}&email=${email}`); } }); }
  catch (error) { caught = error; }
  assert.equal(caught.code, 'network');
  assert.ok(!caught.message.includes(secret));
  assert.ok(!caught.message.includes(email));
  const source = `${verifyWithMtn}`;
  assert.ok(!/no2bounce|n2b|bullmq|redis|prisma/i.test(source));
});
