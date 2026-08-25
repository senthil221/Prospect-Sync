# syntax=docker/dockerfile:1.7
#
# Production image for Prospect Sync.
#
# Built in GitHub Actions, not on the VPS. `next build` wants more CPU and RAM
# than a 2 vCPU box has to spare while it is also running PostgreSQL, and a
# failed build should never be able to take the app down.

# ── deps ───────────────────────────────────────────────────────────────────
FROM node:22.13-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

# The worker has two small runtime-only dependencies. Keeping its lockfile
# separate avoids copying the complete Next.js dependency tree into the image.
FROM node:22.13-alpine AS worker-deps
WORKDIR /app/worker
COPY worker/package.json worker/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund

# ── build ──────────────────────────────────────────────────────────────────
FROM node:22.13-alpine AS builder
WORKDIR /app

# NEXT_PUBLIC_* values are inlined into the client bundle at build time, so they
# must be supplied here — setting them only at runtime leaves the browser with
# an undefined Supabase URL and a login page that cannot reach anything.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
# The git SHA this image is built from. next.config.ts's headers() runs here,
# during `next build` -- it is baked into .next/routes-manifest.json and is
# NOT re-evaluated by the standalone server at boot or per request (verified
# empirically; see the comment in next.config.ts). Setting this in the runner
# stage instead, where it looks like it should belong, has no effect: by the
# time that stage exists, the manifest is already frozen.
ARG APP_VERSION=unknown
ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL} \
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY} \
    APP_VERSION=${APP_VERSION} \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_ENV=production

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Fail loudly rather than shipping a broken bundle.
#
# A missing build-arg is an empty string, not an error, so `next build` happily
# produces an image whose login page points at undefined. That image looks
# healthy, passes its healthcheck, serves HTML — and cannot reach Supabase at
# all. Catching it here costs one line; catching it in production costs an
# afternoon.
RUN if [ -z "$NEXT_PUBLIC_SUPABASE_URL" ] || [ -z "$NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY" ]; then \
      echo "ERROR: NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY must be" >&2; \
      echo "       passed as build args. In CI they come from repository secrets of the" >&2; \
      echo "       same name — check they exist and are not empty." >&2; \
      exit 1; \
    fi

RUN npm run build

# The values must actually reach the client bundle, not just the build env.
RUN grep -rq "$NEXT_PUBLIC_SUPABASE_URL" .next/static \
    || { echo "ERROR: NEXT_PUBLIC_SUPABASE_URL is not present in the built client bundle." >&2; exit 1; }

# ── runtime ────────────────────────────────────────────────────────────────
FROM node:22.13-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001

# `output: "standalone"` emits a self-contained server plus only the node_modules
# it actually traced — a few hundred MB smaller than shipping the full tree.
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/worker ./worker
COPY --from=worker-deps --chown=nextjs:nodejs /app/worker/node_modules ./worker/node_modules

USER nextjs
EXPOSE 3000

CMD ["node", "server.js"]
