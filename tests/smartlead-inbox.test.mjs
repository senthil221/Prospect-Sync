import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSmartleadInboxPage, readSmartleadInboxPage, SMARTLEAD_INBOX_CATEGORY_IDS } from '../lib/integrations/smartlead-inbox.mjs';
import { executeSmartleadInboxUnit } from '../worker/smartlead-inbox-sync.mjs';
import { sealCredential } from '../lib/integrations/credentials.ts';

const official = {
  messages: [{
    id: 'msg-1', campaign_lead_map_id: 'map-1', lead: { email: 'Person@Example.com' },
    campaign: { id: 42, name: 'Acme | Sequence' }, category: { id: 120097, name: 'Not the right fit' },
    last_message: { received_at: '2026-09-25T15:55:32.000Z', subject: 'not retained', body: 'not retained' },
  }], total_count: 1, offset: 0, limit: 20,
};

test('parses the documented Smartlead response without retaining message content', () => {
  const page = parseSmartleadInboxPage(official, 0);
  assert.deepEqual(page, { rows: [{ providerKey: 'map-1', campaignId: 42, campaignName: 'Acme | Sequence', email: 'person@example.com', categoryId: 120097, replyTime: '2026-09-25T15:55:32.000Z' }], count: 1, total: 1, contract: 'official-v1' });
  assert.doesNotMatch(JSON.stringify(page), /not retained/);
});

test('parses the observed flat response and permits pending categorization', () => {
  const page = parseSmartleadInboxPage({ ok: true, data: [{ email_lead_map_id: '3628763479', email_campaign_id: 3882520,
    email_campaign_name: 'Client - Campaign', email: 'lead@example.test', lead_category_id: null,
    last_reply_time: '2026-09-25T15:55:32.000Z' }] }, 5, 5);
  assert.equal(page.contract, 'observed-flat-v1');
  assert.equal(page.rows[0].categoryId, null);
});

test('parses the live flat lead_email field without changing the observed contract', () => {
  const row = { email_lead_map_id: '3628763479', email_campaign_id: 3882520,
    email_campaign_name: 'Client - Campaign', lead_email: 'Lead@Example.test', lead_category_id: null,
    last_reply_time: '2026-09-25T15:55:32.000Z' };
  const page = parseSmartleadInboxPage({ ok: true, data: [row], offset: 0, limit: 5 }, 0, 5);
  assert.equal(page.contract, 'observed-flat-v1');
  assert.equal(page.rows[0].email, 'lead@example.test');
  assert.equal(page.rows[0].categoryId, null);
  assert.equal(parseSmartleadInboxPage({ ok: true, data: [{ ...row, email: 'lead@example.test' }] }, 0, 5).rows[0].email, 'lead@example.test');
  assert.throws(() => parseSmartleadInboxPage({ ok: true, data: [{ ...row, email: 'other@example.test' }] }, 0, 5), /Unexpected Smartlead inbox item/);
  assert.throws(() => parseSmartleadInboxPage({ ok: true, data: [{ ...row, lead_email: 'bad-address' }] }, 0, 5), /Unexpected Smartlead inbox item/);
  assert.throws(() => parseSmartleadInboxPage({ ok: true, data: [{ ...row, lead_email: null }] }, 0, 5), /Unexpected Smartlead inbox item/);
});

test('rejects unknown response shapes, duplicate items and oversized pages', () => {
  assert.throws(() => parseSmartleadInboxPage({ data: [] }, 0), /Unexpected/);
  assert.throws(() => parseSmartleadInboxPage({ ...official, messages: [official.messages[0], official.messages[0]], total_count: 2 }, 0), /Duplicate/);
  assert.throws(() => parseSmartleadInboxPage({ messages: Array(21).fill(official.messages[0]), total_count: 21, offset: 0, limit: 20 }, 0), /Unexpected/);
});

test('uses the fixed no-history POST endpoint and bounded page contract', async () => {
  let captured;
  const result = await readSmartleadInboxPage(0, 'secret', async (url, init) => {
    captured = { url: String(url), init };
    return new Response(JSON.stringify({ ...official, limit: 5 }), { status: 200, headers: { 'content-type': 'application/json' } });
  }, 5);
  assert.equal(result.ok, true);
  const url = new URL(captured.url);
  assert.equal(url.origin + url.pathname, 'https://server.smartlead.ai/api/v1/master-inbox/inbox-replies');
  assert.equal(url.searchParams.get('api_key'), 'secret');
  assert.equal(url.searchParams.get('fetch_message_history'), 'false');
  assert.equal(captured.init.redirect, 'error');
  assert.deepEqual(JSON.parse(captured.init.body), { filters: {}, offset: 0, limit: 5, sortBy: 'REPLY_TIME_DESC' });

  const window = ['2026-09-25T13:00:00.000Z','2026-09-25T15:00:00.000Z'];
  await readSmartleadInboxPage(0, 'secret', async (_url, init) => {
    assert.deepEqual(JSON.parse(init.body).filters, { replyTimeBetween: window });
    return new Response(JSON.stringify({ messages: [], total_count: 0, offset: 0, limit: 5 }), { status: 200, headers: { 'content-type': 'application/json' } });
  }, 5, window);
});

test('accepts the live flat shape from a successful HTTP response', async () => {
  const row = { email_lead_map_id: '3628763479', email_campaign_id: 3882520,
    email_campaign_name: 'Client - Campaign', lead_email: 'lead@example.test', lead_category_id: 6,
    last_reply_time: '2026-09-25T15:55:32.000Z' };
  const result = await readSmartleadInboxPage(0, 'secret', async () => new Response(
    JSON.stringify({ ok: true, data: [row], offset: 0, limit: 5 }),
    { status: 200, headers: { 'content-type': 'application/json; charset=utf-8' } },
  ), 5);
  assert.equal(result.ok, true);
  assert.equal(result.page.rows[0].email, 'lead@example.test');
  assert.equal(result.page.rows[0].categoryId, 6);
});

test('worker pauses on an unknown contract and honors provider cooldowns', async () => {
  const key = '11'.repeat(32);
  const credential = sealCredential('smartlead', 'provider-secret', key);
  const outcomes = [];
  await executeSmartleadInboxUnit({ offset: 0, attempts: 1, credential, mode: 'full' }, { key,
    request: async () => ({ ok: false, status: 502, contractError: true }),
    finish: async (...args) => outcomes.push(args),
  });
  assert.equal(outcomes[0][0], 'needs_review');
  assert.equal(outcomes[0][1].reason, 'unrecognized_inbox_contract');
  outcomes.length = 0;
  await executeSmartleadInboxUnit({ offset: 0, attempts: 2, credential, mode: 'full' }, { key,
    request: async () => ({ ok: false, status: 429, retryAfter: '120' }),
    finish: async (...args) => outcomes.push(args),
  });
  assert.equal(outcomes[0][0], 'cooldown');
  assert.equal(outcomes[0][2], 120);
});

test('worker refuses to checkpoint an incremental page outside its requested window', async () => {
  const outcomes = [];
  const key = '22'.repeat(32);
  await executeSmartleadInboxUnit({
    credential: sealCredential('smartlead', 'provider-secret', key), mode: 'incremental', offset: 0,
    from: '2026-09-25T10:00:00.000Z', to: '2026-09-25T11:00:00.000Z', attempts: 1,
  }, {
    key,
    request: async () => ({ ok: true, page: {
      contract: 'observed-flat-v1', count: 1, total: null,
      rows: [{ replyTime: '2026-09-25T09:59:59.000Z' }],
    } }),
    finish: async (...args) => { outcomes.push(args); },
  });
  assert.equal(outcomes[0][0], 'needs_review');
  assert.equal(outcomes[0][1].reason, 'provider_reply_window_not_enforced');
});

test('category allowlist includes every supplied category and preserves OOO identity', () => {
  for (const id of [1,2,3,4,5,6,7,8,9,115247,115248,120097,163624,171350]) assert.equal(SMARTLEAD_INBOX_CATEGORY_IDS.has(id), true);
});
