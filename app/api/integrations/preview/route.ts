import { getAuthorizedUser } from '../../../../lib/auth';
import { readBoundedJson } from '../../../../lib/bounded-json';
import { integrationAdmin, integrationWriteAllowed } from '../../../../lib/integrations/credentials';
import { prepareIntegrationPreview, previewHash } from '../../../../lib/integrations/preview';
import { createAdminClient } from '../../../../lib/supabase/admin';

export const runtime='nodejs';
const reply=(value:unknown,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store'}});
export async function POST(request:Request) {
  try {
    const user=await getAuthorizedUser();
    if (!user) return reply({error:'Unauthorized'},401);
    if (!integrationAdmin(user.email,process.env.INTEGRATION_ADMIN_EMAILS)) return reply({error:'An integration administrator is required.'},403);
    if (!integrationWriteAllowed(request,process.env.APP_PUBLIC_URL || (process.env.NODE_ENV!=='production'?new URL(request.url).origin:undefined))) return reply({error:'Same-origin JSON requests are required.'},403);
    const decoded=await readBoundedJson(request,{bytes:131072,depth:5,timeoutMs:5000});
    if (decoded.response) return decoded.response;
    const p=decoded.value as {clientId?:unknown;campaignId?:unknown;prospectIds?:unknown;mapping?:unknown;requestId?:unknown};
    if (!p || typeof p.clientId!=='string' || !p.clientId || p.clientId.length>200 || typeof p.campaignId!=='number'
      || !Number.isSafeInteger(p.campaignId) || p.campaignId<1 || typeof p.requestId!=='string'
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(p.requestId)
      || !Array.isArray(p.prospectIds) || !p.prospectIds.length || p.prospectIds.length>400
      || p.prospectIds.some(id=>typeof id!=='string' || !id || id.length>200)) return reply({error:'Choose 1–400 explicit prospects, a client and a campaign.'},400);
    const db=createAdminClient();
    const {data:rows,error}=await db.rpc('integration_selection_v1',{p_client:p.clientId,p_ids:[...new Set(p.prospectIds)]}).abortSignal(AbortSignal.timeout(10000));
    if (error) return reply({error:'Unable to load the full selection. Reload prospects or select a smaller batch.'},409);
    let preview;
    try { preview=prepareIntegrationPreview(rows,p.mapping); }
    catch (e) {return reply({error:e instanceof Error?e.message:'Invalid mapping.'},400);}
    const {sourceIds: _sourceIds,mapping: _mapping,...counts}=preview.summary;
    // Keep audit links private; the browser only sees bounded sample + counts.
    void _sourceIds; void _mapping;
    if (!counts.eligible) return reply({counts,sample:[],jobId:null,dispatchEnabled:false});
    const staged=await db.rpc('stage_mapped_integration_job_v1',{
      p_actor:user.id,p_request:p.requestId,p_hash:previewHash(p.clientId,p.campaignId,preview),
      p_client:p.clientId,p_campaign:p.campaignId,p_batches:preview.batches,p_summary:preview.summary,
    }).abortSignal(AbortSignal.timeout(10000));
    if (staged.error) return reply({error:'Preview could not be saved. Check the client destination, cancel unused drafts, or start a new preview if the source data changed.'},409);
    return reply({jobId:staged.data,counts,sample:preview.sample,dispatchEnabled:false});
  } catch {return reply({error:'Unable to prepare this preview. No leads were sent.'},503);}
}
