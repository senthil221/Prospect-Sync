import { csvRows, uniqueHeaders } from "./csv-stream.mjs";

const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const restUrl = (process.env.SUPABASE_REST_URL ?? "http://rest:3000").replace(/\/$/, "");
const storageUrl = (process.env.SUPABASE_STORAGE_URL ?? "http://storage:5000").replace(/\/$/, "");
const appUrl = (process.env.IMPORT_APP_URL ?? "http://app-router:3000").replace(/\/$/, "");
const workerId = `${process.env.HOSTNAME ?? "import-worker"}:${process.pid}`;
const bucket = "prospect-imports";
const leaseSeconds = 300;
const batchSize = Math.max(25, Math.min(250, Number(process.env.IMPORT_BATCH_SIZE ?? 250)));
let stopping = false;

if (!serviceKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required by the import worker.");
process.on("SIGTERM", () => { stopping = true; });
process.on("SIGINT", () => { stopping = true; });

const authHeaders = { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function rpc(name, body) {
  const response = await fetch(`${restUrl}/rpc/${name}`, {
    method: "POST",
    headers: { ...authHeaders, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) throw new Error(data?.message || data?.error || `${name} returned HTTP ${response.status}`);
  return data;
}

function objectUrl(path) {
  return `${storageUrl}/object/${bucket}/${path.split("/").map(encodeURIComponent).join("/")}`;
}

async function download(path) {
  const response = await fetch(objectUrl(path), { headers: authHeaders });
  if (!response.ok || !response.body) throw new Error(`Stored CSV download returned HTTP ${response.status}`);
  return response.body;
}

async function removeObject(path) {
  const response = await fetch(`${storageUrl}/object/${bucket}`, {
    method: "DELETE",
    headers: { ...authHeaders, "content-type": "application/json" },
    body: JSON.stringify({ prefixes: [path] }),
  });
  if (!response.ok) console.error(`Could not remove completed import object ${path}: HTTP ${response.status}`);
}

async function inspectCsv(job) {
  let headers = null;
  let totalRows = 0;
  for await (const row of csvRows(await download(job.storageObjectPath))) {
    if (!headers) headers = uniqueHeaders(row);
    else totalRows += 1;
  }
  if (!headers?.length || totalRows === 0) throw new Error("FATAL: The stored CSV has no header or data rows.");
  const expected = Array.isArray(job.sourceHeaders) ? job.sourceHeaders.map(String) : [];
  if (JSON.stringify(headers) !== JSON.stringify(expected)) throw new Error("FATAL: Stored CSV headers do not match the reviewed field mapping.");
  return { headers, totalRows };
}

async function heartbeat(job, totalRows, committedRows) {
  const processedBytes = totalRows > 0
    ? Math.min(Number(job.fileSizeBytes ?? 0), Math.round(Number(job.fileSizeBytes ?? 0) * committedRows / totalRows))
    : 0;
  const renewed = await rpc("heartbeat_prospect_import_v1", {
    p_import_id: job.id,
    p_worker_id: workerId,
    p_lease_seconds: leaseSeconds,
    p_total_rows: totalRows,
    p_processed_bytes: processedBytes,
  });
  if (renewed !== true) throw new Error("Import lease was lost.");
}

async function postApp(path, body) {
  const response = await fetch(`${appUrl}${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${serviceKey}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) throw new Error(data?.error || `${path} returned HTTP ${response.status}`);
  return data;
}

async function commitBatch(job, headers, rows, rowOffset, attempt = 0) {
  try {
    return await postApp("/api/internal/imports/chunk", {
      importId: job.id,
      listId: job.listId,
      headers,
      rows,
      rowOffset,
      fieldMap: job.fieldMap ?? {},
    });
  } catch (error) {
    if (attempt < 2) {
      await wait(1000 * 2 ** attempt);
      return commitBatch(job, headers, rows, rowOffset, attempt + 1);
    }
    if (rows.length > 25) {
      const middle = Math.ceil(rows.length / 2);
      await commitBatch(job, headers, rows.slice(0, middle), rowOffset);
      return commitBatch(job, headers, rows.slice(middle), rowOffset + middle);
    }
    throw error;
  }
}

async function processJob(job) {
  const inspected = await inspectCsv(job);
  await heartbeat(job, inspected.totalRows, Number(job.committedRowOffset ?? 0));
  let sourceIndex = 0;
  let pending = [];

  for await (const row of csvRows(await download(job.storageObjectPath))) {
    if (sourceIndex === 0) { sourceIndex += 1; continue; }
    const rowOffset = sourceIndex - 1;
    sourceIndex += 1;
    if (rowOffset < Number(job.committedRowOffset ?? 0)) continue;
    pending.push(row);
    if (pending.length < batchSize) continue;
    const offset = rowOffset - pending.length + 1;
    await commitBatch(job, inspected.headers, pending, offset);
    await heartbeat(job, inspected.totalRows, offset + pending.length);
    pending = [];
    if (stopping) throw new Error("Worker is shutting down; import will resume automatically.");
    await wait(50);
  }
  if (pending.length) {
    const offset = inspected.totalRows - pending.length;
    await commitBatch(job, inspected.headers, pending, offset);
    await heartbeat(job, inspected.totalRows, inspected.totalRows);
  }
  await postApp("/api/internal/imports/complete", { importId: job.id, listId: job.listId });
  await removeObject(job.storageObjectPath).catch((error) => console.error("Could not remove completed import object", error));
}

async function failOrRetry(job, error) {
  const message = error instanceof Error ? error.message : String(error);
  const fatal = message.startsWith("FATAL:");
  const retrySeconds = Math.min(3600, 15 * 2 ** Math.min(Number(job.attemptCount ?? 1) - 1, 8));
  await rpc("retry_prospect_import_v1", {
    p_import_id: job.id,
    p_worker_id: workerId,
    p_error: message.replace(/^FATAL:\s*/, ""),
    p_retry_seconds: retrySeconds,
    p_max_attempts: fatal ? 1 : 10,
  }).catch((retryError) => console.error("Could not record import retry", retryError));
}

async function main() {
  console.log(`Prospect import worker ${workerId} started; batch size ${batchSize}.`);
  while (!stopping) {
    let job = null;
    try {
      job = await rpc("claim_next_prospect_import_v1", { p_worker_id: workerId, p_lease_seconds: leaseSeconds });
      if (!job) { await wait(3000); continue; }
      console.log(`Processing import ${job.id} from row ${job.committedRowOffset ?? 0}.`);
      await processJob(job);
      console.log(`Completed import ${job.id}.`);
    } catch (error) {
      console.error(`Import ${job?.id ?? "claim"} failed`, error);
      if (job) await failOrRetry(job, error);
      else await wait(5000);
    }
  }
  console.log("Prospect import worker stopped.");
}

await main();
