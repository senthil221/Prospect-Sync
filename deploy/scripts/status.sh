#!/usr/bin/env bash
# One screen that answers "is everything OK?".
#
#   ./scripts/status.sh          or, from anywhere:  prospect status
#
# Checks the public URLs rather than the containers alone: a container can be
# happily Up while Caddy, DNS or the certificate in front of it is broken, and
# the only view that matters is the one your team actually gets.
set -uo pipefail   # deliberately no -e: a failed probe should be reported, not fatal

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'
  OK=$'\e[32m'; WARN=$'\e[33m'; BAD=$'\e[31m'
else
  B=""; DIM=""; R=""; OK=""; WARN=""; BAD=""
fi

WARNINGS=()
warn() { WARNINGS+=("$1"); }

head() { printf '\n%s%s%s\n' "$B" "$1" "$R"; }
row()  { printf '  %-22s %s\n' "$1" "$2"; }

printf '%s┌ Prospect Sync ─ %s ─ %s%s\n' "$B" "$(hostname)" "$(date -u '+%Y-%m-%d %H:%M UTC')" "$R"
printf '%s└ up %s%s\n' "$DIM" "$(uptime -p | sed 's/^up //')" "$R"

# ── Services ───────────────────────────────────────────────────────────────
head "SERVICES"
while IFS='|' read -r svc state; do
  [[ -z "$svc" ]] && continue
  case "$state" in
    *"(healthy)"*)    row "$svc" "${OK}● ${state}${R}" ;;
    *"(unhealthy)"*)
      # Studio's own healthcheck probes the analytics service we deliberately
      # do not run. Its unhealthy flag is expected and means nothing.
      if [[ "$svc" == "studio" ]]; then
        row "$svc" "${OK}● Up${R} ${DIM}(reports unhealthy — expected)${R}"
      else
        row "$svc" "${WARN}● ${state}${R}"; warn "$svc reports unhealthy"
      fi ;;
    Up*)              row "$svc" "${OK}● ${state}${R}" ;;
    *Restarting*)     row "$svc" "${BAD}● ${state}${R}"; warn "$svc is restart-looping — check: prospect logs $svc" ;;
    *)                row "$svc" "${BAD}● ${state:-not running}${R}"; warn "$svc is not running" ;;
  esac
done < <(docker compose ps --format '{{.Service}}|{{.Status}}' 2>/dev/null | sort)

# ── Public endpoints ───────────────────────────────────────────────────────
head "PUBLIC URLS"
probe() {
  local label="$1" url="$2" want="$3"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 12 "$url" 2>/dev/null || echo 000)
  if [[ ",$want," == *",$code,"* ]]; then
    row "$label" "${OK}${code}${R} ${DIM}${url}${R}"
  else
    row "$label" "${BAD}${code}${R} ${DIM}${url} (expected ${want})${R}"
    warn "$label returned $code, expected $want"
  fi
}
probe "app + data" "https://${APP_DOMAIN}/api/health"     "200"
probe "api (auth)" "https://${API_DOMAIN}/auth/v1/health" "200"
probe "studio gate" "https://${STUDIO_DOMAIN}/"           "401,403"
probe "api (data)" "https://${API_DOMAIN}/rest/v1/"       "403"
printf '  %s403 on the data API is correct — it means the internet cannot reach it.%s\n' "$DIM" "$R"

# ── Certificates ───────────────────────────────────────────────────────────
head "CERTIFICATE"
expiry=$(echo | openssl s_client -servername "${APP_DOMAIN}" -connect "${APP_DOMAIN}:443" 2>/dev/null \
         | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [[ -n "$expiry" ]]; then
  days=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
  if   (( days < 10 )); then row "expires in" "${BAD}${days} days${R}"; warn "certificate expires in ${days} days and has not renewed"
  elif (( days < 21 )); then row "expires in" "${WARN}${days} days${R}"
  else                       row "expires in" "${OK}${days} days${R} ${DIM}(renews automatically at 30)${R}"
  fi
else
  row "expires in" "${WARN}could not read${R}"
fi

# ── Application ────────────────────────────────────────────────────────────
head "DEPLOYED VERSION"
row "image" "${APP_IMAGE##*/}"
if [[ -f .last-image ]]; then
  row "rollback to" "${DIM}$(sed 's|.*/||' .last-image)${R}"
else
  row "rollback to" "${DIM}nothing yet — armed after your next deploy${R}"
fi
row "repo commit" "$(git -C .. log --oneline -1 2>/dev/null || echo unknown)"

# ── Database ───────────────────────────────────────────────────────────────
head "DATABASE"
q() { docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
        psql -tAq -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 -c "$1" </dev/null 2>/dev/null; }

if size=$(q "select pg_size_pretty(pg_database_size(current_database()));") && [[ -n "$size" ]]; then
  row "size" "$size"
  row "migrations" "$(q "select count(*) from supabase_migrations.schema_migrations;") applied"
  row "connections" "$(q "select count(*)||' of '||current_setting('max_connections') from pg_stat_activity;")"
  row "users" "$(q "select count(*) from auth.users;") can log in"
  printf '\n  %sRows%s\n' "$DIM" "$R"
  q "select '    '||rpad(relname,16)||to_char(n_live_tup,'FM999,999,999')
     from pg_stat_user_tables
     where relname in ('clients','companies','prospects','lists','list_rows','imports')
     order by relname;"
else
  row "status" "${BAD}cannot query${R}"; warn "database is not answering queries"
fi

# ── Backups ────────────────────────────────────────────────────────────────
head "BACKUPS"
last=$(find /var/backups/prospect -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)
if [[ -n "$last" ]]; then
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$last") ) / 3600 ))
  if (( age_h > 30 )); then
    row "most recent" "${WARN}${age_h}h ago${R} ${DIM}$(basename "$last")${R}"
    warn "last backup was ${age_h}h ago — the nightly timer may not be running"
  else
    row "most recent" "${OK}${age_h}h ago${R} ${DIM}($(du -sh "$last" 2>/dev/null | cut -f1))${R}"
  fi
  row "kept locally" "$(find /var/backups/prospect -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)"
else
  row "most recent" "${WARN}none yet${R}"
  warn "no backup has run yet"
fi

if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
  row "off-server" "${OK}${RESTIC_REPOSITORY}${R}"
else
  row "off-server" "${BAD}not configured${R}"
  warn "backups exist only on this server — a hardware failure loses the database and its backups together"
fi
row "next run" "$(systemctl list-timers prospect-backup.timer --no-pager 2>/dev/null | awk 'NR==2{print $1" "$2" "$3}' || echo unknown)"

# ── Machine ────────────────────────────────────────────────────────────────
head "MACHINE"
row "memory" "$(free -h | awk '/^Mem:/{print $3" used of "$2", "$6" cache"}')"
row "load" "$(uptime | sed 's/.*load average: //')  ${DIM}(2 cores)${R}"

disk_pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
disk_txt=$(df -h / | awk 'NR==2{print $3" of "$2" ("$5"), "$4" free"}')
if   (( disk_pct > 85 )); then row "disk" "${BAD}${disk_txt}${R}"; warn "disk is ${disk_pct}% full — PostgreSQL needs free space to reclaim its own"
elif (( disk_pct > 75 )); then row "disk" "${WARN}${disk_txt}${R}"; warn "disk is ${disk_pct}% full"
else                           row "disk" "${OK}${disk_txt}${R}"
fi

if [[ -f /var/run/reboot-required ]]; then
  row "reboot" "${WARN}pending${R} ${DIM}(kernel update — reboot when convenient)${R}"
fi

# ── Verdict ────────────────────────────────────────────────────────────────
echo
if (( ${#WARNINGS[@]} == 0 )); then
  printf '%s  ✓  Everything is healthy.%s\n\n' "$OK$B" "$R"
else
  printf '%s  %d thing(s) need attention:%s\n' "$WARN$B" "${#WARNINGS[@]}" "$R"
  for w in "${WARNINGS[@]}"; do printf '     %s•%s %s\n' "$WARN" "$R" "$w"; done
  printf '\n     %sMost problems: prospect logs <service>%s\n\n' "$DIM" "$R"
fi
