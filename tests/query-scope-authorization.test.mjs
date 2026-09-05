import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { authorizeFilterSets } from '../lib/filter-sets.ts';

const filter = setId => ({ field: '__website', operator: 'equals', values: [], setId });
test('parent filters are authorized even when the visible result has no filters', async () => {
  const calls = [];
  const db = { rpc: async (name, args) => { calls.push({ name, args }); return { error: { code: 'P0002' } }; } };
  const denial = await authorizeFilterSets(db, [], 'signed-in-user', 'prospect', '', [
    { entityType: 'company', clientScope: '', filters: [filter('private-set')] },
  ]);
  assert.equal(denial.status, 403);
  assert.equal(calls[0].args.p_owner_id, 'signed-in-user');
  assert.equal(calls[0].args.p_entity_type, 'company');
});
test('nested dependencies deduplicate only within the same entity and scope', async () => {
  const calls = [];
  const db = { rpc: async (_name, args) => { calls.push(args); return { data: [{}], error: null }; } };
  const parent = { entityType: 'company', clientScope: '', filters: [filter('same-id')], parents: [
    { entityType: 'prospect', clientScope: 'client-a', filters: [filter('same-id')] },
  ] };
  assert.equal(await authorizeFilterSets(db, [filter('same-id'), filter('same-id')], 'owner', 'company', '', [parent]), null);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls.map(c => [c.p_entity_type, c.p_client_scope]), [['company', ''], ['prospect', 'client-a']]);
});
test('cyclic/overdeep scopes fail before any database call', async () => {
  const parent = { entityType: 'company', clientScope: '', filters: [] };
  parent.parents = [parent];
  const db = { rpc: () => { throw new Error('must not query'); } };
  assert.equal((await authorizeFilterSets(db, [], 'owner', 'prospect', '', [parent])).status, 400);
});
test('all current listing, export and result-set consumers pass pivot filters to authorization', async () => {
  for (const [path, scope] of [
    ['app/api/prospects/route.ts', 'companyScope'], ['app/api/companies/route.ts', 'peopleScope'],
    ['app/api/prospects/export/route.ts', 'companyScope'], ['app/api/result-sets/route.ts', 'scopePayload'],
    ['app/api/exports/route.ts', 'scopePayload'],
  ]) {
    const source = await readFile(new URL(`../${path}`, import.meta.url), 'utf8');
    assert.match(source, new RegExp(`authorizeFilterSets\\([\\s\\S]*?filters: ${scope}\\.filters`), path);
  }
});
