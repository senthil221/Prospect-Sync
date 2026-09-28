import pg from 'pg';
import {createServer} from 'node:http';
import {executeSmartleadUnit} from './smartlead-transport.mjs';
import {executeSmartleadInboxUnit} from './smartlead-inbox-sync.mjs';
const key=process.env.INTEGRATION_ENCRYPTION_KEY;
if(!/^[a-f0-9]{64}$/i.test(key ?? ''))throw new Error('Integration encryption is not configured');
let stopping=false,connected=false,lastProgress=Date.now();
process.on('SIGTERM',()=>{stopping=true;});process.on('SIGINT',()=>{stopping=true;});
const db=new pg.Client({application_name:'prospect-integration-worker',connectionTimeoutMillis:10000});
db.on('error',()=>{connected=false;stopping=true;});
const health=createServer((req,res)=>{
  if(req.url!=='/health'){res.writeHead(404).end();return;}
  const ok=connected && !stopping && Date.now()-lastProgress<90000;
  res.writeHead(ok?200:503,{'Content-Type':'application/json','Cache-Control':'no-store'}).end(JSON.stringify({status:ok?'ok':'unavailable'}));
});
async function main(){
  await db.connect();await db.query("set statement_timeout='10s'");await db.query("set lock_timeout='3s'");
  await db.query("select 'prospect_integrations.claim_v1(text)'::regprocedure");
  await db.query("select 'prospect_integrations.claim_smartlead_inbox_sync_v1()'::regprocedure");
  connected=true;health.listen(9092,'0.0.0.0');
  let turn=0,lastCleanup=0;
  while(!stopping){
    if(Date.now()-lastCleanup>60000){await db.query('select prospect_integrations.cleanup_v1()');lastCleanup=Date.now();}
    const kind=['upload','create','inbox_sync','inbox_action'][turn++%4];
    const {rows}=kind==='inbox_sync'
      ? await db.query('select prospect_integrations.claim_smartlead_inbox_sync_v1() as unit')
      : kind==='inbox_action'
        ? await db.query('select prospect_integrations.claim_smartlead_inbox_action_v1() as unit')
        : await db.query('select prospect_integrations.claim_v1($1) as unit',[kind]);
    const unit=rows[0]?.unit;
    if(unit && kind==='inbox_sync')await executeSmartleadInboxUnit(unit,{key,
      finish:async(state,result,delay)=>{
        const r=await db.query('select prospect_integrations.finish_smartlead_inbox_sync_v1($1,$2,$3,$4) as saved',[unit.token,state,JSON.stringify(result),delay]);
        console.log(JSON.stringify({event:'smartlead_inbox_sync',offset:unit.offset,state,saved:r.rows[0].saved}));
      }});
    else if(unit && kind==='inbox_action'){
      try{
        const r=await db.query('select prospect_integrations.apply_smartlead_inbox_action_v1($1,$2) as result',[unit.id,unit.token]);
        console.log(JSON.stringify({event:'smartlead_inbox_action',id:unit.id,state:r.rows[0].result?.state ?? 'stale'}));
      }catch{
        await db.query('select prospect_integrations.retry_smartlead_inbox_action_v1($1,$2,$3,$4)',[unit.id,unit.token,'apply_failed',60]).catch(()=>{});
        console.error(JSON.stringify({event:'smartlead_inbox_action',id:unit.id,state:'retry'}));
      }
    }else if(unit)await executeSmartleadUnit(unit,{key,
        prepare:async()=>{const r=await db.query('select prospect_integrations.prepare_upload_v1($1,$2) as payload',[unit.id,unit.token]);return r.rows[0].payload;},
        finish:async(state,result,delay)=>{
          const r=await db.query('select prospect_integrations.finish_v1($1,$2,$3,$4,$5,$6) as saved',[unit.kind,unit.id,unit.token,state,JSON.stringify(result),delay]);
          console.log(JSON.stringify({event:'smartlead_unit',kind:unit.kind,id:unit.id,state,saved:r.rows[0].saved}));
        }});
    lastProgress=Date.now();
    await new Promise(resolve=>setTimeout(resolve,1500));
  }
}
main().catch(()=>{console.error('Integration worker stopped; uncertain operations remain fenced for review.');process.exitCode=1;})
  .finally(async()=>{connected=false;health.close();await db.end().catch(()=>{});});
