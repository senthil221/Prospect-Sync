import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parseFilters, filterErrorResponse } from '../lib/prospect-filters.ts';
import { parseCompanyScope, parsePeopleScope } from '../lib/workspace-scopes.ts';
import { parseBulkSelection } from '../lib/client-operations.ts';
import { readWorkspaceUrl, writeWorkspaceUrl, defaultWorkspaceState } from '../lib/workspace-url.ts';

const valid = { field: '__title', operator: 'contains', values: ['manager'] };
const uuid = '11111111-1111-1111-1111-111111111111';
test('malformed predicates reject the whole query, including bulk mutation selection', () => {
  const bad = [null, [], 4, { ...valid, field: '' }, { ...valid, field: 'x'.repeat(161) },
    { ...valid, operator: 'unsupported' }, { ...valid, values: 'manager' }, { ...valid, values: [{}] },
    { ...valid, setId: '' }, { ...valid, setId: uuid },
    { ...valid, operator: 'equals', setId: uuid },
    { ...valid, operator: 'boolean', values: ['manager', 'engineer'] },
    { ...valid, operator: 'number_ranges', values: ['1:10', 'bad'] },
    { ...valid, operator: 'number_ranges', values: ['10:1'] },
    { ...valid, operator: 'number_ranges', values: ['9007199254740992:'] },
    { ...valid, field: '__company_keywords', scopes: ['description', 'unknown'] },
    { ...valid, field: '__company_keywords', scopes: 'description' }];
  for (const filter of bad) {
    assert.throws(() => parseFilters(JSON.stringify([valid, filter])));
    assert.throws(() => parseBulkSelection({ filters: [valid, filter] }));
    for (const parse of [parseCompanyScope, parsePeopleScope]) assert.throws(() => parse(JSON.stringify({ filters: [filter] })));
  }
  for (const nonArray of ['{}', 'null', '"filter"']) assert.throws(() => parseFilters(nonArray));
});

test('valid draft rows, legacy scalar values, numeric ranges and set transport remain compatible', () => {
  assert.deepEqual(parseFilters(JSON.stringify([{ ...valid, values: [] }])), []);
  assert.deepEqual(parseFilters(JSON.stringify([{ field: '__title', value: 'manager' }]))[0].values, ['manager']);
  const ranges = ['0:0', '1:10', '100:', 'unknown'];
  assert.deepEqual(parseFilters(JSON.stringify([{ ...valid, operator: 'number_ranges', values: ranges }]))[0].values, ranges);
  assert.equal(parseFilters(JSON.stringify([{ ...valid, operator: 'equals', values: [], setId: uuid }]))[0].setId, uuid);
});

test('invalid filter or scope links return a blocking restoration error without throwing during render', () => {
  for (const key of ['pf', 'cf', 'cscope', 'pscope']) {
    for (const raw of ['{', 'null', '"broken"']) {
      const params = new URLSearchParams({ s: 'prospects', [key]: raw });
      assert.match(readWorkspaceUrl(params).restoreError, /cannot be restored safely/);
      assert.match(readWorkspaceUrl(new URLSearchParams('s=companies'), `#workspace-v1?${key}=${encodeURIComponent(raw)}`).restoreError, /cannot be restored safely/);
    }
  }
  const setFilter = JSON.stringify([{ field: '__website', operator: 'equals', setId: uuid }]);
  assert.ok(readWorkspaceUrl(new URLSearchParams({ cf: setFilter })).restoreError, 'never drop setId to hydrate an empty editable filter');
  assert.ok(readWorkspaceUrl(new URLSearchParams(), '#workspace-v2?cf=[]').restoreError);
  assert.ok(readWorkspaceUrl(new URLSearchParams({ q: 'x'.repeat(301) })).restoreError);
});

test('Boolean filter and both pivots preserve source syntax across reload and compile exactly once on the server', () => {
  globalThis.window ??= { location: { pathname: '/' } };
  const source = '("IT consulting" OR MSP) AND NOT recruitment';
  const filter = { id: 'b', field: '__company_keywords', operator: 'boolean', values: [source], scopes: ['description'] };
  const scope = { search: '', filters: [filter], limit: 250000 };
  let state = { ...defaultWorkspaceState, section: 'companies', companyFilters: [filter], prospectFilters: [filter], companyPeopleScope: scope, peopleCompanyScope: scope };
  for (let i = 0; i < 3; i++) {
    const url = new URL(writeWorkspaceUrl(state), 'https://example.test');
    state = readWorkspaceUrl(url.searchParams, url.hash);
    assert.equal(state.restoreError, undefined);
    for (const filters of [state.companyFilters, state.prospectFilters, state.companyPeopleScope.filters, state.peopleCompanyScope.filters]) {
      assert.equal(filters[0].values[0], source);
      assert.deepEqual(parseFilters(JSON.stringify(filters)), parseFilters(JSON.stringify([filter])));
    }
  }
});

test('malformed requests return 400 and the browser guards query, prefetch and URL rewrite paths', async () => {
  let error;
  try { parseFilters('{}'); } catch (caught) { error = caught; }
  assert.equal(filterErrorResponse(error, 'invalid').status, 400);
  const app = await readFile(new URL('../app/DashboardApp.tsx', import.meta.url), 'utf8');
  assert.match(app, /active: !restoreError && section === "prospects"/);
  assert.match(app, /active: !restoreError && section === "companies"/);
  assert.match(app, /if \(restoreError\) return; \/\/ Preserve/);
  assert.match(app, /setRestoreError\(restored.restoreError \?\? ''\);\s*if \(restored.restoreError\) return;/);
  assert.match(app, /const prefetchSection = useCallback\(\(next: Section\) => \{\s*if \(restoreError\) return;/);
  assert.match(app, /if \(restoreError\) return <main/);
  assert.match(app, /Clear this link and start a new search/);
});
