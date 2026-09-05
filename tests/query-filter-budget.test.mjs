import assert from 'node:assert/strict';
import test from 'node:test';
import { assertQueryFilterBudget, FilterLimitError, parseFilters } from '../lib/prospect-filters.ts';
import { authorizeFilterSets } from '../lib/filter-sets.ts';
const filter = count => ({ field: '__website', operator: 'equals', values: Array.from({ length: count }, (_, i) => `v${i}`) });
test('cumulative budget stops the per-filter multiplicative loophole without dropping values', () => {
  assert.equal(parseFilters(JSON.stringify(Array.from({ length: 4 }, () => filter(5000)))).length, 4);
  assert.throws(() => parseFilters(JSON.stringify(Array.from({ length: 5 }, () => filter(5000)))),
    error => error instanceof FilterLimitError && error.kind === 'total_values' && error.received === 25000);
  assert.doesNotThrow(() => assertQueryFilterBudget([[filter(150)]]));
});
test('pivot values count towards the same query budget before database access', async () => {
  const db = { rpc: () => { throw new Error('must not query'); } };
  const denial = await authorizeFilterSets(db, Array.from({ length: 3 }, () => filter(5000)), 'owner', 'prospect', '', [
    { entityType: 'company', clientScope: '', filters: [filter(5000), filter(1)] },
  ]);
  assert.equal(denial.status, 413);
  assert.equal((await denial.json()).limit, 'total_values');
});
test('UTF-8 byte budget rejects wide Unicode inputs as 413 before JSON parsing', () => {
  assert.throws(() => parseFilters('漢'.repeat(350000)), error => error instanceof FilterLimitError && error.kind === 'request_bytes');
});
