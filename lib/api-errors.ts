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
    limit: "statement_timeout",
    alternative,
  }, { status: 504 });
}
