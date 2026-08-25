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
set -eEuo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

STATE_FILE=".last-image"

if [[ "${1:-}" == "--rollback" ]]; then
  [[ -f "$STATE_FILE" ]] || { echo "No previous image recorded." >&2; exit 1; }
  NEW_IMAGE="$(cat "$STATE_FILE")"
  EXPECTED_VERSION=""
  echo "Rolling back to ${NEW_IMAGE}"
  echo "NOTE: rollback does not undo migrations. If the failure was a migration,"
  echo "      restore from backup instead."
else
  NEW_IMAGE="${1:-$APP_IMAGE}"
  EXPECTED_VERSION="${2:-}"
fi

PREVIOUS_IMAGE="$(docker compose ps app --format json 2>/dev/null | jq -r '.Image // empty' | head -1)"

set_app_image() {
  local image="$1"
  awk -v v="$image" -F= '$1=="APP_IMAGE"{print "APP_IMAGE=" v; next} {print}' .env > .env.tmp
  mv .env.tmp .env
  chmod 600 .env
}

wait_for_app() {
  local attempts="${1:-30}"
  local attempt status
  for attempt in $(seq 1 "$attempts"); do
    status="$(docker inspect --format '{{.State.Health.Status}}' prospect-app 2>/dev/null || echo starting)"
    if [[ "$status" == "healthy" ]]; then
      echo "    healthy after ${attempt}0s"
      return 0
    fi
    sleep 10
  done
  return 1
}

restore_previous_image() {
  if [[ -z "$PREVIOUS_IMAGE" || "$PREVIOUS_IMAGE" == "$NEW_IMAGE" ]]; then
    echo "No distinct previous image is available for automatic rollback." >&2
    return 1
  fi

  echo "==> Automatically rolling back to ${PREVIOUS_IMAGE}" >&2
  set_app_image "$PREVIOUS_IMAGE"
  docker compose up -d app
  if wait_for_app 18; then
    echo "Automatic rollback succeeded; the previous app is serving again." >&2
    return 0
  fi

  echo "Automatic rollback also failed. Inspect: docker compose logs --tail 100 app" >&2
  return 1
}

rollback_on_error() {
  local status="${1:-1}"
  trap - ERR
  set +e
  restore_previous_image
  exit "$status"
}

echo "==> Pulling ${NEW_IMAGE}"
docker pull "$NEW_IMAGE"

# Persist the choice so a manual `docker compose up -d` later uses the same one.
set_app_image "$NEW_IMAGE"
trap 'rollback_on_error $?' ERR

echo "==> Ensuring platform services are up"
docker compose up -d db auth rest meta studio caddy

echo "==> Applying pending migrations"
./scripts/migrate.sh

echo "==> Starting new application container"
docker compose up -d --pull always app

echo "==> Waiting for health"
if ! wait_for_app 30; then
  echo
  echo "!! New container did not become healthy. Last 60 log lines:" >&2
  docker compose logs --tail 60 app >&2
  rollback_on_error 1
fi

if [[ -n "$EXPECTED_VERSION" ]]; then
  echo "==> Verifying the public route serves ${EXPECTED_VERSION}"
  public_ready=0
  for attempt in $(seq 1 12); do
    headers="$(curl -sS -D - -o /dev/null -m 15 "${APP_PUBLIC_URL}/api/health" || true)"
    code="$(printf '%s' "$headers" | head -1 | grep -o '[0-9]\{3\}' || echo 000)"
    version="$(printf '%s' "$headers" | grep -i '^x-app-version:' | tr -d '\r' | cut -d' ' -f2)"
    if [[ "$code" == "200" && "$version" == "$EXPECTED_VERSION" ]]; then
      public_ready=1
      break
    fi
    echo "    attempt ${attempt}: HTTP ${code:-000}, X-App-Version=${version:-<none>}"
    sleep 5
  done
  if [[ "$public_ready" != "1" ]]; then
    echo "The new container is healthy internally, but the public route is not serving the expected version." >&2
    rollback_on_error 1
  fi
fi

docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true
[[ -n "$PREVIOUS_IMAGE" ]] && echo "$PREVIOUS_IMAGE" > "$STATE_FILE"
trap - ERR
echo
echo "Deployed ${NEW_IMAGE}"
