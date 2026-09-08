import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const gate = readFileSync(new URL("../deploy/scripts/finalize-fixed-fields-maintenance.sh", import.meta.url), "utf8");
const audit = readFileSync(new URL("../scripts/verify-fixed-fields-completion.sql", import.meta.url), "utf8");

test("completion audit refuses retired fields, stale titles and index divergence", () => {
  assert.match(audit, /begin read only/);
  assert.match(audit, /raise exception 'Fixed-field maintenance is incomplete/);
  for (const field of ["personal_email", "seniority", "department", "city", "state", "country", "location", "keywords"])
    assert.ok(audit.includes(field));
  assert.match(audit, /title_classified_at</);
  assert.match(audit, /classifier_projection_mismatches/);
  assert.match(audit, /extra_source_payloads/);
});

test("completion gate rejects unfinished checkpoints and failed audits", { skip: process.platform === "win32" }, () => {
  const root = mkdtempSync(join(tmpdir(), "fixed-field-gate-"));
  try {
    for (const dir of ["deploy/scripts", "deploy/.fixed-fields-checkpoints", "scripts", "bin"])
      mkdirSync(join(root, dir), { recursive: true });
    const script = join(root, "deploy/scripts/finalize.sh");
    writeFileSync(script, gate);
    writeFileSync(join(root, "deploy/scripts/_env.sh"), "load_env() { POSTGRES_PASSWORD=synthetic; POSTGRES_DB=postgres; }\n");
    writeFileSync(join(root, "scripts/finalize-fixed-fields.sql"), "metadata");
    writeFileSync(join(root, "scripts/verify-fixed-fields-completion.sql"), "audit");
    const calls = join(root, "calls");
    writeFileSync(join(root, "bin/docker"), '#!/usr/bin/env bash\npayload=$(cat)\nprintf "%s\\n" "$payload" >> "$TEST_CALLS"\nif [[ "$payload" == audit && "$TEST_FAIL_AUDIT" == 1 ]]; then exit 1; fi\n', { mode: 0o700 });
    const run = (fail = "0") => spawnSync("bash", [script], {
      encoding: "utf8", timeout: 10000,
      env: { ...process.env, PATH: `${join(root, "bin")}:${process.env.PATH}`, TEST_CALLS: calls, TEST_FAIL_AUDIT: fail },
    });
    const missing = run();
    assert.notEqual(missing.status, 0);
    assert.equal(existsSync(calls), false);
    for (const entity of ["company", "prospect", "list_row", "catalog"])
      writeFileSync(join(root, `deploy/.fixed-fields-checkpoints/${entity}`), "DONE 1\n");
    const failed = run("1");
    assert.notEqual(failed.status, 0);
    assert.doesNotMatch(failed.stdout, /verified complete/);
    const success = run();
    assert.equal(success.status, 0, success.stderr);
    assert.match(success.stdout, /verified complete/);
    assert.deepEqual(readFileSync(calls, "utf8").trim().split("\n"), ["metadata", "audit", "metadata", "audit"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
