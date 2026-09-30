import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const migrationPath = "../supabase/migrations/20260930260000_icp_check_auto_apply.sql";

test("new checks apply results; checks that existed before are never applied retroactively", async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /add column if not exists auto_apply boolean not null default false;\s+alter table public\.icp_strategy_checks alter column auto_apply set default true;/);
  // Decided and reviewed rows are queued for applying only when the check applies.
  assert.match(migration, /apply_pending = v_check\.auto_apply,/);
  assert.match(migration, /apply_pending = apply_pending or \(v_check\.auto_apply and v_verdict is distinct from verdict\)/);
});

test("FIT becomes ICP verified and NON_FIT a blocklist domain, through the existing paths", async () => {
  const migration = await read(migrationPath);
  assert.match(migration, /public\.set_company_icp_verified_v2\(v_check\.client_id, true, v_ids/);
  assert.match(migration, /select distinct v_check\.client_id, 'domain', w\.domain, 'ICP Invalid', 'icp_check' from wanted w/);
  assert.match(migration, /public\.add_client_blocklist_batch_v2\(v_check\.client_id, v_domains, null, 'ICP Invalid'/);
  // Never block a company a person already verified, or a free-mail domain.
  assert.match(migration, /and not public\.is_free_email_domain_v1\(r->>'domain'\)\s+and not exists \(select 1 from public\.client_company_icp_validations iv/);
  // Undo only what this check applied.
  assert.match(migration, /where r->>'applied' = 'FIT' and \(r->>'applied_verified'\)::boolean and r->>'verdict' is distinct from 'FIT'/);
  assert.match(migration, /b\.source = 'icp_check'\s+where r->>'applied' = 'NON_FIT' and \(r->>'applied_blocked'\)::boolean/);
  // A review landing mid-apply stays pending for the next round.
  assert.match(migration, /apply_pending = s\.verdict is distinct from r\.verdict/);
  assert.match(migration, /ICP apply proof passed and was rolled back/);
});

test("the free-mail list matches the one imports use", async () => {
  const migration = await read(migrationPath);
  const normalize = await read("../db/normalize.ts");
  const js = normalize.split("const freeEmailDomains = new Set([")[1].split("]);")[0].match(/"[^"]+"/g).map((value) => value.slice(1, -1)).sort();
  const sql = migration.split("select lower(btrim(coalesce(p_domain, ''))) in (")[1].split(")\n$$")[0].match(/'[^']+'/g).map((value) => value.slice(1, -1)).sort();
  assert.deepEqual(sql, js);
});

test("the ICP worker applies results in its own loop, never inside a batch", async () => {
  const worker = await read("../worker/icp-worker.mjs");
  assert.match(worker, /select public\.apply_icp_check_results_v1\(\$1\) as result', \[50\], 3\)/);
  assert.match(worker, /const applier = applyLoop\(\);/);
  assert.match(worker, /new pg\.Pool\(\{ max: 3,/);
  const bootstrap = await read("../deploy/postgres/init/00-prospect-bootstrap.sh");
  assert.match(bootstrap, /alter role prospect_icp_worker with login password '\$\{POSTGRES_PASSWORD\}' nosuperuser nocreatedb nocreaterole nobypassrls connection limit 4;/);
  const migration = await read(migrationPath);
  assert.match(migration, /grant execute on function public\.apply_icp_check_results_v1\(integer\) to prospect_icp_validator/);
  assert.match(migration, /pg_try_advisory_xact_lock\(hashtext\('apply_icp_check_results_v1'\)\)/);
});

test("both start paths offer the switch, on by default", async () => {
  const screen = await read("../app/components/IcpChecksWorkspace.tsx");
  assert.match(screen, /const \[autoApply, setAutoApply\] = useState\(true\);/);
  assert.match(screen, /label="Apply results automatically"/);
  const dialog = await read("../app/components/IcpCheck.tsx");
  assert.match(dialog, /const \[autoApply, setAutoApply\] = useState\(true\);/);
  assert.match(dialog, /force, autoApply, scope: "selection"/);
});
