import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { finished } from "node:stream/promises";
import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";

if (process.env.IMPORT_FENCING_TEST_ALLOW !== "1") {
  throw new Error("Set IMPORT_FENCING_TEST_ALLOW=1 only for the disposable import-fencing database.");
}
const url = new URL(process.env.DATABASE_URL ?? "");
if (!["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    || decodeURIComponent(url.pathname.slice(1)) !== "cursor_migration_test"
    || decodeURIComponent(url.username) !== "postgres"
    || decodeURIComponent(url.password) !== "disposable-ci-only") {
  throw new Error("Import fencing checks require postgres@loopback/cursor_migration_test with the disposable password.");
}

const require = createRequire(new URL("../worker/package.json", import.meta.url));
const pg = require("pg");
const { from: copyFrom } = require("pg-copy-streams");
const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: 8,
  options: "-c statement_timeout=120000 -c lock_timeout=10000",
});
const roleSessions = new Set();
const tag = randomUUID().replaceAll("-", "").slice(0, 12);
const id = (label) => `import-fence-${tag}-${label}`;
const worker = id("worker");
const clientId = id("client");
let stage = "setup";
let workerProcess = null;
let storageServer = null;

const sleep = (milliseconds) => new Promise(resolve => setTimeout(resolve, milliseconds));
const copyText = (value) => String(value).replaceAll("\\", "\\\\").replaceAll("\t", "\\t")
  .replaceAll("\n", "\\n").replaceAll("\r", "\\r");

async function roleClient(role = "prospect_importer") {
  const client = new pg.Client({
    connectionString: process.env.DATABASE_URL,
    application_name: `import-fencing-${role}`,
    connectionTimeoutMillis: 5_000,
  });
  client.on("error", () => undefined);
  await client.connect();
  await client.query(`set role ${role}`);
  await client.query("set statement_timeout='120s'");
  await client.query("set lock_timeout='10s'");
  roleSessions.add(client);
  return client;
}

async function postgresClient(label) {
  const client = new pg.Client({
    connectionString: process.env.DATABASE_URL,
    application_name: `import-fencing-${label}`,
    connectionTimeoutMillis: 5_000,
  });
  client.on("error", () => undefined);
  await client.connect();
  await client.query("set statement_timeout='120s'");
  await client.query("set lock_timeout='10s'");
  roleSessions.add(client);
  return client;
}

async function closeRoleClient(client) {
  if (!client || !roleSessions.has(client)) return;
  roleSessions.delete(client);
  await client.end().catch(() => undefined);
}

async function expectRejected(action, label, pattern = /IMPORT_(?:CLAIM_LOST|LEASE_EXPIRED)|Protocol 2|permission denied|Import not found/u) {
  try {
    await action();
  } catch (error) {
    if (pattern.test(String(error?.message ?? error))) return;
    throw new Error(`${label} failed for the wrong reason: ${error?.message ?? error}`);
  }
  throw new Error(`${label} unexpectedly succeeded`);
}

async function createImport(label, { verify = false, protocol = 1, mode = "background", status = "queued" } = {}) {
  const listId = id(`list-${label}`);
  const importId = id(`job-${label}`);
  await pool.query(`insert into public.lists(id,client_id,name,source_file_name)
    values($1,$2,$3,$4)`, [listId, clientId, `Fence ${label}`, `${label}.csv`]);
  await pool.query(`insert into public.imports(
      id,client_id,list_id,file_name,status,total_rows,ingestion_mode,storage_object_path,
      source_headers,field_map,file_size_bytes,verify_work_emails,import_protocol_version)
    values($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10::jsonb,100,$11,$12)`, [
    importId, clientId, listId, `${label}.csv`, status, status === "processing" ? 0 : null,
    mode, mode === "background" ? `fixture/${importId}.csv` : null,
    JSON.stringify(["Email"]), JSON.stringify({ Email: "Email" }), verify, protocol,
  ]);
  return { importId, listId };
}

function payload(rowOffset, label) {
  const email = `${label}-${tag}-${rowOffset}@example.test`;
  return {
    firstName: "Fence",
    lastName: String(rowOffset),
    fullName: `Fence ${rowOffset}`,
    workEmail: email,
    personalEmail: "",
    mobileNumber: "",
    linkedinUrl: "",
    title: "Tester",
    keywords: [],
    seniority: "",
    department: "",
    city: "",
    state: "",
    country: "",
    location: "",
    companyName: "Fence Labs",
    companyDomain: "fence.example.test",
    companyId: "domain:fence.example.test",
    normalizedCompanyName: "fence labs",
    raw: { Email: email },
    identifiers: [{ type: "work_email", value: email }],
    sourceRowNumber: rowOffset + 2,
  };
}

async function makeTempStage(client, rows, label) {
  const table = `stage_${label.replace(/[^a-z0-9_]/giu, "_")}_${tag}`.toLowerCase();
  await client.query(`create temporary table ${table}(row_offset integer primary key,payload jsonb not null) on commit preserve rows`);
  const copy = client.query(copyFrom(`copy ${table}(row_offset,payload) from stdin`));
  for (const [rowOffset, body] of rows) {
    copy.write(`${rowOffset}\t${copyText(JSON.stringify(body))}\n`);
  }
  copy.end();
  await finished(copy);
  return `pg_temp.${table}`;
}

async function claim(client, leaseSeconds = 30, workerId = worker) {
  const result = await client.query("select prospect_import.claim_next_v2($1,$2) claim", [workerId, leaseSeconds]);
  return result.rows[0]?.claim ?? null;
}

async function waitForBlock(waitingPid, blockerPid, label) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const result = await pool.query(`select state,wait_event_type,pg_blocking_pids(pid) blockers
      from pg_stat_activity where pid=$1`, [waitingPid]);
    const row = result.rows[0];
    if (row?.state === "active" && row.wait_event_type === "Lock"
        && (row.blockers ?? []).map(Number).includes(blockerPid)) return;
    await sleep(20);
  }
  throw new Error(`${label} did not reach the PostgreSQL row-lock barrier`);
}

async function waitForCondition(check, label, timeoutMilliseconds = 30_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (await check()) return;
    if (workerProcess?.exitCode !== null && workerProcess?.exitCode !== undefined) {
      throw new Error(`${label} stopped because the real worker exited ${workerProcess.exitCode}`);
    }
    await sleep(100);
  }
  throw new Error(`${label} timed out`);
}

try {
  await pool.query("insert into public.clients(id,name,normalized_name) values($1,$2,$3)",
    [clientId, `Import Fence ${tag}`, `import fence ${tag}`]);

  stage = "two claimers and a rotating same-worker token";
  const primary = await createImport("primary", { verify: true });
  const claimerA = await roleClient();
  const claimerB = await roleClient();
  const [claimA, claimB] = await Promise.all([claim(claimerA), claim(claimerB)]);
  const firstClaim = claimA ?? claimB;
  if (!firstClaim || (claimA === null) === (claimB === null)) throw new Error("exactly one concurrent claimer must win");
  const owner = claimA ? claimerA : claimerB;
  const other = claimA ? claimerB : claimerA;
  if (firstClaim.id !== primary.importId || firstClaim.protocolVersion !== 2 || !firstClaim.claimToken) {
    throw new Error(`unexpected v2 claim: ${JSON.stringify(firstClaim)}`);
  }

  stage = "lease renewal outlives the initial staging lease";
  const stagedRows = [[0, payload(0, "primary")], [1, payload(1, "primary")]];
  const tempTable = await makeTempStage(owner, stagedRows, "primary");
  await pool.query("update public.imports set lease_expires_at=clock_timestamp()+interval '500 milliseconds' where id=$1", [primary.importId]);
  const renewed = await owner.query(`select prospect_import.renew_claim_v2($1,$2,$3,$4,30,2,100) state`,
    [primary.importId, primary.listId, worker, firstClaim.claimToken]);
  if (renewed.rows[0].state?.status !== "processing") throw new Error("renewal did not acknowledge ownership");
  await sleep(700);
  await owner.query(`select prospect_import.publish_temp_stage_v2($1,$2,$3,$4,$5::regclass,2,100)`,
    [primary.importId, primary.listId, worker, firstClaim.claimToken, tempTable]);

  stage = "expired renewal cannot revive and a reclaim fences every old mutation";
  await pool.query("update public.imports set lease_expires_at=clock_timestamp()-interval '1 second' where id=$1", [primary.importId]);
  await expectRejected(() => owner.query(`select prospect_import.renew_claim_v2($1,$2,$3,$4,30,null,null)`,
    [primary.importId, primary.listId, worker, firstClaim.claimToken]), "expired renewal", /IMPORT_LEASE_EXPIRED/u);
  const secondClaim = await claim(other, 30, worker);
  if (!secondClaim || secondClaim.id !== primary.importId || secondClaim.claimToken === firstClaim.claimToken) {
    throw new Error("same worker reclaim did not rotate the claim token");
  }
  const staleArgs = [primary.importId, primary.listId, worker, firstClaim.claimToken];
  await expectRejected(() => owner.query("select prospect_import.renew_claim_v2($1,$2,$3,$4,30,null,null)", staleArgs), "stale renewal");
  await expectRejected(() => owner.query("select prospect_import.publish_temp_stage_v2($1,$2,$3,$4,$5::regclass,2,100)", [...staleArgs, tempTable]), "stale publication");
  await expectRejected(() => owner.query("select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,0,2)", staleArgs), "stale batch");
  await expectRejected(() => owner.query("select prospect_import.retry_claim_v2($1,$2,$3,$4,'stale',1,3)", staleArgs), "stale retry");
  await expectRejected(() => owner.query("select prospect_import.complete_claim_v2($1,$2,$3,$4)", staleArgs), "stale completion");

  stage = "source mapping identity and committed-batch replay";
  await pool.query("update public.imports set field_map=jsonb_build_object('Email','Changed') where id=$1", [primary.importId]);
  await expectRejected(() => other.query("select prospect_import.stage_state_v2($1,$2,$3,$4)",
    [primary.importId, primary.listId, worker, secondClaim.claimToken]), "changed mapping stage reuse", /no longer matches/u);
  await pool.query("update public.imports set field_map=jsonb_build_object('Email','Email') where id=$1", [primary.importId]);
  const merged = await other.query("select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,0,2)",
    [primary.importId, primary.listId, worker, secondClaim.claimToken]);
  if (Number(merged.rows[0]?.processed) !== 2 || Number(merged.rows[0]?.committed_row_offset) !== 2) {
    throw new Error(`first fenced batch returned the wrong cursor: ${JSON.stringify(merged.rows[0])}`);
  }
  const replay = await other.query("select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,0,2)",
    [primary.importId, primary.listId, worker, secondClaim.claimToken]);
  if (Number(replay.rows[0]?.processed) !== 2 || Number(replay.rows[0]?.committed_row_offset) !== 2) {
    throw new Error("a fully committed ambiguous replay was not recognized");
  }
  const counts = await pool.query(`select i.processed_rows,i.committed_row_offset,
      (select count(*)::int from public.list_rows where import_id=i.id) list_rows,
      (select count(*)::int from public.list_memberships where import_id=i.id) memberships
    from public.imports i where i.id=$1`, [primary.importId]);
  if (Number(counts.rows[0]?.processed_rows) !== 2 || Number(counts.rows[0]?.committed_row_offset) !== 2
      || counts.rows[0]?.list_rows !== 2 || counts.rows[0]?.memberships !== 2) {
    throw new Error(`ambiguous replay duplicated or lost rows: ${JSON.stringify(counts.rows[0])}`);
  }

  stage = "completion receipt and verification snapshot are once-only";
  const completionA = await other.query("select prospect_import.complete_claim_v2($1,$2,$3,$4) result",
    [primary.importId, primary.listId, worker, secondClaim.claimToken]);
  const completionB = await other.query("select prospect_import.complete_claim_v2($1,$2,$3,$4) result",
    [primary.importId, primary.listId, worker, secondClaim.claimToken]);
  const receiptA = completionA.rows[0]?.result?.completionReceipt;
  if (!receiptA || receiptA !== completionB.rows[0]?.result?.completionReceipt) {
    throw new Error("ambiguous completion did not return the winning receipt");
  }
  const verification = await pool.query(`select count(distinct r.id)::int runs,count(t.run_id)::int targets
    from prospect_verification.runs r left join prospect_verification.run_targets t on t.run_id=r.id
    where r.source_import_id=$1`, [primary.importId]);
  if (verification.rows[0]?.runs !== 1 || verification.rows[0]?.targets !== 2) {
    throw new Error(`completion created duplicate or missing verification work: ${JSON.stringify(verification.rows[0])}`);
  }
  const terminalHeartbeat = await other.query("select prospect_import.renew_claim_v2($1,$2,$3,$4,30,null,null) result",
    [primary.importId, primary.listId, worker, secondClaim.claimToken]);
  if (terminalHeartbeat.rows[0]?.result?.status !== "completed"
      || terminalHeartbeat.rows[0]?.result?.completionReceipt !== receiptA) {
    throw new Error("a heartbeat queued behind completion did not observe the terminal receipt");
  }

  stage = "killed temporary stager cannot leak durable rows";
  const killed = await createImport("killed");
  const killedOwner = await roleClient();
  const killedClaim = await claim(killedOwner);
  const killedPid = Number((await killedOwner.query("select pg_backend_pid() pid")).rows[0].pid);
  await makeTempStage(killedOwner, [[0, payload(0, "killed")]], "killed");
  await pool.query("select pg_terminate_backend($1)", [killedPid]);
  const durableAfterKill = await pool.query("select count(*)::int count from prospect_import.staged_rows_v2 where import_id=$1", [killed.importId]);
  if (durableAfterKill.rows[0].count !== 0) throw new Error("an uncommitted temporary stage reached durable storage");
  await closeRoleClient(killedOwner);
  await pool.query("update public.imports set lease_expires_at=clock_timestamp()-interval '1 second' where id=$1", [killed.importId]);
  const cleanupOwner = await roleClient();
  const cleanupClaim = await claim(cleanupOwner);
  if (cleanupClaim?.id !== killed.importId || cleanupClaim?.claimToken === killedClaim?.claimToken) {
    throw new Error("killed staging claim was not recoverable with a new token");
  }
  await cleanupOwner.query("select prospect_import.retry_claim_v2($1,$2,$3,$4,'fixture cleanup',1,1)",
    [killed.importId, killed.listId, worker, cleanupClaim.claimToken]);
  await closeRoleClient(cleanupOwner);

  stage = "admitted batch serializes before cancellation";
  const cancelled = await createImport("cancelled");
  const cancelOwner = await roleClient();
  const cancelClaim = await claim(cancelOwner);
  const cancelTemp = await makeTempStage(cancelOwner, [[0, payload(0, "cancelled")]], "cancelled");
  await cancelOwner.query("select prospect_import.publish_temp_stage_v2($1,$2,$3,$4,$5::regclass,1,100)",
    [cancelled.importId, cancelled.listId, worker, cancelClaim.claimToken, cancelTemp]);
  const batchClient = await roleClient();
  const cancelClient = await postgresClient("canceller");
  const batchPid = Number((await batchClient.query("select pg_backend_pid() pid")).rows[0].pid);
  const cancelPid = Number((await cancelClient.query("select pg_backend_pid() pid")).rows[0].pid);
  await batchClient.query("begin");
  await batchClient.query("select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,0,1)",
    [cancelled.importId, cancelled.listId, worker, cancelClaim.claimToken]);
  const cancelling = cancelClient.query("select public.cancel_background_prospect_import_v2($1) result", [cancelled.importId]);
  await waitForBlock(cancelPid, batchPid, "cancellation");
  await batchClient.query("commit");
  await cancelling;
  const cancelledState = await pool.query(`select
      exists(select 1 from public.imports where id=$1) import_exists,
      exists(select 1 from public.list_rows where import_id=$1) row_exists,
      exists(select 1 from public.list_memberships where import_id=$1) membership_exists`, [cancelled.importId]);
  if (cancelledState.rows[0]?.import_exists || cancelledState.rows[0]?.row_exists || cancelledState.rows[0]?.membership_exists) {
    throw new Error(`cancellation left import membership state: ${JSON.stringify(cancelledState.rows[0])}`);
  }
  const canonicalAfterCancel = await pool.query("select count(*)::int count from public.prospects where work_email=$1",
    [`cancelled-${tag}-0@example.test`]);
  if (canonicalAfterCancel.rows[0]?.count !== 1) throw new Error("cancellation deleted the canonical person");
  await expectRejected(() => cancelOwner.query("select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,0,1)",
    [cancelled.importId, cancelled.listId, worker, cancelClaim.claimToken]), "post-cancel stale batch");
  await closeRoleClient(batchClient);
  await closeRoleClient(cancelClient);
  await closeRoleClient(cancelOwner);

  stage = "legacy browser and worker compatibility plus protocol guard";
  const legacy = await createImport("legacy");
  const service = await roleClient("service_role");
  const legacyClaim = (await service.query("select public.claim_next_prospect_import_v1($1,30) claim", [id("legacy-worker")])).rows[0]?.claim;
  if (legacyClaim?.id !== legacy.importId) throw new Error("legacy v1 worker could not claim a protocol-1 job");
  const legacyHeartbeat = await service.query("select public.heartbeat_prospect_import_v1($1,$2,30,0,0) ok",
    [legacy.importId, id("legacy-worker")]);
  if (legacyHeartbeat.rows[0]?.ok !== true) throw new Error("legacy heartbeat stopped working for protocol 1");
  await service.query("select public.retry_prospect_import_v1($1,$2,'fixture',1,1)", [legacy.importId, id("legacy-worker")]);
  const browser = await createImport("browser", { mode: "browser", status: "processing" });
  await pool.query("update public.imports set total_rows=1 where id=$1", [browser.importId]);
  const browserBatch = await service.query("select * from public.import_prospect_batch_v5($1,$2,$3::jsonb,0)",
    [browser.importId, browser.listId, JSON.stringify([payload(0, "browser")])]);
  if (Number(browserBatch.rows[0]?.processed) !== 1) throw new Error("legacy browser People batch compatibility broke");
  const browserComplete = await service.query("select public.complete_prospect_import_v2($1,$2) result", [browser.importId, browser.listId]);
  if (browserComplete.rows[0]?.result?.summary?.status !== "completed") throw new Error("browser completion compatibility broke");
  const companyImportId = id("company-import");
  await pool.query(`insert into public.company_imports(id,file_name,data_source,status,total_rows)
    values($1,'company.csv','Fixture','processing',1)`, [companyImportId]);
  const companyBatch = await service.query("select * from public.import_company_batch_v2($1,$2::jsonb,0)", [companyImportId,
    JSON.stringify([{ name: "Fence Company", normalizedName: `fence-company-${tag}`,
      domain: `${tag}.company.test`, normalizedDomain: `${tag}.company.test`, sourceRowNumber: 2, raw: { fixture: true } }])]);
  if (Number(companyBatch.rows[0]?.processed) !== 1) throw new Error("Company import compatibility broke");
  const guarded = await createImport("guarded");
  const guardedOwner = await roleClient();
  const guardedClaim = await claim(guardedOwner);
  if (guardedClaim?.id !== guarded.importId) throw new Error("could not claim protocol-guard fixture");
  await expectRejected(() => service.query("select * from public.import_prospect_batch_v5($1,$2,'[]'::jsonb,0)",
    [guarded.importId, guarded.listId]), "legacy batch against v2 job", /Protocol 2/u);
  await expectRejected(() => guardedOwner.query("select * from prospect_import.process_staged_batch_v2($1,$2,$3,$4,0,null)",
    [guarded.importId, guarded.listId, worker, guardedClaim.claimToken]), "null batch count", /Invalid staged batch bounds/u);
  await expectRejected(() => guardedOwner.query("select prospect_import.complete_claim_v2($1,$2,$3,$4)",
    [guarded.importId, guarded.listId, worker, guardedClaim.claimToken]), "completion before a known total", /has not committed every staged row/u);
  await guardedOwner.query("select prospect_import.retry_claim_v2($1,$2,$3,$4,'fixture cleanup',1,1)",
    [guarded.importId, guarded.listId, worker, guardedClaim.claimToken]);
  await closeRoleClient(guardedOwner);
  await closeRoleClient(service);

  stage = "ACL non-bypass";
  const acl = await pool.query(`select
      has_table_privilege('prospect_importer','prospect_import.staged_rows_v2','INSERT') importer_insert,
      has_function_privilege('prospect_importer','prospect_import.import_prospect_batch_core_v2(text,text,jsonb,integer)','EXECUTE') importer_core,
      has_function_privilege('prospect_importer','public.import_prospect_batch_v5(text,text,jsonb,integer)','EXECUTE') importer_legacy_batch,
      has_function_privilege('anon','prospect_import.claim_next_v2(text,integer)','EXECUTE') anon_claim,
      has_function_privilege('authenticated','prospect_import.claim_next_v2(text,integer)','EXECUTE') authenticated_claim`);
  if (Object.values(acl.rows[0]).some(Boolean)) throw new Error(`a fenced import bypass remains: ${JSON.stringify(acl.rows[0])}`);

  stage = "real worker completes consecutive imports despite object cleanup failure";
  const workerImportA = await createImport("worker-a", { verify: true, protocol: 2 });
  const workerImportB = await createImport("worker-b", { verify: true, protocol: 2 });
  const timeoutImport = await createImport("worker-timeout", { protocol: 2 });
  const csvByPath = new Map([
    [`/object/prospect-imports/fixture/${workerImportA.importId}.csv`, `Email\nworker-a-${tag}@example.test\n`],
    [`/object/prospect-imports/fixture/${workerImportB.importId}.csv`, `Email\nworker-b-${tag}@example.test\n`],
  ]);
  const stalledPaths = new Set([`/object/prospect-imports/fixture/${timeoutImport.importId}.csv`]);
  let stalledRequests = 0;
  let cleanupRequests = 0;
  storageServer = createServer((request, response) => {
    if (request.method === "GET" && csvByPath.has(request.url ?? "")) {
      response.writeHead(200, { "content-type": "text/csv" });
      response.end(csvByPath.get(request.url ?? ""));
      return;
    }
    if (request.method === "GET" && stalledPaths.has(request.url ?? "")) {
      stalledRequests += 1;
      response.writeHead(200, { "content-type": "text/csv" });
      response.write("Email\n");
      return;
    }
    if (request.method === "DELETE" && request.url === "/object/prospect-imports") {
      cleanupRequests += 1;
      response.writeHead(cleanupRequests === 1 ? 500 : 200, { "content-type": "application/json" });
      response.end(cleanupRequests === 1 ? '{"error":"synthetic cleanup failure"}' : "{}");
      return;
    }
    response.writeHead(404).end();
  });
  await new Promise((resolve, reject) => {
    storageServer.once("error", reject);
    storageServer.listen(0, "127.0.0.1", resolve);
  });
  const address = storageServer.address();
  if (!address || typeof address === "string") throw new Error("fake Storage did not bind a TCP port");
  let workerOutput = "";
  const diagnosticWorkerOutput = () => workerOutput
    .replaceAll("disposable-ci-only", "[redacted]")
    .replaceAll("synthetic-ci-key", "[redacted]")
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, "postgresql://[redacted]@")
    .slice(-4_000);
  workerProcess = spawn(process.execPath, [fileURLToPath(new URL("../worker/import-worker.mjs", import.meta.url))], {
    cwd: fileURLToPath(new URL("../", import.meta.url)),
    env: {
      ...process.env,
      PGHOST: url.hostname === "[::1]" ? "::1" : url.hostname,
      PGPORT: url.port || "5432",
      PGUSER: decodeURIComponent(url.username),
      PGPASSWORD: decodeURIComponent(url.password),
      PGDATABASE: decodeURIComponent(url.pathname.slice(1)),
      SUPABASE_SERVICE_ROLE_KEY: "synthetic-ci-key",
      SUPABASE_STORAGE_URL: `http://127.0.0.1:${address.port}`,
      IMPORT_BATCH_SIZE: "100",
      IMPORT_STAGING_TIMEOUT: "8s",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  workerProcess.stdout.on("data", chunk => { workerOutput = `${workerOutput}${chunk}`.slice(-8_000); });
  workerProcess.stderr.on("data", chunk => { workerOutput = `${workerOutput}${chunk}`.slice(-8_000); });
  await waitForCondition(async () => {
    const result = await pool.query("select id,status,completion_receipt from public.imports where id=any($1::text[]) order by id",
      [[workerImportA.importId, workerImportB.importId]]);
    return result.rows.length === 2 && result.rows.every(row => row.status === "completed" && row.completion_receipt);
  }, "two consecutive real-worker imports", 45_000).catch(error => {
    throw new Error(`${error.message}; worker output: ${workerOutput}`);
  });
  const workerVerification = await pool.query(`select r.source_import_id,count(distinct r.id)::int runs,
      count(t.run_id)::int targets
    from prospect_verification.runs r left join prospect_verification.run_targets t on t.run_id=r.id
    where r.source_import_id=any($1::text[])
    group by r.source_import_id order by r.source_import_id`, [[workerImportA.importId, workerImportB.importId]]);
  if (workerVerification.rows.length !== 2
      || workerVerification.rows.some(row => row.runs !== 1 || row.targets !== 1)) {
    throw new Error(`real worker completion was not once-only: ${JSON.stringify(workerVerification.rows)}`);
  }
  if (cleanupRequests !== 2) throw new Error(`real worker made ${cleanupRequests} cleanup requests instead of two`);

  stage = "real worker bounds a stalled Storage download";
  await waitForCondition(async () => {
    const result = await pool.query("select status,attempt_count,last_error from public.imports where id=$1", [timeoutImport.importId]);
    const row = result.rows[0];
    return row?.status === "queued" && Number(row.attempt_count) === 1 && Boolean(row.last_error);
  }, "stalled download retry", 20_000).catch(error => {
    throw new Error(`${error.message}; worker output: ${workerOutput}`);
  });
  if (stalledRequests !== 1) throw new Error(`stalled download opened ${stalledRequests} requests instead of one`);
  const timeoutStage = await pool.query("select count(*)::int count from prospect_import.staged_rows_v2 where import_id=$1",
    [timeoutImport.importId]);
  if (timeoutStage.rows[0]?.count !== 0) throw new Error("a timed-out download published durable rows");

  stage = "real worker rolls an active database batch back and releases the claim on shutdown";
  const shutdownImport = await createImport("worker-shutdown", { protocol: 2 });
  const shutdownEmail = `worker-shutdown-${tag}@example.test`;
  csvByPath.set(`/object/prospect-imports/fixture/${shutdownImport.importId}.csv`, `Email\n${shutdownEmail}\n`);
  const sleepFunction = `import_fencing_sleep_${tag}`;
  const sleepTrigger = `import_fencing_sleep_trigger_${tag}`;
  await pool.query(`create function public.${sleepFunction}() returns trigger language plpgsql as $body$
    begin
      if new.work_email = $email$${shutdownEmail}$email$ then perform pg_sleep(30); end if;
      return new;
    end $body$`);
  await pool.query(`create trigger ${sleepTrigger} before insert on public.prospects
    for each row execute function public.${sleepFunction}()`);
  await waitForCondition(async () => {
    const result = await pool.query(`select exists(select 1 from pg_stat_activity
      where application_name='prospect-import-worker-v2' and state='active'
        and query like '%process_staged_batch_v2%' and wait_event='PgSleep') sleeping`);
    return result.rows[0]?.sleeping === true;
  }, "active PostgreSQL batch before shutdown", 15_000).catch(error => {
    throw new Error(`${error.message}; worker output: ${workerOutput}`);
  });
  const workerExit = new Promise(resolve => workerProcess.once("exit", (code, signal) => resolve({ code, signal })));
  workerProcess.kill("SIGTERM");
  const graceful = await Promise.race([workerExit, sleep(8_000).then(() => null)]);
  if (!graceful || graceful.code !== 0) {
    workerProcess.kill("SIGKILL");
    throw new Error(`real worker did not shut down cleanly: ${JSON.stringify(graceful)}; output: ${workerOutput}`);
  }
  const shutdownState = await pool.query(`select i.status,i.worker_id,i.claim_token,i.lease_expires_at,
      i.committed_row_offset,
      exists(select 1 from public.prospects p where p.work_email=$2) prospect_exists,
      (select count(*)::int from public.list_rows lr where lr.import_id=i.id) list_rows,
      (select count(*)::int from prospect_import.staged_rows_v2 s where s.import_id=i.id) staged_rows
    from public.imports i where i.id=$1`, [shutdownImport.importId, shutdownEmail]);
  const shutdownRow = shutdownState.rows[0];
  if (shutdownRow?.status !== "queued" || shutdownRow.worker_id !== null
      || shutdownRow.claim_token !== null || shutdownRow.lease_expires_at !== null
      || Number(shutdownRow.committed_row_offset) !== 0 || shutdownRow.prospect_exists
      || shutdownRow.list_rows !== 0 || shutdownRow.staged_rows !== 1) {
    throw new Error(`shutdown did not roll back and release the active batch: ${JSON.stringify(shutdownRow)}; worker output: ${diagnosticWorkerOutput()}`);
  }
  workerProcess = null;
  await new Promise(resolve => storageServer.close(resolve));
  storageServer = null;

  await closeRoleClient(claimerA);
  await closeRoleClient(claimerB);
  process.stdout.write("Import fencing concurrency, recovery, completion, compatibility and ACL checks passed.\n");
} catch (error) {
  const safe = String(error?.stack ?? error).replaceAll("disposable-ci-only", "[redacted]")
    .replace(/postgres(?:ql)?:\/\/[^\s@]+@/giu, "postgresql://[redacted]@").slice(0, 4000);
  process.stderr.write(`::error title=Import fencing contract::${stage}: ${safe.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A")}\n`);
  throw error;
} finally {
  if (workerProcess && workerProcess.exitCode === null) workerProcess.kill("SIGKILL");
  if (storageServer) await new Promise(resolve => storageServer.close(resolve));
  await Promise.allSettled([...roleSessions].map(client => closeRoleClient(client)));
  await pool.end().catch(() => undefined);
}
