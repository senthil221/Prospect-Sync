# Self-hosting Prospect Sync

Everything needed to run Prospect Sync and its Supabase backend on a single
Hostinger KVM 2 VPS: PostgreSQL, GoTrue auth, PostgREST, Studio, the Next.js
app, TLS, backups, and a one-command deploy.

---

## Architecture

```
                         Internet
                            │
                     ┌──────┴──────┐
                     │    Caddy    │  :80 :443 — automatic TLS
                     └──────┬──────┘
          ┌─────────────────┼─────────────────────┐
          │                 │                     │
   app.<domain>       api.<domain>         studio.<domain>
          │                 │                     │
    ┌─────┴─────┐    ┌──────┴───────┐      ┌──────┴──────┐
    │ app-router│    │ /auth/v1 → GoTrue   │   Studio    │  basic auth
    │ blue/green│    │   public            │  + meta     │  CIDR + basic auth
    └─────┬─────┘    │ /rest/v1 → PostgREST└──────┬──────┘
    ┌─────┴─────┐    │   private IPs only        │
    │  Next.js  │    └──────┬───────┘            │
    │ active slot│          │                    │
    └─────┬─────┘           │                    │
          └─────────────────┼────────────────────┘
                     ┌──────┴──────┐
                     │ PostgreSQL  │  ← the only thing that matters
                     └─────────────┘
```

### Why this shape

**Kong is gone.** Supabase's reference stack puts Kong in front of everything as
an API gateway. Caddy already terminates TLS and routes by hostname, so Kong
would be a second gateway with a second config file doing a subset of the same
job. Its `key-auth` plugin is not load-bearing here — PostgREST and GoTrue each
validate the JWT themselves. One fewer service, ~200 MB back.

**Analytics (Logflare) and Vector are gone.** They are the heaviest part of the
reference stack, the most common cause of a self-hosted stack that will not
start, and they exist to power Studio's Logs tab. `docker compose logs` and the
Caddy JSON access logs cover the same ground on a box this size.

**Storage, Realtime, and Edge Functions are defined but off.** The app doesn't
use them today — verified: the browser only ever calls Supabase to sign in, and
all 28 API routes go through PostgREST with the service-role key. They're one
env var away when you need them. See [Adding capabilities](#adding-capabilities).

That leaves roughly 4 GB in use on an 8 GB box, so PostgreSQL gets a real page
cache instead of competing with services you aren't using.

---

## Why the API is safe

Worth understanding before you change anything, because it is unusually strong
and easy to break by accident.

Every table in `supabase/migrations` has RLS enabled. **Not one policy exists,
and nothing is granted to `anon` or `authenticated`** — the migrations
explicitly `revoke` from them and grant only to `service_role`. So:

- The anon key in the browser bundle can do exactly one thing: sign in.
- The service-role key never leaves the server container.
- All data access happens in Next.js route handlers, after `authorizeApi()`
  checks both the GoTrue session and `ALLOWED_USER_EMAILS`.

On top of that, Caddy serves `/rest/v1/*` only to private and tailnet source
addresses. Two independent locks.

**If you ever want the Data API reachable directly** — an MCP server, a partner
integration, a mobile client — you must write real RLS policies first. Removing
the Caddy IP restriction without them exposes every table to anyone holding the
anon key, which is a public value baked into your JavaScript.

---

## Sizing

Hostinger KVM 2 is 2 vCPU / 8 GB RAM / 100 GB NVMe. Steady-state allocation:

| Component | RAM | Notes |
|---|---|---|
| PostgreSQL | ~2.5 GB | `shared_buffers=2GB` |
| Next.js app | ~0.5 GB | capped at 1.5 GB |
| Studio | ~0.3 GB | idle unless open |
| GoTrue + PostgREST + meta | ~0.25 GB | |
| Caddy + app router | ~0.06 GB | graceful blue/green cutovers |
| **Free for page cache** | **~4 GB** | this is what keeps queries fast |

Plus a 4 GB swapfile so a large import spike degrades instead of triggering the
OOM killer mid-write.

**Disk is your real ceiling, not RAM.** `list_rows` keeps every source row and
`all_data` keeps every uploaded field as JSONB, so figure roughly 3–5 KB per
prospect once indexes are counted. 100 GB comfortably holds several million
prospects — but keep 30–40% free, because PostgreSQL needs headroom to VACUUM
and to rewrite indexes. `scripts/maintenance.sh` warns you past 75%.

---

## First deploy

### 1. DNS

Three A records at your registrar, all pointing at the VPS IPv4:

```
app.clearroadco.link      → <vps-ip>
api.clearroadco.link      → <vps-ip>
studio.clearroadco.link   → <vps-ip>
```

Wait for propagation before step 4 — Caddy asks Let's Encrypt for certificates
on first boot, and repeated failures will rate-limit you for a week. If you want
to be careful, uncomment `acme_ca` (staging) in `caddy/Caddyfile` for the first
run.

### 2. Provision the VPS

Create the KVM 2 instance with **Ubuntu 24.04 LTS**, plain — not a Hostinger
one-click app template. Then, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/senthil221/Prospect-Sync/main/deploy/scripts/bootstrap-vps.sh -o bootstrap.sh && bash bootstrap.sh 'ssh-ed25519 AAAA... you@laptop'
```

This creates a `deploy` user, locks SSH to keys only, configures ufw and
fail2ban, adds swap, disables transparent hugepages, installs Docker, and caps
container log growth.

### 3. Configure

```bash
ssh deploy@<vps-ip>
git clone https://github.com/senthil221/Prospect-Sync.git /opt/prospect
cd /opt/prospect/deploy
cp .env.example .env
nano .env          # domains, ACME_EMAIL, ALLOWED_USER_EMAILS
./scripts/gen-secrets.sh
./scripts/check-images.sh
```

`gen-secrets.sh` mints the JWT secret plus matching anon and service-role keys,
the database password, and a Studio login. **The Studio password is printed
once.** Save it immediately.

Studio is denied before its password prompt unless the caller is in
`STUDIO_ALLOWED_CIDRS`. The default permits Tailscale (`100.64.0.0/10`) and
loopback only. Prefer private DNS that resolves `studio.<domain>` to the VPS's
Tailscale address. If that is not available, add only your fixed public IP as a
`/32`; never set `0.0.0.0/0`.

`check-images.sh` matters: the image tags in `.env.example` were current when it
was written, and container tags get superseded. If any fail, copy the current
pins from
[supabase/docker/docker-compose.yml](https://github.com/supabase/supabase/blob/master/docker/docker-compose.yml).

### 4. Start

```bash
docker compose up -d
docker compose ps
```

This starts the database, Supabase services, Studio, and Caddy. The application
uses profiled blue/green slots and starts with the first GitHub deployment; this
avoids running two app containers during ordinary operation.

Give Caddy a minute to get certificates, then confirm:

```bash
curl -I https://api.clearroadco.link/auth/v1/health
```

### 5. Load the schema

**Coming from your hosted project** — this copies the data too:

```bash
./scripts/import-from-hosted.sh 'postgresql://postgres.<ref>:<pw>@aws-0-<region>.pooler.supabase.com:5432/postgres'
```

Use the **session pooler** connection string from Project Settings → Database.
The direct connection is IPv6-only on the free tier and will hang.

**Starting fresh:**

```bash
./scripts/migrate.sh
```

### 6. Create users

Auth users do not transfer — GoTrue's tables belong to whatever version wrote
them, and forcing one version's schema onto another breaks login in ways that
are miserable to debug. You have two users; recreate them:

```bash
./scripts/create-user.sh owner@clearroadco.link
./scripts/create-user.sh boss@clearroadco.link
```

Both addresses must also appear in `ALLOWED_USER_EMAILS`.

### 7. Build and deploy the app

Add these GitHub repository secrets (Settings → Secrets and variables →
Actions):

| Secret | Value |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://api.clearroadco.link` |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | `ANON_KEY` from `.env` |
| `APP_PUBLIC_URL` | `https://app.clearroadco.link` |
| `VPS_HOST` | VPS IPv4 |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | private key whose public half you passed to bootstrap |
| `VPS_SSH_HOST_KEY` | output of `ssh-keyscan <vps-ip>` — **run this yourself, from a trusted network, and paste the result** |

The VPS needs to pull from GHCR once:

```bash
echo <github-pat-with-read:packages> | docker login ghcr.io -u senthil221 --password-stdin
```

Then push to `main`. CI runs lint, build, tests, and the migration guard; the
image builds; the deploy applies pending migrations and starts the inactive
blue/green slot. Readiness checks Next.js, Auth, PostgREST, and PostgreSQL before
Caddy atomically sends new traffic to that slot. The previous slot stays online
until the public version check passes, so a failed rollout keeps serving the
known-good application. SSH transport is retried without starting concurrent
deployments.

### 8. Turn on backups

```bash
sudo ./scripts/install-timers.sh
sudo systemctl start prospect-backup.service
journalctl -u prospect-backup.service -n 50 --no-pager
```

Set `RESTIC_REPOSITORY` in `.env` first. A backup sitting on the same VPS as the
database is not a backup — one Hostinger incident loses both. Cloudflare R2 has
no egress fees and costs cents a month at this size.

---

## Day-to-day

| Task | Command |
|---|---|
| Deploy | push to `main` |
| Deploy by hand | `./scripts/update.sh` |
| Roll back the app | `./scripts/update.sh --rollback` |
| Apply migrations | `./scripts/migrate.sh` (`--dry-run` first) |
| Add a user | `./scripts/create-user.sh <email>` |
| Back up now | `./scripts/backup.sh` |
| **Restore drill** | `./scripts/restore.sh --verify-only` |
| Real restore | `./scripts/restore.sh --into-production <dir>` |
| Health / capacity | `./scripts/status.sh` and `./scripts/maintenance.sh` |
| Logs | `prospect logs app` |
| SQL shell | `docker compose exec db psql -U postgres` |

### The monthly ten minutes

1. `./scripts/restore.sh --verify-only` — restores the latest backup into a
   scratch database and counts rows. Production is untouched. **Do this.** An
   untested backup is a hypothesis.
2. `./scripts/maintenance.sh` — read the disk line and the slow-query list.
3. `sudo apt update && sudo apt list --upgradable` — security patches apply
   automatically, but kernel updates need a reboot you choose.

### The quarterly thirty minutes

Bump the Supabase image tags in `.env` against upstream, then:

```bash
./scripts/backup.sh && ./scripts/check-images.sh && docker compose up -d
```

Upgrade the whole stack together. Mixing a new GoTrue against an old PostgreSQL
image is how you get auth schema drift.

**The PostgreSQL image is the exception.** Bumping its major version is a
dump-and-restore, not a container swap. Read Supabase's upgrade notes, take a
backup, and set aside a real window.

---

## Adding capabilities

Edit `COMPOSE_PROFILES` in `.env`, then `docker compose up -d`.

**File storage** (`storage`) — adds storage-api + imgproxy, ~200 MB. Files land
on the VPS disk, so they compete with the database for those 100 GB. If uploads
become significant, point `STORAGE_BACKEND=s3` at R2 instead.

**Realtime** (`realtime`) — ~300 MB. Only useful once you want live-updating
tables across sessions.

**Edge Functions** (`functions`) — ~150 MB. Put function source in
`deploy/functions/`. Honestly: you already have Next.js route handlers on the
same box. Reach for those first.

### For the API and MCP work you're planning

Two things to do before exposing anything:

1. **Write RLS policies.** The current model — RLS on, no policies, service-role
   only — is airtight precisely because nothing else can reach the data. An MCP
   server or partner API means a second consumer, and the safe way to give it
   access is policies plus its own role, not a shared service-role key.
2. **Give it its own schema.** Add `api` to `PGRST_DB_SCHEMAS` and expose only
   deliberately-written views and functions there. Never expose `public`
   directly — those tables are your internal shape and will change.

A dedicated PostgREST role with a scoped JWT, restricted to an `api` schema, is
a much smaller thing to reason about than opening up what you have now.

---

## Troubleshooting

**Caddy will not get a certificate.** DNS has not propagated, or ports 80/443
are blocked. `dig +short app.clearroadco.link` and `sudo ufw status`.
`docker compose logs caddy` names the actual ACME error.

**Auth works, but every API call 401s.** The email is not in
`ALLOWED_USER_EMAILS`, or the active app slot did not pick up a change to it.
Run `./scripts/update.sh "$APP_IMAGE"` to roll the configuration through the
inactive slot without interrupting traffic.

**Login page loads but sign-in hangs.** The browser cannot reach
`api.<domain>/auth/v1/*`. Check the browser console for a CSP violation — the
CSP's `connect-src` is derived from `NEXT_PUBLIC_SUPABASE_URL`, which is baked
into the image at build time. If you changed the domain, rebuild.

**Server-side Supabase calls feel slow.** The Caddy container carries a network
alias for `API_DOMAIN`, so containers resolve the API hostname to Caddy on the
Docker bridge instead of going out to the public internet. If Docker's resolver
does not pick the alias up, requests hairpin out to your own public IP and back
— still correct, just an extra round trip. Confirm with:

```bash
docker exec "$(docker ps --filter 'name=prospect-app-' --format '{{.Names}}' | head -1)" \
  node -e "require('dns').lookup('api.clearroadco.link',console.log)"
```

A `172.x` address is the alias working; your public IP means it is hairpinning.

**A service cannot connect to the database.** Role passwords are set by the
init script, which runs only on an empty data directory. Re-apply by hand:

```bash
docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh
```

**Imports got slow.** `./scripts/maintenance.sh` — look for a high `dead_pct` on
`prospect_index` or `list_rows`, and check whether the disk crossed 75%.

**Something is exposed that should not be.** From a machine that is *not* the
VPS: `curl -I https://api.clearroadco.link/rest/v1/prospects` must return 403.
`sudo ss -tlnp` on the VPS should show only 22, 80, and 443 on 0.0.0.0.

---

## When to move off one box

Watch for: sustained load average above 2, PostgreSQL cache hit ratio under 95%,
or disk past 70%.

The first move is a bigger KVM plan — same stack, more headroom, no
architectural change. The second is splitting PostgreSQL onto its own instance.
Both are far off; a single tuned box handles this workload for a long time.
