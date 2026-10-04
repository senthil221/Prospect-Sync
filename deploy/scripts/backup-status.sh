#!/usr/bin/env bash

# Write one credential-free stage receipt atomically. Separate receipts mean a
# later retention failure cannot overwrite proof of a verified upload.
write_backup_stage() {
  local stage="$1" state="$2" stamp="$3" backup_name="${4:-}" objects="${5:-0}" bytes="${6:-0}" snapshot_id="${7:-}"
  local status_dir="${BACKUP_DIR}/.status" target temp
  [[ "$stage" =~ ^(local|offsite|retention)$ ]] || return 2
  [[ "$state" =~ ^[a-z_]+$ ]] || return 2
  [[ "$backup_name" =~ ^[A-Za-z0-9._-]*$ ]] || return 2
  [[ "$objects" =~ ^[0-9]+$ ]] || return 2
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 2
  [[ "$snapshot_id" =~ ^[A-Fa-f0-9]*$ ]] || return 2
  mkdir -p "$status_dir"
  chmod 700 "$status_dir"
  target="${status_dir}/${stage}.json"
  temp="${target}.tmp.$$"
  printf '{"stage":"%s","state":"%s","recorded_at":"%s","backup":"%s","objects":%s,"bytes":%s,"snapshot_id":"%s"}\n' \
    "$stage" "$state" "$stamp" "$backup_name" "$objects" "$bytes" "$snapshot_id" > "$temp"
  chmod 600 "$temp"
  mv -f -- "$temp" "$target"
}

write_backup_attempt() {
  local state="$1" phase="$2" stamp="$3" backup_name="${4:-}" operation="${5:-backup}"
  local status_dir="${BACKUP_DIR}/.status" target temp
  [[ "$state" =~ ^(running|failed|complete)$ ]] || return 2
  [[ "$phase" =~ ^[a-z_]+$ ]] || return 2
  [[ "$backup_name" =~ ^[A-Za-z0-9._-]*$ ]] || return 2
  [[ "$operation" =~ ^(backup|retention)$ ]] || return 2
  mkdir -p "$status_dir"
  chmod 700 "$status_dir"
  if [[ "$operation" == "backup" ]]; then
    target="${status_dir}/attempt.json"
  else
    target="${status_dir}/${operation}-attempt.json"
  fi
  temp="${target}.tmp.$$"
  printf '{"state":"%s","phase":"%s","recorded_at":"%s","backup":"%s"}\n' \
    "$state" "$phase" "$stamp" "$backup_name" > "$temp"
  chmod 600 "$temp"
  mv -f -- "$temp" "$target"
}

# Print the ID only when a restic listing proves the exact path, host and tag
# are all present on one non-empty snapshot. A successful command with [] is
# not verification.
select_offsite_snapshot_id() {
  local receipt="$1" target="$2"
  jq -er --arg target "$target" '
    if type != "array" then error("snapshot listing is not an array") else . end
    | map(select(
        .hostname == "prospect-vps"
        and (.tags | type == "array" and index("prospect-db"))
        and (.paths | type == "array" and index($target))
      ))
    | if length != 1 then error("expected exactly one matching snapshot") else .[0].id end
    | select(type == "string" and test("^[a-fA-F0-9]+$"))
  ' "$receipt"
}
