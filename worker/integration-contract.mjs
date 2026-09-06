// Pure contract shared by preview, durable dispatch and tests. No network/DB.
export const SMARTLEAD_BATCH_LIMIT = 400;
export const SMARTLEAD_BATCH_BYTES = 512 * 1024;
const targets = new Set(['email', 'first_name', 'last_name', 'company_name', 'phone_number', 'website', 'location', 'linkedin_profile', 'company_url']);
const reserved = new Set(['__proto__', 'prototype', 'constructor']);

export function validateMapping(input) {
  if (!Array.isArray(input) || input.length < 1 || input.length > 209) throw new Error('Choose between 1 and 209 mapped fields.');
  const seen = new Set(); let customCount = 0;
  const mapping = input.map(entry => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)
      || typeof entry.source !== 'string' || !entry.source || entry.source.length > 200
      || typeof entry.target !== 'string' || reserved.has(entry.source)) throw new Error('Invalid field mapping.');
    const custom = entry.target.startsWith('custom:');
    const name = custom ? entry.target.slice(7) : entry.target;
    if (reserved.has(name) || !name || (custom ? !/^[A-Za-z][A-Za-z0-9_]{0,99}$/.test(name) : !targets.has(name))) throw new Error('Invalid destination field.');
    const identity = `${custom ? 'custom:' : ''}${name.toLowerCase()}`;
    if (seen.has(identity)) throw new Error('Each destination field can only be mapped once.');
    seen.add(identity); if (custom) customCount++;
    return { source: entry.source, target: entry.target };
  });
  if (!seen.has('email')) throw new Error('Map an email column before continuing.');
  if (customCount > 200) throw new Error('Smartlead supports at most 200 custom fields.');
  return mapping;
}

export function normalizeDeliveryEmail(value) {
  if (typeof value !== 'string') return null;
  const email = value.trim().toLowerCase();
  // Conservative syntax gate; not a deliverability verdict. Never remove dots
  // or plus suffixes: those transformations can identify a different mailbox.
  if (email.length > 254 || !/^[^\s@,;<>]+@[^\s@,;<>]+\.[^\s@,;<>]+$/.test(email)) return null;
  return email;
}

export function mapDeliveryLead(row, mapping) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) throw new Error('Invalid source record.');
  const lead = Object.create(null); const custom = Object.create(null);
  for (const { source, target } of validateMapping(mapping)) {
    const value = Object.hasOwn(row, source) ? row[source] : null;
    if (value == null || value === '') continue;
    if (!['string', 'number', 'boolean'].includes(typeof value) || (typeof value === 'number' && !Number.isFinite(value))) throw new Error('Mapped values must be text, finite numbers or booleans.');
    const text = String(value);
    if (text.length > 4000 || text.includes('\0')) throw new Error('A mapped field exceeds the supported value size.');
    if (target.startsWith('custom:')) custom[target.slice(7)] = text;
    else lead[target] = text;
  }
  const email = normalizeDeliveryEmail(lead.email);
  if (!email) return { eligible: false, reason: 'missing_or_invalid_email' };
  lead.email = email;
  if (Object.keys(custom).length) lead.custom_fields = custom;
  return { eligible: true, lead };
}

export function verificationAllowsDelivery(result, email, minimumCheckedAt) {
  if (!result || result.status !== 'valid' || normalizeDeliveryEmail(result.email) !== normalizeDeliveryEmail(email)
    || !normalizeDeliveryEmail(email) || typeof result.checkedAt !== 'string') return false;
  const checked = Date.parse(result.checkedAt);
  return Number.isFinite(checked) && checked >= minimumCheckedAt && checked <= Date.now() + 60000;
}

export function uploadPayload(leads) {
  if (!Array.isArray(leads) || !leads.length || leads.length > SMARTLEAD_BATCH_LIMIT) throw new Error('Upload batches must contain 1–400 leads.');
  const emails = new Set();
  for (const lead of leads) {
    const email = normalizeDeliveryEmail(lead?.email);
    if (!email || email !== lead.email || emails.has(email)) throw new Error('Upload batches require unique normalized emails.');
    emails.add(email);
  }
  const payload = { lead_list: leads, settings: { ignore_global_block_list: false, ignore_unsubscribe_list: false, ignore_duplicate_leads_in_other_campaign: false } };
  if (Buffer.byteLength(JSON.stringify(payload), 'utf8') > SMARTLEAD_BATCH_BYTES) throw new Error('Upload batch exceeds the byte-size limit.');
  return payload;
}

export function classifyUploadReceipt(value, submittedEmails) {
  const review = reason => ({ state: 'needs_review', reason });
  if (!Array.isArray(submittedEmails) || !submittedEmails.length || submittedEmails.length > SMARTLEAD_BATCH_LIMIT
    || submittedEmails.some(e => normalizeDeliveryEmail(e) !== e || !e)
    || new Set(submittedEmails).size !== submittedEmails.length) return review('invalid_submission');
  if (!value || typeof value !== 'object' || value.success !== true
    || !Number.isSafeInteger(value.added_count) || !Number.isSafeInteger(value.skipped_count)
    || value.added_count < 0 || value.skipped_count < 0
    || value.added_count + value.skipped_count !== submittedEmails.length) return review('unaccounted_rows');
  if (value.skipped_count === 0) {
    if (value.skipped_leads != null && (!Array.isArray(value.skipped_leads) || value.skipped_leads.length)) return review('conflicting_skipped_rows');
    return { state: 'completed', added: [...submittedEmails], skipped: [] };
  }
  if (!Array.isArray(value.skipped_leads) || value.skipped_leads.length !== value.skipped_count) return review('missing_skipped_details');
  const input = new Set(submittedEmails); const skipped = []; const seen = new Set();
  for (const row of value.skipped_leads) {
    const email = normalizeDeliveryEmail(row?.email);
    if (!email || !input.has(email) || seen.has(email) || typeof row.reason !== 'string') return review('invalid_skipped_details');
    seen.add(email); skipped.push({ email, reason: row.reason.slice(0, 200) });
  }
  return { state: 'completed', added: submittedEmails.filter(e => !seen.has(e)), skipped };
}

export function uploadFailureDisposition(status) {
  if (status === 429) return 'cooldown';
  if (status === 401 || status === 403) return 'connection_paused';
  if ([400, 404, 422].includes(status)) return 'rejected';
  // Timeouts, 5xx and interrupted writes may have committed upstream. Never
  // automatically POST them again without reconciliation or manual review.
  return 'needs_review';
}
