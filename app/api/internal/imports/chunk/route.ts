import { importProspectChunk, type ProspectChunkPayload } from "../../../../../lib/import-batch.ts";
import { authorizeImportWorker } from "../../../../../lib/worker-auth.ts";

export async function POST(request: Request) {
  const unauthorized = authorizeImportWorker(request);
  if (unauthorized) return unauthorized;
  const result = await importProspectChunk(await request.json() as ProspectChunkPayload);
  return result.response ?? Response.json(result.data);
}
