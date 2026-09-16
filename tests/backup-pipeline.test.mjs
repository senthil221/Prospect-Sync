import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
test('backup verification drains the archive and preserves both pipeline failures', async () => {
  const source = await readFile(new URL('../deploy/scripts/backup.sh', import.meta.url), 'utf8');
  assert.match(source, /set -euo pipefail/);
  assert.match(source, /pg pg_restore --list[^\n]*\|\| manifest_status=\$\?/);
  assert.match(source, /cat >\/dev\/null\s+exit "\$manifest_status"/);
  assert.ok(source.indexOf('exit "$manifest_status"') < source.indexOf('restic backup'));
});
test('synthetic backup pipeline regression executes under Linux CI', { skip: process.platform === 'win32' }, () => {
  const result = spawnSync('bash', ['scripts/test-backup-pipeline.sh'], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

// Offsite retention has to actually retain something.
//
// Measured against the live repository on 2026-09-16. `restic forget` groups
// snapshots by host+paths by default, and every backup here is taken from a
// fresh /var/backups/prospect/<TIMESTAMP> directory - so each snapshot formed a
// group of one, the policy kept "1 of 1" in every group, and nothing was ever
// removed. Five snapshots, five groups, zero deletions: a retention policy that
// read as configured and did nothing, with the repository growing about a
// gigabyte a night. --dry-run with --group-by host,tags printed one group of
// five instead, which is what the daily/weekly/monthly counts were written for.
//
// The stale lock is the other half. A run killed part-way leaves a lock nothing
// clears; after 2026-09-08 every night uploaded successfully and then died on
// that lock, so the unit exited 1 and a good backup reported failure for eight
// nights. `restic unlock` removes only locks whose process is gone.
test('offsite retention is grouped so the policy can remove anything, and a stale lock cannot fail a good backup', async () => {
  const source = await readFile(new URL('../deploy/scripts/backup.sh', import.meta.url), 'utf8');

  assert.match(source, /restic forget --tag prospect-db --group-by host,tags/);
  assert.match(source, /--keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune/);

  // Order matters in both directions: unlock after the upload, so it never
  // clears a lock the upload is holding, and before forget, which is the step
  // the stale lock was killing.
  assert.ok(source.indexOf('restic backup') < source.indexOf('restic unlock'),
    'unlock must come after the upload, not before it');
  assert.ok(source.indexOf('restic unlock') < source.indexOf('restic forget'),
    'unlock must come before the step the stale lock blocks');
});
