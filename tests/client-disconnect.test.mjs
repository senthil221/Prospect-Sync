import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

// A browser that navigates away is not a server failure.
//
// Next.js raises ResponseAborted when it writes to a connection the client has
// already closed. supabase-js hands it back where a database error would be, so
// it reached databaseErrorResponse and became a 500 - and then the observability
// wrapper, which logs anything >= 500 at error level, wrote a second row for the
// same non-event. Three of the thirteen errors this application had ever
// recorded were that, and all three were somebody closing a tab.
//
// This matters because of what the rest of the project has spent its time on:
// clearing signals that always say "failed" so the remaining ones get read. An
// error log with wolves in it is the same problem in a different place.
test("a client disconnect is recognised by identity, never by the word 'aborted'", async () => {
  const { isClientDisconnect } = await import("../lib/api-errors.ts");

  // The shapes a disconnect actually arrives in.
  assert.equal(isClientDisconnect({ message: "ResponseAborted: " }), true);
  assert.equal(isClientDisconnect({ name: "AbortError", message: "" }), true);
  assert.equal(isClientDisconnect({ message: "The operation was aborted." }), true);
  assert.equal(isClientDisconnect({ code: "ECONNRESET" }), true);
  assert.equal(isClientDisconnect({ code: "ABORT_ERR" }), true);

  // THE TRAP. SQLSTATE 25P02 is "current transaction is aborted, commands
  // ignored until end of transaction block" - a real failure whose message
  // contains the word. A substring match on "aborted" would silence it, and the
  // failure it silences is one that leaves a transaction wedged.
  assert.equal(isClientDisconnect({
    code: "25P02",
    message: "current transaction is aborted, commands ignored until end of transaction block",
  }), false, "25P02 is a real failure and must never be read as a disconnect");

  // A SQLSTATE means the database answered, so it is disqualifying on its own -
  // even if something downstream had also pasted a disconnect word into the
  // message.
  assert.equal(isClientDisconnect({ code: "57014", message: "canceling statement due to statement timeout" }), false);
  assert.equal(isClientDisconnect({ code: "42883", message: "function does not exist" }), false);
  assert.equal(isClientDisconnect({ code: "25P02", message: "ResponseAborted" }), false);

  // And the ordinary cases.
  assert.equal(isClientDisconnect(null), false);
  assert.equal(isClientDisconnect(undefined), false);
  assert.equal(isClientDisconnect({ message: "relation does not exist" }), false);
});

// Both halves answer 499, and neither writes an error row.
test("neither the returned nor the thrown disconnect path records a server error", async () => {
  const [errors, admission, observability] = await Promise.all([
    readFile(new URL("../lib/api-errors.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/admission.ts", import.meta.url), "utf8"),
    readFile(new URL("../lib/observability.ts", import.meta.url), "utf8"),
  ]);

  // The returned path: databaseErrorResponse checks before it logs, so the
  // check cannot be skipped by an early return added later.
  const body = errors.slice(errors.indexOf("export function databaseErrorResponse"));
  assert.ok(body.indexOf("isClientDisconnect(error)") < body.indexOf("logServerEvent"),
    "the disconnect check must come before anything is logged");
  assert.match(body, /status: 499/);

  // The thrown path: same, in the slot wrapper.
  const slot = admission.slice(admission.indexOf("} catch (error) {"));
  assert.ok(slot.indexOf("isClientDisconnect(error)") < slot.indexOf("logServerEvent"),
    "the wrapper must classify before it logs");
  assert.match(slot, /recordRequest\(route, 499,/);

  // 499 has to land in the band that is already treated as ordinary client
  // behaviour, or the fix moves the noise rather than removing it. This is the
  // reason 499 was chosen over a bespoke outcome: no second special case.
  const { outcomeFor } = await import("../lib/observability.ts");
  assert.equal(outcomeFor(499), "client_error");
  assert.equal(outcomeFor(500), "server_error");
  assert.doesNotMatch(observability, /outcome === "client_error"[^\n]*logServerEvent/);

  // The error still propagates - there is nobody left to answer, and swallowing
  // it would release the slot into a handler that thinks it succeeded.
  assert.match(slot, /if \(isClientDisconnect\(error\)\) \{[\s\S]{0,200}?throw error;/);
});
