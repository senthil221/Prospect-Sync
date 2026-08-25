import { Upload } from "tus-js-client";
import { createClient } from "./supabase/client.ts";
import { getPublicSupabaseEnv } from "./supabase/env.ts";

export async function prospectUploadFingerprint(file: File) {
  const sampleBytes = 1024 * 1024;
  const first = await file.slice(0, sampleBytes).arrayBuffer();
  const last = await file.slice(Math.max(0, file.size - sampleBytes)).arrayBuffer();
  const metadata = new TextEncoder().encode(`${file.name}\0${file.size}\0${file.lastModified}\0`);
  const joined = new Uint8Array(metadata.byteLength + first.byteLength + last.byteLength);
  joined.set(metadata, 0);
  joined.set(new Uint8Array(first), metadata.byteLength);
  joined.set(new Uint8Array(last), metadata.byteLength + first.byteLength);
  const digest = await crypto.subtle.digest("SHA-256", joined);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function uploadProspectCsv(file: File, objectPath: string, signature: string, onProgress: (percentage: number) => void) {
  const supabase = createClient();
  const { data: { session }, error } = await supabase.auth.getSession();
  if (error || !session) throw new Error("Your session expired. Sign in and try again.");
  const { url } = getPublicSupabaseEnv();
  return new Promise<void>((resolve, reject) => {
    try {
      const upload = new Upload(file, {
        endpoint: `${url.replace(/\/$/, "")}/storage/v1/upload/resumable`,
        retryDelays: [0, 1000, 3000, 5000, 10000, 20000],
        chunkSize: 6 * 1024 * 1024,
        uploadDataDuringCreation: true,
        removeFingerprintOnSuccess: true,
        headers: { authorization: `Bearer ${session.access_token}`, "x-signature": signature },
        metadata: {
          bucketName: "prospect-imports",
          objectName: objectPath,
          contentType: "text/csv",
          cacheControl: "0",
        },
        onError: (uploadError) => reject(uploadError),
        onProgress: (uploaded, total) => onProgress(total ? Math.round(uploaded / total * 100) : 0),
        onSuccess: () => resolve(),
      });
      void upload.findPreviousUploads().then((previous) => {
        if (previous.length) upload.resumeFromPreviousUpload(previous[0]);
        upload.start();
      }).catch(reject);
    } catch (caught) {
      reject(caught);
    }
  });
}
