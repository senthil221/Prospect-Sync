#!/usr/bin/env bash
# Verify every pinned image tag in .env actually resolves before you try to
# deploy. Image tags move and get yanked; finding that out during `up -d` on a
# box that is already serving traffic is the wrong time.
#
#   ./scripts/check-images.sh
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

images=(
  "supabase/postgres:${POSTGRES_IMAGE_TAG}"
  "supabase/gotrue:${GOTRUE_IMAGE_TAG}"
  "postgrest/postgrest:${POSTGREST_IMAGE_TAG}"
  "supabase/postgres-meta:${POSTGRES_META_IMAGE_TAG}"
  "supabase/studio:${STUDIO_IMAGE_TAG}"
  "caddy:${CADDY_IMAGE_TAG}"
  "supabase/storage-api:${STORAGE_IMAGE_TAG}"
  "darthsim/imgproxy:${IMGPROXY_IMAGE_TAG}"
  "supabase/realtime:${REALTIME_IMAGE_TAG}"
  "supabase/edge-runtime:${EDGE_RUNTIME_IMAGE_TAG}"
)

failed=0
for image in "${images[@]}"; do
  if docker manifest inspect "$image" >/dev/null 2>&1; then
    printf '  ok      %s\n' "$image"
  else
    printf '  MISSING %s\n' "$image"
    failed=1
  fi
done

echo
if (( failed )); then
  cat <<'EOF'
One or more tags do not exist. Find the current pins here:
  https://github.com/supabase/supabase/blob/master/docker/docker-compose.yml
  https://hub.docker.com/r/supabase/postgres/tags

Copy the tag Supabase currently ships and update .env. Keep the whole stack on
one upstream release wave — mixing a new gotrue with an old postgres image is
how you get auth schema drift.
EOF
  exit 1
fi
echo "All image tags resolve."
