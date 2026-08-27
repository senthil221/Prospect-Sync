#!/usr/bin/env bash
# Deploy the application with a blue/green handoff. The currently active slot
# stays online until the candidate image is healthy, reports the expected build
# version, and Caddy has atomically switched new traffic to it.
#
#   ./scripts/update.sh                       # deploy APP_IMAGE
#   ./scripts/update.sh ghcr.io/.../app:abc123 <full-git-sha>
#   ./scripts/update.sh --rollback            # switch to the previous image
#
# Migrations still run first, so they must remain backward-compatible with the
# active application. migrate.sh uses a short lock timeout: a migration that
# would freeze live traffic fails the release instead.
set -eEuo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

LAST_IMAGE_FILE=".last-image"
ACTIVE_SLOT_FILE=".active-app-slot"
LOCK_FILE=".deploy.lock"
CADDY_TEMPLATE="caddy/Caddyfile"
ROUTER_TEMPLATE="caddy/AppRouter.Caddyfile"

# An SSH retry must not race a remote deployment that survived a disconnected
# client. Wait for the first process, then perform another idempotent handoff.
exec 9>"$LOCK_FILE"
if ! flock -w 600 9; then
  echo "Another deployment still holds ${LOCK_FILE} after 10 minutes." >&2
  exit 75
fi

slot_service() {
  case "$1" in
    blue) echo "app-blue" ;;
    green) echo "app-green" ;;
    legacy) echo "app" ;;
    *) return 1 ;;
  esac
}

slot_container() {
  case "$1" in
    blue) echo "prospect-app-blue" ;;
    green) echo "prospect-app-green" ;;
    legacy) echo "prospect-app" ;;
    *) return 1 ;;
  esac
}

container_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

container_healthy() {
  [[ "$(docker inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null || true)" == "healthy" ]]
}

image_for_slot() {
  docker inspect --format '{{.Config.Image}}' "$(slot_container "$1")" 2>/dev/null || true
}

detect_active_slot() {
  local recorded=""
  if [[ -f "$ACTIVE_SLOT_FILE" ]]; then
    recorded="$(tr -d '[:space:]' < "$ACTIVE_SLOT_FILE")"
    if [[ "$recorded" =~ ^(blue|green)$ ]] && container_running "$(slot_container "$recorded")"; then
      echo "$recorded"
      return 0
    fi
  fi

  # First deployment after upgrading from the single-container topology.
  if container_running "$(slot_container legacy)"; then
    echo legacy
    return 0
  fi

  for recorded in blue green; do
    if container_healthy "$(slot_container "$recorded")"; then
      echo "$recorded"
      return 0
    fi
  done

  echo none
}

set_app_image() {
  local image="$1"
  awk -v v="$image" -F= '$1=="APP_IMAGE"{print "APP_IMAGE=" v; next} {print}' .env > .env.tmp
  mv .env.tmp .env
  chmod 600 .env
  # load_env exports APP_IMAGE. Shell environment has higher precedence than
  # Compose's .env file, so update the current process too or Compose will
  # quietly start the previous image even though the file is correct.
  APP_IMAGE="$image"
  export APP_IMAGE
}

wait_for_container() {
  local container="$1" attempts="${2:-30}"
  local attempt status
  for attempt in $(seq 1 "$attempts"); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo starting)"
    echo "    attempt ${attempt}/${attempts}: ${status}"
    if [[ "$status" == "healthy" ]]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

verify_candidate_version() {
  local container="$1" expected="$2"
  [[ -z "$expected" ]] && return 0
  docker exec -e EXPECTED_VERSION="$expected" "$container" node -e '
    fetch("http://127.0.0.1:3000/api/health").then((response) => {
      const version = response.headers.get("x-app-version") || "";
      if (!response.ok || version !== process.env.EXPECTED_VERSION) {
        console.error(`candidate returned HTTP ${response.status}, X-App-Version=${version}`);
        process.exit(1);
      }
      console.log(`candidate is serving ${version}`);
    }).catch((error) => { console.error(error); process.exit(1); });
  '
}

render_router_for_slot() {
  local slot="$1" upstream tmp
  upstream="$(slot_service "$slot")"
  [[ "$slot" =~ ^(blue|green)$ ]] || return 1
  tmp="$(mktemp /tmp/prospect-AppRouter.XXXXXX)"
  sed "s/reverse_proxy app-blue:3000 app-green:3000 {/reverse_proxy ${upstream}:3000 {/" \
    "$ROUTER_TEMPLATE" > "$tmp"
  grep -q "reverse_proxy ${upstream}:3000 {" "$tmp" || {
    rm -f "$tmp"
    echo "Could not render the Caddy upstream for ${slot}." >&2
    return 1
  }
  echo "$tmp"
}

switch_traffic() {
  local slot="$1" rendered router_path edge_path
  edge_path="/tmp/Caddyfile.prospect-edge"

  if ! container_running prospect-caddy; then
    docker compose up -d --no-deps caddy
  fi

  if [[ "$slot" == "legacy" ]]; then
    # Only used if the very first blue/green cutover needs to roll back. The
    # legacy container is addressed by its unique Docker name, so bypass the
    # router without colliding with the router's compatibility `app` alias.
    rendered="$(mktemp /tmp/prospect-Caddyfile-legacy.XXXXXX)"
    sed 's/reverse_proxy app-router:3000 {/reverse_proxy prospect-app:3000 {/' "$CADDY_TEMPLATE" > "$rendered"
    docker cp "$rendered" "prospect-caddy:${edge_path}"
    rm -f "$rendered"
    docker exec prospect-caddy caddy validate --config "$edge_path" --adapter caddyfile
    docker exec prospect-caddy caddy reload --config "$edge_path" --adapter caddyfile
    return 0
  fi

  rendered="$(render_router_for_slot "$slot")"
  router_path="/tmp/Caddyfile.prospect-${slot}"
  if ! container_running prospect-app-router; then
    docker compose up -d --no-deps app-router
  fi
  docker cp "$rendered" "prospect-app-router:${router_path}"
  rm -f "$rendered"
  docker exec prospect-app-router caddy validate --config "$router_path" --adapter caddyfile
  docker exec prospect-app-router caddy reload --config "$router_path" --adapter caddyfile

  # The edge proxy is never recreated. This graceful reload performs the
  # one-time migration from the former direct `app` upstream and is harmless on
  # later releases. The router also keeps the `app` alias as a reboot fallback
  # for an edge container created before blue/green deployment existed.
  docker cp "$CADDY_TEMPLATE" "prospect-caddy:${edge_path}"
  docker exec prospect-caddy caddy validate --config "$edge_path" --adapter caddyfile
  docker exec prospect-caddy caddy reload --config "$edge_path" --adapter caddyfile
}

verify_public_route() {
  local expected="$1" attempts="${2:-12}"
  local attempt headers code version
  for attempt in $(seq 1 "$attempts"); do
    headers="$(curl -sS -D - -o /dev/null -m 15 "${APP_PUBLIC_URL}/api/health" || true)"
    code="$(printf '%s' "$headers" | head -1 | grep -o '[0-9]\{3\}' || echo 000)"
    version="$(printf '%s' "$headers" | grep -i '^x-app-version:' | tr -d '\r' | cut -d' ' -f2)"
    if [[ "$code" == "200" && ( -z "$expected" || "$version" == "$expected" ) ]]; then
      echo "    public route is healthy${version:+ on ${version}}"
      return 0
    fi
    echo "    attempt ${attempt}/${attempts}: HTTP ${code:-000}, X-App-Version=${version:-<none>}"
    sleep 5
  done
  return 1
}

verify_public_upload_route() {
  local attempts="${1:-8}" attempt code
  for attempt in $(seq 1 "$attempts"); do
    # Deliberately omit auth and upload metadata. A live TUS route rejects the
    # request with a client/auth error; the regression this protects against is
    # the edge proxy's 404 before Storage ever sees it.
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -X POST \
      -H 'Tus-Resumable: 1.0.0' -H 'Upload-Length: 0' \
      "${SUPABASE_PUBLIC_URL}/storage/v1/upload/resumable" || echo 000)"
    case "$code" in
      404|000|"") ;;
      2??|4??)
        echo "    public resumable-upload route reached Storage (HTTP ${code})"
        return 0
        ;;
    esac
    echo "    attempt ${attempt}/${attempts}: upload route returned HTTP ${code:-000}"
    sleep 5
  done
  return 1
}

ACTIVE_SLOT="$(detect_active_slot)"
case "$ACTIVE_SLOT" in
  blue) CANDIDATE_SLOT=green ;;
  green) CANDIDATE_SLOT=blue ;;
  legacy|none) CANDIDATE_SLOT=blue ;;
esac

PREVIOUS_IMAGE=""
if [[ "$ACTIVE_SLOT" != "none" ]]; then
  PREVIOUS_IMAGE="$(image_for_slot "$ACTIVE_SLOT")"
fi

if [[ "${1:-}" == "--rollback" ]]; then
  [[ -f "$LAST_IMAGE_FILE" ]] || { echo "No previous image recorded." >&2; exit 1; }
  NEW_IMAGE="$(tr -d '[:space:]' < "$LAST_IMAGE_FILE")"
  EXPECTED_VERSION=""
  echo "Rolling back to ${NEW_IMAGE} through the inactive slot."
  echo "NOTE: rollback does not undo migrations; migrations must be backward-compatible."
else
  NEW_IMAGE="${1:-$APP_IMAGE}"
  EXPECTED_VERSION="${2:-}"
fi

CANDIDATE_SERVICE="$(slot_service "$CANDIDATE_SLOT")"
CANDIDATE_CONTAINER="$(slot_container "$CANDIDATE_SLOT")"
TRAFFIC_SWITCHED=0
CANDIDATE_STARTED=0

# A retry after a lost SSH response may arrive after the first remote process
# already completed. Do not bounce the same build through the other slot or
# overwrite the useful rollback image in that case.
if [[ "$ACTIVE_SLOT" =~ ^(blue|green)$ && "$PREVIOUS_IMAGE" == "$NEW_IMAGE" ]] \
  && verify_public_route "$EXPECTED_VERSION" 1; then
  set_app_image "$NEW_IMAGE"
  echo "${NEW_IMAGE} is already healthy on ${ACTIVE_SLOT}; nothing to redeploy."
  exit 0
fi

rollback_on_error() {
  local status="${1:-1}"
  local safe_to_stop_candidate=1
  trap - ERR
  set +e

  echo "==> Deployment failed; keeping the previous application online." >&2
  if [[ "$TRAFFIC_SWITCHED" == "1" && "$ACTIVE_SLOT" != "none" ]]; then
    echo "==> Returning traffic to ${ACTIVE_SLOT}." >&2
    if ! switch_traffic "$ACTIVE_SLOT"; then
      echo "WARNING: proxy rollback failed; leaving both slots running to avoid an outage." >&2
      safe_to_stop_candidate=0
    fi
  fi
  if [[ "$CANDIDATE_STARTED" == "1" && "$safe_to_stop_candidate" == "1" ]]; then
    docker stop -t 30 "$CANDIDATE_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PREVIOUS_IMAGE" && "$safe_to_stop_candidate" == "1" ]]; then
    set_app_image "$PREVIOUS_IMAGE"
    docker compose up -d --no-deps import-worker >/dev/null 2>&1 \
      || echo "WARNING: the previous import worker image could not be restored automatically." >&2
  fi
  exit "$status"
}
trap 'rollback_on_error $?' ERR

echo "==> Active slot: ${ACTIVE_SLOT}; candidate slot: ${CANDIDATE_SLOT}"
echo "==> Pulling ${NEW_IMAGE}"
docker pull "$NEW_IMAGE"
set_app_image "$NEW_IMAGE"

echo "==> Ensuring the database and Supabase services are up"
docker compose up -d db auth rest storage meta studio

echo "==> Refreshing database roles and guard rails"
docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh

echo "==> Applying pending backward-compatible migrations"
./scripts/migrate.sh

echo "==> Starting and verifying the durable import worker on ${NEW_IMAGE}"
docker compose up -d --no-deps app-router
docker compose up -d --no-deps --pull always import-worker
if ! wait_for_container prospect-import-worker 18; then
  echo "Import worker did not become healthy. Last 80 log lines:" >&2
  docker compose logs --tail 80 import-worker >&2 || true
  rollback_on_error 1
fi

echo "==> Starting ${CANDIDATE_SERVICE} without touching ${ACTIVE_SLOT}"
CANDIDATE_STARTED=1
docker compose up -d --no-deps --pull always "$CANDIDATE_SERVICE"

echo "==> Waiting for backend-aware candidate health"
if ! wait_for_container "$CANDIDATE_CONTAINER" 30; then
  echo "Candidate did not become healthy. Last 80 log lines:" >&2
  docker compose logs --tail 80 "$CANDIDATE_SERVICE" >&2 || true
  rollback_on_error 1
fi
verify_candidate_version "$CANDIDATE_CONTAINER" "$EXPECTED_VERSION"

echo "==> Atomically switching new traffic to ${CANDIDATE_SLOT}"
# Arm rollback before the first reload. If the router reload succeeds but the
# following edge-proxy validation fails, traffic has already moved and must be
# explicitly returned to the still-running previous slot.
TRAFFIC_SWITCHED=1
switch_traffic "$CANDIDATE_SLOT"

echo "==> Verifying the public route"
if ! verify_public_route "$EXPECTED_VERSION" 12; then
  echo "The candidate is healthy internally, but the public route failed verification." >&2
  rollback_on_error 1
fi

echo "==> Verifying the public resumable-upload route"
if ! verify_public_upload_route 8; then
  echo "The application is healthy, but the public Storage TUS route is unavailable." >&2
  rollback_on_error 1
fi

# Caddy reloads are graceful: requests already assigned to the previous config
# retain it, while new requests use the candidate. Docker then gives any old
# Next.js process up to five minutes to drain before forcing it down.
printf '%s\n' "$CANDIDATE_SLOT" > "${ACTIVE_SLOT_FILE}.tmp"
mv "${ACTIVE_SLOT_FILE}.tmp" "$ACTIVE_SLOT_FILE"
if [[ -n "$PREVIOUS_IMAGE" ]]; then
  printf '%s\n' "$PREVIOUS_IMAGE" > "${LAST_IMAGE_FILE}.tmp"
  mv "${LAST_IMAGE_FILE}.tmp" "$LAST_IMAGE_FILE"
fi

# The candidate is verified and the durable state is recorded. Cleanup is
# best-effort from here; a cleanup failure must never route traffic backward.
trap - ERR
if [[ "$ACTIVE_SLOT" != "none" && "$ACTIVE_SLOT" != "$CANDIDATE_SLOT" ]]; then
  echo "==> Draining and stopping ${ACTIVE_SLOT}"
  docker stop -t 300 "$(slot_container "$ACTIVE_SLOT")" >/dev/null \
    || echo "WARNING: the inactive ${ACTIVE_SLOT} container could not be stopped." >&2
fi

docker image prune -f --filter "until=168h" >/dev/null 2>&1 || true

echo
echo "Deployed ${NEW_IMAGE} to ${CANDIDATE_SLOT} with no application interruption."
