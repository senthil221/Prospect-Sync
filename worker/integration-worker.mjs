import pg from 'pg';
import {createServer} from 'node:http';
import {executeSmartleadUnit} from './smartlead-transport.mjs';
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
  connected=true;health.listen(9092,'0.0.0.0');
  let turn=0,lastCleanup=0;
  while(!stopping){
    if(Date.now()-lastCleanup>60000){await db.query('select prospect_integrations.cleanup_v1()');lastCleanup=Date.now();}
    const kind=turn++%2?'upload':'create';
    const {rows}=await db.query('select prospect_integrations.claim_v1($1) as unit',[kind]);
    const unit=rows[0]?.unit;
    if(unit)await executeSmartleadUnit(unit,{key,
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
