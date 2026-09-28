import { backoff, decryptSmartlead } from './smartlead-transport.mjs';
import { readSmartleadInboxPage, smartleadInboxFailure, SMARTLEAD_INBOX_PAGE_SIZE } from '../lib/integrations/smartlead-inbox.mjs';

export const smartleadInboxRequest = (offset, secret, replyWindow, fetcher = fetch) =>
  readSmartleadInboxPage(offset, secret, fetcher, SMARTLEAD_INBOX_PAGE_SIZE, replyWindow);

export async function executeSmartleadInboxUnit(unit, { key, finish, request = smartleadInboxRequest }) {
  let secret;
  try { secret = decryptSmartlead(unit.credential, key); }
  catch { return finish('connection_paused', { reason: 'credential_unavailable' }, 60); }
  const replyWindow = unit.mode === 'incremental' ? [unit.from, unit.to] : null;
  if (unit.mode !== 'full' && unit.mode !== 'incremental') return finish('needs_review', { reason: 'invalid_scan_mode' }, 300);
  const response = await request(Number(unit.offset), secret, replyWindow);
  if (!response.ok) {
    const state = response.contractError ? 'needs_review' : smartleadInboxFailure(response.status);
    const reason = response.status === 429 ? 'rate_limited'
      : [401, 403].includes(response.status) ? 'credential_rejected'
      : response.contractError ? 'unrecognized_inbox_contract'
      : response.status === 422 ? 'provider_contract_rejected'
      : 'provider_read_unavailable';
    return finish(state, { reason }, backoff(Number(unit.attempts ?? 1), response.retryAfter));
  }
  let page;
  try { page = response.page; if (!page) throw new Error('Missing page.'); }
  catch { return finish('needs_review', { reason: 'unrecognized_inbox_contract' }, 300); }
  if (unit.mode === 'incremental') {
    const from = Date.parse(unit.from); const to = Date.parse(unit.to);
    if (!Number.isFinite(from) || !Number.isFinite(to) || from > to
      || page.rows.some(row => {
        const replyTime = Date.parse(row.replyTime);
        return !Number.isFinite(replyTime) || replyTime < from || replyTime > to;
      })) return finish('needs_review', { reason: 'provider_reply_window_not_enforced' }, 300);
  }
  return finish('completed', page, 5);
}
