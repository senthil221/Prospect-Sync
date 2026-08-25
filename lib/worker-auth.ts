import { timingSafeEqual } from "node:crypto";

export function authorizeImportWorker(request: Request) {
  const expected = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
  const supplied = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  const expectedBuffer = Buffer.from(expected);
  const suppliedBuffer = Buffer.from(supplied);
  const allowed = expectedBuffer.length > 0
    && expectedBuffer.length === suppliedBuffer.length
    && timingSafeEqual(expectedBuffer, suppliedBuffer);
  return allowed ? null : Response.json({ error: "Unauthorized" }, { status: 401 });
}
