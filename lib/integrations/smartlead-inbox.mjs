const EMAIL = /^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/;
export const SMARTLEAD_INBOX_PAGE_SIZE = 20;
export const SMARTLEAD_INBOX_CATEGORY_IDS = new Set([1, 2, 3, 4, 5, 6, 7, 8, 9, 115247, 115248, 120097, 163624, 171350]);

function integer(value) {
  const parsed = typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : value;
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function textId(value) {
  if ((typeof value !== 'string' && typeof value !== 'number') || !String(value).trim()) return null;
  const result = String(value).trim();
  return result.length <= 160 ? result : null;
}

function email(value) {
  if (typeof value !== 'string') return null;
  const result = value.trim().toLowerCase();
  return result.length <= 254 && EMAIL.test(result) ? result : null;
}

function isoDate(value) {
  if (typeof value !== 'string' || value.length > 40 || !Number.isFinite(Date.parse(value))) return null;
  return new Date(value).toISOString();
}

function parseOfficial(row) {
  const providerKey = textId(row?.campaign_lead_map_id ?? row?.id);
  const campaignId = integer(row?.campaign?.id);
  const campaignName = typeof row?.campaign?.name === 'string' ? row.campaign.name.trim().slice(0, 300) : '';
  const normalizedEmail = email(row?.lead?.email);
  const categoryId = row?.category == null ? null : integer(row.category.id);
  const replyTime = isoDate(row?.last_message?.received_at ?? row?.stats?.last_activity);
  if (!providerKey || !campaignId || !campaignName || !normalizedEmail || (row?.category != null && !categoryId) || !replyTime) return null;
  return { providerKey, campaignId, campaignName, email: normalizedEmail, categoryId, replyTime };
}

function parseObserved(row) {
  const providerKey = textId(row?.email_lead_map_id ?? row?.email_lead_id);
  const campaignId = integer(row?.email_campaign_id);
  const campaignName = typeof row?.email_campaign_name === 'string' ? row.email_campaign_name.trim().slice(0, 300) : '';
  const leadEmail = email(row?.lead_email);
  const legacyEmail = email(row?.email);
  if ((row?.lead_email != null && !leadEmail) || (row?.email != null && !legacyEmail)
    || (leadEmail && legacyEmail && leadEmail !== legacyEmail)) return null;
  const normalizedEmail = leadEmail ?? legacyEmail;
  const categoryId = row?.lead_category_id == null ? null : integer(row.lead_category_id);
  const replyTime = isoDate(row?.last_reply_time ?? row?.last_sent_time);
  if (!providerKey || !campaignId || !campaignName || !normalizedEmail || (row?.lead_category_id != null && !categoryId) || !replyTime) return null;
  return { providerKey, campaignId, campaignName, email: normalizedEmail, categoryId, replyTime };
}

export function parseSmartleadInboxPage(value, expectedOffset, expectedLimit = SMARTLEAD_INBOX_PAGE_SIZE) {
  if (!Number.isSafeInteger(expectedOffset) || expectedOffset < 0 || !Number.isSafeInteger(expectedLimit)
    || expectedLimit < 1 || expectedLimit > SMARTLEAD_INBOX_PAGE_SIZE || !value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Unexpected Smartlead inbox response.');
  }
  const official = Array.isArray(value.messages);
  const rows = official ? value.messages : value.ok === true && Array.isArray(value.data) ? value.data : null;
  if (!rows || rows.length > expectedLimit) throw new Error('Unexpected Smartlead inbox response.');
  if (official) {
    if (value.offset != null && value.offset !== expectedOffset) throw new Error('Unexpected Smartlead inbox pagination.');
    if (value.limit != null && value.limit !== expectedLimit) throw new Error('Unexpected Smartlead inbox pagination.');
    if (value.total_count != null && (!Number.isSafeInteger(value.total_count) || value.total_count < rows.length)) throw new Error('Unexpected Smartlead inbox count.');
  }
  const seen = new Set();
  const parsed = rows.map(row => official ? parseOfficial(row) : parseObserved(row));
  if (parsed.some(row => !row)) throw new Error('Unexpected Smartlead inbox item.');
  for (const row of parsed) {
    if (seen.has(row.providerKey)) throw new Error('Duplicate Smartlead inbox item.');
    seen.add(row.providerKey);
  }
  return {
    rows: parsed,
    count: parsed.length,
    total: official && Number.isSafeInteger(value.total_count) ? value.total_count : null,
    contract: official ? 'official-v1' : 'observed-flat-v1',
  };
}

export function smartleadInboxFailure(status) {
  if (status === 429) return 'cooldown';
  if (status === 401 || status === 403) return 'connection_paused';
  if (status === 422) return 'needs_review';
  return 'retry';
}

export async function readSmartleadInboxPage(offset, secret, fetcher = fetch, limit = SMARTLEAD_INBOX_PAGE_SIZE, replyWindow = null) {
  if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1
    || limit > SMARTLEAD_INBOX_PAGE_SIZE || typeof secret !== 'string' || !secret) throw new Error('Invalid inbox request.');
  let filters = {};
  if (replyWindow != null) {
    if (!Array.isArray(replyWindow) || replyWindow.length !== 2 || replyWindow.some(value => typeof value !== 'string' || !Number.isFinite(Date.parse(value)))
      || Date.parse(replyWindow[0]) > Date.parse(replyWindow[1])) throw new Error('Invalid inbox reply window.');
    filters = { replyTimeBetween: replyWindow };
  }
  const url = new URL('https://server.smartlead.ai/api/v1/master-inbox/inbox-replies');
  url.searchParams.set('api_key', secret);
  url.searchParams.set('fetch_message_history', 'false');
  let value;
  try {
    const response = await fetcher(url, {
      method: 'POST', redirect: 'error', cache: 'no-store',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify({ filters, offset, limit, sortBy: 'REPLY_TIME_DESC' }),
      signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      return { ok: false, status: response.status, retryAfter: response.headers.get('retry-after') };
    }
    if (!response.headers.get('content-type')?.toLowerCase().includes('application/json')) {
      void response.body?.cancel().catch(() => {});
      return { ok: false, status: 502 };
    }
    const reader = response.body?.getReader();
    if (!reader) return { ok: false, status: 502 };
    const chunks = []; let size = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 4 * 1024 * 1024) throw new Error('Response too large.');
        chunks.push(value);
      }
    } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
    value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    // Credentials are query parameters. Never return or log the URL/error.
    return { ok: false, status: 0 };
  }
  try { return { ok: true, page: parseSmartleadInboxPage(value, offset, limit) }; }
  catch { return { ok: false, status: 502, contractError: true }; }
}
