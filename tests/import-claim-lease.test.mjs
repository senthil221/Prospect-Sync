import assert from "node:assert/strict";
import test from "node:test";
import { ImportClaimLease, ImportOwnershipLostError, isDefinitiveClaimLoss } from "../worker/import-claim-lease.mjs";

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const acknowledged = (overrides = {}) => ({
  status: "processing",
  leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
  ...overrides,
});

test("renewals serialize even when one heartbeat is blocked", async () => {
  let active = 0;
  let maximum = 0;
  let calls = 0;
  const lease = new ImportClaimLease({
    leaseMilliseconds: 200,
    renewEveryMilliseconds: 5,
    retryEveryMilliseconds: 5,
    safetyMilliseconds: 20,
    renew: async () => {
      calls += 1;
      active += 1;
      maximum = Math.max(maximum, active);
      await sleep(calls === 2 ? 25 : 2);
      active -= 1;
      return acknowledged();
    },
    readState: async () => acknowledged(),
  });
  await lease.start();
  await sleep(45);
  await lease.stop();
  assert.equal(maximum, 1);
  assert.ok(calls >= 2);
  assert.equal(lease.signal.aborted, false);
});

test("transport timeouts retry only inside the last acknowledged lease budget", async () => {
  let calls = 0;
  const lease = new ImportClaimLease({
    leaseMilliseconds: 70,
    renewEveryMilliseconds: 5,
    retryEveryMilliseconds: 5,
    safetyMilliseconds: 15,
    renew: async () => {
      calls += 1;
      if (calls === 1) return acknowledged();
      throw new Error("network timeout");
    },
    readState: async () => acknowledged(),
  });
  await lease.start();
  await sleep(80);
  assert.equal(lease.signal.aborted, true);
  assert.ok(lease.signal.reason instanceof ImportOwnershipLostError);
  await lease.stop();
});

test("a heartbeat queued behind completion records the receipt instead of losing ownership", async () => {
  let calls = 0;
  const receipt = "00000000-0000-4000-8000-000000000001";
  const lease = new ImportClaimLease({
    leaseMilliseconds: 100,
    renewEveryMilliseconds: 5,
    renew: async () => (++calls === 1 ? acknowledged() : { status: "completed", completionReceipt: receipt }),
    readState: async () => ({ status: "completed", completionReceipt: receipt }),
  });
  await lease.start();
  await sleep(20);
  assert.equal(lease.signal.aborted, false);
  assert.equal(lease.terminal?.completionReceipt, receipt);
  await lease.stop();
});

test("missing acknowledgements fail closed and validation errors are not misclassified as claim loss", async () => {
  const lease = new ImportClaimLease({
    renew: async () => ({ status: "processing" }),
    readState: async () => null,
  });
  await assert.rejects(lease.start(), ImportOwnershipLostError);
  assert.equal(isDefinitiveClaimLoss({ code: "P0002", message: "Durable stage is missing a contiguous batch" }), false);
  assert.equal(isDefinitiveClaimLoss({ code: "P0002", message: "IMPORT_CLAIM_LOST" }), true);
});
