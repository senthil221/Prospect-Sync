#!/usr/bin/env bash
# Create an approved user, the way this app expects them: confirmed, with a
# generated password, no self-signup involved.
#
#   ./scripts/create-user.sh owner@example.com
#   ./scripts/create-user.sh owner@example.com 'a-password-you-chose'
#
# Access is gated twice - GoTrue must have the user, AND the address must be in
# ALLOWED_USER_EMAILS. This script reminds you about the second half, because
# forgetting it produces a login that succeeds and then bounces to a 401.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

EMAIL="${1:-}"
[[ -n "$EMAIL" ]] || { echo "Usage: $0 <email> [password]" >&2; exit 1; }

PASSWORD="${2:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)}"
GENERATED=$([[ -z "${2:-}" ]] && echo yes || echo no)

# A throwaway curl container on the stack's network: GoTrue's admin API is not
# reachable from outside, and busybox wget in the other images is too limited to
# POST JSON reliably.
response="$(docker run --rm --network prospect_internal curlimages/curl:latest \
  -sS -X POST "http://auth:9999/admin/users" \
  -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
  -H "apikey: ${SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"email_confirm\":true}" 2>&1)" || {
  echo "Failed to create user:" >&2
  echo "$response" >&2
  exit 1
}

if grep -q '"id"' <<<"$response"; then
  echo "Created ${EMAIL}"
  if [[ "$GENERATED" == "yes" ]]; then
    echo
    echo "  password: ${PASSWORD}"
    echo "  (shown once - save it, then have them change it after first login)"
  fi
else
  echo "Unexpected response:" >&2
  echo "$response" >&2
  exit 1
fi

if ! grep -qi "$EMAIL" <<<"${ALLOWED_USER_EMAILS}"; then
  cat <<EOF

!! ${EMAIL} is NOT in ALLOWED_USER_EMAILS. They can sign in but every request
   will return 401 until you add them:

     ALLOWED_USER_EMAILS=${ALLOWED_USER_EMAILS},${EMAIL}

   Then: ./scripts/update.sh "$APP_IMAGE"
EOF
fi
