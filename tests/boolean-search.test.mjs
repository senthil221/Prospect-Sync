import assert from "node:assert/strict";
import test from "node:test";
import { compileBooleanSearch } from "../lib/boolean-search.ts";

test("compiles Apollo-style Boolean expressions with stable precedence", () => {
  assert.equal(compileBooleanSearch("Sales OR Product AND NOT Design"), "('sales' | ('product' & !('design')))");
  assert.equal(compileBooleanSearch("(Sales OR Product) AND Design"), "(('sales' | 'product') & 'design')");
});

test("supports quoted phrases and implicit AND without passing SQL through", () => {
  assert.equal(compileBooleanSearch('"Product Design" manager'), "(('product' <-> 'design') & 'manager')");
  const compiled = compileBooleanSearch("sales';drop");
  assert.equal(compiled, "('sales' & 'drop')");
  assert.doesNotMatch(compiled, /[;)]\s*drop/i);
});

test("rejects malformed Boolean expressions", () => {
  assert.throws(() => compileBooleanSearch("Sales AND"), /word or phrase/);
  assert.throws(() => compileBooleanSearch("(Sales OR Marketing"), /parenthesis/);
  assert.throws(() => compileBooleanSearch('""'), /cannot be empty/);
});
