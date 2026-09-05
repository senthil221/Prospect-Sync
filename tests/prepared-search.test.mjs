import assert from 'node:assert/strict';
import test from 'node:test';
import { needsCompanyPreparation, awaitPreparedSearch } from '../lib/prepared-search.ts';
import { parseCompanyScope } from '../lib/workspace-scopes.ts';

const scope = (count, scopes = ['name','keywords','description']) => ({ search:'',limit:250000,
  filters:[{field:'__company_keywords',operator:'contains',values:Array.from({length:count},(_,i)=>`term ${i}`),scopes}] });

test('51, 100 and 150 description terms use preparation; small and non-description searches remain direct', () => {
  for (const count of [51,100,150]) assert.equal(needsCompanyPreparation(scope(count)),true);
  assert.equal(needsCompanyPreparation(scope(7)),false);
  assert.equal(needsCompanyPreparation(scope(150,['name','keywords'])),false);
  assert.equal(needsCompanyPreparation(null),false);
  const exact=scope(150); exact.filters[0].operator='equals';
  assert.equal(needsCompanyPreparation(exact),false);
});

test('browser input cannot supply a prepared set or its owner', () => {
  const parsed = parseCompanyScope(JSON.stringify({...scope(51),_prepared_set_id:'someone-elses-id',_prepared_owner:'someone-else'}));
  assert.equal('_prepared_set_id' in parsed,false);
  assert.equal('_prepared_owner' in parsed,false);
  assert.equal(parsed.filters[0].values.length,51);
});

test('preparation classification totals terms across filters and inside Boolean expressions', () => {
  const split = scope(4); split.filters.push(...scope(4).filters);
  assert.equal(needsCompanyPreparation(split), true);
  for (const expression of ['cloud OR hosting OR software OR MSP OR security OR data OR consulting OR migration',
    "('cloud' | 'hosting' | 'software' | 'MSP' | 'security' | 'data' | 'consulting' | 'migration')"]) {
    const boolean = scope(1); boolean.filters[0].operator = 'boolean'; boolean.filters[0].values = [expression];
    assert.equal(needsCompanyPreparation(boolean), true);
  }
});

test('continuous invalidation stops instead of rebuilding forever', async () => {
  let calls = 0;
  await assert.rejects(awaitPreparedSearch(async () => {
    calls++;
    return Response.json({ preparation: { status: 'refreshing' } }, { status: 202 });
  }, { delayMs: 1 }), /Company data is changing/);
  assert.equal(calls, 2);
});

test('queued searches publish progress then return the actual result response', async () => {
  let calls=0; const progress=[];
  const result=await awaitPreparedSearch(async()=> ++calls===1
    ? Response.json({preparation:{status:'building',message:'Finding companies',matchedCompanies:0}},{status:202})
    : Response.json({total:81477}),{delayMs:1,onProgress:p=>progress.push(p)});
  assert.equal(calls,2);
  assert.equal((await result.json()).total,81477);
  assert.equal(progress[0].status,'building');
  assert.equal(progress.at(-1),null);
});

test('cancelling during preparation stops subsequent requests immediately',async()=>{
  const controller=new AbortController(); let calls=0;
  await assert.rejects(awaitPreparedSearch(async()=>{
    calls++; return Response.json({preparation:{status:'pending',message:'Queued',matchedCompanies:0}},{status:202});
  },{signal:controller.signal,onProgress:p=>{if(p)controller.abort();},delayMs:10000}),{name:'AbortError'});
  assert.equal(calls,1);
});

test('failed queries are not automatically polled and malformed preparation cannot spin forever',async()=>{
  let calls=0;
  const response=await awaitPreparedSearch(async()=>{calls++;return Response.json({error:'failed'},{status:504});});
  assert.equal(response.status,504); assert.equal(calls,1);
  await assert.rejects(awaitPreparedSearch(async()=>Response.json({},{status:202})),/invalid search preparation/);
});

test('a stalled preparation has a deadline and retains no progress indicator after failure',async()=>{
  const progress=[];
  await assert.rejects(awaitPreparedSearch(async()=>Response.json({preparation:{status:'pending'}},{status:202}),
    {deadlineMs:0,onProgress:p=>progress.push(p)}),/still being prepared/);
  assert.equal(progress.at(-1),null);
});
