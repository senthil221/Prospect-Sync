# Sourced by the other scripts. Not executable on its own.
#
# `set -a; source .env; set +a` is the obvious way to load a .env file and it is
# wrong: bash parses the file as shell, so a perfectly valid Compose line like
#
#     SMTP_SENDER_NAME=Prospect Sync
#
# tries to run `Sync` as a command and the script dies with a message that says
# nothing about .env. Docker Compose accepts that line, so the file looks fine.
#
# This loader reads the file as data instead - no evaluation, no surprises from
# spaces, #, $ or quotes in a password.

load_env() {
  local file="${1:-.env}"
  local line key value

  [[ -f "$file" ]] || { echo "No ${file} found. Run: cp .env.example .env" >&2; return 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolerate CRLF from a Windows edit
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"

    # Only KEY=VALUE lines; ignore anything that is not a plain identifier.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    # Strip one layer of matching surrounding quotes, as Compose does.
    if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    export "${key}=${value}"
  done < "$file"
}
