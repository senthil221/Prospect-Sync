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
  assert.match(update, /Automatically rolling back/);
  assert.match(update, /set_app_image "\$PREVIOUS_IMAGE"/);
  assert.match(update, /trap 'rollback_on_error \$\?' ERR/);
  assert.ok(caddy.indexOf("respond @studio_external 403") < caddy.indexOf("basic_auth"));
  assert.match(caddy, /STUDIO_ALLOWED_CIDRS/);
  assert.match(backup, /Refusing to use broad backup directory/);
  assert.match(backup, /-name '20\[0-9\]/);
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
