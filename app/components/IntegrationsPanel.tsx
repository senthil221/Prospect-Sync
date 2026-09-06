"use client";

import { useEffect, useRef, useState } from 'react';
import type { Campaign } from '../../lib/integrations/provider-api';
import type { Provider } from '../../lib/integrations/credentials';

type Connection = { provider: Provider; connected: boolean; checked_at: string | null };
type Destination = { client_id: string; campaign_id: number; campaign_name: string; connection_current: boolean };
type Status = { connections: Connection[]; canManage: boolean; encryptionReady: boolean;dispatchEnabled:boolean;
  campaigns?: Campaign[]; clients?: {id:string;name:string}[]; destinations?: Destination[];
  jobs?: {id:string;client_id:string;campaign_id:number;status:string;total:number;created_at:string}[];
  progress?: {creations:{id:string;name:string;status:string;campaign_id:number|null;error_code:string|null}[];
    deliveries:{id:string;status:string;added:number;skipped:number;suppressed:number;error_code:string|null}[]} };

async function readStatus(signal?: AbortSignal): Promise<Status> {
  const response = await fetch('/api/integrations', { cache: 'no-store', signal });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error ?? 'Unable to load connections.');
  return body;
}

export default function IntegrationsPanel() {
  const [status, setStatus] = useState<Status | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState<Provider | null>(null);
  const [filter, setFilter] = useState('');
  const [clientId, setClientId] = useState('');
  const [campaignId, setCampaignId] = useState('');
  const [newName,setNewName]=useState('');
  const [progressWarning,setProgressWarning]=useState('');
  const createRequest=useRef<string|null>(null);

  async function refresh(signal?: AbortSignal) {
    setStatus(await readStatus(signal));
  }
  useEffect(() => {
    const controller = new AbortController();
    void readStatus(controller.signal).then(setStatus).catch(e => { if (!controller.signal.aborted) setError(e.message); });
    return () => controller.abort();
  }, []);
  const pending=!!status?.jobs?.some(j=>['queued','running'].includes(j.status)) || !!status?.progress?.creations.some(j=>['queued','sending'].includes(j.status));
  useEffect(()=>{
    if(!pending)return;
    const controller=new AbortController();
    let timer:ReturnType<typeof setTimeout>;
    const poll=async()=>{try{setStatus(await readStatus(controller.signal));setProgressWarning('');}catch{if(!controller.signal.aborted)setProgressWarning('Progress refresh failed. The worker may still be running; use Refresh progress to check again.');}finally{if(!controller.signal.aborted)timer=setTimeout(poll,5000);}};
    timer=setTimeout(poll,5000);
    return ()=>{clearTimeout(timer);controller.abort();};
  },[pending]);

  async function act(provider: Provider, action: string, secret?: string, destination?: {clientId?:string;campaignId?:number;jobId?:string;requestId?:string;name?:string;confirm?:boolean;allowActive?:boolean}) {
    setBusy(provider); setError(''); setNotice('');
    try {
      const response = await fetch('/api/integrations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ provider, action, ...destination, ...(secret ? { secret } : {}) }), signal: AbortSignal.timeout(25000) });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? 'Connection check failed.');
      setNotice(action === 'disconnect' ? 'Credential removed. No campaign or verifier data was deleted.'
        : action === 'map' ? 'Client destination saved. No leads were sent.'
        : action === 'unmap' ? 'Client destination removed. No campaign or leads were deleted.'
        : action === 'cancel' ? 'Future batches cancelled. Already uploaded leads are not removed; in-flight work may finish.'
        : action === 'create_campaign' ? 'Campaign creation queued. It will be created as a draft and mapped to the chosen client.'
        : action === 'enqueue' ? 'Delivery queued. Follow progress below; closing the browser does not stop it.'
        : 'Connection checked successfully. No leads were sent.');
      await refresh();
    } catch (e) { setError(e instanceof Error ? e.message : 'Connection check failed.'); }
    finally { setBusy(null); }
  }
  const campaigns = status?.campaigns ?? [];
  const filtered = campaigns.filter(c => `${c.name} ${c.id}`.toLowerCase().includes(filter.toLowerCase()));
  const visible = filtered.slice(0, 100);
  return <div className="integrations-workspace">
    <header className="section-heading"><div><p className="eyebrow">CONNECTED WORKFLOW</p><h2>Integrations</h2><p>One agency connection. Explicit client destinations. No spreadsheet handoffs.</p></div></header>
    {error && <p role="alert">{error} <button onClick={() => { setError(''); void refresh().catch(e => setError(e.message)); }}>Reload connections</button></p>}
    {notice && <p role="status">{notice}</p>}
    {progressWarning && <p role="status">{progressWarning}</p>}
    {!status && !error && <p role="status">Loading connections…</p>}
    {status && !status.canManage && <p>Only a configured integration administrator can change credentials or check campaigns.</p>}
    {status && !status.encryptionReady && <p role="status">Setup required: configure the server encryption key before saving credentials.</p>}
    <div className="integration-cards">{(['smartlead', 'verifier'] as const).map(provider => {
      const connection = status?.connections.find(c => c.provider === provider);
      return <section className="panel integration-card" key={provider} aria-labelledby={`${provider}-title`}>
        <h3 id={`${provider}-title`}>{provider === 'smartlead' ? 'Smartlead' : 'No2Ninja Verifier'}</h3>
        <p>{connection?.connected ? 'Credential saved' : 'Not connected'}</p>
        <p>{provider === 'smartlead' ? 'Connect your agency account to discover campaigns. Campaign destinations will be mapped to each client.' : 'Connect the service API on app.betterlanebase.link. Your verification engine stays on its own VPS.'}</p>
        {connection?.checked_at && <p>Last successful check: {new Date(connection.checked_at).toLocaleString()}</p>}
        {status?.canManage && <form onSubmit={event => {
          event.preventDefault();
          const form = event.currentTarget;
          const secret = String(new FormData(form).get('secret') ?? '');
          form.reset();
          void act(provider, 'connect', secret);
        }}>
          <label htmlFor={`${provider}-key`}>{connection?.connected ? 'Replacement API key' : 'API key'}</label>
          <input id={`${provider}-key`} name="secret" type="password" autoComplete="off" spellCheck={false} required minLength={16} maxLength={2048} disabled={!!busy || !status.encryptionReady}/>
          <p>Encrypted on the server. Never displayed after saving.</p>
          <button className="primary" disabled={!!busy || !status.encryptionReady}>{busy === provider ? 'Checking…' : 'Test and save connection'}</button>
        </form>}
        {status?.canManage && connection?.connected && <div className="integration-actions">
          <button disabled={!!busy} onClick={() => void act(provider, 'check')}>{provider === 'smartlead' ? 'Check and load campaigns' : 'Check connection'}</button>
          <button disabled={!!busy} onClick={() => { if (window.confirm('Remove this saved credential? No provider data will be deleted.')) void act(provider, 'disconnect'); }}>Disconnect</button>
        </div>}
      </section>;
    })}</div>
    {campaigns.length > 0 && <section className="panel integration-card"><h3>Smartlead campaigns · read only</h3>
      <label htmlFor="campaign-search">Find a campaign</label><input id="campaign-search" value={filter} onChange={e => setFilter(e.target.value)}/>
      <p>Showing {visible.length} of {campaigns.length} campaigns. Campaigns are never automatically started.</p>
      <ul>{visible.map(c => <li key={c.id}>{c.name} — {c.status} · Campaign {c.id}{c.clientId ? ` · Smartlead client ${c.clientId}` : ''}</li>)}</ul>
    </section>}
    {status?.canManage && <section className="panel integration-card"><h3>Client campaign destinations</h3>
      <p>A campaign belongs to one Prospect Sync client. Each client can have multiple campaigns. Replacing the agency key requires re-approving destinations.</p>
      <form onSubmit={event => { event.preventDefault(); void act('smartlead','map',undefined,{clientId,campaignId:Number(campaignId)}); }}>
        <label htmlFor="destination-client">Prospect Sync client</label>
        <select id="destination-client" value={clientId} onChange={e=>{setClientId(e.target.value);createRequest.current=null;}} required disabled={!!busy}>
          <option value="">Choose client</option>{status.clients?.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <label htmlFor="destination-campaign">Smartlead campaign</label>
        <select id="destination-campaign" value={campaignId} onChange={e=>setCampaignId(e.target.value)} required disabled={!!busy}>
          <option value="">Choose campaign</option>{visible.map(c=><option key={c.id} value={c.id}>{c.name} · {c.status} · {c.id}</option>)}
        </select>
        <p>Use “Find a campaign” above to narrow the choices. Refresh with “Check and load campaigns” if the last check was over 15 minutes ago.</p>
        <button className="primary" disabled={!!busy || !clientId || !campaignId}>Save destination</button>
      </form>
      {!status.destinations?.length && <p>No destinations mapped yet.</p>}
      <ul>{status.destinations?.map(d=><li key={d.campaign_id}>
        {status.clients?.find(c=>c.id===d.client_id)?.name ?? d.client_id} → {d.campaign_name} · {d.campaign_id}
        {!d.connection_current && <strong> · Re-approval required after connection change</strong>}{' '}
        <button disabled={!!busy} onClick={()=>void act('smartlead','unmap',undefined,{clientId:d.client_id,campaignId:d.campaign_id})}>Remove destination</button>
      </li>)}</ul>
    </section>}
    {status?.canManage && <section className="panel integration-card"><h3>Create a Smartlead draft campaign</h3>
      <p>Select the Prospect Sync client above. Sending accounts, sequences and schedules can be configured in Smartlead; this action never launches a campaign.</p>
      <form onSubmit={e=>{e.preventDefault();createRequest.current ??= crypto.randomUUID();void act('smartlead','create_campaign',undefined,{clientId,name:newName,requestId:createRequest.current,confirm:true});}}>
        <label htmlFor="new-campaign-name">Campaign name</label><input id="new-campaign-name" value={newName} required maxLength={160} disabled={!!busy} onChange={e=>{setNewName(e.target.value);createRequest.current=null;}}/>
        <p>Client: {status.clients?.find(c=>c.id===clientId)?.name ?? 'Choose a client above'}</p>
        <button className="primary" disabled={!!busy || !clientId || !newName.trim() || !status.dispatchEnabled}>Create draft campaign</button>
      </form>
      <ul>{status.progress?.creations.map(c=><li key={c.id}>{c.name} · {c.status}{c.campaign_id?` · Campaign ${c.campaign_id}`:''}{c.error_code?` · ${c.error_code}`:''}</li>)}</ul>
      <p>If creation needs review, check Smartlead before creating another campaign—the first request may have succeeded.</p>
    </section>}
    {status?.canManage && <section className="panel integration-card"><h3>Your Smartlead deliveries</h3>
      <button disabled={!!busy} onClick={()=>void refresh().catch(e=>setError(e.message))}>Refresh progress</button>
      <p>Choose up to 400 checked people, then “Preview Smartlead delivery” to map fields and freeze a draft.</p>
      {!status.jobs?.length && <p>No drafts yet.</p>}
      <ul>{status.jobs?.map(j=>{const progress=status.progress?.deliveries.find(d=>d.id===j.id);return <li key={j.id}>{status.clients?.find(c=>c.id===j.client_id)?.name ?? j.client_id} · Campaign {j.campaign_id} · {j.total} leads · {j.status}{' '}
        {progress && <span> · Added {progress.added} · Skipped {progress.skipped} · Suppressed before upload {progress.suppressed}{progress.error_code?` · ${progress.error_code}`:''}</span>}{' '}
        {j.status==='draft' && <button disabled={!!busy || !status.dispatchEnabled} onClick={()=>{if(window.confirm(`Transfer this frozen draft of ${j.total} leads to campaign ${j.campaign_id}? Only draft, paused or stopped campaigns are allowed from this screen.`))void act('smartlead','enqueue',undefined,{jobId:j.id,confirm:true,allowActive:false});}}>Push saved draft</button>}{' '}
        {['draft','queued','running'].includes(j.status) && <button disabled={!!busy} onClick={()=>void act('smartlead','cancel',undefined,{jobId:j.id})}>Cancel future batches</button>}
        {' '}<a href={`/api/integrations/report?jobId=${encodeURIComponent(j.id)}`}>Download outcome report</a>
      </li>;})}</ul>
      <p>Needs review means no automatic replay. Check campaign membership in Smartlead before preparing another upload. Invalid credentials pause delivery until reconnected. Completed and cancelled job reports are retained for 30 days; unresolved jobs remain available.</p>
    </section>}
    <section className="panel integration-card"><h3>{status?.dispatchEnabled?'Smartlead delivery is available':'Smartlead delivery worker unavailable'}</h3><p>Direct Smartlead delivery is separate from email verification. Verifier delivery remains disabled. No verification credits are spent.</p></section>
  </div>;
}
