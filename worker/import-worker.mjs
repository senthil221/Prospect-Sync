import { csvRows, uniqueHeaders } from "./csv-stream.mjs";
import { once } from "node:events";
import { finished } from "node:stream/promises";
import pg from "pg";
import { from as copyFrom } from "pg-copy-streams";
import { mapProspect, normalizeText } from "./prospect-map.mjs";

const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const restUrl = (process.env.SUPABASE_REST_URL ?? "http://rest:3000").replace(/\/$/, "");
const storageUrl = (process.env.SUPABASE_STORAGE_URL ?? "http://storage:5000").replace(/\/$/, "");
const appUrl = (process.env.IMPORT_APP_URL ?? "http://app-router:3000").replace(/\/$/, "");
const workerId = `${process.env.HOSTNAME ?? "import-worker"}:${process.pid}`;
const bucket = "prospect-imports";
const leaseSeconds = 300;
const batchSize = Math.max(100, Math.min(5000, Number(process.env.IMPORT_BATCH_SIZE ?? 1000)));
const skipImportField = "Skip column";
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

function copyText(value) {
  return String(value).replaceAll("\\", "\\\\").replaceAll("\t", "\\t").replaceAll("\n", "\\n").replaceAll("\r", "\\r");
}

function mappedPayload(headers, sourceValues, fieldMap, rowOffset) {
  const keptColumns = headers.map((header, column) => ({ header, column }))
    .filter(({ header }) => fieldMap?.[header] !== skipImportField);
  if (!keptColumns.length) throw new Error("FATAL: Every import column was skipped.");
  const keptHeaders = keptColumns.map(({ header }) => header);
  const values = keptColumns.map(({ column }) => String(sourceValues[column] ?? ""));
  const mappedHeaders = keptHeaders.map((header) => String(fieldMap?.[header] || header));
  const prospect = mapProspect(mappedHeaders, values);
  prospect.raw = Object.fromEntries(keptHeaders.map((header, index) => [header, String(values[index] ?? "").trim()]));
  const companyId = prospect.companyDomain
    ? `domain:${prospect.companyDomain}`
    : prospect.companyName ? `name:${normalizeText(prospect.companyName)}` : "";
  return { ...prospect, companyId, normalizedCompanyName: normalizeText(prospect.companyName), sourceRowNumber: rowOffset + 2 };
}

async function stageCsv(client, job, committedOffset) {
  const iterator = csvRows(await download(job.storageObjectPath))[Symbol.asyncIterator]();
  const first = await iterator.next();
  const headers = first.done ? [] : uniqueHeaders(first.value);
  const expected = Array.isArray(job.sourceHeaders) ? job.sourceHeaders.map(String) : [];
  if (!headers.length) throw new Error("FATAL: The stored CSV has no header.");
  if (JSON.stringify(headers) !== JSON.stringify(expected)) throw new Error("FATAL: Stored CSV headers do not match the reviewed field mapping.");

  await client.query("begin");
  let copy;
  try {
    await client.query("delete from prospect_import.staged_rows where import_id = $1", [job.id]);
    copy = client.query(copyFrom("copy prospect_import.staged_rows (import_id, row_offset, payload) from stdin"));
    let totalRows = 0;
    for await (const row of { [Symbol.asyncIterator]: () => iterator }) {
      const rowOffset = totalRows;
      totalRows += 1;
      if (rowOffset < committedOffset) continue;
      const payload = mappedPayload(headers, row, job.fieldMap ?? {}, rowOffset);
      const line = `${copyText(job.id)}\t${rowOffset}\t${copyText(JSON.stringify(payload))}\n`;
      if (!copy.write(line)) await once(copy, "drain");
      if (stopping) throw new Error("Worker is shutting down; import will resume automatically.");
    }
    if (totalRows === 0) throw new Error("FATAL: The stored CSV has no data rows.");
    copy.end();
    await finished(copy);
    await client.query("commit");
    return totalRows;
  } catch (error) {
    if (copy && !copy.destroyed) copy.destroy(error instanceof Error ? error : new Error(String(error)));
    if (copy) await finished(copy).catch(() => undefined);
    await client.query("rollback").catch(() => undefined);
    throw error;
  }
}

async function stageState(client, importId) {
  const result = await client.query(
    "select count(*)::integer as count, min(row_offset)::integer as minimum, max(row_offset)::integer as maximum from prospect_import.staged_rows where import_id = $1",
    [importId],
  );
  return result.rows[0];
}

async function processJob(job) {
  const client = new pg.Client({ application_name: "prospect-import-worker", connectionTimeoutMillis: 10000 });
  await client.connect();
  try {
    await client.query("set role prospect_importer");
    await client.query("set statement_timeout = '10min'");
    const committedStart = Number(job.committedRowOffset ?? 0);
    let state = await stageState(client, job.id);
    let totalRows = Number(job.totalRows ?? 0);
    const expectedRemaining = totalRows > 0 ? totalRows - committedStart : -1;
    const alreadyMerged = totalRows > 0 && committedStart === totalRows && state.count === 0;
    const reusable = state.count > 0 && state.minimum === committedStart
      && (expectedRemaining < 0 || (state.count === expectedRemaining && state.maximum === totalRows - 1));
    if (!reusable && !alreadyMerged) {
      totalRows = await stageCsv(client, job, committedStart);
      state = await stageState(client, job.id);
      if (state.count !== totalRows - committedStart) throw new Error("Staged row count does not match the CSV row count.");
    } else if (totalRows === 0) {
      totalRows = committedStart + state.count;
    }

    let committedRows = committedStart;
    await heartbeat(job, totalRows, committedRows);
    while (committedRows < totalRows) {
      const result = await client.query(
        "select * from prospect_import.process_staged_batch_v1($1, $2, $3, $4)",
        [job.id, job.listId, committedRows, batchSize],
      );
      const processed = Number(result.rows[0]?.processed ?? 0);
      if (processed <= 0) throw new Error(`No staged rows were processed at offset ${committedRows}.`);
      committedRows += processed;
      await heartbeat(job, totalRows, committedRows);
      if (stopping) throw new Error("Worker is shutting down; import will resume automatically.");
    }
  } finally {
    await client.end().catch(() => undefined);
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
    p_max_attempts: fatal ? 1 : 3,
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
