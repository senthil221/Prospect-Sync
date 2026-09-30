import test from 'node:test';
import assert from 'node:assert/strict';
import { sealCredential, openCredential, integrationAdmin, integrationWriteAllowed as originAllowed } from '../lib/integrations/credentials.ts';
import { checkProvider, parseCampaigns, parseSmartleadCategories, providerRead, readSmartleadCategories, retryDelay } from '../lib/integrations/provider-api.ts';
import { readWorkspaceUrl } from '../lib/workspace-url.ts';

const key = 'ab'.repeat(32);
test('credentials use randomized authenticated encryption bound to provider', () => {
  const a = sealCredential('smartlead', 'secret-fixture-value', key);
  assert.notEqual(a, sealCredential('smartlead', 'secret-fixture-value', key));
  assert.equal(openCredential('smartlead', a, key), 'secret-fixture-value');
  assert.ok(!a.includes('secret-fixture-value'));
  assert.throws(() => openCredential('verifier', a, key));
  assert.throws(() => openCredential('smartlead', a, 'cd'.repeat(32)));
  assert.throws(() => openCredential('smartlead', a.slice(0, -5), key));
  assert.throws(() => sealCredential('smartlead', 'secret', ''));
});
test('administration is explicitly allowlisted and fails closed', () => {
  assert.equal(integrationAdmin('admin@example.test', undefined), false);
  assert.equal(integrationAdmin('ADMIN@example.test', ' admin@example.test, other@example.test '), true);
  assert.equal(integrationAdmin('someone@example.test', 'admin@example.test'), false);
  assert.equal(integrationAdmin(undefined, '*'), false);
});
test('writes require same origin JSON', () => {
  const req = headers => new Request('https://app.example.test/api/integrations', { headers });
  const integrationWriteAllowed = request => originAllowed(request, 'https://app.example.test');
  assert.ok(integrationWriteAllowed(req({ origin: 'https://app.example.test', 'content-type': 'application/json' })));
  assert.ok(!integrationWriteAllowed(req({ origin: 'https://evil.test', 'content-type': 'application/json' })));
  assert.ok(!integrationWriteAllowed(req({ 'content-type': 'application/json' })));
  assert.ok(!integrationWriteAllowed(req({ origin: 'https://app.example.test', 'content-type': 'text/plain' })));
});
test('proxy origin validation uses configured public URL and rejects header spoofing', () => {
  const req = origin => new Request('http://0.0.0.0:3000/api/integrations', {
    headers: { origin, 'content-type': 'application/json; charset=utf-8',
      host: 'evil.test', 'x-forwarded-host': 'evil.test', 'x-forwarded-proto': 'https' },
  });
  assert.equal(originAllowed(req('https://app.example.test'), 'https://app.example.test/'), true);
  for (const origin of ['https://evil.test', 'http://app.example.test', 'null', 'https://app.example.test.evil.test']) {
    assert.equal(originAllowed(req(origin), 'https://app.example.test'), false);
  }
  for (const config of [undefined, '', 'invalid', 'ftp://app.example.test', 'https://user:pass@app.example.test', 'https://app.example.test/path', 'https://app.example.test?query']) {
    assert.equal(originAllowed(req('https://app.example.test'), config), false);
  }
});
test('campaign parser rejects malformed or duplicate records', () => {
  assert.deepEqual(parseCampaigns([{ id: 1, name: 'Draft', status: 'DRAFTED', client_id: 2 }]), [{ id: 1, name: 'Draft', status: 'DRAFTED', clientId: 2 }]);
  for (const value of [{ data: [] }, [{ id: '1', name: 'x', status: 'ACTIVE' }], [{ id: 1, name: 'x', status: 'ACTIVE', client_id: -1 }], [{ id: 1, name: 'x', status: 'ACTIVE' }, { id: 1, name: 'x', status: 'ACTIVE' }]]) assert.throws(() => parseCampaigns(value));
});
test('discovers account category IDs by exact normalized names', async () => {
  const response = [{ id: 44, name: 'Interested' }, { id: 91, name: ' Out   of Office ' },
    { category_id: 712, category_name: 'Not the right fit' }];
  assert.deepEqual(parseSmartleadCategories(response), [
    { id: 44, name: 'Interested' }, { id: 91, name: 'Out of Office' }, { id: 712, name: 'Not the right fit' },
  ]);
  let requestUrl = '';
  const categories = await readSmartleadCategories('sensitive-key', async url => {
    requestUrl = String(url);
    return Response.json({ data: response });
  });
  assert.equal(new URL(requestUrl).pathname, '/api/v1/leads/fetch-categories');
  assert.equal(new URL(requestUrl).searchParams.get('api_key'), 'sensitive-key');
  assert.equal(categories[2].id, 712);
});
test('fails closed when category identities are missing, duplicated or ambiguous', () => {
  assert.throws(() => parseSmartleadCategories([{ id: 1, name: 'Interested' }, { id: 2, name: 'Out of Office' }]));
  assert.throws(() => parseSmartleadCategories([{ id: 1, name: 'Out of Office' }, { id: 2, name: 'Not the right fit' }, { id: 3, name: 'out of office' }]));
  assert.throws(() => parseSmartleadCategories([{ id: 1, name: 'Out of Office' }, { id: 1, name: 'Not the right fit' }]));
});
test('provider check uses only fixed read endpoint and never follows redirects', async () => {
  let calls = 0;
  await checkProvider('smartlead', 'test-secret', async (url, options) => {
    calls++;
    assert.equal(url.origin, 'https://server.smartlead.ai');
    assert.equal(url.searchParams.get('api_key'), 'test-secret');
    assert.equal(options.method, 'GET'); assert.equal(options.redirect, 'error');
    return Response.json([]);
  });
  assert.equal(calls, 1);
});
test('provider errors never leak secrets or raw response bodies', async () => {
  await assert.rejects(providerRead('smartlead', 'sensitive', async () => { throw new Error('https://example.test?api_key=sensitive'); }), e => !e.message.includes('sensitive'));
  await assert.rejects(providerRead('smartlead', 'sensitive', async () => new Response('sensitive', { status: 401 })), e => e.status === 422 && !e.message.includes('sensitive'));
  await assert.rejects(providerRead('smartlead', 'sensitive', async () => new Response('', { status: 429, headers: { 'retry-after': '123' } })), e => e.status === 429 && e.retryAfter === 123);
});
test('verifier capabilities require the expected authenticated API contract', async () => {
  await checkProvider('verifier', 'fixture', async (url, options) => {
    assert.equal(url.origin, 'https://app.betterlanebase.link');
    assert.equal(options.headers.Authorization, 'Bearer fixture');
    return Response.json({ version: 1, service: 'no2ninja-verifier' });
  });
  await assert.rejects(checkProvider('verifier', 'fixture', async () => Response.json({ status: 'ok' })));
});
test('oversized responses and HTML login pages fail closed', async () => {
  await assert.rejects(providerRead('smartlead', 'fixture', async () => new Response('x'.repeat(4 * 1024 * 1024 + 1), { headers: { 'content-type': 'application/json' } })));
  await assert.rejects(providerRead('verifier', 'fixture', async () => new Response('<html>login</html>', { headers: { 'content-type': 'text/html' } })));
});
test('rate delay is bounded and accepts HTTP-date', () => {
  assert.equal(retryDelay('nonsense'), 60);
  assert.equal(retryDelay('99999999'), 86400);
  assert.equal(retryDelay(new Date(120000).toUTCString(), 60000), 60);
});
test('reply blocklist survives URL restoration; an old Integrations link lands on Overview', () => {
  assert.equal(readWorkspaceUrl(new URLSearchParams('s=reply-blocklist')).section, 'reply-blocklist');
  // The Integrations screen was removed on 2026-09-30.
  assert.equal(readWorkspaceUrl(new URLSearchParams('s=integrations')).section, 'overview');
  assert.equal(readWorkspaceUrl(new URLSearchParams('s=icp-validator')).section, 'icp-validator');
});
