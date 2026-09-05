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
