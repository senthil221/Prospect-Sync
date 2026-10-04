#!/usr/bin/env bash

QUIESCE_SERVICES=(app-blue app-green rest auth studio meta storage realtime functions import-worker operations-worker integration-worker verification-worker icp-worker)
RUNNING_SERVICES=()
RUNNING_CONTAINER_IDS=()
RUNNING_LEGACY_ID=""

capture_running_services() {
  RUNNING_SERVICES=()
  RUNNING_CONTAINER_IDS=()
  RUNNING_LEGACY_ID=""
  local service_output container_output legacy_id service container_id
  service_output="$(docker compose ps --status running --services)" || return 1
  container_output="$(docker compose ps --status running -q)" || return 1
  while IFS= read -r service; do
    [[ -n "$service" ]] && RUNNING_SERVICES+=("$service")
  done <<<"$service_output"
  while IFS= read -r container_id; do
    [[ -n "$container_id" ]] && RUNNING_CONTAINER_IDS+=("$container_id")
  done <<<"$container_output"
  # Kept for installations from before blue/green Compose slots. It is not a
  # dependency and is restarted only if it was actually running.
  legacy_id="$(docker inspect --format '{{if .State.Running}}{{.Id}}{{end}}' prospect-app 2>/dev/null || true)"
  if [[ -n "$legacy_id" ]]; then
    RUNNING_LEGACY_ID="$legacy_id"
    RUNNING_CONTAINER_IDS+=("$legacy_id")
  fi
}

restart_previous_services() {
  (( ${#RUNNING_CONTAINER_IDS[@]} == 0 )) || docker start "${RUNNING_CONTAINER_IDS[@]}" >/dev/null
}

# A failed multi-container start can have started only a prefix. Put every
# database writer back down before returning failure; callers must never assume
# a non-zero `docker start` means no container started.
restart_previous_services_fail_closed() {
  if restart_previous_services; then
    return 0
  fi
  if ! stop_database_writers; then
    return 2
  fi
  return 1
}

stop_database_writers() {
  SERVICES_STOPPED=1
  docker compose stop "${QUIESCE_SERVICES[@]}" || return 1
  if [[ -n "$RUNNING_LEGACY_ID" ]]; then docker stop "$RUNNING_LEGACY_ID" >/dev/null || return 1; fi
  local still_running service
  still_running="$(docker compose ps --status running --services)" || return 1
  for service in "${QUIESCE_SERVICES[@]}"; do
    if grep -Fxq "$service" <<<"$still_running"; then
      echo "Refusing restore: ${service} is still running." >&2
      return 1
    fi
  done
  if [[ -n "$RUNNING_LEGACY_ID" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$RUNNING_LEGACY_ID" 2>/dev/null || echo unknown)" != "false" ]]; then
    echo "Refusing restore: legacy application writer is still running." >&2
    return 1
  fi
}
