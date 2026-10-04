import { csvRows, uniqueHeaders } from "./csv-stream.mjs";
import { once } from "node:events";
import { finished } from "node:stream/promises";
import pg from "pg";
import { from as copyFrom } from "pg-copy-streams";
import { createServer } from "node:http";
import { mapProspect, normalizeText, stripUnstorableCharacters } from "./prospect-map.mjs";
import { bindAbortToPgSession } from "./abortable-pg-session.mjs";
import { ImportClaimLease, ImportOwnershipLostError, isDefinitiveClaimLoss } from "./import-claim-lease.mjs";
import { pgInterval, pgIntervalMilliseconds } from "./pg-interval.mjs";
import { createWorkerPhaseMetrics } from "./phase-metrics.mjs";

const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const storageUrl = (process.env.SUPABASE_STORAGE_URL ?? "http://storage:5000").replace(/\/$/u, "");
const workerId = `${process.env.HOSTNAME ?? "import-worker"}:${process.pid}`;
const bucket = "prospect-imports";
const protocolVersion = 2;
const leaseSeconds = 300;
const renewalSeconds = 60;
const shutdownRetryBudgetMs = 4_000;
const batchSize = Math.max(100, Math.min(5000, Number(process.env.IMPORT_BATCH_SIZE ?? 1000)));
const batchTimeout = pgInterval(process.env.IMPORT_BATCH_TIMEOUT, "120s", "IMPORT_BATCH_TIMEOUT");
const stagingTimeout = pgInterval(process.env.IMPORT_STAGING_TIMEOUT, "10min", "IMPORT_STAGING_TIMEOUT");
const publicationTimeout = pgInterval(process.env.IMPORT_PUBLICATION_TIMEOUT, "120s", "IMPORT_PUBLICATION_TIMEOUT");
const batchTimeoutMs = pgIntervalMilliseconds(batchTimeout);
const stagingTimeoutMs = pgIntervalMilliseconds(stagingTimeout);
const personImportFields = new Set(["First Name", "Last Name", "Job Title", "Email", "Mobile Number", "Personal LinkedIn URL", "Company Name", "Website"]);
const importPool = new pg.Pool({
  application_name: "prospect-import-worker-v2",
  max: 3,
  connectionTimeoutMillis: 10_000,
  idleTimeoutMillis: 30_000,
});
importPool.on("error", error => console.error("Idle import database connection failed", error?.message ?? error));
let stopping = false;
let activeAbortController = null;
let lastProgressAt = Date.now();
let activeImportId = "";
let activePhase = "idle";
let activePhaseStartedAt = 0;
let activePhaseDeadlineAt = 0;
const metrics = createWorkerPhaseMetrics({ worker: "import-worker", phases: ["claim", "stage", "merge", "complete", "retry"] });

if (!serviceKey) throw new Error("SUPABASE_SERVICE_ROLE_KEY is required by the import worker.");

const shutdown = () => {
  stopping = true;
  activeAbortController?.abort(new Error("Import worker is shutting down."));
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

const authHeaders = { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const markProgress = (importId = activeImportId) => { lastProgressAt = Date.now(); activeImportId = importId; };
const beginPhase = (phase, budgetMs) => {
  activePhase = phase;
  activePhaseStartedAt = Date.now();
  activePhaseDeadlineAt = activePhaseStartedAt + budgetMs;
};
const endPhase = () => {
  markProgress();
  activePhase = "idle";
  activePhaseStartedAt = 0;
  activePhaseDeadlineAt = 0;
};

const healthServer = createServer((request, response) => {
  if (request.url !== "/health") { response.writeHead(404).end(); return; }
  const now = Date.now();
  const ageMs = now - lastProgressAt;
  const activeWithinBudget = activePhase !== "idle" && now <= activePhaseDeadlineAt;
  const healthy = !stopping && (ageMs < 180_000 || activeWithinBudget);
  response.writeHead(healthy ? 200 : 503, { "content-type": "application/json", "cache-control": "no-store" });
  response.end(JSON.stringify({ status: healthy ? "ok" : "stale", protocolVersion,
    activeImportId: activeImportId || null, ageMs, activePhase,
    activePhaseAgeMs: activePhaseStartedAt ? now - activePhaseStartedAt : 0 }));
});

function objectUrl(path) {
  return `${storageUrl}/object/${bucket}/${path.split("/").map(encodeURIComponent).join("/")}`;
}

function linkedSignal(...signals) {
  const live = signals.filter(Boolean);
  return live.length ? AbortSignal.any(live) : undefined;
}

async function fetchWithDeadline(url, options, timeoutMilliseconds, parentSignal) {
  return fetch(url, { ...options, signal: linkedSignal(parentSignal, AbortSignal.timeout(timeoutMilliseconds)) });
}

async function download(path, signal) {
  const controller = new AbortController();
  const abortFromParent = () => controller.abort(signal?.reason ?? new Error("Import download aborted."));
  signal?.addEventListener("abort", abortFromParent, { once: true });
  const headerTimer = setTimeout(() => controller.abort(new Error("Stored CSV response headers timed out.")), 30_000);
  try {
    const response = await fetch(objectUrl(path), { headers: authHeaders, signal: controller.signal });
    clearTimeout(headerTimer);
    if (!response.ok || !response.body) {
      signal?.removeEventListener("abort", abortFromParent);
      throw new Error(`Stored CSV download returned HTTP ${response.status}`);
    }
    return {
      body: response.body,
      cleanup: () => signal?.removeEventListener("abort", abortFromParent),
    };
  } catch (error) {
    clearTimeout(headerTimer);
    signal?.removeEventListener("abort", abortFromParent);
    throw error;
  }
}

async function removeObject(path, signal) {
  const response = await fetchWithDeadline(`${storageUrl}/object/${bucket}`, {
    method: "DELETE",
    headers: { ...authHeaders, "content-type": "application/json" },
    body: JSON.stringify({ prefixes: [path] }),
  }, 15_000, signal);
  if (!response.ok) console.error(`Could not remove completed import object ${path}: HTTP ${response.status}`);
}

function copyText(value) {
  return String(value).replaceAll("\\", "\\\\").replaceAll("\t", "\\t").replaceAll("\n", "\\n").replaceAll("\r", "\\r");
}

function mappedPayload(headers, sourceValues, fieldMap, rowOffset) {
  const keptColumns = headers.map((header, column) => ({ header, column }))
    .map(column => ({ ...column, field: String(fieldMap?.[column.header] ?? "") }))
    .filter(({ field }) => personImportFields.has(field));
  if (!keptColumns.length) throw new Error("FATAL: Every import column was skipped.");
  const keptHeaders = keptColumns.map(({ field }) => field);
  const values = keptColumns.map(({ column }) => stripUnstorableCharacters(String(sourceValues[column] ?? "")));
  const prospect = mapProspect(keptHeaders, values);
  prospect.raw = Object.fromEntries(keptHeaders.map((header, index) => [header, String(values[index] ?? "").trim()]));
  if (!prospect.identifiers.length) throw new Error(`FATAL: Source row ${rowOffset + 2} has no usable identity (email, LinkedIn, or name plus company/website).`);
  const companyId = prospect.companyDomain
    ? `domain:${prospect.companyDomain}`
    : prospect.companyName ? `name:${normalizeText(prospect.companyName)}` : "";
  return { ...prospect, companyId, normalizedCompanyName: normalizeText(prospect.companyName), sourceRowNumber: rowOffset + 2 };
}

function boundedDbQuery(client, text, values = [], queryTimeout = 10_000) {
  return client.query({ text, values, query_timeout: queryTimeout });
}

async function importerClient({ statementTimeout = "10s", lockTimeout = "10s" } = {}) {
  const client = await importPool.connect();
  try {
    await boundedDbQuery(client, "set role prospect_importer");
    await boundedDbQuery(client, `set statement_timeout='${statementTimeout}'`);
    await boundedDbQuery(client, `set lock_timeout='${lockTimeout}'`);
    return client;
  } catch (error) {
    client.release(true);
    throw error;
  }
}

async function claimNext() {
  const client = await importerClient({ statementTimeout: "5s", lockTimeout: "3s" });
  try {
    const result = await client.query({ text: "select prospect_import.claim_next_v2($1,$2) claim",
      values: [workerId, leaseSeconds], query_timeout: 7_000 });
    return result.rows[0]?.claim ?? null;
  } finally {
    client.release();
  }
}

function createRenewalTransport(shutdownSignal) {
  let client = null;
  let detachClientAbort = async () => undefined;

  const discardClient = async (force = true) => {
    const discarded = client;
    const detach = detachClientAbort;
    client = null;
    detachClientAbort = async () => undefined;
    await detach();
    if (discarded) {
      try { discarded.release(force); } catch { /* Shutdown may already have ended the socket. */ }
    }
  };

  return {
    async query(text, values) {
      if (!client) {
        client = await importerClient({ statementTimeout: "8s", lockTimeout: "8s" });
        detachClientAbort = bindAbortToPgSession(client, shutdownSignal);
        if (shutdownSignal.aborted) {
          await discardClient();
          throw shutdownSignal.reason;
        }
      }
      try {
        return await client.query({ text, values, query_timeout: 10_000 });
      } catch (error) {
        await discardClient();
        throw error;
      }
    },
    async close() {
      await discardClient(shutdownSignal.aborted);
    },
  };
}

function createLease(job, transport) {
  const args = [job.id, job.listId, workerId, job.claimToken];
  return new ImportClaimLease({
    leaseMilliseconds: leaseSeconds * 1000,
    renewEveryMilliseconds: renewalSeconds * 1000,
    renew: async ({ totalRows, processedBytes }) => {
      markProgress(job.id);
      const result = await transport.query(
        "select prospect_import.renew_claim_v2($1,$2,$3,$4,$5,$6,$7) state",
        [...args, leaseSeconds, totalRows, processedBytes],
      );
      return result.rows[0]?.state;
    },
    readState: async () => {
      const result = await transport.query("select prospect_import.claim_state_v2($1,$2,$3,$4) state", args);
      return result.rows[0]?.state;
    },
  });
}

async function stageState(client, job) {
  const result = await client.query({ text: "select prospect_import.stage_state_v2($1,$2,$3,$4) state",
    values: [job.id, job.listId, workerId, job.claimToken], query_timeout: 15_000 });
  return result.rows[0]?.state ?? {};
}

async function stageCsv(client, job, committedOffset, lease, shutdownSignal) {
  await boundedDbQuery(client, `set statement_timeout='${stagingTimeout}'`);
  await boundedDbQuery(client, "drop table if exists pg_temp.prospect_import_stage_buffer");
  await boundedDbQuery(client, "create temporary table prospect_import_stage_buffer(row_offset integer primary key,payload jsonb not null) on commit preserve rows");
  let copy;
  let responseBody;
  let cleanupDownload = () => undefined;
  const stageController = new AbortController();
  const stageTimer = setTimeout(() => stageController.abort(new Error("Import staging timed out.")), stagingTimeoutMs);
  const stageSignal = linkedSignal(shutdownSignal, lease.signal, stageController.signal);
  const abortCopy = () => copy?.destroy(stageSignal.reason ?? new Error("Import staging aborted."));
  stageSignal.addEventListener("abort", abortCopy, { once: true });
  try {
    const downloaded = await download(job.storageObjectPath, stageSignal);
    responseBody = downloaded.body;
    cleanupDownload = downloaded.cleanup;
    const iterator = csvRows(responseBody)[Symbol.asyncIterator]();
    const first = await iterator.next();
    const headers = first.done ? [] : uniqueHeaders(first.value);
    const expected = Array.isArray(job.sourceHeaders) ? job.sourceHeaders.map(String) : [];
    if (!headers.length) throw new Error("FATAL: The stored CSV has no header.");
    if (JSON.stringify(headers) !== JSON.stringify(expected)) throw new Error("FATAL: Stored CSV headers do not match the reviewed field mapping.");

    // Do not keep a database transaction open while waiting for Storage.  COPY
    // itself is transactional, and the temporary buffer belongs to this
    // connection, so the transaction only needs to cover the streamed write.
    await boundedDbQuery(client, "begin");
    copy = client.query(copyFrom("copy prospect_import_stage_buffer(row_offset,payload) from stdin"));
    let totalRows = 0;
    for await (const row of { [Symbol.asyncIterator]: () => iterator }) {
      if (stageSignal.aborted) throw stageSignal.reason;
      const rowOffset = totalRows;
      totalRows += 1;
      if (totalRows % 10_000 === 0) markProgress(job.id);
      if (rowOffset < committedOffset) continue;
      const body = mappedPayload(headers, row, job.fieldMap ?? {}, rowOffset);
      if (!copy.write(`${rowOffset}\t${copyText(JSON.stringify(body))}\n`)) await once(copy, "drain");
    }
    if (totalRows === 0) throw new Error("FATAL: The stored CSV has no data rows.");
    copy.end();
    await finished(copy);
    await boundedDbQuery(client, "commit", [], 15_000);

    // Publication holds the import row lock, so it uses a batch-sized bound
    // instead of inheriting the ten-minute COPY ceiling.
    if (stageSignal.aborted) throw stageSignal.reason;
    await boundedDbQuery(client, `set statement_timeout='${publicationTimeout}'`);
    const published = await client.query({
      text: "select prospect_import.publish_temp_stage_v2($1,$2,$3,$4,'pg_temp.prospect_import_stage_buffer'::regclass,$5,$6) state",
      values: [job.id, job.listId, workerId, job.claimToken, totalRows, Number(job.fileSizeBytes ?? 0)],
      query_timeout: pgIntervalMilliseconds(publicationTimeout) + 15_000,
    });
    return { totalRows, state: published.rows[0]?.state };
  } catch (error) {
    if (copy && !copy.destroyed) copy.destroy(error instanceof Error ? error : new Error(String(error)));
    if (copy) await finished(copy).catch(() => undefined);
    await boundedDbQuery(client, "rollback", [], 5_000).catch(() => undefined);
    throw error;
  } finally {
    stageSignal.removeEventListener("abort", abortCopy);
    clearTimeout(stageTimer);
    if (!stageController.signal.aborted) stageController.abort(new Error("Import staging finished."));
    cleanupDownload();
    await boundedDbQuery(client, "drop table if exists pg_temp.prospect_import_stage_buffer", [], 5_000).catch(() => undefined);
  }
}

async function completeClaim(client, lease, job) {
  const args = [job.id, job.listId, workerId, job.claimToken];
  try {
    const result = await client.query({ text: "select prospect_import.complete_claim_v2($1,$2,$3,$4) result",
      values: args, query_timeout: 135_000 });
    return result.rows[0]?.result;
  } catch (error) {
    if (isDefinitiveClaimLoss(error)) throw error;
    // A response can be lost after COMMIT. Recover the token-specific receipt
    // instead of issuing a blind second completion.
    const state = await lease.readAuthoritativeState().catch(() => null);
    if (state?.status === "completed" && state?.completionReceipt) return state;
    throw error;
  }
}

async function processJob(job) {
  markProgress(job.id);
  const jobAbort = new AbortController();
  activeAbortController = jobAbort;
  let mergeClient = null;
  let renewalTransport = null;
  let lease = null;
  let detachMergeAbort = async () => undefined;
  let completed = false;
  const stageStarted = performance.now();
  let mergeStarted = 0;
  try {
    mergeClient = await importerClient({ statementTimeout: stagingTimeout, lockTimeout: "30s" });
    detachMergeAbort = bindAbortToPgSession(mergeClient, jobAbort.signal);
    if (jobAbort.signal.aborted) throw jobAbort.signal.reason;
    renewalTransport = createRenewalTransport(jobAbort.signal);
    lease = createLease(job, renewalTransport);
    await lease.start();
    beginPhase("stage", stagingTimeoutMs + 15_000);
    const committedStart = Number(job.committedRowOffset ?? 0);
    let state = await stageState(mergeClient, job);
    let totalRows = Number(job.totalRows ?? 0);
    const expectedRemaining = totalRows > 0 ? totalRows - committedStart : -1;
    const alreadyMerged = totalRows > 0 && committedStart === totalRows && Number(state.count ?? 0) === 0;
    const reusable = Number(state.count ?? 0) > 0 && Number(state.minimum) === committedStart
      && (expectedRemaining < 0 || (Number(state.count) === expectedRemaining && Number(state.maximum) === totalRows - 1));
    if (!reusable && !alreadyMerged) {
      const staged = await stageCsv(mergeClient, job, committedStart, lease, jobAbort.signal);
      totalRows = staged.totalRows;
      state = staged.state ?? await stageState(mergeClient, job);
      if (Number(state.count) !== totalRows - committedStart) throw new Error("Staged row count does not match the CSV row count.");
    } else if (totalRows === 0) {
      totalRows = committedStart + Number(state.count ?? 0);
    }
    lease.setProgress({ totalRows, processedBytes: Number(job.fileSizeBytes ?? 0) });
    metrics.record("stage", reusable || alreadyMerged ? "skipped" : "ok", performance.now() - stageStarted,
      Math.max(0, totalRows - committedStart));
    endPhase();

    await mergeClient.query(`set statement_timeout = '${batchTimeout}'`);
    let committedRows = committedStart;
    mergeStarted = performance.now();
    let mergedRows = 0;
    while (committedRows < totalRows) {
      if (lease.signal.aborted) throw lease.signal.reason;
      if (jobAbort.signal.aborted) throw jobAbort.signal.reason;
      beginPhase("merge", batchTimeoutMs + 15_000);
      const expectedCount = Math.min(batchSize, totalRows - committedRows);
      let row;
      try {
        const result = await mergeClient.query({
          text: "select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,$5,$6)",
          values: [job.id, job.listId, workerId, job.claimToken, committedRows, expectedCount],
          query_timeout: batchTimeoutMs + 15_000,
        });
        row = result.rows[0];
      } catch (error) {
        if (isDefinitiveClaimLoss(error) || lease.signal.aborted) throw error;
        const authoritative = await lease.readAuthoritativeState().catch(() => null);
        const authoritativeCursor = Number(authoritative?.committedRowOffset ?? -1);
        if (authoritativeCursor === committedRows + expectedCount) {
          row = { processed: expectedCount, committed_row_offset: authoritativeCursor };
        } else {
          throw error;
        }
      }
      const authoritativeCursor = Number(row?.committed_row_offset ?? -1);
      if (authoritativeCursor !== committedRows + expectedCount) {
        throw new Error(`Database returned an unexpected import cursor at row ${committedRows}.`);
      }
      committedRows = authoritativeCursor;
      mergedRows += expectedCount;
      lease.setProgress({ totalRows, processedBytes: totalRows > 0
        ? Math.min(Number(job.fileSizeBytes ?? 0), Math.round(Number(job.fileSizeBytes ?? 0) * committedRows / totalRows)) : 0 });
      endPhase();
    }
    metrics.record("merge", "ok", performance.now() - mergeStarted, mergedRows);

    const completeStarted = performance.now();
    beginPhase("complete", 135_000);
    if (lease.signal.aborted) throw lease.signal.reason;
    if (jobAbort.signal.aborted) throw jobAbort.signal.reason;
    await mergeClient.query("set statement_timeout='120s'");
    const completion = await completeClaim(mergeClient, lease, job);
    if (completion?.status !== "completed" || !completion?.completionReceipt) {
      throw new Error("Database completion did not return a durable receipt.");
    }
    lease.markCompleted(completion);
    completed = true;
    metrics.record("complete", "ok", performance.now() - completeStarted);
    endPhase();

    await removeObject(job.storageObjectPath, jobAbort.signal).catch(error => console.error("Could not remove completed import object", error));
    await mergeClient.query("set statement_timeout='20s'").catch(() => undefined);
    await mergeClient.query({ text: "select prospect_import.analyze_after_import_v2()", query_timeout: 25_000 }).catch(error => {
      console.error("Post-import ANALYZE failed without affecting completed import", error?.message ?? error);
    });
  } catch (error) {
    const phase = activePhase;
    if (phase === "stage") metrics.record("stage", "error", performance.now() - stageStarted);
    else if (phase === "merge") metrics.record("merge", "error", performance.now() - mergeStarted);
    else if (phase === "complete") metrics.record("complete", "error", 0);
    endPhase();
    throw error;
  } finally {
    if (!completed && stopping) lease?.abort(new Error("Import worker is shutting down."));
    await lease?.stop();
    await Promise.all([renewalTransport?.close(), detachMergeAbort()]);
    // A per-job connection also guarantees that a cancelled COPY or client-side
    // query timeout cannot leak protocol state into the next import.
    if (mergeClient) {
      try { mergeClient.release(true); } catch { /* The abort path already ended the socket. */ }
    }
    activeAbortController = null;
  }
}

async function failOrRetry(job, error) {
  const started = performance.now();
  const message = error instanceof Error ? error.message : String(error);
  if (error instanceof ImportOwnershipLostError || isDefinitiveClaimLoss(error)) {
    metrics.record("retry", "skipped", performance.now() - started);
    return;
  }
  const fatal = message.startsWith("FATAL:");
  const retryMessage = message.replace(/^FATAL:\s*/u, "");
  if (stopping) {
    // Shutdown is bounded by Docker's grace period. Do not reuse the normal
    // pool here: acquiring it and then waiting on its 10-12 second query bounds
    // can keep the process alive after both active job sessions were aborted.
    // A dedicated connection has one wall-clock budget; failure simply leaves
    // the lease to expire and be reclaimed through the same rotating token.
    const deadline = new AbortController();
    const timer = setTimeout(() => deadline.abort(new Error("Shutdown retry budget expired.")), shutdownRetryBudgetMs);
    const client = new pg.Client({
      application_name: "prospect-import-worker-shutdown-release",
      connectionTimeoutMillis: 1_250,
    });
    client.on("error", () => undefined);
    const detachAbort = bindAbortToPgSession(client, deadline.signal, 250);
    try {
      await client.connect();
      if (deadline.signal.aborted) throw deadline.signal.reason;
      await client.query({
        text: "set role prospect_importer; set statement_timeout='2s'; set lock_timeout='1s'",
        query_timeout: 750,
      });
      const result = await client.query({
        text: "select prospect_import.retry_claim_v2($1,$2,$3,$4,$5,1,$6) status",
        values: [job.id, job.listId, workerId, job.claimToken, retryMessage, fatal ? 1 : 3],
        query_timeout: 2_500,
      });
      metrics.record("retry", result.rows[0]?.status ? "ok" : "skipped", performance.now() - started);
    } catch (retryError) {
      metrics.record("retry", isDefinitiveClaimLoss(retryError) ? "skipped" : "error", performance.now() - started);
      if (!isDefinitiveClaimLoss(retryError)) {
        console.error("Could not release import claim within shutdown budget", retryError?.message ?? retryError);
      }
    } finally {
      clearTimeout(timer);
      if (!deadline.signal.aborted) deadline.abort(new Error("Shutdown retry finished."));
      await detachAbort();
    }
    return;
  }

  const retrySeconds = Math.min(3600, 15 * 2 ** Math.min(Number(job.attemptCount ?? 1) - 1, 8));
  const client = await importerClient({ statementTimeout: "10s", lockTimeout: "10s" }).catch(() => null);
  if (!client) return;
  try {
    const result = await client.query({
      text: "select prospect_import.retry_claim_v2($1,$2,$3,$4,$5,$6,$7) status",
      values: [job.id, job.listId, workerId, job.claimToken, retryMessage, retrySeconds, fatal ? 1 : 3],
      query_timeout: 12_000,
    });
    metrics.record("retry", result.rows[0]?.status ? "ok" : "skipped", performance.now() - started);
  } catch (retryError) {
    metrics.record("retry", isDefinitiveClaimLoss(retryError) ? "skipped" : "error", performance.now() - started);
    if (!isDefinitiveClaimLoss(retryError)) console.error("Could not record import retry", retryError?.message ?? retryError);
  } finally {
    client.release();
  }
}

async function main() {
  console.log(`Prospect import worker started with fenced protocol ${protocolVersion}; batch size ${batchSize}, staging timeout ${stagingTimeout}, batch timeout ${batchTimeout}.`);
  while (!stopping) {
    markProgress("");
    let job = null;
    try {
      const claimStarted = performance.now();
      job = await claimNext();
      metrics.record("claim", job ? "ok" : "empty", performance.now() - claimStarted, job ? 1 : 0);
      if (!job) { await wait(3000); continue; }
      console.log(`Processing fenced import ${job.id} from row ${job.committedRowOffset ?? 0}.`);
      await processJob(job);
      console.log(`Completed fenced import ${job.id}.`);
    } catch (error) {
      console.error(`Import ${job?.id ?? "claim"} failed`, error?.message ?? error);
      if (job) await failOrRetry(job, error);
      else if (!stopping) await wait(5000);
    }
  }
  metrics.flush();
  await importPool.end().catch(() => undefined);
  console.log("Prospect import worker stopped.");
}

await new Promise((resolve, reject) => {
  healthServer.once("error", reject);
  healthServer.listen(9090, "0.0.0.0", resolve);
});
await main();
await new Promise(resolve => healthServer.close(resolve));
