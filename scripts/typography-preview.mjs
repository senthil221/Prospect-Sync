// Local-only visual fixture. Run after `npm run build`:
// node --import ./tests/helpers/tsx-loader.mjs scripts/typography-preview.mjs
// No customer records, credentials, application routes or API requests.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { renderTypographyPreview } from "../tests/fixtures/typography-preview.tsx";

const root = new URL("../", import.meta.url);
// Match Next's real stylesheet ordering: alphabetical chunk order changes
// the cascade and can hide typography regressions behind older component CSS.
const manifest = await readFile(new URL(".next/server/app/page_client-reference-manifest.js", root), "utf8");
const cssEntries = JSON.parse(manifest.match(/"entryCSSFiles":(\{.*?\}),"entryJSFiles":/s)[1]);
const styles = cssEntries["[project]/app/layout"].map(({ path }) => `/_next/${path}`);
if (!styles.length) throw new Error("Run npm run build before starting the typography preview.");
const fontFiles = ["Inter-VariableFont_opsz,wght.ttf", "Inter-Italic-VariableFont_opsz,wght.ttf"];
const assets = new Map([
  ...styles.map((path) => [path, { url: new URL(path.replace(/^\/_next\//, ".next/"), root), type: "text/css" }]),
  ...fontFiles.map((name) => [`/fonts/inter/${name}`, { url: new URL(`public/fonts/inter/${name}`, root), type: "font/ttf" }]),
]);

const server = createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1:3217");
  try {
    if (url.pathname === "/") {
      const theme = url.searchParams.get("theme") === "dark" ? "dark" : "light";
      const density = url.searchParams.get("density") === "compact" ? "compact" : "default";
      const scale = ["100", "125", "200"].includes(url.searchParams.get("scale")) ? url.searchParams.get("scale") : "100";
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      response.end(renderTypographyPreview({ theme, density, scale, styles }));
      return;
    }
    const asset = assets.get(decodeURIComponent(url.pathname));
    if (!asset) { response.writeHead(404); response.end("Not found"); return; }
    response.writeHead(200, { "Content-Type": asset.type, "Cache-Control": "no-store" });
    response.end(await readFile(asset.url));
  } catch (error) { response.writeHead(500); response.end("Preview failed"); console.error(error); }
});
server.listen(3217, "127.0.0.1", () => console.log("Typography fixture: http://127.0.0.1:3217 (synthetic data, production CSS)"));
