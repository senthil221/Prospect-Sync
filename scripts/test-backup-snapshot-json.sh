#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || {
  echo "jq is required for the snapshot receipt regression." >&2
  exit 1
}

source deploy/scripts/backup-status.sh
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
target="/var/backups/prospect/20261004T000000Z"

printf '%s\n' '[{"id":"a1b2c3","hostname":"prospect-vps","tags":["prospect-db"],"paths":["/var/backups/prospect/20261004T000000Z"]}]' >"$fixture_root/valid.json"
[[ "$(select_offsite_snapshot_id "$fixture_root/valid.json" "$target")" == "a1b2c3" ]]

printf '%s\n' '[]' >"$fixture_root/empty.json"
if select_offsite_snapshot_id "$fixture_root/empty.json" "$target" >/dev/null 2>&1; then
  echo "empty snapshot listing was accepted" >&2
  exit 1
fi

printf '%s\n' '[{"id":"a1b2c3","hostname":"other-host","tags":["prospect-db"],"paths":["/var/backups/prospect/20261004T000000Z"]}]' >"$fixture_root/mismatch.json"
if select_offsite_snapshot_id "$fixture_root/mismatch.json" "$target" >/dev/null 2>&1; then
  echo "mismatched snapshot was accepted" >&2
  exit 1
fi

printf '%s\n' '[{"id":"not-a-snapshot-id","hostname":"prospect-vps","tags":["prospect-db"],"paths":["/var/backups/prospect/20261004T000000Z"]}]' >"$fixture_root/nonhex.json"
if select_offsite_snapshot_id "$fixture_root/nonhex.json" "$target" >/dev/null 2>&1; then
  echo "invalid snapshot id was accepted" >&2
  exit 1
fi

printf '%s\n' '{not-json' >"$fixture_root/invalid.json"
if select_offsite_snapshot_id "$fixture_root/invalid.json" "$target" >/dev/null 2>&1; then
  echo "invalid JSON was accepted" >&2
  exit 1
fi

printf 'PASS: offsite snapshot receipt rejects empty, mismatched and malformed listings\n'
