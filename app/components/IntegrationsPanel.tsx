"use client";

import { useEffect, useState } from 'react';
import type { Campaign } from '../../lib/integrations/provider-api';
import type { Provider } from '../../lib/integrations/credentials';

type Connection = { provider: Provider; connected: boolean; checked_at: string | null };
type Status = { connections: Connection[]; canManage: boolean; encryptionReady: boolean };

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
  const [campaigns, setCampaigns] = useState<Campaign[]>([]);
  const [filter, setFilter] = useState('');

  async function refresh(signal?: AbortSignal) {
    setStatus(await readStatus(signal));
  }
  useEffect(() => {
    const controller = new AbortController();
    void readStatus(controller.signal).then(setStatus).catch(e => { if (!controller.signal.aborted) setError(e.message); });
    return () => controller.abort();
  }, []);

  async function act(provider: Provider, action: string, secret?: string) {
    setBusy(provider); setError(''); setNotice('');
    try {
      const response = await fetch('/api/integrations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ provider, action, ...(secret ? { secret } : {}) }), signal: AbortSignal.timeout(25000) });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? 'Connection check failed.');
      if (provider === 'smartlead') setCampaigns(body.campaigns ?? []);
      setNotice(action === 'disconnect' ? 'Credential removed. No campaign or verifier data was deleted.' : 'Connection checked successfully. No leads were sent.');
      await refresh();
    } catch (e) { setError(e instanceof Error ? e.message : 'Connection check failed.'); }
    finally { setBusy(null); }
  }
  const visible = campaigns.filter(c => c.name.toLowerCase().includes(filter.toLowerCase())).slice(0, 100);
  return <div className="integrations-workspace">
    <header className="section-heading"><div><p className="eyebrow">CONNECTED WORKFLOW</p><h2>Integrations</h2><p>One agency connection. Explicit client destinations. No spreadsheet handoffs.</p></div></header>
    {error && <p role="alert">{error} <button onClick={() => { setError(''); void refresh().catch(e => setError(e.message)); }}>Reload connections</button></p>}
    {notice && <p role="status">{notice}</p>}
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
      <p>Showing {visible.length} of {campaigns.length} campaigns. This screen cannot start campaigns or upload leads.</p>
      <ul>{visible.map(c => <li key={c.id}>{c.name} — {c.status} · Campaign {c.id}{c.clientId ? ` · Smartlead client ${c.clientId}` : ''}</li>)}</ul>
    </section>}
    <section className="panel integration-card"><h3>Lead delivery is not enabled yet</h3><p>Client mapping, selection preview, verification and resumable delivery are the next build stage. Connecting an account here does not send leads or spend verification credits.</p></section>
  </div>;
}
