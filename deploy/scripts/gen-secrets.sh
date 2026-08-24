#!/usr/bin/env bash
# Fill every empty secret in .env. Existing values are left alone, so this is
# safe to re-run after adding a new optional service.
#
#   ./scripts/gen-secrets.sh
#
# Rotating a secret later means clearing that line in .env and re-running this.
# Read the rotation notes in deploy/README.md first — rotating JWT_SECRET
# invalidates ANON_KEY and SERVICE_ROLE_KEY together, and both must be
# redeployed to the app at the same time.
set -euo pipefail

cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "No .env found. Run: cp .env.example .env" >&2; exit 1; }

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# HS256 JWT with a 10 year life, matching how Supabase issues its own long-lived
# anon and service_role keys.
mint_jwt() {
  local role="$1" secret="$2" iat exp header payload h p sig
  iat=$(date +%s)
  exp=$((iat + 10 * 365 * 24 * 3600))
  header='{"alg":"HS256","typ":"JWT"}'
  payload="{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}"
  h=$(printf '%s' "$header" | b64url)
  p=$(printf '%s' "$payload" | b64url)
  sig=$(printf '%s' "${h}.${p}" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)
  printf '%s.%s.%s' "$h" "$p" "$sig"
}

current() { grep -E "^${1}=" .env | head -1 | cut -d= -f2- ; }

# Write KEY=VALUE without letting sed choke on / + = in generated secrets.
put() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" -F= '
    $1 == k { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' .env > "$tmp"
  mv "$tmp" .env
}

set_if_empty() {
  local key="$1" value="$2"
  if [[ -z "$(current "$key")" ]]; then
    put "$key" "$value"
    echo "  generated  $key"
  else
    echo "  kept       $key"
  fi
}

echo "Generating secrets in $(pwd)/.env"

# Alphanumeric only: this password ends up inside libpq connection URIs in a
# dozen services, and punctuation there causes parsing bugs that surface days
# later as a service that silently will not reconnect.
set_if_empty POSTGRES_PASSWORD "$(openssl rand -hex 24)"
set_if_empty JWT_SECRET "$(openssl rand -hex 32)"
set_if_empty REALTIME_ENC_KEY "$(openssl rand -hex 8)"
set_if_empty REALTIME_SECRET_KEY_BASE "$(openssl rand -hex 32)"

JWT_SECRET_VALUE="$(current JWT_SECRET)"
set_if_empty ANON_KEY "$(mint_jwt anon "$JWT_SECRET_VALUE")"
set_if_empty SERVICE_ROLE_KEY "$(mint_jwt service_role "$JWT_SECRET_VALUE")"

if [[ -z "$(current STUDIO_BASIC_AUTH_HASH)" ]]; then
  STUDIO_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  CADDY_TAG="$(current CADDY_IMAGE_TAG)"
  HASH="$(docker run --rm "caddy:${CADDY_TAG:-2-alpine}" caddy hash-password --plaintext "$STUDIO_PW")"
  put STUDIO_BASIC_AUTH_HASH "$HASH"
  echo "  generated  STUDIO_BASIC_AUTH_HASH"
  echo
  echo "  ┌──────────────────────────────────────────────────────────────┐"
  echo "  │ Studio login — save this in your password manager NOW.       │"
  echo "  │ It is hashed in .env and cannot be recovered.                 │"
  echo "  ├──────────────────────────────────────────────────────────────┤"
  printf  "  │ user: %-54s │\n" "$(current STUDIO_BASIC_AUTH_USER)"
  printf  "  │ pass: %-54s │\n" "$STUDIO_PW"
  echo "  └──────────────────────────────────────────────────────────────┘"
else
  echo "  kept       STUDIO_BASIC_AUTH_HASH"
fi

chmod 600 .env

echo
echo "Done. Next:"
echo "  1. Set APP_DOMAIN / API_DOMAIN / STUDIO_DOMAIN / ACME_EMAIL in .env"
echo "  2. Set ALLOWED_USER_EMAILS in .env"
echo "  3. ./scripts/check-images.sh"
echo
echo "Values your GitHub Actions deploy needs as repository secrets:"
echo "  NEXT_PUBLIC_SUPABASE_URL             = $(current SUPABASE_PUBLIC_URL)"
echo "  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = $(current ANON_KEY)"
