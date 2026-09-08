#!/usr/bin/env bash
# Explicitly apply the approved historical field deletion, in resumable batches.
# Create and verify a recovery backup before invoking this script.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh
load_env .env
umask 077
mkdir -p .fixed-fields-checkpoints
exec 9>.fixed-fields-checkpoints/runner.lock
flock -n 9 || { echo 'A fixed-field cleanup is already running.' >&2; exit 1; }
for entity in company prospect list_row catalog; do
  checkpoint=".fixed-fields-checkpoints/${entity}"
  cursor=''
  total=0
  [[ ! -f "$checkpoint" ]] || read -r cursor total < "$checkpoint"
  [[ "$cursor" != 'DONE' ]] || continue
  while :; do
    result="$(docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
      psql -X -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 -tAq -F '|' \
      -v entity="$entity" -v cursor="$cursor" <<'SQL'
set statement_timeout='120s';
set lock_timeout='5s';
select scanned,updated,replace(encode(convert_to(coalesce(next_after_id,''),'UTF8'),'base64'),E'\n',''),remaining
from public.sanitize_import_payloads_v1(:'entity',nullif(convert_from(decode(:'cursor','base64'),'UTF8'),''),500,true);
SQL
    )"
    IFS='|' read -r scanned updated cursor remaining <<< "$result"
    total=$((total + updated))
    printf '%s entity=%s scanned=%s updated=%s total=%s remaining=%s\n' "$(date -u +%FT%TZ)" "$entity" "$scanned" "$updated" "$total" "$remaining"
    [[ "$remaining" == 't' ]] || cursor='DONE'
    printf '%s %s\n' "$cursor" "$total" > "${checkpoint}.tmp"
    mv "${checkpoint}.tmp" "$checkpoint"
    [[ "$cursor" != 'DONE' ]] || break
    [[ "$scanned" != '0' ]] || { echo 'Cleanup made no progress.' >&2; exit 1; }
    sleep 0.2
  done
done
echo 'Fixed-field cleanup complete.'
