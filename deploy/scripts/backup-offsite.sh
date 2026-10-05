#!/usr/bin/env bash

# Shared, bounded offsite upload used by the nightly backup and by the
# upload-existing recovery command. This file is sourced after backup-status.sh.

configure_restic_pacing() {
  export RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-8}"
  export RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-8}"
  export RCLONE_DRIVE_PACER_MIN_SLEEP="${RCLONE_DRIVE_PACER_MIN_SLEEP:-200ms}"
  export RCLONE_DRIVE_PACER_BURST="${RCLONE_DRIVE_PACER_BURST:-50}"
  export RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-20}"
}

restic_failure_class() {
  local log_file="$1"
  if grep -Eqi 'quota exceeded|rate.?limit|too many requests|unauthorized|forbidden|invalid credentials|authentication failed|wrong password|access denied|401|403' "$log_file"; then
    printf 'terminal\n'
  elif grep -Eqi '(^|[^0-9])5[0-9][0-9]([^0-9]|$)|timeout|timed out|temporar|connection reset|connection refused|unexpected eof' "$log_file"; then
    printf 'transient\n'
  else
    printf 'terminal\n'
  fi
}

restic_repository_missing() {
  local log_file="$1"
  # Provider authentication, quota and throttling messages sometimes append
  # Restic's generic repository hint. Those failures must never initialize.
  grep -Eqi 'quota exceeded|rate.?limit|too many requests|unauthorized|forbidden|invalid credentials|authentication failed|wrong password|access denied|401|403' "$log_file" && return 1
  grep -Eqi 'repository does not exist|unable to open config file.*not found|is there a repository at the following location' "$log_file"
}

run_restic_bounded() {
  local label="$1" attempts="$2"
  shift 2
  local timeout_seconds="${RESTIC_COMMAND_TIMEOUT_SECONDS:-3600}" attempt log_file status class
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] && (( timeout_seconds <= 7200 )) || { echo "RESTIC_COMMAND_TIMEOUT_SECONDS must be between 1 and 7200." >&2; return 2; }
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] && (( attempts <= 5 )) || { echo "Restic attempts must be between 1 and 5." >&2; return 2; }
  log_file="$(mktemp)"
  for (( attempt=1; attempt<=attempts; attempt++ )); do
    status=0
    timeout --signal=TERM --kill-after=30 "${timeout_seconds}s" restic "$@" >"$log_file" 2>&1 || status=$?
    if (( status == 0 )); then rm -f -- "$log_file"; return 0; fi
    if (( status == 124 || status == 137 )); then
      echo "${label} exceeded its bounded deadline." >&2
      rm -f -- "$log_file"
      return "$status"
    fi
    class="$(restic_failure_class "$log_file")"
    if [[ "$class" != "transient" || "$attempt" == "$attempts" ]]; then
      echo "${label} failed (${class}); provider output was suppressed because it may contain repository credentials." >&2
      rm -f -- "$log_file"
      return "$status"
    fi
    sleep "$(( attempt * 10 ))"
  done
  rm -f -- "$log_file"
  return 1
}

resolve_backup_within_root() {
  local root="$1" requested="$2" resolved_root resolved
  resolved_root="$(realpath -- "$root")"
  resolved="$(realpath -- "$requested")"
  [[ "$resolved" == "$resolved_root"/20[0-9][0-9][01][0-9][0-3][0-9]T[0-2][0-9][0-5][0-9][0-5][0-9]Z ]] || {
    echo "Backup must be one timestamp directory directly inside ${resolved_root}." >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

validate_local_backup_for_upload() {
  local dest="$1" name objects recorded_objects manifest_check manifest_status archive_image
  name="$(basename "$dest")"
  [[ ! -L "$dest/database.dump.zst" && ! -L "$dest/globals.sql.zst" && ! -L "$dest/manifest.txt" && ! -L "$dest/meta.json"
    && -f "$dest/database.dump.zst" && -f "$dest/globals.sql.zst" && -f "$dest/manifest.txt" && -f "$dest/meta.json" ]] || {
    echo "Backup ${name} is incomplete." >&2; return 1;
  }
  command -v jq >/dev/null || { echo "jq is required to validate backup metadata." >&2; return 1; }
  timeout --signal=TERM --kill-after=30 300s zstd -q -t "$dest/database.dump.zst" \
    && timeout --signal=TERM --kill-after=30 300s zstd -q -t "$dest/globals.sql.zst" || {
    echo "Backup ${name} contains a corrupt compressed archive." >&2; return 1;
  }
  objects="$(wc -l < "$dest/manifest.txt")"
  (( objects > 50 )) || { echo "Backup ${name} has an incomplete manifest." >&2; return 1; }
  jq -e --arg name "$name" '.created_at == $name and (.database | type == "string" and length > 0) and (.postgres_image | type == "string" and startswith("supabase/postgres:")) and (.objects | type == "number" and . > 50)' "$dest/meta.json" >/dev/null || {
    echo "Backup ${name} metadata does not match the archive directory." >&2; return 1;
  }
  recorded_objects="$(jq -er '.objects' "$dest/meta.json")"
  [[ "$recorded_objects" == "$objects" ]] || { echo "Backup ${name} manifest count differs from metadata." >&2; return 1; }
  archive_image="$(jq -er '.postgres_image' "$dest/meta.json")"
  [[ -n "${POSTGRES_IMAGE_TAG:-}" && "$archive_image" == "supabase/postgres:${POSTGRES_IMAGE_TAG}" ]] || {
    echo "Backup ${name} PostgreSQL image differs from the configured reviewed image." >&2; return 1;
  }
  command -v docker >/dev/null || { echo "docker is required to verify the PostgreSQL archive." >&2; return 1; }
  manifest_check="$(mktemp)"
  set +e
  timeout --signal=TERM --kill-after=30 300s zstd -dc "$dest/database.dump.zst" | {
    manifest_status=0
    timeout --signal=TERM --kill-after=30 300s docker run --rm --pull never --network none --cpus .25 --memory 256m -i "$archive_image" pg_restore --list >"$manifest_check" 2>/dev/null || manifest_status=$?
    cat >/dev/null
    exit "$manifest_status"
  }
  manifest_status=$?
  set -e
  if (( manifest_status != 0 )) || ! cmp -s "$manifest_check" "$dest/manifest.txt"; then
    rm -f -- "$manifest_check"
    echo "Backup ${name} PostgreSQL archive does not match its manifest." >&2
    return 1
  fi
  rm -f -- "$manifest_check"
}

probe_restic_repository() {
  local allow_init="$1" timeout_seconds="${RESTIC_COMMAND_TIMEOUT_SECONDS:-3600}" probe_log init_log status=0 class
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] && (( timeout_seconds <= 7200 )) || return 2
  probe_log="$(mktemp)"
  timeout --signal=TERM --kill-after=30 "${timeout_seconds}s" restic cat config >"$probe_log" 2>&1 || status=$?
  if (( status == 0 )); then rm -f -- "$probe_log"; return 0; fi
  if [[ "$allow_init" == "1" ]] && restic_repository_missing "$probe_log"; then
    init_log="$(mktemp)"
    if timeout --signal=TERM --kill-after=30 "${timeout_seconds}s" restic init >"$init_log" 2>&1; then
      rm -f -- "$probe_log" "$init_log"
      return 0
    fi
    rm -f -- "$probe_log" "$init_log"
    echo "Offsite repository initialization failed; provider output was suppressed." >&2
    return 1
  fi
  class="$(restic_failure_class "$probe_log")"
  rm -f -- "$probe_log"
  echo "Offsite repository probe failed (${class}); it was not initialized or unlocked." >&2
  return "$status"
}

upload_backup_offsite() {
  local dest="$1" stamp="$2" objects="$3" backup_bytes="$4" allow_init="${5:-0}" operation="${6:-backup}"
  local snapshot_receipt remote_meta remote_error snapshot_id status=0
  configure_restic_pacing
  [[ -n "${RESTIC_REPOSITORY:-}" ]] || { echo "RESTIC_REPOSITORY is required for offsite upload." >&2; return 1; }

  probe_restic_repository "$allow_init" || return $?

  BACKUP_PHASE="offsite_upload"
  write_backup_attempt running "$BACKUP_PHASE" "$stamp" "$(basename "$dest")" "$operation"
  run_restic_bounded "Offsite backup upload" "${RESTIC_UPLOAD_ATTEMPTS:-3}" backup "$dest" --tag prospect-db --host prospect-vps || return $?

  BACKUP_PHASE="offsite_verify"
  write_backup_attempt running "$BACKUP_PHASE" "$stamp" "$(basename "$dest")" "$operation"
  snapshot_receipt="$(mktemp)"
  remote_meta="$(mktemp)"
  remote_error="$(mktemp)"
  trap 'rm -f -- "$snapshot_receipt" "$remote_meta" "$remote_error"' RETURN
  timeout --signal=TERM --kill-after=30 "${RESTIC_COMMAND_TIMEOUT_SECONDS:-3600}s" restic snapshots --tag prospect-db --host prospect-vps --path "$dest" --latest 1 --json >"$snapshot_receipt" 2>"$remote_error" || status=$?
  (( status == 0 )) || { echo "Offsite snapshot listing failed or timed out." >&2; return "$status"; }
  snapshot_id="$(select_offsite_snapshot_id "$snapshot_receipt" "$dest")" || {
    echo "Offsite upload returned, but its exact snapshot could not be verified." >&2; return 1;
  }
  status=0
  timeout --signal=TERM --kill-after=30 "${RESTIC_COMMAND_TIMEOUT_SECONDS:-3600}s" restic dump "$snapshot_id" "${dest}/meta.json" >"$remote_meta" 2>"$remote_error" || status=$?
  (( status == 0 )) && cmp -s "$remote_meta" "${dest}/meta.json" || {
    echo "Offsite snapshot metadata could not be read back byte-for-byte." >&2; return 1;
  }
  write_backup_stage offsite verified "$stamp" "$(basename "$dest")" "$objects" "$backup_bytes" "$snapshot_id"
  trap - RETURN
  rm -f -- "$snapshot_receipt" "$remote_meta" "$remote_error"
}
