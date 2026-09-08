#!/usr/bin/env bash
# Wait for the existing cleanup runner, then finalize and prove completion.
# This never resumes a failed cleanup or treats an absent checkpoint as success.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/_env.sh
load_env .env
umask 077
[[ -d .fixed-fields-checkpoints ]] || { echo 'No cleanup checkpoints found.' >&2; exit 1; }
exec 9>.fixed-fields-checkpoints/runner.lock
echo 'Waiting for the fixed-field cleanup runner to release its lock.'
flock 9
for entity in company prospect list_row catalog; do
  checkpoint=".fixed-fields-checkpoints/${entity}"
  [[ -f "$checkpoint" ]] || { echo "Missing ${entity} checkpoint." >&2; exit 1; }
  read -r cursor total < "$checkpoint"
  [[ "$cursor" == 'DONE' ]] || { echo "Cleanup stopped before ${entity} completed." >&2; exit 1; }
done
for sql in ../scripts/finalize-fixed-fields.sql ../scripts/verify-fixed-fields-completion.sql; do
  docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 < "$sql"
done
printf '%s Fixed-field maintenance and title backfill verified complete.\n' "$(date -u +%FT%TZ)"
