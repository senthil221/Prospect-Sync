import assert from 'node:assert/strict';
import test from 'node:test';
import { runCompanyExport } from '../lib/export-runner.ts';

const options = { requestId: 'export-regression', search: '', filters: [], peopleScope: null,
  websitesOnly: false, customFieldNames: [], fields: ['__company_name', '__website'],
  format: 'single', rowsPerFile: 25000, fileBaseName: 'companies', totalRows: 5000 };

test('company export writes 600, 5000 and 6001 streamed rows and commits once', async () => {
  const originalWindow = globalThis.window;
  const originalFetch = globalThis.fetch;
  try {
    for (const count of [600, 5000, 6001]) {
      const chunks = [];
      let closed = 0;
      globalThis.window = { isSecureContext: true, showDirectoryPicker() {},
        showSaveFilePicker: async () => ({ createWritable: async () => ({
          write: async text => chunks.push(text), close: async () => { closed++; },
          abort: async () => assert.fail('successful stream must not abort'),
        }) }) };
      globalThis.fetch = async () => new Response(new ReadableStream({
        start(controller) {
          const encoder = new TextEncoder();
          controller.enqueue(encoder.encode('\uFEFFCompany Name,Website\r\n'));
          for (let start = 0; start < count; start += 500) {
            const rows = Array.from({ length: Math.min(500, count - start) }, (_, i) => `Company ${start + i},https://company${start + i}.example`);
            controller.enqueue(encoder.encode(rows.join('\r\n') + '\r\n'));
          }
          controller.close();
        },
      }), { headers: { 'Content-Type': 'text/csv' } });
      const result = await runCompanyExport({ ...options, totalRows: count });
      assert.equal(result.exported, count);
      assert.equal(closed, 1);
      assert.equal(chunks.join('').split('\r\n').length, count + 1);
      assert.match(chunks.join(''), new RegExp(`Company ${count - 1},`));
    }
  } finally { globalThis.window = originalWindow; globalThis.fetch = originalFetch; }
});

test('a failed company response never opens or commits a writable file', async () => {
  const originalWindow = globalThis.window;
  const originalFetch = globalThis.fetch;
  try {
    globalThis.window = { isSecureContext: true, showDirectoryPicker() {},
      showSaveFilePicker: async () => ({ createWritable: async () => assert.fail('must not open on failure') }) };
    globalThis.fetch = async () => Response.json({ error: 'Database timed out' }, { status: 504 });
    await assert.rejects(runCompanyExport(options), /Database timed out/);
  } finally { globalThis.window = originalWindow; globalThis.fetch = originalFetch; }
});

test('empty and truncated successful responses fail instead of saving an empty or partial CSV', async () => {
  const originalWindow = globalThis.window;
  const originalFetch = globalThis.fetch;
  try {
    for (const body of ['', 'Company Name,Website\r\n"Incomplete company']) {
      let closed = false;
      globalThis.window = { isSecureContext: true, showDirectoryPicker() {},
        showSaveFilePicker: async () => ({ createWritable: async () => ({
          write: async () => {}, abort: async () => {}, close: async () => { closed = true; },
        }) }) };
      globalThis.fetch = async () => new Response(body, { headers: { 'Content-Type': 'text/csv' } });
      await assert.rejects(runCompanyExport(options), /empty response|quoted field/);
      assert.equal(closed, false);
    }
  } finally { globalThis.window = originalWindow; globalThis.fetch = originalFetch; }
});
