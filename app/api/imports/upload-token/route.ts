import { authorizeApi } from "../../../../lib/auth.ts";
import { maximumProspectImportBytes, prospectImportBucket } from "../../../../lib/import-storage.ts";
import { createAdminClient } from "../../../../lib/supabase/admin.ts";

export async function POST(request: Request) {
  const unauthorized = await authorizeApi();
  if (unauthorized) return unauthorized;
  const { fileName, fileSize, fingerprint } = await request.json() as { fileName?: string; fileSize?: number; fingerprint?: string };
  if (!/\.csv$/i.test(String(fileName ?? ""))) return Response.json({ error: "Large background imports currently require CSV." }, { status: 400 });
  if (!Number.isSafeInteger(fileSize) || Number(fileSize) <= 0 || Number(fileSize) > maximumProspectImportBytes) {
    return Response.json({ error: "CSV files must be between 1 byte and 1 GB." }, { status: 400 });
  }
  if (!/^[0-9a-f]{64}$/i.test(String(fingerprint ?? ""))) return Response.json({ error: "Invalid upload fingerprint." }, { status: 400 });

  const supabase = createAdminClient();
  const bucket = await supabase.storage.getBucket(prospectImportBucket);
  if (bucket.error) {
    const created = await supabase.storage.createBucket(prospectImportBucket, {
      public: false,
      fileSizeLimit: maximumProspectImportBytes,
      allowedMimeTypes: ["text/csv", "text/plain", "application/csv", "application/vnd.ms-excel"],
    });
    if (created.error && !/already exists/i.test(created.error.message)) {
      return Response.json({ error: created.error.message }, { status: 500 });
    }
  }

  const objectPath = `pending/${fingerprint}.csv`;
  const existing = await supabase.storage.from(prospectImportBucket).list("pending", { search: `${fingerprint}.csv`, limit: 2 });
  if (existing.error) return Response.json({ error: existing.error.message }, { status: 500 });
  if (existing.data.some((item) => item.name === `${fingerprint}.csv`)) {
    return Response.json({ objectPath, alreadyUploaded: true });
  }
  const signed = await supabase.storage.from(prospectImportBucket).createSignedUploadUrl(objectPath);
  if (signed.error) return Response.json({ error: signed.error.message }, { status: 500 });
  return Response.json({ objectPath, token: signed.data.token, alreadyUploaded: false });
}
