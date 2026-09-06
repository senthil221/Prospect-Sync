import { randomUUID } from 'node:crypto';
import { getAuthorizedUser } from '../../../lib/auth';
import { readBoundedJson } from '../../../lib/bounded-json';
import { createAdminClient } from '../../../lib/supabase/admin';
import { integrationAdmin, integrationWriteAllowed, isProvider, openCredential, sealCredential } from '../../../lib/integrations/credentials';
import { checkProvider, ProviderError } from '../../../lib/integrations/provider-api';

export const runtime = 'nodejs';
const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store', ...extra } });
const storageError = () => reply({ error: 'Integration storage is unavailable. Check the migration and server configuration.' }, 503);

export async function GET() {
  try {
    const user = await getAuthorizedUser();
    if (!user) return reply({ error: 'Unauthorized' }, 401);
    const canManage = integrationAdmin(user.email, process.env.INTEGRATION_ADMIN_EMAILS);
    const { data, error } = await createAdminClient().from('integration_connections').select('provider,connected,checked_at').order('provider').abortSignal(AbortSignal.timeout(5000));
    if (error) return storageError();
    return reply({ connections: data, canManage, encryptionReady: /^[a-fA-F0-9]{64}$/.test(process.env.INTEGRATION_ENCRYPTION_KEY ?? ''), dispatchEnabled: false });
  } catch { return storageError(); }
}

export async function POST(request: Request) {
  try {
    const user = await getAuthorizedUser();
    if (!user) return reply({ error: 'Unauthorized' }, 401);
    if (!integrationAdmin(user.email, process.env.INTEGRATION_ADMIN_EMAILS)) return reply({ error: 'An integration administrator is required.' }, 403);
    if (!integrationWriteAllowed(request)) return reply({ error: 'Same-origin JSON requests are required.' }, 403);
    const decoded = await readBoundedJson(request, { bytes: 8192, depth: 4, timeoutMs: 5000 });
    if (decoded.response) return decoded.response;
    const payload = decoded.value as Record<string, unknown> | null;
    if (!payload || Array.isArray(payload) || !isProvider(payload.provider)
      || !['connect', 'check', 'disconnect'].includes(String(payload.action))) return reply({ error: 'Invalid connection request.' }, 400);
    const { provider, action } = payload;
    const db = createAdminClient();
    if (action === 'disconnect') {
      const { error } = await db.from('integration_connections').update({ credential_ciphertext: null, connected: false, checked_at: null, updated_by: user.id, attempt_token: randomUUID() }).eq('provider', provider).abortSignal(AbortSignal.timeout(5000));
      return error ? storageError() : reply({ disconnected: true });
    }
    const key = process.env.INTEGRATION_ENCRYPTION_KEY ?? '';
    if (!/^[a-fA-F0-9]{64}$/.test(key)) return reply({ error: 'The server encryption key must be configured before connecting.' }, 503);
    let secret = '';
    if (action === 'connect') {
      if (typeof payload.secret !== 'string' || !/^[\x21-\x7e]{16,2048}$/.test(payload.secret)) return reply({ error: 'Enter a valid API key without whitespace (16–2,048 characters).' }, 400);
      secret = payload.secret;
    }
    const { data: token, error: reserveError } = await db.rpc('reserve_integration_read_v1', { p_provider: provider }).abortSignal(AbortSignal.timeout(5000));
    if (reserveError) return storageError();
    if (!token) return reply({ error: 'A connection check is already running or cooling down. Try again shortly.' }, 429, { 'Retry-After': '15' });
    if (action === 'check') {
      const { data, error } = await db.from('integration_connections').select('credential_ciphertext,connected').eq('provider', provider).eq('attempt_token', token).abortSignal(AbortSignal.timeout(5000)).maybeSingle();
      if (error) return storageError();
      if (!data?.connected || !data.credential_ciphertext) return reply({ error: 'Connect this provider first, or reload its changed status.' }, 409);
      secret = openCredential(provider, data.credential_ciphertext, key);
    }
    try {
      const result = await checkProvider(provider, secret);
      const update = { connected: true, checked_at: new Date().toISOString(), updated_by: user.id,
        ...(action === 'connect' ? { credential_ciphertext: sealCredential(provider, secret, key) } : {}) };
      const { data, error } = await db.from('integration_connections').update(update).eq('provider', provider).eq('attempt_token', token).select('provider').abortSignal(AbortSignal.timeout(5000));
      if (error) return storageError();
      if (!data?.length) return reply({ error: 'The connection changed during this check. Reload its status.' }, 409);
      return reply({ connected: true, ...result });
    } catch (error) {
      if (error instanceof ProviderError) {
        if (error.retryAfter) await db.from('integration_connections').update({ next_request_at: new Date(Date.now() + error.retryAfter * 1000).toISOString() }).eq('provider', provider).eq('attempt_token', token).abortSignal(AbortSignal.timeout(5000));
        return reply({ error: error.message }, error.status, error.retryAfter ? { 'Retry-After': String(error.retryAfter) } : {});
      }
      throw error;
    }
  } catch { return reply({ error: 'Unable to update the integration. No leads were sent.' }, 503); }
}
