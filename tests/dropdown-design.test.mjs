import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("all dropdowns share the polished accessible control system", async () => {
  const css = await readFile(new URL("../app/components.css", import.meta.url), "utf8");

  assert.match(css, /select \{[\s\S]+appearance: none/);
  assert.match(css, /background-image: url\("data:image\/svg\+xml/);
  assert.match(css, /select:hover:not\(:disabled\)/);
  assert.match(css, /select:focus-visible/);
  assert.match(css, /select:disabled/);
  assert.match(css, /select option,[\s\S]+select optgroup/);
  assert.match(css, /:where\(\.column-menu, \.token-options, \.multi-value-menu\)/);
  assert.match(css, /:root\[data-theme="dark"\] select/);
});
