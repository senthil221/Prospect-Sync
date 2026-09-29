import { randomUUID } from 'node:crypto';
import { getAuthorizedUser } from '../../../lib/auth';
import { readBoundedJson } from '../../../lib/bounded-json';
import { createAdminClient } from '../../../lib/supabase/admin';
import { integrationAdmin, integrationWriteAllowed, isProvider, openCredential, sealCredential } from '../../../lib/integrations/credentials';
import { checkProvider, ProviderError, readSmartleadCategories, retryDelay } from '../../../lib/integrations/provider-api';
import { readSmartleadInboxPage } from '../../../lib/integrations/smartlead-inbox.mjs';
import { inboxConnectionCurrent } from '../../../lib/integrations/inbox-connection';

export const runtime = 'nodejs';
const reply = (body: unknown, status = 200, extra: Record<string, string> = {}) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store', ...extra } });
const storageError = () => reply({ error: 'Integration storage is unavailable. Check the migration and server configuration.' }, 503);
async function deliveryReady() {
  if(process.env.SMARTLEAD_DELIVERY_ENABLED!=='true' || !process.env.INTEGRATION_WORKER_HEALTH_URL)return false;
  try {return (await fetch(process.env.INTEGRATION_WORKER_HEALTH_URL,{cache:'no-store',signal:AbortSignal.timeout(2000)})).ok;} catch{return false;}
}

export async function GET() {
  try {
    const user = await getAuthorizedUser();
    if (!user) return reply({ error: 'Unauthorized' }, 401);
    const canManage = integrationAdmin(user.email, process.env.INTEGRATION_ADMIN_EMAILS);
    const db = createAdminClient();
    const { data, error } = await db.from('integration_connections').select('provider,connected,checked_at').order('provider').abortSignal(AbortSignal.timeout(5000));
    if (error) return storageError();
    let management = {};
    if (canManage) {
      const [catalog, clients, destinations, jobs, progress, inbox] = await Promise.all([
        db.from('integration_connections').select('campaigns,generation').eq('provider','smartlead').abortSignal(AbortSignal.timeout(5000)).single(),
        db.from('clients').select('id,name').order('name').limit(1001).abortSignal(AbortSignal.timeout(5000)),
        db.rpc('integration_destinations_v1').abortSignal(AbortSignal.timeout(5000)),
        db.rpc('integration_job_status_v1',{p_actor:user.id}).abortSignal(AbortSignal.timeout(5000)),
        db.rpc('smartlead_progress_v1',{p_actor:user.id}).abortSignal(AbortSignal.timeout(5000)),
        db.rpc('smartlead_inbox_status_v1').abortSignal(AbortSignal.timeout(5000)),
      ]);
      if (catalog.error || clients.error || destinations.error || jobs.error || progress.error || inbox.error) return storageError();
      if ((clients.data?.length ?? 0)>1000) return reply({ error: 'Integration client selector exceeds 1,000 clients. A paginated selector is required.' },503);
      const smartleadConnected = data?.some(connection => connection.provider === 'smartlead' && connection.connected) ?? false;
      const inboxSettings = inbox.data?.settings;
      management = { campaigns: catalog.data.campaigns, clients: clients.data, destinations: destinations.data, jobs:jobs.data, progress:progress.data,
        inbox: inbox.data ? { ...inbox.data, settings: { ...inboxSettings,
          connection_current: typeof inboxSettings?.connection_current === 'boolean' ? inboxSettings.connection_current
            : inboxConnectionCurrent(smartleadConnected, catalog.data.generation, inboxSettings?.verified_generation, inboxSettings?.verified_at),
        } } : null };
    }
    return reply({ connections: data, canManage, ...management, encryptionReady: /^[a-fA-F0-9]{64}$/.test(process.env.INTEGRATION_ENCRYPTION_KEY ?? ''), dispatchEnabled: canManage && await deliveryReady() });
  } catch { return storageError(); }
}

export async function POST(request: Request) {
  try {
    const user = await getAuthorizedUser();
    if (!user) return reply({ error: 'Unauthorized' }, 401);
    if (!integrationAdmin(user.email, process.env.INTEGRATION_ADMIN_EMAILS)) return reply({ error: 'An integration administrator is required.' }, 403);
    const publicUrl = process.env.APP_PUBLIC_URL
      || (process.env.NODE_ENV !== 'production' ? new URL(request.url).origin : undefined);
    if (!integrationWriteAllowed(request, publicUrl)) return reply({ error: 'Same-origin JSON requests are required.' }, 403);
    const decoded = await readBoundedJson(request, { bytes: 8192, depth: 4, timeoutMs: 5000 });
    if (decoded.response) return decoded.response;
    const payload = decoded.value as Record<string, unknown> | null;
    if (!payload || Array.isArray(payload) || !isProvider(payload.provider)
      || !['connect', 'check', 'disconnect', 'map', 'unmap', 'cancel', 'enqueue', 'create_campaign',
        'validate_inbox', 'enable_inbox', 'disable_inbox', 'sync_inbox', 'map_inbox', 'unmap_inbox'].includes(String(payload.action))) return reply({ error: 'Invalid connection request.' }, 400);
    const provider = payload.provider;
    const action = String(payload.action);
    const db = createAdminClient();
    if (['enable_inbox','disable_inbox','sync_inbox','map_inbox','unmap_inbox'].includes(action)) {
      if (provider !== 'smartlead') return reply({error:'Smartlead is required.'},400);
      if (action === 'enable_inbox' || action === 'disable_inbox') {
        const {data,error}=await db.rpc('set_smartlead_inbox_enabled_v1',{p_actor:user.id,p_enabled:action==='enable_inbox'}).abortSignal(AbortSignal.timeout(5000));
        return !error && data ? reply({saved:true}) : reply({error:action==='enable_inbox'?'Validate the current Smartlead inbox contract before enabling sync.':'Unable to pause inbox sync.'},409);
      }
      if (action === 'sync_inbox') {
        const {data,error}=await db.rpc('request_smartlead_inbox_sync_v1',{p_actor:user.id}).abortSignal(AbortSignal.timeout(5000));
        return !error && data ? reply({queued:true}) : reply({error:'Enable inbox sync and wait for any current page to finish.'},409);
      }
      if (typeof payload.prefix !== 'string' || !payload.prefix.trim() || payload.prefix.length>200
        || typeof payload.clientId !== 'string' || !payload.clientId || payload.clientId.length>200) return reply({error:'Choose a campaign prefix and client.'},400);
      const {data,error}=await db.rpc('set_smartlead_inbox_mapping_v1',{p_actor:user.id,p_prefix:payload.prefix,p_client:payload.clientId,p_enabled:action==='map_inbox'}).abortSignal(AbortSignal.timeout(5000));
      return !error && data ? reply({saved:true}) : reply({error:'Unable to save the inbox client mapping.'},409);
    }
    if (action === 'validate_inbox') {
      if (provider !== 'smartlead') return reply({error:'Smartlead is required.'},400);
      const key=process.env.INTEGRATION_ENCRYPTION_KEY ?? '';
      if(!/^[a-fA-F0-9]{64}$/.test(key))return reply({error:'The server encryption key must be configured.'},503);
      const {data:token,error:reserveError}=await db.rpc('reserve_integration_read_v1',{p_provider:'smartlead'}).abortSignal(AbortSignal.timeout(5000));
      if(reserveError)return storageError();
      if(!token)return reply({error:'Smartlead is busy or cooling down. Try again shortly.'},429,{'Retry-After':'15'});
      const {data,error}=await db.from('integration_connections').select('credential_ciphertext,connected,generation').eq('provider','smartlead').eq('attempt_token',token).abortSignal(AbortSignal.timeout(5000)).maybeSingle();
      if(error)return storageError();
      if(!data?.connected || !data.credential_ciphertext || !data.generation)return reply({error:'Connect Smartlead first.'},409);
      const secret=openCredential('smartlead',data.credential_ciphertext,key);
      const result=await readSmartleadInboxPage(0,secret,fetch,5);
      if(!result.ok){
        const status=typeof result.status==='number'?result.status:0;
        const retryAfter=result.retryAfter ? retryDelay(result.retryAfter) : 0;
        if(retryAfter>0)await db.from('integration_connections').update({next_request_at:new Date(Date.now()+Math.min(86400,Math.max(1,retryAfter))*1000).toISOString()}).eq('provider','smartlead').eq('attempt_token',token).abortSignal(AbortSignal.timeout(5000));
        return reply({error:[401,403].includes(status)?'Smartlead rejected the saved credential.':status===429?'Smartlead rate limit reached. Try again after the cooldown.':'Smartlead did not return a supported Master Inbox response.'},[401,403].includes(status)?422:status===429?429:502,retryAfter?{'Retry-After':String(retryAfter)}:{});
      }
      const page=result.page;
      if(!page)return reply({error:'Smartlead did not return a supported Master Inbox response.'},502);
      let categories;
      try { categories=await readSmartleadCategories(secret); }
      catch (error) {
        if (error instanceof ProviderError) return reply({error:error.message},error.status,error.retryAfter?{'Retry-After':String(error.retryAfter)}:{});
        throw error;
      }
      const {data:saved,error:savedError}=await db.rpc('confirm_smartlead_inbox_contract_v2',{
        p_actor:user.id,p_generation:data.generation,p_contract:page.contract,p_categories:categories,
      }).abortSignal(AbortSignal.timeout(5000));
      return !savedError && saved ? reply({validated:true,contract:page.contract,sampleCount:page.count}) : reply({error:'The Smartlead connection changed during validation. Retry.'},409);
    }
    if(action==='enqueue' || action==='create_campaign') {
      if(provider!=='smartlead' || payload.confirm!==true)return reply({error:'Explicit Smartlead confirmation is required.'},400);
      if(!await deliveryReady())return reply({error:'The delivery worker is unavailable. Please retry later.'},503);
      if(action==='enqueue') {
        if(typeof payload.jobId!=='string' || !/^[0-9a-f-]{36}$/i.test(payload.jobId) || typeof payload.allowActive!=='boolean')return reply({error:'Invalid delivery confirmation.'},400);
        const {data,error}=await db.rpc('enqueue_integration_job_v1',{p_actor:user.id,p_job:payload.jobId,p_allow_active:payload.allowActive}).abortSignal(AbortSignal.timeout(5000));
        return !error && data ? reply({queued:true}) : reply({error:'Cannot enqueue this draft. Check its destination and expiration, then prepare a new preview.'},409);
      }
      if(typeof payload.requestId!=='string' || !/^[0-9a-f-]{36}$/i.test(payload.requestId)
        || typeof payload.clientId!=='string' || !payload.clientId || payload.clientId.length>200
        || typeof payload.name!=='string' || !payload.name.trim() || payload.name.length>160)return reply({error:'Choose a client and a campaign name (1–160 characters).'},400);
      const {data,error}=await db.rpc('request_smartlead_campaign_v1',{p_actor:user.id,p_request:payload.requestId,p_client:payload.clientId,p_name:payload.name.trim()}).abortSignal(AbortSignal.timeout(5000));
      return !error ? reply({queued:true,creationId:data}) : reply({error:'Unable to queue campaign creation. Check the connection and existing requests before retrying.'},409);
    }
    if (action==='cancel') {
      if (typeof payload.jobId!=='string' || !/^[0-9a-f-]{36}$/i.test(payload.jobId)) return reply({error:'Invalid draft ID.'},400);
      const {data,error}=await db.rpc('cancel_integration_job_v1',{p_actor:user.id,p_job:payload.jobId}).abortSignal(AbortSignal.timeout(5000));
      return !error && data ? reply({cancelled:true}) : reply({error:'Draft is unavailable or already finished.'},409);
    }
    if (action === 'map' || action === 'unmap') {
      if (provider !== 'smartlead' || typeof payload.clientId !== 'string' || !payload.clientId || payload.clientId.length>200
        || typeof payload.campaignId !== 'number' || !Number.isSafeInteger(payload.campaignId) || payload.campaignId<1) return reply({error:'Choose a client and campaign.'},400);
      const {data,error} = await db.rpc('set_integration_destination_v1', {
        p_actor:user.id,p_client:payload.clientId,p_campaign:payload.campaignId,p_enabled:action==='map',
      }).abortSignal(AbortSignal.timeout(5000));
      if (error) return reply({error: error.code==='22023' ? 'Refresh campaigns and choose an unassigned campaign from this account. Remove another client’s mapping before reassigning.' : 'Unable to save the campaign destination.'}, error.code==='22023'?409:503);
      return data ? reply({saved:true}) : reply({error:'Destination changed. Reload connections.'},409);
    }
    if (action === 'disconnect') {
      if (provider==='smartlead') {
        const {data,error}=await db.rpc('disconnect_smartlead_connection_v1',{
          p_actor:user.id,p_new_generation:randomUUID(),
        }).abortSignal(AbortSignal.timeout(5000));
        return error ? storageError() : data ? reply({disconnected:true}) : reply({error:'Unable to disconnect Smartlead.'},409);
      }
      const { error } = await db.from('integration_connections').update({ credential_ciphertext: null, connected: false, checked_at: null, campaigns: [], generation: randomUUID(), updated_by: user.id, attempt_token: randomUUID() }).eq('provider', provider).abortSignal(AbortSignal.timeout(5000));
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
      if (provider==='smartlead' && action==='connect') {
        const categories=await readSmartleadCategories(secret);
        const {data,error}=await db.rpc('rotate_smartlead_connection_v1',{
          p_actor:user.id,p_attempt_token:token,p_ciphertext:sealCredential(provider,secret,key),
          p_campaigns:result.campaigns,p_categories:categories,p_new_generation:randomUUID(),
        }).abortSignal(AbortSignal.timeout(5000));
        if(error)return storageError();
        return data ? reply({connected:true,...result}) : reply({error:'The connection changed during this check. Reload its status.'},409);
      }
      const update = { connected: true, checked_at: new Date().toISOString(), updated_by: user.id,
        campaigns: result.campaigns,
        ...(action === 'connect' ? { credential_ciphertext: sealCredential(provider, secret, key), generation: randomUUID() } : {}) };
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
  } catch { return reply({ error: 'Unable to confirm this action. Check job history before retrying.' }, 503); }
}
