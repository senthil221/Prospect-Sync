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

// A transient read must not be mistaken for an absent repository.
//
// `restic snapshots >/dev/null 2>&1 || restic init` was the single most common
// cause of a missing offsite copy. On 13 and 15 September the listing failed for
// its own reasons, the fallback ran init against a repository that already
// existed, and the script died on "config file already exists" with set -e
// taking the upload down with it. Two nights with a healthy local archive and
// nothing offsite, from a line written for first-run convenience.
test('a failed repository probe never destroys the upload, and the remote is paced', async () => {
  const source = await readFile(new URL('../deploy/scripts/backup.sh', import.meta.url), 'utf8');
  // Comment lines stripped: the change is explained in prose that quotes the
  // exact line being removed, which an absence check would otherwise trip over.
  const code = source.split(/\r?\n/).filter((line) => !line.trimStart().startsWith('#')).join('\n');

  // The old shape must not come back.
  assert.doesNotMatch(code, /restic snapshots[^\n]*\|\|\s*restic init/);

  // `cat config` is the probe: one small object, not a full listing, so it is
  // cheaper and less likely to be what trips a quota.
  assert.match(source, /restic cat config >\/dev\/null 2>&1/);

  // And an init that reports the repository already exists is treated as
  // success, because it means the probe was wrong rather than the repo missing.
  assert.match(source, /grep -q 'config file already exists'/);
  // Any other init failure is still fatal - this must not become "ignore
  // everything init says".
  assert.match(source, /echo "\$init_output" >&2\s*\n\s*exit 1/);

  // Drive's per-minute quota is the binding constraint: 140 rejections over
  // five nights. restic runs rclone as a subprocess, so RCLONE_* env is the
  // only way to reach its flags.
  for (const flag of ['RCLONE_TPSLIMIT', 'RCLONE_DRIVE_PACER_MIN_SLEEP', 'RCLONE_LOW_LEVEL_RETRIES']) {
    // A plain substring rather than a built regex: the thing being asserted is
    // shell ${VAR:-default} syntax, which is almost entirely regex metacharacters.
    assert.ok(source.includes(`export ${flag}="${"$"}{${flag}:-`),
      `${flag} must be exported with an overridable default`);
  }
});
