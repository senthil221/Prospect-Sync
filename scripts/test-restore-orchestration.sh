#!/usr/bin/env bash
set -euo pipefail

source deploy/scripts/restore-orchestration.sh
SERVICES_STOPPED=0
state="running"
calls=()
legacy_running="false"
query_failure="false"

docker() {
  calls+=("$*")
  if [[ "$query_failure" == "true" && "$*" == "compose ps --status running --services" ]]; then
    return 12
  fi
  if [[ "$*" == "compose ps --status running --services" ]]; then
    if [[ "$state" == "running" ]]; then
      printf '%s\n' app-blue import-worker operations-worker caddy db
    elif [[ "$state" == "stuck" ]]; then
      printf '%s\n' operations-worker caddy db
    else
      printf '%s\n' caddy db
    fi
  elif [[ "$*" == "compose ps --status running -q" ]]; then
    printf '%s\n' container-app container-import container-ops container-caddy container-db
  elif [[ "$1 $2" == "inspect --format" ]]; then
    if [[ "$*" == *"{{if .State.Running}}"* && "$legacy_running" == "true" ]]; then printf '%s\n' legacy-id; fi
    if [[ "$*" == *"{{.State.Running}}"* ]]; then printf '%s\n' "$legacy_running"; fi
  elif [[ "$1 $2" == "compose stop" ]]; then
    [[ "$state" == "stuck" ]] || state="stopped"
  elif [[ "$1" == "stop" ]]; then
    legacy_running="false"
  elif [[ "$1" == "start" && "$state" == "restartfail" ]]; then
    return 7
  fi
}

capture_running_services
[[ " ${RUNNING_SERVICES[*]} " == *" import-worker "* ]]
[[ " ${RUNNING_SERVICES[*]} " == *" caddy "* ]]
stop_database_writers
[[ "$SERVICES_STOPPED" == "1" ]]
restart_previous_services
[[ "${calls[*]}" == *"start container-app container-import container-ops container-caddy container-db"* ]]

state="stuck"
if stop_database_writers 2>/dev/null; then
  echo "writer shutdown fixture did not fail closed" >&2
  exit 1
fi

state="running"
legacy_running="true"
capture_running_services
stop_database_writers
[[ "${calls[*]}" == *"stop legacy-id"* ]]

state="queryfail"
query_failure="true"
if capture_running_services; then
  echo "running-service discovery failure was swallowed" >&2
  exit 1
fi
query_failure="false"

RUNNING_CONTAINER_IDS=(container-app container-import)
state="restartfail"
if restart_previous_services_fail_closed; then
  echo "partial service restart failure was swallowed" >&2
  exit 1
fi
[[ "$state" == "stopped" ]]

printf 'PASS: writer shutdown is checked and exact prior services are restored\n'
