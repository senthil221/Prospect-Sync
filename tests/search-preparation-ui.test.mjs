import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import './helpers/tsx-loader.mjs';

const { default: SearchPreparation } = await import('../app/components/SearchPreparation.tsx');
const callbacks = { onRetry() {}, onClear() {}, clearLabel:'Clear company scope' };

test('preparation and failure have accessible, actionable states, not misleading empty results', () => {
  const pending=renderToStaticMarkup(createElement(SearchPreparation,{...callbacks,error:'',progress:{status:'pending',message:'Queued',matchedCompanies:0}}));
  assert.match(pending,/role="status"/);
  assert.match(pending,/Queued/);
  assert.doesNotMatch(pending,/Retry search/);
  const failed=renderToStaticMarkup(createElement(SearchPreparation,{...callbacks,error:'Please retry shortly',progress:null}));
  assert.match(failed,/role="alert"/);
  assert.match(failed,/Retry search/);
  assert.match(failed,/Clear company scope/);
  assert.equal(renderToStaticMarkup(createElement(SearchPreparation,{...callbacks,error:'',progress:null})), '');
});

test('workspaces hide stale actions without unmounting table state during preparation or failure',async()=>{
  for (const file of ['CompaniesWorkspace','ProspectsWorkspace','ClientsPanel']) {
    const source=await readFile(new URL(`../app/components/${file}.tsx`,import.meta.url),'utf8');
    assert.doesNotMatch(source,/if\s*\((?:controller\.)?preparation\)\s*return/);
    assert.match(source,/hidden=\{Boolean\((?:controller\.)?preparation \|\| (?:controller\.)?preparationError\)\}/);
    assert.match(source,/<SearchPreparation/);
    assert.match(source,/setPreparationError\(message\)/);
  }
});
