import { createDecipheriv } from 'node:crypto';
import { classifyUploadReceipt, uploadPayload, uploadFailureDisposition } from './integration-contract.mjs';

export function decryptSmartlead(envelope,key) {
  if(!/^[a-f0-9]{64}$/i.test(key ?? ''))throw new Error('Encryption configuration missing');
  const parts=envelope.split('.');
  if(parts.length!==4 || parts[0]!=='v1')throw new Error('Invalid envelope');
  const cipher=createDecipheriv('aes-256-gcm',Buffer.from(key,'hex'),Buffer.from(parts[1],'base64'));
  cipher.setAAD(Buffer.from('prospect-integrations:v1:smartlead'));cipher.setAuthTag(Buffer.from(parts[2],'base64'));
  return Buffer.concat([cipher.update(Buffer.from(parts[3],'base64')),cipher.final()]).toString('utf8');
}
export function backoff(attempt,retryAfter=null,now=Date.now(),random=Math.random) {
  const parsed=retryAfter && (/^\d+$/.test(retryAfter)?Number(retryAfter):Math.ceil((Date.parse(retryAfter)-now)/1000));
  return Math.min(86400,Math.max(5,Number.isFinite(parsed)?parsed:0,Math.min(900,5*2**Math.min(attempt,8))+Math.floor(random()*5)));
}
export async function smartleadRequest(kind,campaign,secret,body,fetcher=fetch) {
  if(!['create','campaign','upload'].includes(kind) || (kind!=='create' && (!Number.isSafeInteger(campaign) || campaign<1)))throw new Error('Invalid operation');
  const path=kind==='create'?'campaigns/create':`campaigns/${campaign}${kind==='upload'?'/leads':''}`;
  const url=new URL(`https://server.smartlead.ai/api/v1/${path}`);url.searchParams.set('api_key',secret);
  try {
    const response=await fetcher(url,{method:kind==='campaign'?'GET':'POST',redirect:'error',cache:'no-store',
      headers:{Accept:'application/json','Content-Type':'application/json'},...(kind==='campaign'?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(20000)});
    if(!response.ok){void response.body?.cancel().catch(()=>{});return {ok:false,status:response.status,retryAfter:response.headers.get('retry-after')};}
    const reader=response.body?.getReader();if(!reader)throw new Error('No body');
    let size=0;const chunks=[];
    try {for(;;){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>4*1024*1024)throw new Error('Response too large');chunks.push(value);}}
    finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
    return {ok:true,value:JSON.parse(Buffer.concat(chunks).toString('utf8'))};
  }catch{return {ok:false,status:0};} // Never include key-bearing URLs or raw error bodies.
}
export function campaignAllowsUpload(value,id,allowActive) {
  if(!value || Number(value.id)!==id || typeof value.status!=='string')return false;
  if(['DRAFTED','PAUSED','STOPPED'].includes(value.status))return true;
  return allowActive===true && ['ACTIVE','STARTED','RUNNING'].includes(value.status);
}
export async function executeSmartleadUnit(unit,{key,prepare,finish,request=smartleadRequest}) {
  let secret;
  try{secret=decryptSmartlead(unit.credential,key);}catch{return finish('needs_review',{reason:'credential_unavailable'},60);}
  if(unit.kind==='create'){
    const response=await request('create',null,secret,{name:unit.name});
    if(!response.ok)return finish(uploadFailureDisposition(response.status),{reason:response.status===429?'rate_limited':'campaign_creation_failed_or_uncertain'},backoff(unit.attempts,response.retryAfter));
    const v=response.value;
    if(v?.ok!==true || !Number.isSafeInteger(v.id) || v.id<1)return finish('needs_review',{reason:'unrecognized_creation_receipt'},60);
    return finish('completed',{campaignId:v.id},5);
  }
  const campaign=await request('campaign',Number(unit.campaign),secret);
  if(!campaign.ok)return finish([401,403].includes(campaign.status)?'connection_paused':'read_retry',{reason:'campaign_read_unavailable'},backoff(unit.attempts,campaign.retryAfter));
  if(!campaignAllowsUpload(campaign.value,Number(unit.campaign),unit.allowActive))return finish('needs_review',{reason:'campaign_not_approved_for_upload'},5);
  const payload=await prepare();
  if(payload===null)return finish('needs_review',{reason:'cancelled_or_destination_changed'},5);
  if(!payload.length)return finish('completed',{addedCount:0,skippedCount:0,added:[],skipped:[]},5);
  let body;
  try{body=uploadPayload(payload);}catch{return finish('needs_review',{reason:'invalid_frozen_payload'},5);}
  const response=await request('upload',Number(unit.campaign),secret,body);
  if(!response.ok)return finish(uploadFailureDisposition(response.status),{reason:response.status===429?'rate_limited':[400,404,422].includes(response.status)?'provider_rejected':'upload_failed_or_uncertain'},backoff(unit.attempts,response.retryAfter));
  const receipt=classifyUploadReceipt(response.value,payload.map(p=>p.email));
  if(receipt.state!=='completed')return finish('needs_review',{reason:receipt.reason},60);
  return finish('completed',{addedCount:receipt.added.length,skippedCount:receipt.skipped.length,added:receipt.added,skipped:receipt.skipped},5);
}
