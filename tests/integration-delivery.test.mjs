import test from 'node:test';
import assert from 'node:assert/strict';
import { validateMapping, mapDeliveryLead, normalizeDeliveryEmail, uploadPayload, classifyUploadReceipt, uploadFailureDisposition, verificationAllowsDelivery } from '../worker/integration-contract.mjs';
const mapping = [{ source: 'work_email', target: 'email' }, { source: 'title', target: 'custom:job_title' }];
test('mapping preserves explicitly selected custom values, not unrelated PII', () => {
  const out = mapDeliveryLead({ work_email: ' A+Tag@Example.test ', title: 'Director', hidden: 'private' }, mapping);
  assert.equal(out.lead.email, 'a+tag@example.test');
  assert.equal(out.lead.custom_fields.job_title, 'Director');
  assert.equal(out.lead.hidden, undefined);
});
test('mapping rejects duplicate, dangerous, absent-email and nested values', () => {
  for (const extra of [{ source: 'x', target: 'email' }, { source: 'x', target: 'custom:JOB_TITLE' }, { source: '__proto__', target: 'first_name' }, { source: 'x', target: 'custom:constructor' }]) assert.throws(() => validateMapping([...mapping, extra]));
  assert.throws(() => validateMapping([{ source: 'x', target: 'first_name' }]));
  assert.throws(() => mapDeliveryLead({ work_email: 'x@y.test', title: { secret: true } }, mapping));
  assert.throws(() => mapDeliveryLead({ work_email: 'x@y.test', title: 'x'.repeat(4001) }, mapping));
});
test('email normalization does not merge distinct dot or plus identities', () => {
  assert.notEqual(normalizeDeliveryEmail('a.b@example.test'), normalizeDeliveryEmail('ab@example.test'));
  assert.notEqual(normalizeDeliveryEmail('a+x@example.test'), normalizeDeliveryEmail('a@example.test'));
  assert.equal(normalizeDeliveryEmail('bad address@example.test'), null);
  assert.equal(mapDeliveryLead({}, mapping).eligible, false);
});
test('upload preserves blocklists and rejects oversized/duplicate batches', () => {
  const leads = Array.from({ length: 400 }, (_, i) => ({ email: `test${i}@example.test` }));
  assert.equal(uploadPayload(leads).settings.ignore_unsubscribe_list, false);
  assert.equal(uploadPayload(leads).settings.ignore_global_block_list, false);
  assert.throws(() => uploadPayload([...leads, { email: 'extra@example.test' }]));
  assert.throws(() => uploadPayload([leads[0], leads[0]]));
  assert.throws(() => uploadPayload([{ email: 'a@example.test', custom_fields: { big: 'x'.repeat(524288) } }]));
});
test('receipts never substitute batch length for missing success counts', () => {
  const emails = ['a@example.test', 'b@example.test'];
  assert.equal(classifyUploadReceipt({}, emails).state, 'needs_review');
  assert.equal(classifyUploadReceipt({ success: true, added_count: 1, skipped_count: 0 }, emails).state, 'needs_review');
  assert.equal(classifyUploadReceipt({ success: true, added_count: 1, skipped_count: 1 }, emails).state, 'needs_review');
  const result = classifyUploadReceipt({ success: true, added_count: 1, skipped_count: 1, skipped_leads: [{ email: emails[1], reason: 'blocked' }] }, emails);
  assert.deepEqual(result.added, [emails[0]]);
  assert.equal(result.skipped[0].reason, 'blocked');
});
test('conflicting or duplicated skipped receipts stop for review', () => {
  const emails = ['a@example.test', 'b@example.test'];
  assert.equal(classifyUploadReceipt({ success: true, added_count: 0, skipped_count: 2, skipped_leads: [{ email: emails[0], reason: 'x' }, { email: emails[0], reason: 'x' }] }, emails).state, 'needs_review');
  assert.equal(classifyUploadReceipt({ success: true, added_count: 2, skipped_count: 0, skipped_leads: [{ email: emails[0], reason: 'x' }] }, emails).state, 'needs_review');
});
test('only fresh valid result for the actual email passes verification', () => {
  const now = Date.now(); const result = { status: 'valid', email: 'a@example.test', checkedAt: new Date(now).toISOString() };
  assert.ok(verificationAllowsDelivery(result, result.email, now - 1000));
  for (const status of ['risky', 'invalid', 'unknown', 'unresolved']) assert.ok(!verificationAllowsDelivery({ ...result, status }, result.email, now - 1000));
  assert.ok(!verificationAllowsDelivery(result, 'b@example.test', now - 1000));
  assert.ok(!verificationAllowsDelivery(result, result.email, now + 1000));
});
test('uncertain writes never automatically retry', () => {
  for (const status of [undefined, 500, 502, 503, 408]) assert.equal(uploadFailureDisposition(status), 'needs_review');
  assert.equal(uploadFailureDisposition(429), 'cooldown');
  assert.equal(uploadFailureDisposition(401), 'connection_paused');
  assert.equal(uploadFailureDisposition(422), 'rejected');
});
