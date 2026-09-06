import test from 'node:test';
import assert from 'node:assert/strict';
import {prepareIntegrationPreview,previewHash} from '../lib/integrations/preview.ts';
const mapping=[{source:'work_email',target:'email'},{source:'raw:Message',target:'custom:message'}];
const row=(id,email,suppressed=false)=>({id,fields:{work_email:email},custom:{Message:'Hello'},suppressed});
test('preview accounts for suppression, invalid emails and deterministic duplicates',()=>{
  const result=prepareIntegrationPreview([row('b','A@example.test'),row('a',' a@example.test '),row('c','bad'),row('d','d@example.test',true)],mapping);
  assert.deepEqual(Object.fromEntries(Object.entries(result.summary).filter(([k])=>!['mapping','sourceIds'].includes(k))),{selected:4,eligible:1,suppressed:1,invalid:1,duplicates:1});
  assert.deepEqual(result.summary.sourceIds['a@example.test'],['a','b']);
  assert.equal(result.sample[0].custom_fields.message,'Hello');
});
test('preview rejects arbitrary email columns and oversized explicit selections',()=>{
  assert.throws(()=>prepareIntegrationPreview([row('a','a@example.test')],[{source:'raw:Message',target:'email'}]));
  assert.throws(()=>prepareIntegrationPreview(Array.from({length:401},(_,i)=>row(String(i),'a@example.test')),mapping));
});
test('snapshot hash follows frozen values, mapping and destination',()=>{
  const a=prepareIntegrationPreview([row('a','a@example.test')],mapping);
  const b=prepareIntegrationPreview([row('a','b@example.test')],mapping);
  assert.notEqual(previewHash('client',1,a),previewHash('client',1,b));
  assert.notEqual(previewHash('client',1,a),previewHash('client',2,a));
});
test('preview splits batches by bytes and never drops an oversize record',()=>{
  const wideMapping=[{source:'work_email',target:'email'},...Array.from({length:100},(_,i)=>({source:'raw:Message',target:`custom:field${i}`}))];
  const rows=[row('a','a@example.test'),row('b','b@example.test')].map(r=>({...r,custom:{Message:'x'.repeat(3500)}}));
  const result=prepareIntegrationPreview(rows,wideMapping);
  assert.equal(result.batches.length,2);
  assert.equal(result.summary.eligible,2);
});
