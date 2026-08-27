import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("readiness checks Auth, PostgREST, and PostgreSQL before a deploy passes", async () => {
  const [route, compose, workflow] = await Promise.all([
    readFile(new URL("../app/api/health/route.ts", import.meta.url), "utf8"),
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../.github/workflows/deploy.yml", import.meta.url), "utf8"),
  ]);

  assert.match(route, /\/auth\/v1\/health/);
  assert.match(route, /\.from\("clients"\)/);
  assert.match(route, /status: 503/);
  assert.match(compose, /fetch\('http:\/\/127\.0\.0\.1:3000\/api\/health'\)/);
  assert.match(workflow, /APP_PUBLIC_URL }}\/api\/health/);
});

test("public resumable uploads translate the signed Supabase URL to Storage's internal TUS route", async () => {
  const [caddy, compose, resumable, update] = await Promise.all([
    readFile(new URL("../deploy/caddy/Caddyfile", import.meta.url), "utf8"),
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../lib/resumable-upload.ts", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
  ]);

  const publicTus = caddy.match(/handle \/storage\/v1\/upload\/resumable\* \{[\s\S]*?\n\t\}/)?.[0];
  assert.ok(publicTus, "the signed TUS endpoint must have a dedicated public route");
  assert.match(publicTus, /uri strip_prefix \/storage\/v1/);
  assert.match(publicTus, /header_up X-Forwarded-Prefix \/storage\/v1/);
  assert.match(compose, /TUS_URL_PATH: \/upload\/resumable/);
  assert.doesNotMatch(compose, /TUS_URL_PATH: \/storage\/v1\/upload\/resumable/);
  assert.match(resumable, /storage\/v1\/upload\/resumable\/sign/);
  assert.match(update, /storage\/v1\/upload\/resumable\/sign/);

  const publicRoute = caddy.indexOf("handle /storage/v1/upload/resumable*");
  const internalRoute = caddy.indexOf("handle_path /storage/v1/*");
  assert.ok(publicRoute >= 0 && publicRoute < internalRoute, "the signed route must win before the internal Storage guard");
});

test("restore, rollback, Studio, and backup guards fail closed", async () => {
  const [restore, update, caddy, backup] = await Promise.all([
    readFile(new URL("../deploy/scripts/restore.sh", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../deploy/caddy/Caddyfile", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/backup.sh", import.meta.url), "utf8"),
  ]);

  assert.doesNotMatch(restore, /pg_restore[^\n]*\|\s*grep[^\n]*\|\| true/);
  assert.doesNotMatch(restore, /pg_restore[^\n]*--jobs/);
  assert.match(restore, /alter database \$\{POSTGRES_DB\} rename to \$\{POSTGRES_DB\}_old/);
  assert.match(restore, /psql_as -d template1/);
  assert.match(restore, /restore_failed/);
  assert.match(restore, /42710/);
  assert.match(update, /Deployment failed; keeping the previous application online/);
  assert.match(update, /Returning traffic to \$\{ACTIVE_SLOT\}/);
  assert.match(update, /set_app_image "\$PREVIOUS_IMAGE"/);
  assert.match(update, /trap 'rollback_on_error \$\?' ERR/);
  assert.match(caddy, /route\s*\{[\s\S]*?respond @studio_external 403[\s\S]*?basic_auth\s*\{/);
  assert.match(caddy, /STUDIO_ALLOWED_CIDRS/);
  assert.match(backup, /Refusing to use broad backup directory/);
  assert.match(backup, /-name '20\[0-9\]/);
});

test("deployments retry transport failures and switch blue/green traffic only after readiness", async () => {
  const [workflow, update, compose, caddy, router, migrate] = await Promise.all([
    readFile(new URL("../.github/workflows/deploy.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/update.sh", import.meta.url), "utf8"),
    readFile(new URL("../deploy/docker-compose.yml", import.meta.url), "utf8"),
    readFile(new URL("../deploy/caddy/Caddyfile", import.meta.url), "utf8"),
    readFile(new URL("../deploy/caddy/AppRouter.Caddyfile", import.meta.url), "utf8"),
    readFile(new URL("../deploy/scripts/migrate.sh", import.meta.url), "utf8"),
  ]);

  assert.match(workflow, /for attempt in 1 2 3 4/);
  assert.match(workflow, /ConnectTimeout=15/);
  assert.match(workflow, /ServerAliveInterval=30/);
  assert.match(workflow, /"\$status" -ne 255/);
  assert.match(update, /flock -w 600/);
  assert.match(update, /APP_IMAGE="\$image"\s+export APP_IMAGE/);
  assert.match(compose, /app-blue:/);
  assert.match(compose, /app-green:/);
  assert.match(compose, /app-router:/);
  assert.doesNotMatch(compose, /container_name: prospect-app\s*$/m);
  assert.match(caddy, /reverse_proxy app-router:3000/);
  assert.match(router, /reverse_proxy app-blue:3000 app-green:3000/);
  assert.match(router, /health_uri \/api\/health/);
  assert.match(router, /lb_try_duration 5s/);
  assert.match(migrate, /set local lock_timeout = '5s'/);

  const start = update.indexOf('docker compose up -d --no-deps --pull always "$CANDIDATE_SERVICE"');
  const ready = update.indexOf('verify_candidate_version "$CANDIDATE_CONTAINER"');
  const cutover = update.indexOf('switch_traffic "$CANDIDATE_SLOT"');
  const publicCheck = update.indexOf('verify_public_route "$EXPECTED_VERSION" 12');
  const stopOld = update.indexOf('docker stop -t 300 "$(slot_container "$ACTIVE_SLOT")"');
  assert.ok(start >= 0 && start < ready);
  assert.ok(ready < cutover);
  assert.ok(cutover < publicCheck);
  assert.ok(publicCheck < stopOld);
});

test("migration guard rejects changes to an existing migration", async () => {
  const directory = await mkdtemp(join(tmpdir(), "prospect-migration-guard-"));
  try {
    await mkdir(join(directory, ".github", "scripts"), { recursive: true });
    await mkdir(join(directory, "supabase", "migrations"), { recursive: true });
    await copyFile(
      new URL("../.github/scripts/check-migrations.mjs", import.meta.url),
      join(directory, ".github", "scripts", "check-migrations.mjs"),
    );
    const migration = join(directory, "supabase", "migrations", "20260101000000_initial.sql");
    await writeFile(migration, "select 1;\n");

    execFileSync("git", ["init", "-q"], { cwd: directory });
    execFileSync("git", ["config", "user.email", "ci@example.test"], { cwd: directory });
    execFileSync("git", ["config", "user.name", "CI"], { cwd: directory });
    execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: directory });
    execFileSync("git", ["add", "."], { cwd: directory });
    execFileSync("git", ["commit", "-qm", "base"], { cwd: directory });
    const base = execFileSync("git", ["rev-parse", "HEAD"], { cwd: directory, encoding: "utf8" }).trim();

    await writeFile(migration, "select 2;\n");
    execFileSync("git", ["add", "."], { cwd: directory });
    execFileSync("git", ["commit", "-qm", "rewrite history"], { cwd: directory });

    const result = spawnSync("node", [".github/scripts/check-migrations.mjs", "--base", base], {
      cwd: directory,
      encoding: "utf8",
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /applied migration files are immutable/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
