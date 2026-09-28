import assert from "node:assert/strict";
import test from "node:test";
import {
  MAX_MANUAL_VERIFICATION_EMAILS,
  parseManualVerificationEmailLimit,
} from "../lib/verification-limits.ts";

test("manual verification email limit preserves omitted legacy requests", () => {
  assert.equal(parseManualVerificationEmailLimit(undefined), undefined);
  assert.equal(parseManualVerificationEmailLimit(null), undefined);
});

test("manual verification email limit accepts only bounded integer JSON numbers", () => {
  assert.equal(parseManualVerificationEmailLimit(1), 1);
  assert.equal(parseManualVerificationEmailLimit(10_000), 10_000);
  assert.equal(parseManualVerificationEmailLimit(MAX_MANUAL_VERIFICATION_EMAILS), 200_000);
  for (const value of [0, -1, 1.5, 200_001, Number.NaN, Number.POSITIVE_INFINITY, "10000", "", true]) {
    assert.throws(() => parseManualVerificationEmailLimit(value), /whole number from 1 to 2,00,000/);
  }
});
