import { authorizeApi } from "../../../../lib/auth";
import { importProspectChunk, type ProspectChunkPayload } from "../../../../lib/import-batch.ts";
import { observed } from "../../../../lib/observability.ts";

async function handlePOST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const result = await importProspectChunk(await request.json() as ProspectChunkPayload);
  return result.response ?? Response.json(result.data);
}

export const POST = observed("/api/imports/chunk", handlePOST);
