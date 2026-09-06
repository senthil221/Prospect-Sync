import test from 'node:test';
import assert from 'node:assert/strict';
import {sealCredential} from '../lib/integrations/credentials.ts';
import {deliveryReport} from '../lib/integrations/report.ts';
import {executeSmartleadUnit,smartleadRequest,backoff,campaignAllowsUpload,decryptSmartlead} from '../worker/smartlead-transport.mjs';
const key='ab'.repeat(32),credential=sealCredential('smartlead','fixture-secret',key);
const unit={kind:'upload',id:'fixture',campaign:123,allowActive:false,credential,attempts:1};
test('outcome export distinguishes skipped, suppressed and uncertain and escapes formulas',()=>{
  const csv=deliveryReport([{status:'completed',emails:['a@example.test','b@example.test','c@example.test'],dispatchEmails:['a@example.test','b@example.test'],outcome:{added:['a@example.test'],skipped:[{email:'b@example.test',reason:'=danger'}]}},
    {status:'needs_review',emails:['d@example.test'],dispatchEmails:['d@example.test'],outcome:{reason:'timeout'}}]);
  assert.match(csv,/"a@example.test","added"/);assert.match(csv,/"b@example.test","skipped","'=danger"/);
  assert.match(csv,/"c@example.test","suppressed"/);assert.match(csv,/"d@example.test","uncertain"/);
});
test('worker decrypts provider-bound application credentials',()=>{
  assert.equal(decryptSmartlead(credential,key),'fixture-secret');
  assert.throws(()=>decryptSmartlead(sealCredential('verifier','fixture-secret',key),key));
});
test('active campaigns require explicit authorization; unknown status fails closed',()=>{
  assert.equal(campaignAllowsUpload({id:123,status:'DRAFTED'},123,false),true);
  assert.equal(campaignAllowsUpload({id:123,status:'ACTIVE'},123,false),false);
  assert.equal(campaignAllowsUpload({id:123,status:'ACTIVE'},123,true),true);
  assert.equal(campaignAllowsUpload({id:123,status:'UNKNOWN'},123,true),false);
});
test('upload performs a fresh campaign check, suppression preflight and exactly one POST',async()=>{
  const calls=[];let outcome;
  await executeSmartleadUnit(unit,{key,prepare:async()=>[{email:'x@example.test'}],finish:async(...a)=>{outcome=a;},request:async(kind,id,secret,body)=>{
    calls.push(kind);assert.equal(secret,'fixture-secret');
    if(kind==='campaign')return {ok:true,value:{id,status:'PAUSED'}};
    assert.equal(body.settings.ignore_global_block_list,false);
    return {ok:true,value:{success:true,added_count:1,skipped_count:0}};
  }});
  assert.deepEqual(calls,['campaign','upload']);assert.equal(outcome[0],'completed');assert.equal(outcome[1].addedCount,1);
});
test('an ambiguous upload never retries the POST',async()=>{
  let writes=0,state;
  await executeSmartleadUnit(unit,{key,prepare:async()=>[{email:'x@example.test'}],finish:async s=>{state=s;},request:async kind=>{
    if(kind==='campaign')return {ok:true,value:{id:123,status:'DRAFTED'}};writes++;return {ok:false,status:0};
  }});
  assert.equal(writes,1);assert.equal(state,'needs_review');
});
test('cancelled and fully suppressed batches make no upload',async()=>{
  for(const payload of [null,[]]){
    let writes=0;await executeSmartleadUnit(unit,{key,prepare:async()=>payload,finish:async()=>{},request:async kind=>{if(kind!=='campaign')writes++;return {ok:true,value:{id:123,status:'PAUSED'}};}});assert.equal(writes,0);
  }
});
test('creation recognizes the documented receipt and never starts a campaign',async()=>{
  const calls=[];let outcome;
  await executeSmartleadUnit({...unit,kind:'create',name:'Draft'},{key,finish:async(...a)=>{outcome=a;},request:async kind=>{calls.push(kind);return {ok:true,value:{ok:true,id:456}};}});
  assert.deepEqual(calls,['create']);assert.equal(outcome[1].campaignId,456);
});
test('rate limits respect Retry-After and malformed receipts stop for review',async()=>{
  assert.ok(backoff(1,'300',0,()=>0)>=300);assert.equal(backoff(1,'9999999'),86400);
  let outcome;await executeSmartleadUnit({...unit,kind:'create',name:'Draft'},{key,finish:async(...a)=>{outcome=a;},request:async()=>({ok:true,value:{id:456}})});
  assert.equal(outcome[0],'needs_review');
});
test('transport has fixed URLs, a deadline, disabled redirects and sanitized errors',async()=>{
  const r=await smartleadRequest('upload',123,'secret',{},async(url,options)=>{
    assert.equal(url.origin,'https://server.smartlead.ai');assert.equal(options.redirect,'error');assert.ok(options.signal);throw new Error(`secret ${url}`);
  });assert.deepEqual(r,{ok:false,status:0});
  await assert.rejects(smartleadRequest('delete',123,'secret',{}));
});
