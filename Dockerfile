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

# ── build ──────────────────────────────────────────────────────────────────
FROM node:22.13-alpine AS builder
WORKDIR /app

# NEXT_PUBLIC_* values are inlined into the client bundle at build time, so they
# must be supplied here — setting them only at runtime leaves the browser with
# an undefined Supabase URL and a login page that cannot reach anything.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL} \
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=${NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY} \
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

# The git SHA this image was built from. next.config.ts reads it at request
# time to set X-App-Version, which is how the deploy pipeline's smoke test
# tells "the new container is answering" from "a container is answering" — an
# old container returns 200 on /login just as readily as a new one does.
# ARGs don't cross build stages on their own, so this is redeclared here even
# though the builder stage never needed it.
ARG APP_VERSION=unknown

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0 \
    APP_VERSION=${APP_VERSION}

RUN addgroup -g 1001 -S nodejs && adduser -S nextjs -u 1001

# `output: "standalone"` emits a self-contained server plus only the node_modules
# it actually traced — a few hundred MB smaller than shipping the full tree.
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

USER nextjs
EXPOSE 3000

CMD ["node", "server.js"]
