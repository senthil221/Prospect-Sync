#!/usr/bin/env bash
# Deploy a new application build. Called by GitHub Actions over SSH, and safe to
# run by hand.
#
#   ./scripts/update.sh                       # deploy whatever APP_IMAGE points at
#   ./scripts/update.sh ghcr.io/.../app:abc123
#   ./scripts/update.sh --rollback            # back to the previous image
#
# Order matters: migrations run BEFORE the new container starts, so write every
# migration to be compatible with the currently-running app version too
# (add columns, don't rename them; drop only in a later release). That is what
# makes this safe without a maintenance window.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

STATE_FILE=".last-image"

if [[ "${1:-}" == "--rollback" ]]; then
  [[ -f "$STATE_FILE" ]] || { echo "No previous image recorded." >&2; exit 1; }
  NEW_IMAGE="$(cat "$STATE_FILE")"
  echo "Rolling back to ${NEW_IMAGE}"
  echo "NOTE: rollback does not undo migrations. If the failure was a migration,"
  echo "      restore from backup instead."
else
  NEW_IMAGE="${1:-$APP_IMAGE}"
fi

PREVIOUS_IMAGE="$(docker compose ps app --format json 2>/dev/null | jq -r '.Image // empty' | head -1)"

echo "==> Pulling ${NEW_IMAGE}"
docker pull "$NEW_IMAGE"

# Persist the choice so a manual `docker compose up -d` later uses the same one.
awk -v v="$NEW_IMAGE" -F= '$1=="APP_IMAGE"{print "APP_IMAGE=" v; next} {print}' .env > .env.tmp
mv .env.tmp .env
chmod 600 .env

echo "==> Ensuring platform services are up"
docker compose up -d db auth rest meta studio caddy

echo "==> Applying pending migrations"
./scripts/migrate.sh

echo "==> Starting new application container"
docker compose up -d --pull always app

echo "==> Waiting for health"
for attempt in $(seq 1 30); do
  status="$(docker inspect --format '{{.State.Health.Status}}' prospect-app 2>/dev/null || echo starting)"
  if [[ "$status" == "healthy" ]]; then
    echo "    healthy after ${attempt}0s"
    docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true
    [[ -n "$PREVIOUS_IMAGE" ]] && echo "$PREVIOUS_IMAGE" > "$STATE_FILE"
    echo
    echo "Deployed ${NEW_IMAGE}"
    exit 0
  fi
  sleep 10
done

echo
echo "!! New container did not become healthy. Last 60 log lines:" >&2
docker compose logs --tail 60 app >&2
echo >&2
echo "Roll back with: ./scripts/update.sh --rollback" >&2
exit 1
