#!/usr/bin/env bash
# Resume the title backfill until every prospect matches the current taxonomy.
# Run from a server checkout; progress contains counts only.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh
load_env .env
failures=0
while :; do
  if result="$(docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 -tAq -F '|' \
    -c "set statement_timeout='120s'; set lock_timeout='5s'; select processed,remaining,acquired from public.run_title_classification_batch_v2(1000);")"; then
    failures=0
  else
    failures=$((failures + 1))
    (( failures < 5 )) || { echo 'Classifier failed five consecutive attempts.' >&2; exit 1; }
    echo 'Batch rolled back; retrying from its database checkpoint.'
    sleep 5
    continue
  fi
  IFS='|' read -r processed remaining acquired <<< "$result"
  [[ "$acquired" == "t" ]] || { echo 'Another classifier owns this batch; retrying.'; sleep 5; continue; }
  printf '%s processed=%s remaining=%s\n' "$(date -u +%FT%TZ)" "$processed" "$remaining"
  [[ "$remaining" == "0" ]] && break
  [[ "$processed" != "0" ]] || { echo 'Classifier made no progress.' >&2; exit 1; }
  sleep 1
done
echo 'Title classification complete.'
