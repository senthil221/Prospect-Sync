import { createHash } from 'node:crypto';
import { mapDeliveryLead, validateMapping, uploadPayload } from '../../worker/integration-contract.mjs';

type Source = { id:string; fields:Record<string,unknown>; custom:Record<string,unknown>; suppressed:boolean };
export function prepareIntegrationPreview(rows:Source[], rawMapping:unknown) {
  const mapping = validateMapping(rawMapping);
  const email = mapping.find((m:{source:string;target:string})=>m.target==='email');
  if (!email || !['work_email','personal_email'].includes(email.source)) throw new Error('Use work or personal email as the recipient column.');
  if (!Array.isArray(rows) || !rows.length || rows.length>400) throw new Error('Choose 1–400 explicit prospects.');
  const leads:Record<string,unknown>[]=[];
  const sourceIds:Record<string,string[]> = Object.create(null);
  let suppressed=0,invalid=0,duplicates=0;
  for (const row of [...rows].sort((a,b)=>a.id.localeCompare(b.id))) {
    if (row.suppressed) { suppressed++; continue; }
    const fields = {...Object.fromEntries(Object.entries(row.custom ?? {}).map(([k,v])=>[`raw:${k}`,v])),...row.fields};
    const result = mapDeliveryLead(fields,mapping);
    if (!result.eligible) { invalid++; continue; }
    const lead = result.lead as Record<string,unknown>;
    const recipient = String(lead.email);
    if (sourceIds[recipient]) { sourceIds[recipient].push(row.id); duplicates++; continue; }
    sourceIds[recipient]=[row.id]; leads.push(lead);
  }
  const batches:Record<string,unknown>[][]=[]; let batch:Record<string,unknown>[]=[];
  for (const lead of leads) {
    try { uploadPayload([...batch,lead]); }
    catch { if (batch.length) batches.push(batch); batch=[]; uploadPayload([lead]); }
    batch.push(lead);
  }
  if (batch.length) batches.push(batch);
  const summary={selected:rows.length,eligible:leads.length,suppressed,invalid,duplicates,sourceIds,mapping};
  return {batches,summary,sample:leads.slice(0,10)};
}
export function previewHash(client:string,campaign:number,preview:ReturnType<typeof prepareIntegrationPreview>) {
  return createHash('sha256').update(JSON.stringify({client,campaign,batches:preview.batches,summary:preview.summary})).digest('hex');
}
