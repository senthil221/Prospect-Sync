"use client";
import { useEffect, useRef, useState } from 'react';
import { useDialogFocus } from './use-dialog';
type Mapping={source:string;target:string};
type Dest={client_id:string;campaign_id:number;campaign_name:string;connection_current:boolean};
type Options={canManage:boolean;clients:{id:string;name:string}[];destinations:Dest[]};
type Preview={jobId:string|null;counts:{selected:number;eligible:number;suppressed:number;invalid:number;duplicates:number};sample:Record<string,unknown>[]};
const canonical=['first_name','last_name','work_email','personal_email','company_name','website','phone_number','location','linkedin_profile','title'];
export default function IntegrationPreview({ids,clientId,fields,onClose}:{ids:string[];clientId:string;fields:string[];onClose:()=>void}) {
  const dialog=useRef<HTMLElement>(null);
  const requestId=useRef<string | null>(null);
  const [options,setOptions]=useState<Options|null>(null);
  const [client,setClient]=useState(clientId);
  const [campaign,setCampaign]=useState('');
  const [mapping,setMapping]=useState<Mapping[]>([{source:'work_email',target:'email'}, {source:'first_name',target:'first_name'},
    {source:'last_name',target:'last_name'}, {source:'company_name',target:'company_name'}, {source:'title',target:'custom:job_title'}]);
  const [preview,setPreview]=useState<Preview|null>(null);
  const [error,setError]=useState('');
  const [busy,setBusy]=useState(false);
  useDialogFocus(dialog,{onClose,busy});
  useEffect(()=>{
    const controller=new AbortController();
    void fetch('/api/integrations',{signal:controller.signal,cache:'no-store'}).then(async r=>{
      const body=await r.json(); if(!r.ok) throw new Error(body.error); return body;
    }).then(setOptions).catch(e=>{if(!controller.signal.aborted)setError(e.message);});
    return ()=>controller.abort();
  },[]);
  function changed() {requestId.current=null;setPreview(null);setError('');}
  async function prepare() {
    setBusy(true);setError('');requestId.current ??= crypto.randomUUID();
    try {
      const r=await fetch('/api/integrations/preview',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({prospectIds:ids,clientId:client,campaignId:Number(campaign),mapping,requestId:requestId.current}),signal:AbortSignal.timeout(30000)});
      const body=await r.json();if(!r.ok)throw new Error(body.error);setPreview(body);
    }catch(e){setError(e instanceof Error?e.message:'Preview failed.');}finally{setBusy(false);}
  }
  const sources=[...canonical,...fields.map(f=>`raw:${f}`)];
  const destinations=options?.destinations?.filter(d=>d.client_id===client && d.connection_current) ?? [];
  return <div className="modal-backdrop" role="presentation"><section ref={dialog} className="confirm-modal integration-preview" role="dialog" aria-modal="true" aria-labelledby="integration-preview-title">
    <h2 id="integration-preview-title">Smartlead selection preview</h2>
    <p>{ids.length} explicitly selected prospects. This step saves a draft; it does not upload leads or start a campaign.</p>
    {error && <p role="alert">{error}</p>}
    {!options && !error && <p role="status">Loading destinations…</p>}
    {options && !options.canManage && <p>An integration administrator must prepare deliveries in this release.</p>}
    {options?.canManage && <>
      <label htmlFor="preview-client">Destination client</label><select id="preview-client" value={client} disabled={busy} onChange={e=>{changed();setClient(e.target.value);setCampaign('');}}>
        <option value="">Choose client</option>{options.clients.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}
      </select>
      <label htmlFor="preview-campaign">Approved campaign</label><select id="preview-campaign" value={campaign} disabled={busy} onChange={e=>{changed();setCampaign(e.target.value);}}>
        <option value="">Choose campaign</option>{destinations.map(d=><option key={d.campaign_id} value={d.campaign_id}>{d.campaign_name} · {d.campaign_id}</option>)}
      </select>
      {client && !destinations.length && <p>Map a campaign to this client in Integrations first.</p>}
      <h3>Column mapping</h3><p>Use “custom:field_name” for personalization. Duplicate emails use the first prospect by stable ID; linked IDs remain in the private draft.</p>
      {mapping.map((m,i)=><div className="integration-mapping-row" key={i}>
        <select aria-label={`Source column ${i+1}`} value={m.source} disabled={busy} onChange={e=>{changed();setMapping(mapping.map((x,n)=>n===i?{...x,source:e.target.value}:x));}}>
          {sources.map(s=><option key={s} value={s}>{s.startsWith('raw:')?`Imported: ${s.slice(4)}`:s}</option>)}
        </select>
        <input aria-label={`Destination field ${i+1}`} value={m.target} maxLength={107} disabled={busy} onChange={e=>{changed();setMapping(mapping.map((x,n)=>n===i?{...x,target:e.target.value}:x));}}/>
        <button aria-label={`Remove mapping ${i+1}`} disabled={busy || mapping.length===1} onClick={()=>{changed();setMapping(mapping.filter((_,n)=>n!==i));}}>Remove</button>
      </div>)}
      <button disabled={busy || mapping.length>=209} onClick={()=>{changed();setMapping([...mapping,{source:'title',target:`custom:field_${mapping.length+1}`}]);}}>Add field</button>
      {preview && <div role="status"><h3>Draft {preview.jobId?'saved':'not created'}</h3><p>
        Selected: {preview.counts.selected} · Eligible: {preview.counts.eligible} · Suppressed: {preview.counts.suppressed} · Missing/invalid email: {preview.counts.invalid} · Duplicate email: {preview.counts.duplicates}
      </p><p>Preview only. Delivery is not enabled. Cancel unused drafts in Integrations.</p>
        {preview.sample.length>0 && <details><summary>Inspect outbound sample ({preview.sample.length} leads)</summary><pre>{JSON.stringify(preview.sample,null,2)}</pre></details>}
      </div>}
    </>}
    <div className="modal-actions"><button data-autofocus disabled={busy} onClick={onClose}>Close</button>
      {options?.canManage && <button className="primary" disabled={busy || !client || !campaign} onClick={()=>void prepare()}>{busy?'Preparing…':'Freeze and preview selection'}</button>}
    </div>
  </section></div>;
}
