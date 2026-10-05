#!/usr/bin/env bash
set -euo pipefail

# Execute the real isolated-restore control flow against command mocks. No
# Docker daemon, database, network, credentials or production archive is used.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT

cp -R "$repo_root/deploy" "$fixture_root/deploy"
mkdir -p "$fixture_root/mock-bin" "$fixture_root/state" "$fixture_root/backups/20261005T032631Z/.keep"
backup="$fixture_root/backups/20261005T032631Z"
seq 1 60 >"$backup/manifest.txt"
printf 'mock database archive\n' >"$backup/database.dump.zst"
printf 'mock globals archive\n' >"$backup/globals.sql.zst"
printf '%s\n' '{"created_at":"20261005T032631Z","database":"postgres","objects":60,"postgres_image":"supabase/postgres:test"}' >"$backup/meta.json"
printf 'POSTGRES_IMAGE_TAG=test\n' >"$fixture_root/deploy/.env"

cat >"$fixture_root/mock-bin/zstd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" -t "*) exit 0 ;;
  *" -dc "*)
    if [[ "${@: -1}" == *database.dump.zst && "${MOCK_MODE:-}" == restore_*_sigpipe ]]; then
      count_file="$MOCK_STATE/zstd-database.count"
      count=0; [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
      count="$(( count + 1 ))"; printf '%s' "$count" >"$count_file"
      # The first stream is the bounded pg_restore --list validation. Simulate
      # SIGPIPE only for the second stream, the actual database restore.
      if (( count >= 2 )); then
        printf 'partial archive bytes\n' || true
        exit 141
      fi
    fi
    cat "${@: -1}" ;;
  *) exit 2 ;;
esac
EOF

cat >"$fixture_root/mock-bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="" name=""
while (($#)); do
  case "$1" in
    -e|-r|-er) shift ;;
    --arg) [[ "$2" == name ]] && name="$3"; shift 3 ;;
    *) query="$1"; file="$2"; break ;;
  esac
done
JQ_QUERY="$query" JQ_NAME="$name" node - "$file" <<'NODE'
const fs = require("node:fs");
const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const query = process.env.JQ_QUERY;
if (query.includes(".created_at == $name")) {
  process.exit(data.created_at === process.env.JQ_NAME && typeof data.database === "string" && data.database.length > 0
    && typeof data.postgres_image === "string" && data.postgres_image.startsWith("supabase/postgres:")
    && typeof data.objects === "number" && data.objects > 50 ? 0 : 1);
}
if (query.includes(".database | type")) process.exit(typeof data.database === "string" && /^[A-Za-z_][A-Za-z0-9_]*$/.test(data.database) ? 0 : 1);
for (const key of ["objects", "postgres_image", "state"]) {
  if (query.includes(`.${key}`)) { process.stdout.write(String(data[key])); process.exit(0); }
}
process.exit(2);
NODE
EOF

cat >"$fixture_root/mock-bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == --* ]]; do shift; done
shift
if [[ -n "${MOCK_TIMEOUT_MATCH:-}" && " $* " == *"${MOCK_TIMEOUT_MATCH}"* ]]; then exit 124; fi
exec "$@"
EOF

cat >"$fixture_root/mock-bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fixture_root/mock-bin/restic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RESTIC_MOCK_LOG"
if [[ "${RESTIC_MOCK_MODE:-}" == combined ]]; then
  printf '%s\n' '403 forbidden: quota exceeded; is there a repository at the following location?' >&2
  exit 1
fi
[[ "$1" == init ]] && exit 0
printf '%s\n' 'repository does not exist' >&2
exit 1
EOF

cat >"$fixture_root/mock-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_STATE/docker.log"
command_name="${1:-}"; shift || true
case "$command_name" in
  volume)
    sub="${1:-}"; shift || true
    case "$sub" in
      create)
        label=""; name="${@: -1}"
        while (($#)); do [[ "$1" == --label ]] && { label="$2"; shift 2; continue; }; shift; done
        printf '%s' "${label#*=}" >"$MOCK_STATE/volume.label"; printf '%s' "$name" >"$MOCK_STATE/volume.name"
        [[ "${MOCK_MODE:-}" == partial_volume ]] && exit 1
        echo "$name" ;;
      inspect)
        [[ -f "$MOCK_STATE/volume.name" ]] || exit 1
        [[ " $* " == *" --format "* ]] && cat "$MOCK_STATE/volume.label" ;;
      rm)
        [[ "${MOCK_MODE:-}" == cleanup_fail ]] && exit 1
        rm -f "$MOCK_STATE/volume.name" "$MOCK_STATE/volume.label" ;;
    esac ;;
  run)
    if [[ " $* " == *" --rm "* ]]; then
      cat >/dev/null
      cat "$MOCK_MANIFEST"
      exit 0
    fi
    name=""; label=""
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      [[ "${args[$i]}" == --name ]] && name="${args[$((i+1))]}"
      [[ "${args[$i]}" == --label ]] && label="${args[$((i+1))]}"
    done
    printf '%s' "$name" >"$MOCK_STATE/container.name"
    printf '%s' "${label#*=}" >"$MOCK_STATE/container.label"
    if [[ "${MOCK_MODE:-}" == term ]]; then kill -TERM "$PPID"; sleep 0.1; fi
    [[ "${MOCK_MODE:-}" == partial_start ]] && exit 1
    echo mock-container-id ;;
  inspect)
    [[ -f "$MOCK_STATE/container.name" ]] || exit 1
    count=0; [[ ! -f "$MOCK_STATE/inspect.count" ]] || count="$(cat "$MOCK_STATE/inspect.count")"
    count="$((count + 1))"; printf '%s' "$count" >"$MOCK_STATE/inspect.count"
    [[ "${MOCK_MODE:-}" == monitor_fail && "$count" == 1 ]] && exit 1
    if [[ " $* " == *".State.OOMKilled"* ]]; then echo false
    elif [[ " $* " == *" --format "* ]]; then cat "$MOCK_STATE/container.label"
    fi
    exit 0 ;;
  exec)
    joined=" $* "
    if [[ "$joined" == *" pg_isready "* ]]; then exit 0; fi
    if [[ "$joined" == *" du -sb /var/lib/postgresql/data "* ]]; then echo '1048576 /var/lib/postgresql/data'; exit 0; fi
    if [[ "$joined" == *" pg_restore "* ]]; then
      if [[ "${MOCK_MODE:-}" == restore_secret_sigpipe ]]; then
        printf '%s\n' 'pg_restore: error: ERROR: 42501: permission denied for table private_customer_rows' >&2
        printf '%s\n' 'pg_restore: error: from TOC entry 1234; 1259 99999 TABLE private_customer_rows postgres' >&2
        printf '%s\n' "Command was: INSERT INTO private_customer_rows VALUES ('person@example.test', 'password=super-secret');" >&2
        exit 1
      fi
      if [[ "${MOCK_MODE:-}" == restore_timeout_sigpipe ]]; then exit 124; fi
      cat >/dev/null
      exit 0
    fi
    if [[ "$joined" == *" psql "* ]]; then
      cat >/dev/null || true
      [[ "$joined" == *" -XAtq "* ]] && printf 'off|restore_drill|restore_drill_disabled\n'
      exit 0
    fi
    exit 2 ;;
  stop) exit 0 ;;
  rm)
    [[ "${MOCK_MODE:-}" == cleanup_fail ]] && exit 1
    rm -f "$MOCK_STATE/container.name" "$MOCK_STATE/container.label" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fixture_root/mock-bin/"*

export PATH="$fixture_root/mock-bin:$PATH"
export MOCK_STATE="$fixture_root/state"
export MOCK_MANIFEST="$backup/manifest.txt"
export BACKUP_DIR="$fixture_root/backups"
export RESTORE_DRILL_MIN_FREE_BYTES=1
export RESTORE_DRILL_HOST_RESERVE_BYTES=1
export RESTORE_DRILL_MAX_DATA_BYTES=1073741824
export RESTORE_DRILL_TIMEOUT_SECONDS=300

source "$fixture_root/deploy/scripts/backup-offsite.sh"
export RESTIC_MOCK_LOG="$fixture_root/state/restic.log"
export RESTIC_MOCK_MODE=combined
if probe_restic_repository 1 >/dev/null 2>&1; then
  echo "combined quota/403 probe unexpectedly succeeded" >&2
  exit 1
fi
! grep -q '^init$' "$RESTIC_MOCK_LOG"
: >"$RESTIC_MOCK_LOG"
export MOCK_TIMEOUT_MATCH=' restic cat config '
if probe_restic_repository 1 >/dev/null 2>&1; then
  echo "timed-out repository probe unexpectedly succeeded" >&2
  exit 1
fi
! grep -q '^init$' "$RESTIC_MOCK_LOG"
unset MOCK_TIMEOUT_MATCH RESTIC_MOCK_MODE

reset_case() {
  rm -f "$MOCK_STATE/"*
  rm -rf "$BACKUP_DIR/.status"
  mkdir -p "$BACKUP_DIR/.status"
  printf '%s\n' '{"stage":"offsite","state":"verified","recorded_at":"prior"}' >"$BACKUP_DIR/.status/offsite.json"
  cp "$BACKUP_DIR/.status/offsite.json" "$MOCK_STATE/prior-receipt"
  unset MOCK_TIMEOUT_MATCH
}

run_failure() {
  local name="$1" expected="$2" status=0
  shift 2
  MOCK_MODE="$name" bash "$fixture_root/deploy/scripts/restore-isolated.sh" "$backup" >/dev/null 2>&1 || status=$?
  [[ "$status" == "$expected" ]] || { echo "${name}: expected exit ${expected}, got ${status}" >&2; exit 1; }
  cmp -s "$MOCK_STATE/prior-receipt" "$BACKUP_DIR/.status/offsite.json"
  [[ "$(jq -r .state "$BACKUP_DIR/.status/restore_drill-attempt.json")" == failed ]]
}

assert_sanitized_diagnostic() {
  local expected="$1" log_file="$2"
  if ! grep -Eq "$expected" "$log_file"; then
    echo "unexpected sanitized restore diagnostic:" >&2
    grep -E '^Isolated database restore failed:' "$log_file" >&2 || true
    return 1
  fi
}

reset_case
MOCK_MODE=success bash "$fixture_root/deploy/scripts/restore-isolated.sh" "$backup" >/dev/null
[[ "$(jq -r .state "$BACKUP_DIR/.status/restore_drill.json")" == verified ]]
[[ ! -e "$MOCK_STATE/container.name" && ! -e "$MOCK_STATE/volume.name" ]]
cmp -s "$MOCK_STATE/prior-receipt" "$BACKUP_DIR/.status/offsite.json"

reset_case
run_failure partial_volume 1
grep -q '^volume rm ' "$MOCK_STATE/docker.log"

reset_case
run_failure partial_start 1
grep -q '^rm ' "$MOCK_STATE/docker.log"
grep -q '^volume rm ' "$MOCK_STATE/docker.log"

reset_case
run_failure cleanup_fail 1
[[ -e "$MOCK_STATE/container.name" ]]

reset_case
run_failure term 143
grep -q '^rm ' "$MOCK_STATE/docker.log"

reset_case
run_failure monitor_fail 143
grep -q '^rm ' "$MOCK_STATE/docker.log"

reset_case
export MOCK_TIMEOUT_MATCH=' psql -XAtq '
run_failure timeout 124
unset MOCK_TIMEOUT_MATCH

reset_case
diagnostic_log="$fixture_root/restore-diagnostic.log"
diagnostic_status=0
MOCK_MODE=restore_secret_sigpipe bash "$fixture_root/deploy/scripts/restore-isolated.sh" "$backup" >"$diagnostic_log" 2>&1 || diagnostic_status=$?
[[ "$diagnostic_status" == 1 ]]
assert_sanitized_diagnostic '^Isolated database restore failed: category=permission_denied decompressor_status=141 pg_restore_status=1 elapsed_seconds=[0-9]+ oom=false toc_entry=1234\. Raw restore output was suppressed\.$' "$diagnostic_log"
if grep -Eqi 'private_customer_rows|person@example\.test|super-secret|INSERT INTO|password=' "$diagnostic_log"; then
  echo "restore diagnostics exposed raw SQL, PII or a secret" >&2
  exit 1
fi
[[ ! -e "$MOCK_STATE/container.name" && ! -e "$MOCK_STATE/volume.name" ]]
[[ "$(jq -r .state "$BACKUP_DIR/.status/restore_drill-attempt.json")" == failed ]]

reset_case
timeout_diagnostic_log="$fixture_root/restore-timeout-diagnostic.log"
timeout_diagnostic_status=0
MOCK_MODE=restore_timeout_sigpipe bash "$fixture_root/deploy/scripts/restore-isolated.sh" "$backup" >"$timeout_diagnostic_log" 2>&1 || timeout_diagnostic_status=$?
[[ "$timeout_diagnostic_status" == 124 ]]
assert_sanitized_diagnostic '^Isolated database restore failed: category=deadline decompressor_status=141 pg_restore_status=124 elapsed_seconds=[0-9]+ oom=false toc_entry=unknown\. Raw restore output was suppressed\.$' "$timeout_diagnostic_log"
[[ ! -e "$MOCK_STATE/container.name" && ! -e "$MOCK_STATE/volume.name" ]]

printf 'PASS: isolated restore succeeds and fails closed across start, cleanup, signal and timeout paths\n'
