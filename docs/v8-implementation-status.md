# V8 implementation and verification ledger

Updated 2026-09-06. This ledger distinguishes implemented controls from the full
[v8 programme](prospect-sync-scalability-plan-v8-systemwide.md). A passing build
does not certify the database's capacity.

## Package 1 — admission, outage handling and query-scope checks

Candidate release; production rollout pending at the time of this entry.

- Bounded interactive queue: 8 running/32 waiting per app process by default,
  2-second wait; validated configuration and abort/timer/listener cleanup.
- 202 responses count as pending, not completed searches. Bounded route labels,
  per-outcome latency buckets, admission timing and generated request IDs.
  Logs are sampled/rate-bounded. In-memory metrics still reset on process restart;
  this is **not** a persistent monitoring/alerting service.
- Search worker health has a short single-flight cache. An outage prevents new
  preparations while allowing ready, owner-scoped results to be reused. Core
  browsing health remains separate from background-feature health.
- Forward migration `20260905172042_harden_prepared_search_admission_and_timing.sql`:
  service-role-only v2 enqueue/lookup contract; previous v1 remains compatible;
  actual completion timestamp uses `clock_timestamp()`. Worker batch duration
  uses a monotonic clock. Historical timing rows are not rewritten.
- Preparation classifier counts description terms across filters and inside
  Boolean expressions. Repeated invalidation is bounded; polling is jittered.
- Main and pivot filter-set ownership checks share a bounded recursive helper
  across People, Companies, streaming/background exports and result creation.
  Filter-based mutations check ownership too; unsupported pivoted live mutations
  fail explicitly instead of silently discarding the pivot.
- Inline query budgets: 20,000 values and 1 MiB of filter JSON across main/pivot
  filters, retaining the existing 60-filter/5,000-per-filter ceilings. Limit
  breaches return 413 without silently dropping values; 100–150 keyword searches
  remain supported. A complete transport/body-size contract remains V8-02 work.
- Maintenance no longer automatically rebuilds indexes, falls back to blocking
  reindex, or resets query statistics. Explicit concurrent reindex remains an
  operator-controlled action requiring disk/bloat review.
- Load harness waits through 202 to actual results, fails ordinary-load gates on
  503, requires explicit remote-target opt-in, and supports the supplied keyword
  journey. It does not establish a multi-user/cold-arrival capacity certificate.

### Verification to date

- 429 unit/source/render tests pass (405 before this programme).
- Lint passes. Production build/type checking rerun after cumulative budgets;
  see release verification below for final outcome.
- Candidate Compose passes the server's `docker compose ... config --quiet`.
- New migration plus `scripts/check-v8-preparation.sql` passed in a short
  **rolled-back** transaction: worker-down no-enqueue, pending reuse, ready reuse,
  owner separation, public-role denials, worker table-access denial and timestamp
  definition. Only synthetic private cache rows were written, then rolled back.
- Supabase CLI advisors **not run successfully**: local database connection
  refused on port 54322. Targeted live catalogue checks do not replace advisors.
- Authenticated Codex browser access is now available; Overview loads and shows
  681,085 prospects/419,214 companies. New-release journey check still pending.
- Production preflight: prior commit `417f67c`, healthy containers, 56 GiB free.
  No stress tests, worker restarts, customer-record mutations or restore drills
  have been performed against production.

## Remaining programme — not completed by Package 1

| Package | Remaining work |
| --- | --- |
| V8-01 | Persistent journey/job telemetry, queue age/capacity/schema readiness, real peak arrival measurements and alerts. |
| V8-02 | Full versioned QuerySpec/canonical identity, transport/body budgets, typed result/count adapters and complete route inventory. Recursive ownership and cumulative inline-filter budgets are implemented, not the entire package. |
| V8-03 | Storage reservations/quotas/pins, attempt fencing and cancellation, fair batch scheduling, bounded cleanup and shared heavy-work budget. |
| V8-04 | Unified execution across both pivots, all scoped views, exports and frozen selection; complete over-cap membership path. |
| V8-05 | Dependency-version consistency, immutable snapshot inputs, resumable search evaluation and measured term-cache experiment. |
| V8-06 | Deferred exact counts, measured pagination/suggestion improvements, drift checks and safe online-index tooling. |
| V8-07 | Tier A/B mixed-load, restart/fencing tests, authenticated browser regression, isolated restore and rollback drills. |

No staging database is running locally and no separate staging destination is
confirmed. Synthetic load generation can be implemented locally, but intrusive
capacity/failure/restore experiments need a confirmed isolated target. No
production data is to be copied to an unapproved destination. Business RPO/RTO
and any required infrastructure spending remain user choices.

## Release and rollback

Run the CI quality gate, apply the backward-compatible migration, start the
compatible worker, verify candidate app/core and feature health, then switch
traffic using the existing blue/green deployment. A failed gate keeps the old
app online. Rollback keeps expanded schema and restores the previous image;
explicit rollback supports legacy health responses. Do not replay old migrations
or reset/overwrite the local working tree.

## Mobile — last

No mobile redesign is included. Validate responsive search states after the
desktop/backend correctness and capacity gates, as requested.
