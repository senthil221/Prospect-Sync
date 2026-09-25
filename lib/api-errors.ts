import { logServerEvent } from "./server-log.ts";
// Postgres cancels a statement that passes its statement_timeout with SQLSTATE
// 57014, and PostgREST forwards it as a plain error. Left alone it reaches the
// browser as a 500 carrying "canceling statement due to statement timeout",
// which reads as a crash: the user cannot tell a broken deployment from a filter
// that asked for more work than the database allows.
//
// It is deliberately not a 503 with Retry-After. The same request will exceed
// the same ceiling again, so inviting a retry is misleading; the answer is to
// ask for less. 504 says the work did not finish in time, and the body says what
// to change, mirroring the shape of the 413 that over-cap requests get.
const statementTimeoutCode = "57014";

export type DatabaseError = { code?: string; message?: string } | null | undefined;

export function isStatementTimeout(error: DatabaseError) {
  return error?.code === statementTimeoutCode;
}

export function statementTimeoutResponse(subject: string, alternative: string): Response {
  return Response.json({
    error: `${subject} took longer than the database allows. ${alternative}`,
    code: "statement_timeout",
    retryable: false,
    limit: "statement_timeout",
    alternative,
  }, { status: 504, headers: { "Cache-Control": "no-store" } });
}

// A browser that navigates away mid-request is not a server failure.
//
// Next.js raises ResponseAborted when the client goes; supabase-js hands it
// back where a database error would be, so it reached databaseErrorResponse and
// was recorded as a 500 - twice, once by the route and once by the observability
// wrapper, which logs anything >= 500 at error level. Three of the thirteen
// errors this application has ever recorded are that, and all three are someone
// closing a tab. An error log that cries wolf is the problem: the whole point of
// clearing the permanently-failing signals elsewhere in this project is that the
// remaining ones get read.
//
// MATCHED ON THE ERROR'S IDENTITY, NOT ON THE WORD "ABORTED". SQLSTATE 25P02 is
// "current transaction is aborted, commands ignored until end of transaction
// block" - a real failure, and one whose message contains the word. A substring
// match on "aborted" would hide it. A Postgres error always carries a five-
// character SQLSTATE and a client disconnect never does, so the code is checked
// first and its presence is disqualifying.
const disconnectNames = new Set(["AbortError", "ResponseAborted"]);
const disconnectCodes = new Set(["ABORT_ERR", "ECONNRESET", "ECONNABORTED"]);

export function isClientDisconnect(error: unknown): boolean {
  if (!error) return false;
  const candidate = error as { name?: string; code?: string; message?: string };
  const code = String(candidate.code ?? "");
  if (disconnectCodes.has(code)) return true;
  // A SQLSTATE means the database answered, so whatever went wrong went wrong
  // server-side. Five characters, letters and digits: 25P02, 57014, 42883.
  if (/^[0-9A-Z]{5}$/.test(code)) return false;
  if (candidate.name && disconnectNames.has(candidate.name)) return true;
  const message = String(candidate.message ?? "");
  return /\bResponseAborted\b|\bAbortError\b|The operation was aborted/.test(message);
}

// A 500 that records only its status is a dead end. Two of them landed on
// /api/prospects at 2026-09-10 18:00:44 UTC and the message was never written
// anywhere - the route returned error.message to the browser and the log kept
// the status alone, so afterwards there was no way to tell what had failed.
// This keeps the message, and the SQLSTATE, which is usually the whole answer.
export function databaseErrorResponse(subject: string, error: DatabaseError): Response {
  // 499 rather than 500, and no error row. outcomeFor() already reads anything
  // in the 4xx range as client_error, and the observability wrapper does not log
  // client_error at all - so answering with the honest status fixes both of the
  // two rows a disconnect used to write, without a second special case there.
  // Nothing reads the body: the connection it would travel down is gone.
  if (isClientDisconnect(error)) {
    return Response.json({ error: "The request was cancelled." }, { status: 499 });
  }
  const message = error?.message ?? "Unknown database error";
  console.error(`${subject} failed`, { code: error?.code, message });
  logServerEvent({
    level: "error", source: "api", statusCode: 500,
    message: `${subject}: ${message}`,
    detail: { code: error?.code ?? null },
  });
  return Response.json({ error: message }, { status: 500 });
}
