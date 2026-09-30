import { importProspectChunk, type ProspectChunkPayload } from "../../../../../lib/import-batch.ts";
import { authorizeImportWorker } from "../../../../../lib/worker-auth.ts";
import { observed } from "../../../../../lib/observability.ts";

async function handlePOST(request: Request) {
  const unauthorized = authorizeImportWorker(request);
  if (unauthorized) return unauthorized;
  const result = await importProspectChunk(await request.json() as ProspectChunkPayload);
  return result.response ?? Response.json(result.data);
}

export const POST = observed("/api/internal/imports/chunk", handlePOST);
