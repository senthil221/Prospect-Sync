// Test-only hydrated fixture: real component + production CSS + mocked API.
// It is not an application route and has no database or authentication bypass.
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const webpack = require('next/dist/compiled/webpack/webpack').webpack;
await require('next/dist/build/swc').loadBindings();
const rootPath = fileURLToPath(new URL('../', import.meta.url));
const outputPath = fileURLToPath(new URL('../.next/email-verification-fixture/', import.meta.url));
await mkdir(outputPath, { recursive: true });
await new Promise((resolve, reject) => webpack({
  mode: 'development', target: 'web', devtool: false,
  context: rootPath,
  entry: './tests/fixtures/email-verification-browser.tsx',
  output: { path: outputPath, filename: 'bundle.js' },
  resolve: { extensions: ['.tsx', '.ts', '.jsx', '.js', '.mjs'] },
  module: { rules: [{ test: /\.[jt]sx?$/u, exclude: /node_modules/u, use: [{
    loader: require.resolve('next/dist/build/webpack/loaders/next-swc-loader'),
    options: { isServer: false, rootDir: rootPath, pagesDir: `${rootPath}/pages`, appDir: `${rootPath}/app`,
      hasReactRefresh: false, compilerType: 'client', nextConfig: { cacheComponents: false }, jsConfig: { compilerOptions: {} } },
  }] }] },
}, (error, stats) => {
  if (error) reject(error);
  else if (stats?.hasErrors()) reject(new Error(stats.toString({ colors: false, errors: true, warnings: false })));
  else resolve();
}));

const manifest = await readFile(new URL('../.next/server/app/page_client-reference-manifest.js', import.meta.url), 'utf8');
const cssEntries = JSON.parse(manifest.match(/"entryCSSFiles":(\{.*?\}),"entryJSFiles":/s)[1]);
const styles = cssEntries['[project]/app/layout'].map(({ path }) => `/_next/${path}`);
const server = createServer(async (request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1:3218');
  if (url.pathname === '/') {
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    response.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Email verification fixture</title>${styles.map(href => `<link rel="stylesheet" href="${href}">`).join('')}</head><body><div id="root"></div><script src="/bundle.js"></script></body></html>`);
    return;
  }
  try {
    if (url.pathname === '/bundle.js') {
      response.writeHead(200, { 'content-type': 'text/javascript' });
      response.end(await readFile(new URL('../.next/email-verification-fixture/bundle.js', import.meta.url)));
      return;
    }
    if (url.pathname.startsWith('/_next/')) {
      response.writeHead(200, { 'content-type': 'text/css' });
      response.end(await readFile(new URL(`../.next/${url.pathname.slice('/_next/'.length)}`, import.meta.url)));
      return;
    }
  } catch { /* Missing fixture assets fall through to the bounded 404 below. */ }
  response.writeHead(404); response.end('Not found');
});
server.listen(3218, '127.0.0.1', () => console.log('Email verification fixture: http://127.0.0.1:3218'));
