import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("offsite retry reuses one verified archive and never dumps, initializes, unlocks or prunes", async () => {
  const [retry, helper] = await Promise.all([
    read("../deploy/scripts/backup-upload-existing.sh"),
    read("../deploy/scripts/backup-offsite.sh"),
  ]);
  assert.match(retry, /resolve_backup_within_root/);
  assert.match(retry, /validate_local_backup_for_upload/);
  assert.match(retry, /flock -n 9/);
  assert.match(retry, /upload_backup_offsite[^\n]*0 offsite_retry/);
  assert.doesNotMatch(retry, /pg_dump|restic init|restic unlock|find [^\n]*-exec|rm -rf/);
  assert.match(helper, /quota exceeded[\s\S]*terminal/);
  assert.match(helper, /5\[0-9\]\[0-9\][\s\S]*transient/);
  assert.match(helper, /attempts <= 5/);
  assert.match(helper, /timeout_seconds <= 7200/);
  assert.match(helper, /if \[\[ "\$allow_init" == "1" \]\] && restic_repository_missing "\$probe_log"/);
  assert.ok(helper.indexOf("quota exceeded") < helper.indexOf("repository does not exist"));
  assert.match(helper, /restic_repository_missing "\$probe_log"/);
  assert.match(helper, /it was not initialized or unlocked/);
  assert.match(helper, /! -L "\$dest\/database\.dump\.zst"/);
  assert.match(helper, /recorded_objects[\s\S]*"\$objects"/);
  assert.match(helper, /pg_restore --list/);
  assert.match(helper, /cmp -s "\$manifest_check" "\$dest\/manifest\.txt"/);
});

test("isolated restore is separately bounded, scheduler-suppressed and cleans only its labels", async () => {
  const [drill, verify, ordinaryRestore] = await Promise.all([
    read("../deploy/scripts/restore-isolated.sh"),
    read("../deploy/scripts/restore-verify.sql"),
    read("../deploy/scripts/restore.sh"),
  ]);
  assert.match(drill, /--network none/);
  assert.match(drill, /DRILL_CPUS="\$\{RESTORE_DRILL_CPUS:-1\}"/);
  assert.match(drill, /DRILL_MEMORY="\$\{RESTORE_DRILL_MEMORY:-2g\}"/);
  assert.match(drill, /DRILL_MEMORY_MIB <= 2048/);
  assert.match(drill, /--memory-swap "\$DRILL_MEMORY"/);
  assert.match(drill, /--jobs=1 --exit-on-error/);
  assert.match(drill, /cron\.database_name=\$\{DRILL_DB\}/);
  assert.match(drill, /cron\.launch_active_jobs=off/);
  assert.match(drill, /pg_net\.database_name=restore_drill_disabled/);
  assert.ok(drill.indexOf("cron.launch_active_jobs=off") < drill.indexOf("database.dump.zst"));
  assert.match(drill, /remaining_deadline/);
  assert.match(drill, /RESTORE_DRILL_MAX_DATA_BYTES/);
  assert.match(drill, /RESTORE_DRILL_HOST_RESERVE_BYTES:-8589934592/);
  assert.match(drill, /du -sb \/var\/lib\/postgresql\/data/);
  assert.match(drill, /probe_failures >= 3/);
  assert.match(drill, /ownership monitoring failed closed/);
  assert.match(drill, /kill -TERM "\$MAIN_PID"/);
  assert.match(drill, /timeout 20 docker stop/);
  assert.match(drill, /timeout 10 docker inspect --format/);
  assert.match(drill, /timeout "\$\(bounded_deadline 10\)" docker exec[^\n]*pg_isready/);
  assert.match(drill, /timeout 10 docker exec "\$CONTAINER" du -sb/);
  assert.match(drill, /timeout --signal=TERM --kill-after=5 "\$\(bounded_deadline 30\)" docker exec[^\n]*psql -XAtq/);
  assert.match(drill, /DRILL_VERIFIED=1/);
  assert.match(drill, /trap 'exit 130' INT/);
  assert.match(drill, /trap 'exit 143' TERM/);
  assert.match(drill, /cleanup could not be proven/);
  assert.ok(drill.indexOf("CREATED_CONTAINER=1") < drill.indexOf("docker run --detach"));
  assert.ok(drill.indexOf("CREATED_VOLUME=1", drill.indexOf("trap cleanup_drill EXIT")) < drill.indexOf("docker volume create"));
  assert.match(drill, /actual.*com\.clearroad\.restore-drill/s);
  assert.match(drill, /write_backup_stage restore_drill verified/);
  assert.match(drill, /restore_failure_category/);
  assert.match(drill, /category=%s decompressor_status=%s pg_restore_status=%s elapsed_seconds=%s oom=%s toc_entry=%s/);
  assert.match(drill, /Raw restore output was suppressed/);
  assert.match(drill, /restore_failure_toc_entry/);
  assert.match(drill, /from\[\[:space:\]\]\+TOC\[\[:space:\]\]\+entry/);
  assert.match(drill, /decompressor_status != 0 && decompressor_status != 141/);
  assert.match(drill, /if \(\( pg_restore_status != 0 \)\); then exit "\$pg_restore_status"/);
  assert.doesNotMatch(drill, /cat "\$restore_log"|tail [^\n]*"\$restore_log"/);
  assert.doesNotMatch(drill, /docker compose|prospect-db|\$POSTGRES_PASSWORD|\$\{POSTGRES_PASSWORD/);
  assert.match(verify, /restored public tables without RLS/);
  assert.match(verify, /restored public table grants exceed/);
  assert.match(verify, /restored list memberships contain an orphan/);
  assert.match(ordinaryRestore, /--into-production/);
});

test("recovery documentation keeps status red until both external proofs exist", async () => {
  const [readiness, runbook] = await Promise.all([
    read("../docs/database-production-readiness.md"),
    read("../deploy/README.md"),
  ]);
  assert.match(readiness, /Recovery stays RED until[\s\S]*verified offsite receipt[\s\S]*isolated-drill receipt/);
  assert.match(runbook, /backup-upload-existing\.sh/);
  assert.match(runbook, /restore\.sh --verify-only/);
  assert.match(runbook, /not an\s+isolated restore/i);
  assert.match(runbook, /restore-isolated\.sh/);
  assert.match(runbook, /shares host disk I\/O with production/);
});

// The 2026-10-05 drill: a full restore into a template0 database stopped on two
// Supabase platform entries. They are applied in a second pass, after pg_graphql
// is recreated; everything else restores in the first pass, unchanged.
test("restores hold back exactly the two Supabase platform entries for a second pass", async () => {
  const { spawnSync } = await import("node:child_process");
  const { mkdtempSync, readFileSync, writeFileSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { tmpdir } = await import("node:os");
  const dir = mkdtempSync(join(tmpdir(), "restore-platform-"));
  const toc = [
    ";",
    "; Archive created at 2026-10-05 03:26:31 UTC",
    "7; 3079 16673 EXTENSION - pg_graphql ",
    "3456; 1259 17000 TABLE public companies supabase_admin",
    "5977; 0 0 ACL graphql_public FUNCTION graphql(\"operationName\" text, query text, variables jsonb, extensions jsonb) supabase_admin",
    "4277; 3466 16613 EVENT TRIGGER - issue_pg_graphql_access supabase_admin",
    "4276; 3466 16563 EVENT TRIGGER - issue_pg_net_access postgres",
    "6001; 0 0 ACL public TABLE companies supabase_admin",
  ].join("\n") + "\n";
  writeFileSync(join(dir, "toc"), toc);
  const run = spawnSync("bash", ["-c", 'source deploy/scripts/restore-platform.sh && restore_platform_split "$1/toc" "$1/main" "$1/late"', "bash", dir.replaceAll("\\", "/")],
    { cwd: new URL("..", import.meta.url), encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  const late = readFileSync(join(dir, "late"), "utf8").trim().split("\n");
  const main = readFileSync(join(dir, "main"), "utf8");
  assert.deepEqual(late.map((line) => line.split(";")[0]), ["5977", "4276"]);
  for (const kept of ["7;", "3456;", "4277;", "6001;"]) assert.ok(main.includes(`\n${kept}`), kept);
  assert.ok(!main.includes("5977;") && !main.includes("4276;"));

  const [platform, drill, restore] = await Promise.all([
    read("../deploy/scripts/restore-platform.sh"),
    read("../deploy/scripts/restore-isolated.sh"),
    read("../deploy/scripts/restore.sh"),
  ]);
  assert.match(platform, /drop extension pg_graphql;\s*execute format\('create extension pg_graphql with schema %I', v_schema\);/);
  assert.match(drill, /--exit-on-error -L \/tmp\/restore-main\.list/);
  assert.match(drill, /--exit-on-error --no-owner -L \/tmp\/restore-late\.list/);
  assert.match(drill, /-c "\$RESTORE_PLATFORM_REBUILD_SQL"/);
  assert.equal((restore.match(/restore_archive_into "\$(SCRATCH|POSTGRES_DB)"/g) ?? []).length, 2);
});
