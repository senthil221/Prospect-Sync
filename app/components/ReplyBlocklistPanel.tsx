"use client";

import { useEffect, useRef, useState } from 'react';
import { AppIcon } from './DashboardUi';
import { readIntegrationStatus, type IntegrationStatus } from './integration-status';
import ReplyBlocksSummary from './ReplyBlocksSummary';
import { Select } from "./ListboxPicker";

type InboxAction = 'connect' | 'check' | 'disconnect' | 'validate_inbox' | 'enable_inbox' | 'disable_inbox' | 'sync_inbox' | 'map_inbox' | 'unmap_inbox';

const actionNotices: Record<InboxAction, string> = {
  connect: 'Smartlead API key saved. Reply sync is paused until this account is validated.',
  check: 'Smartlead connection checked and campaigns refreshed.',
  disconnect: 'Smartlead disconnected. Existing client blocklist entries were kept.',
  validate_inbox: 'Master Inbox connection validated. You can now enable the sync.',
  enable_inbox: 'Sync enabled. Historical replies will be processed in the background.',
  disable_inbox: 'Sync paused. Existing blocklist entries are unchanged.',
  sync_inbox: 'A full reply reconciliation was queued.',
  map_inbox: 'Campaign prefix saved. A new reconciliation was queued.',
  unmap_inbox: 'Mapping removed. Existing blocklist entries are unchanged.',
};

function timeLabel(value: string | null) {
  return value ? new Date(value).toLocaleString() : 'Not yet';
}

function plainStatus(value: string) {
  return value.replaceAll('_', ' ');
}

export default function ReplyBlocklistPanel() {
  const [status, setStatus] = useState<IntegrationStatus | null>(null);
  const [error, setError] = useState('');
  const [warning, setWarning] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState<InboxAction | 'refresh' | null>(null);
  const [prefix, setPrefix] = useState('');
  const [clientId, setClientId] = useState('');
  const [search, setSearch] = useState('');
  const [showAll, setShowAll] = useState(false);
  const [showKeyForm, setShowKeyForm] = useState(false);
  const [apiKey, setApiKey] = useState('');
  const prefixInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const controller = new AbortController();
    void readIntegrationStatus(controller.signal).then(setStatus).catch(e => {
      if (!controller.signal.aborted) setError(e instanceof Error ? e.message : 'Unable to load reply sync.');
    });
    return () => controller.abort();
  }, []);

  const enabled = status?.inbox?.settings.enabled;
  useEffect(() => {
    if (!enabled) return;
    const controller = new AbortController();
    let inFlight = false;
    const timer = setInterval(() => {
      if (inFlight) return;
      inFlight = true;
      void readIntegrationStatus(controller.signal).then(next => {
        setStatus(next);
        setWarning('');
      }).catch(() => {
        if (!controller.signal.aborted) setWarning('Live refresh is delayed. Use Refresh to check the latest state.');
      }).finally(() => { inFlight = false; });
    }, 10000);
    return () => { clearInterval(timer); controller.abort(); };
  }, [enabled]);

  async function refresh() {
    setBusy('refresh');
    setError('');
    try {
      setStatus(await readIntegrationStatus());
      setWarning('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Unable to refresh reply sync.');
    } finally {
      setBusy(null);
    }
  }

  async function act(action: InboxAction, options?: { prefix?: string; clientId?: string; secret?: string }) {
    setBusy(action);
    setError('');
    setNotice('');
    try {
      const response = await fetch('/api/integrations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ provider: 'smartlead', action, ...options }),
        signal: AbortSignal.timeout(25000),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? 'Action failed.');
      setStatus(await readIntegrationStatus());
      setNotice(actionNotices[action]);
      if (action === 'map_inbox') { setPrefix(''); setClientId(''); }
      if (action === 'connect') { setApiKey(''); setShowKeyForm(false); }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Action failed.');
    } finally {
      setBusy(null);
    }
  }

  const inbox = status?.inbox;
  const smartleadConnected = status?.connections.some(connection => connection.provider === 'smartlead' && connection.connected);
  const review = inbox?.unmatched ?? [];
  const filtered = review.filter(item => `${item.campaign_name} ${plainStatus(item.mapping_status)}`.toLowerCase().includes(search.toLowerCase()));
  const visible = showAll ? filtered : filtered.slice(0, 12);

  return <div className="reply-blocklist-workspace">
    <header className="reply-blocklist-header">
      <div><p className="eyebrow">SMARTLEAD · MASTER INBOX</p><h2>Reply blocklist</h2>
        <p>Route tagged replies to the right client blocklist. Campaigns that cannot be matched stay here for review.</p></div>
      <button type="button" className="reply-blocklist-refresh" onClick={() => void refresh()} disabled={!!busy}>
        <AppIcon name="refresh" size={16}/> {busy === 'refresh' ? 'Refreshing…' : 'Refresh'}
      </button>
    </header>

    {error && <div className="reply-blocklist-message is-error" role="alert">{error} <button type="button" onClick={() => void refresh()}>Try again</button></div>}
    {warning && <div className="reply-blocklist-message" role="status">{warning}</div>}
    {notice && <div className="reply-blocklist-message is-success" role="status">{notice}</div>}
    {!status && !error && <section className="panel reply-blocklist-empty" role="status">Loading reply sync…</section>}
    {status && !status.canManage && <section className="panel reply-blocklist-empty"><h3>Administrator access needed</h3><p>Only a configured integration administrator can view and manage reply sync.</p></section>}
    {status?.canManage && !inbox && <section className="panel reply-blocklist-empty"><h3>Reply sync is unavailable</h3><p>Check the Smartlead integration configuration, then refresh this page.</p></section>}

    {status?.canManage && inbox && <>
      <section className="panel reply-blocklist-connection" aria-labelledby="smartlead-connection-heading">
        <div className="reply-blocklist-connection-copy">
          <div className="reply-blocklist-status-row">
            <span className={`reply-blocklist-state ${smartleadConnected ? 'is-on' : 'is-off'}`}><span aria-hidden="true"/>{smartleadConnected ? 'Connected' : 'Not connected'}</span>
            {smartleadConnected && <span className="reply-blocklist-status-detail">API key stored securely</span>}
          </div>
          <h3 id="smartlead-connection-heading">Smartlead account</h3>
          <p>Use the API key from Smartlead Settings. Browser JWTs are not supported or stored.</p>
          {smartleadConnected && <p className="reply-blocklist-connection-checks">
            <span>{inbox.settings.category_ready ? 'Category rules ready' : 'Category rules need review'}</span>
            <span>{inbox.settings.connection_current ? 'Inbox validated' : 'Inbox validation required'}</span>
          </p>}
        </div>
        <div className="reply-blocklist-connection-actions">
          {(!smartleadConnected || showKeyForm) && <form onSubmit={event => { event.preventDefault(); void act('connect', { secret: apiKey }); }}>
            <label htmlFor="smartlead-reply-key">{smartleadConnected ? 'Replacement API key' : 'Smartlead API key'}</label>
            <div><input id="smartlead-reply-key" type="password" autoComplete="off" spellCheck={false} minLength={16} maxLength={2048}
              value={apiKey} onChange={event => setApiKey(event.target.value)} required disabled={!!busy || !status.encryptionReady}
              placeholder="Paste API key"/><button type="submit" className="primary" disabled={!!busy || !status.encryptionReady || apiKey.length<16}>{busy === 'connect' ? 'Testing…' : 'Test & save'}</button></div>
            {smartleadConnected && <button type="button" className="reply-blocklist-text-action" disabled={!!busy} onClick={() => { setApiKey(''); setShowKeyForm(false); }}>Cancel</button>}
          </form>}
          {smartleadConnected && !showKeyForm && <div className="reply-blocklist-connection-buttons">
            <button type="button" className="primary" disabled={!!busy} onClick={() => setShowKeyForm(true)}>Change API key</button>
            <button type="button" disabled={!!busy} onClick={() => void act('check')}>{busy === 'check' ? 'Checking…' : 'Refresh campaigns'}</button>
            <button type="button" disabled={!!busy} onClick={() => { if (window.confirm('Disconnect Smartlead? Reply sync will stop, but existing blocklist entries will stay.')) void act('disconnect'); }}>Disconnect</button>
          </div>}
        </div>
      </section>

      <section className="panel reply-blocklist-overview" aria-label="Reply sync overview">
        <div className="reply-blocklist-overview-main">
          <div className="reply-blocklist-status-row"><span className={`reply-blocklist-state ${inbox.settings.enabled ? 'is-on' : 'is-off'}`}><span aria-hidden="true"/>{inbox.settings.enabled ? 'Sync on' : 'Sync paused'}</span><span className="reply-blocklist-status-detail">{plainStatus(inbox.settings.status)}</span></div>
          <h3>{inbox.settings.enabled ? 'Replies are being monitored' : 'Reply monitoring is paused'}</h3>
          <p>Last successful page: {timeLabel(inbox.settings.last_synced_at)}<span aria-hidden="true"> · </span>{inbox.settings.initial_backfill_complete ? 'Historical scan complete' : !inbox.settings.last_synced_at && !inbox.settings.enabled ? 'Ready for first scan' : inbox.settings.enabled ? 'Historical scan in progress' : 'Historical scan paused'}</p>
          {inbox.settings.last_error_code && <p className="reply-blocklist-inline-alert" role="status">Needs attention: {plainStatus(inbox.settings.last_error_code)}</p>}
        </div>
        <div className="reply-blocklist-overview-actions">
          {!inbox.settings.connection_current && <button type="button" onClick={() => void act('validate_inbox')} disabled={!!busy || !smartleadConnected}>{inbox.settings.verified_at ? 'Revalidate inbox' : 'Validate inbox'}</button>}
          {inbox.settings.enabled
            ? <button type="button" onClick={() => void act('disable_inbox')} disabled={!!busy}>{busy === 'disable_inbox' ? 'Pausing…' : 'Pause sync'}</button>
            : <button type="button" className="primary" onClick={() => void act('enable_inbox')} disabled={!!busy || !inbox.settings.connection_current}>{busy === 'enable_inbox' ? 'Enabling…' : 'Enable sync'}</button>}
        </div>
      </section>

      {!status.encryptionReady && <div className="reply-blocklist-message" role="status">Server encryption is not configured, so API keys cannot be saved yet.</div>}
      {smartleadConnected && !inbox.settings.connection_current && !!inbox.settings.verified_at && <div className="reply-blocklist-message" role="status">The Smartlead key changed. Revalidate the new account before enabling reply sync.</div>}
      {smartleadConnected && !inbox.settings.connection_current && !inbox.settings.verified_at && <div className="reply-blocklist-message" role="status">Validate this Smartlead account before enabling reply sync. Old-account inbox data is retained separately and is not shown here.</div>}

      <section className="reply-blocklist-metrics" aria-label="Reply sync totals">
        <div className="panel"><span>Replies observed</span><strong>{inbox.counts.observed.toLocaleString()}</strong><small>Tagged inbox replies seen</small></div>
        <div className="panel"><span>Block actions applied</span><strong>{inbox.counts.applied.toLocaleString()}</strong><small>Client blocklist additions</small></div>
        <div className="panel"><span>Pending actions</span><strong>{inbox.counts.pending.toLocaleString()}</strong><small>Waiting to be processed</small></div>
        <div className="panel is-review"><span>Needs review</span><strong>{inbox.counts.unmatched.toLocaleString()}</strong><small>Replies without a client match</small></div>
      </section>

      {/* What those block actions were: per client, per reason, and the log. */}
      <ReplyBlocksSummary refreshKey={inbox.counts.applied}/>

      <div className="reply-blocklist-main-grid">
        <section className="panel reply-blocklist-review" aria-labelledby="reply-review-heading">
          <div className="reply-blocklist-section-head"><div><p className="eyebrow">ACTION QUEUE</p><h3 id="reply-review-heading">Campaigns needing review</h3><p>Map an unmatched campaign to a client so its tagged replies can be processed.</p></div>{review.length > 0 && <span className="reply-blocklist-count">{review.length} shown by API</span>}</div>
          {review.length > 0 && <label className="reply-blocklist-search"><AppIcon name="search" size={17}/><span className="sr-only">Search campaigns needing review</span><input value={search} onChange={e => { setSearch(e.target.value); setShowAll(false); }} placeholder="Search campaign names"/></label>}
          {review.length === 0 ? <div className="reply-blocklist-quiet"><AppIcon name="check" size={20}/><div><strong>Nothing to review right now</strong><p>New unmatched campaigns will appear here after a scan.</p></div></div>
            : visible.length === 0 ? <p className="reply-blocklist-no-results">No campaigns match your search.</p>
            : <ul className="reply-blocklist-review-list">{visible.map(item => <li key={`${item.campaign_name}:${item.mapping_status}`}>
              <div><strong>{item.campaign_name}</strong><span>{plainStatus(item.mapping_status)} · {item.replies.toLocaleString()} {item.replies === 1 ? 'reply' : 'replies'}</span></div>
              {item.mapping_status === 'unmatched' && <button type="button" onClick={() => { setPrefix(item.campaign_name); prefixInput.current?.focus(); }}>Map client <AppIcon name="arrow" size={14}/></button>}
            </li>)}</ul>}
          {filtered.length > visible.length && <button type="button" className="reply-blocklist-show-more" onClick={() => setShowAll(true)}>Show all {filtered.length} returned campaigns</button>}
          {inbox.counts.unmatched > review.length && <p className="reply-blocklist-bounded-note">Showing a bounded sample. Counts include all unmatched replies; use a more specific campaign prefix to map additional campaigns.</p>}
        </section>

        <div className="reply-blocklist-side">
          <section className="panel reply-blocklist-mapper" aria-labelledby="reply-map-heading">
            <p className="eyebrow">ROUTING</p><h3 id="reply-map-heading">Map a campaign prefix</h3>
            <p>Exact client names at the start of a campaign match automatically. Add a prefix only when a campaign is unmatched.</p>
            <form onSubmit={event => { event.preventDefault(); void act('map_inbox', { prefix: prefix.trim(), clientId }); }}>
              <label htmlFor="reply-prefix">Campaign prefix</label><input id="reply-prefix" ref={prefixInput} value={prefix} onChange={e => setPrefix(e.target.value)} maxLength={200} required disabled={!!busy} placeholder="e.g. Acme |"/>
              <label htmlFor="reply-client">Route to client</label><Select id="reply-client" value={clientId} onChange={e => setClientId(e.target.value)} required disabled={!!busy}><option value="">Select a client</option>{status.clients?.map(client => <option value={client.id} key={client.id}>{client.name}</option>)}</Select>
              <button type="submit" className="primary" disabled={!!busy || !prefix.trim() || !clientId}>{busy === 'map_inbox' ? 'Saving…' : 'Save mapping'}</button>
            </form>
            <p className="reply-blocklist-form-note">Saving a mapping queues a fresh reconciliation. No campaign is changed in Smartlead.</p>
          </section>
          <section className="panel reply-blocklist-mappings" aria-labelledby="reply-saved-heading"><div className="reply-blocklist-section-head"><div><p className="eyebrow">SAVED RULES</p><h3 id="reply-saved-heading">Prefix mappings</h3></div><span className="reply-blocklist-count">{inbox.mappings.length}</span></div>
            {inbox.mappings.length === 0 ? <p>No manual mappings yet. Exact client-name matches still work automatically.</p> : <ul>{inbox.mappings.map(mapping => <li key={mapping.prefix}><div><strong>{mapping.prefix}</strong><span>→ {mapping.client_name}</span></div><button type="button" disabled={!!busy} aria-label={`Remove mapping ${mapping.prefix}`} onClick={() => { if (window.confirm(`Remove the mapping for “${mapping.prefix}”? Existing blocklist entries will stay.`)) void act('unmap_inbox', { prefix: mapping.prefix, clientId: mapping.client_id }); }}>Remove</button></li>)}</ul>}
          </section>
        </div>
      </div>

      <details className="panel reply-blocklist-details"><summary>Sync details and rules <AppIcon name="chevron" size={16}/></summary><div className="reply-blocklist-details-content">
        <div><h3>Reconciliation</h3><p>{inbox.settings.rows_observed.toLocaleString()} observations across {inbox.settings.pages_scanned.toLocaleString()} pages. {inbox.settings.initial_backfill_complete ? 'Historical scan complete.' : 'Historical scan still in progress.'}</p><button type="button" onClick={() => void act('sync_inbox')} disabled={!!busy || !inbox.settings.enabled || inbox.settings.status === 'running'}>Reconcile all replies now</button></div>
        <div><h3>Blocking rules</h3><p>All assigned categories except Out of Office add the reply email to its matched client blocklist. “Not the right fit” also adds the domain. Category IDs are discovered from the connected account and sync cannot start when these names are uncertain.</p><p>{inbox.counts.manualRemoved.toLocaleString()} manually removed Smartlead entries will remain removed. Changing a reply to Out of Office does not undo an earlier block.</p></div>
      </div></details>
    </>}
  </div>;
}
