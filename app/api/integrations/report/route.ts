import {getAuthorizedUser} from '../../../../lib/auth';
import {integrationAdmin} from '../../../../lib/integrations/credentials';
import {deliveryReport} from '../../../../lib/integrations/report';
import {createAdminClient} from '../../../../lib/supabase/admin';
export async function GET(request:Request){
  try{
    const user=await getAuthorizedUser();
    if(!user || !integrationAdmin(user.email,process.env.INTEGRATION_ADMIN_EMAILS))return new Response('Unauthorized',{status:403});
    const id=new URL(request.url).searchParams.get('jobId') ?? '';
    if(!/^[0-9a-f-]{36}$/i.test(id))return new Response('Invalid job',{status:400});
    const {data,error}=await createAdminClient().rpc('smartlead_report_v1',{p_actor:user.id,p_job:id}).abortSignal(AbortSignal.timeout(5000));
    if(error || !data)return new Response('Report unavailable',{status:404});
    return new Response(deliveryReport(data),{headers:{'Content-Type':'text/csv; charset=utf-8','Content-Disposition':`attachment; filename="smartlead-${id}.csv"`,'Cache-Control':'no-store'}});
  }catch{return new Response('Report unavailable',{status:503});}
}
