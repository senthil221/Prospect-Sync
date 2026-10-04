import assert from "node:assert/strict";
import test from "node:test";
import { bindAbortToPgSession } from "../worker/abortable-pg-session.mjs";

test("worker shutdown destroys an active PostgreSQL session exactly once", async () => {
  const controller = new AbortController();
  let endCalls = 0;
  let releaseEnd;
  const ended = new Promise(resolve => { releaseEnd = resolve; });
  const detach = bindAbortToPgSession({
    end: async () => {
      endCalls += 1;
      await ended;
    },
  }, controller.signal);

  controller.abort(new Error("worker shutdown"));
  controller.abort(new Error("duplicate shutdown"));
  await Promise.resolve();
  assert.equal(endCalls, 1);

  let detached = false;
  const waiting = detach().then(() => { detached = true; });
  await Promise.resolve();
  assert.equal(detached, false, "cleanup must wait for the socket to close");
  releaseEnd();
  await waiting;
  assert.equal(detached, true);
});

test("an already-aborted job cannot acquire a live PostgreSQL session", async () => {
  const controller = new AbortController();
  controller.abort(new Error("shutdown won the acquisition race"));
  let endCalls = 0;
  const detach = bindAbortToPgSession({ end: async () => { endCalls += 1; } }, controller.signal);
  await detach();
  assert.equal(endCalls, 1);
});

test("socket cleanup is bounded even if the driver never acknowledges end", async () => {
  const controller = new AbortController();
  const detach = bindAbortToPgSession({ end: () => new Promise(() => undefined) }, controller.signal, 5);
  controller.abort(new Error("shutdown"));
  await assert.doesNotReject(detach());
});
