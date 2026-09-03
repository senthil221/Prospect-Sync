// Test-only TypeScript transform; no browser or application runtime changes.
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";

export async function resolve(specifier, context, nextResolve) {
  try { return await nextResolve(specifier, context); }
  catch (error) {
    if (error.code !== "ERR_MODULE_NOT_FOUND" || !specifier.startsWith(".")) throw error;
    for (const extension of [".tsx", ".ts"]) {
      const url = new URL(specifier + extension, context.parentURL);
      if (existsSync(url)) return { url: url.href, shortCircuit: true };
    }
    throw error;
  }
}

export async function load(url, context, nextLoad) {
  if (!url.startsWith("file:") || url.includes("/node_modules/") || !/\.tsx?$/.test(url)) {
    return nextLoad(url, context);
  }
  const source = ts.transpileModule(readFileSync(new URL(url), "utf8"), {
    fileName: fileURLToPath(url),
    compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return { format: "module", source, shortCircuit: true };
}
