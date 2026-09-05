# V8 implementation and verification ledger

Updated 2026-09-06. This ledger distinguishes implemented controls from the full
[v8 programme](prospect-sync-scalability-plan-v8-systemwide.md). A passing build
does not certify the database's capacity.

## Package 1 — admission, outage handling and query-scope checks

Released to production as `48eee2d`, followed by backup pipeline fix `bb090e4`.
Both CI and deployment workflows succeeded. Public health reports `bb090e4`
with core checks and prepared-search/background-operation feature checks healthy.

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
  completed successfully. Commit `48eee2d` pushed through the gated deployment.
- Candidate Compose passes the server's `docker compose ... config --quiet`.
- New migration plus `scripts/check-v8-preparation.sql` passed in a short
  **rolled-back** transaction: worker-down no-enqueue, pending reuse, ready reuse,
  owner separation, public-role denials, worker table-access denial and timestamp
  definition. Only synthetic private cache rows were written, then rolled back.
- Supabase CLI advisors **not run successfully**: local database connection
  refused on port 54322. Targeted live catalogue checks do not replace advisors.
- Authenticated browser regression passed for the supplied 51 company keywords
  with name, keywords and description enabled: 41,057 matching companies,
  19,804 covered companies and 81,477 linked prospects. "See these people"
  returned the same 81,477 prospects; page two showed records 51–100 with the
  count and company scope retained. This is one real journey, not a concurrency
  or 100–150-keyword capacity certificate.
- The newly built company set completed in 25.329 seconds according to the
  corrected database timestamps. Historical millisecond durations remain invalid
  measurements and must not be used for before/after performance claims.
- Migration `20260905172042` was verified applied in production.
- The Companies URL dropped the long inline `cf` parameter while retaining the
  active in-memory filters. Long-filter reload/share persistence remains a
  separate QuerySpec/URL-state regression to address; the People pivot retained
  its scope in the URL during the tested journey.
- Production preflight: prior commit `417f67c`, healthy containers, 56 GiB free.
  No stress tests, worker restarts, customer-record mutations or restore drills
  have been performed against production.

## Package 2 — request transport and atomic background rounds

Released as `6219fda`. CI, including the isolated PostgreSQL contract, and the
production deployment succeeded. Public health reports this exact version with
core and background-feature checks healthy.

- Large filters and both pivot scopes use a versioned browser fragment when
  they exceed the small HTTP query budget. Refresh and Back/Forward restore
  the complete narrowing. Controllers mount after fragment hydration so no
  unfiltered first request runs. Small existing URLs remain compatible.
- Eight query/filter-set/export/client-mutation route files use a streamed
  body reader: 4 MiB actual UTF-8 bytes, 64 levels and a 5-second read deadline.
  Missing/false Content-Length cannot bypass the byte limit; overflow returns
  413 instead of parsing a partial payload. Import chunk budgets are unchanged.
- Interactive and operations-worker numeric configuration now fails startup
  on invalid settings instead of quietly choosing a different policy.
- Search, mutation and export receive one resumable unit each per round.
  `run_queue_unit_v1` claims, performs one batch, checkpoints and releases inside
  one SQL transaction. Row locks cover the whole unit; no job ID is retained
  for a later client-side failure write. Failed units roll back their effects
  before recording failure, retaining prior committed checkpoints.
- A transaction-scoped permit limits new operations-worker processes to one
  heavy unit. This does not include the import worker or legacy rollback worker.
  The description build remains atomic and can occupy its full bounded deadline;
  the proposed 1–3-second quanta and fairness latency SLO are not yet certified.
- Added isolated PostgreSQL CI contract fixtures for all three classes. These
  use synthetic builders to exercise checkpoint/resume/failure semantics, not
  production data or a replacement for real-builder integration/load tests.
- Migration creation and grants passed a rolled-back live catalogue check; no
  customer job was run during that check. Local lint/build passed, with 443 tests
  passing and one Linux-only skip. SQL CI passed all three class checkpoint,
  resume, completion and failed-effect-rollback assertions.
- Authenticated browser restored the supplied 51 company keywords from the
  fragment, showing 41,057 matching companies and 81,477 linked prospects.
- A fresh real-worker 51-term build completed in 9.160 seconds by the monotonic
  worker clock (9.158 seconds in corrected database timestamps). The complete
  sorted-ID digest matched the prior 41,057-company set. Different cache/load
  conditions mean this is not a controlled speedup comparison or percentile.
- "See these people" returned 81,477 prospects on the deployed release.

### Follow-up — bounded browser caches and explicit request refusals

Released as `800548d`. CI and production deployment succeeded. Public health
verified the exact full SHA with all core/background checks healthy. Reloading
the large-filter People pivot retained 81,477 matches and page two (51–100).

- Count caches have 40-entry/1-MiB serialized-key-and-value budgets; general API
  responses have 64-entry/8-MiB budgets. These are admission estimates, not exact
  heap measurements. Over-budget responses are served without being cached.
- Cache invalidation advances a generation. Older in-flight reads cannot
  repopulate an invalidated cache or remove a newer request's deduplication entry.
- Aborting a backpressure wait clears its timer and prevents the retry.
- Fragment-only navigation is observed; duplicate popstate/hashchange events
  are deduplicated. Skip-to-content focuses the main landmark without replacing
  the fragment containing the active filters.
- Oversized explicit selections/exclusions return 413 before legacy adapters
  can slice them. The legacy tag/contact action explicitly enforces its 5,000-ID
  limit. Import-chunk handling is unchanged.
- New result-set/export POST requests fail closed when the operations worker
  is unavailable. Existing job status/download GET paths remain independent.
  A POST retry to look up a completed job can also be refused during the outage;
  callers should use its existing job ID to read status/download.
- Local lint, build/type checking and 448 tests pass, with one Linux-only skip.

### Follow-up — fail-closed filter restoration and Boolean source preservation

Released as `7bb99f6`; exact-version public health and the authenticated browser
were verified. A malformed link showed the recovery screen; restoring the valid
People pivot again returned 81,477 matches and page two (51–100).

- Malformed filter objects, field identities/operators, stored-set references,
  mixed inline/set inputs, multiple Boolean expressions, invalid numeric ranges
  and unsupported company keyword scopes now reject the whole request (400).
  A malformed predicate must not be silently dropped from a read or mutation.
  Valid empty draft rows remain no-ops; custom-field catalogue validation and
  full versioned QuerySpec semantics are still separate work.
- Invalid filter/scope URLs block query controllers, prefetch and URL rewriting.
  The original link remains intact and a deliberate reset link is offered.
  Direct set-ID editable-filter links are explicitly unsupported rather than
  losing their restriction. Normal UI links continue carrying inline values.
- URL restoration validates Boolean expressions but retains their source syntax,
  including both pivot scopes, instead of compiling SQL syntax a second time at
  the API. Tests cover three repeated round trips and server compile equivalence.
- Malformed saved views are annotated for review, not modified or deleted.
- The durable-filter client cache now has entry/byte budgets and generation
  protection against invalidated in-flight writes, matching the other caches.
- Local lint/build/type checking pass; 455 tests pass with one Linux-only skip.

## Package 3 — bounded lifecycle and durable background measurements

Implemented; gated release verification pending at this entry.

- `20260905230936_bounded_background_lifecycle.sql` replaces whole-parent cascade
  expiry with one locked parent / at most 5,000 child items per unit (two export
  parts). Metadata is removed only after its children are gone. Cleanup shares
  the operations-worker advisory permit and skips locked work.
- Queued/building exports pin their result-set input. Export creation locks and
  checks that input before attaching it, closing the cleanup race. Unfinished
  acknowledged mutations are never removed merely because their TTL passed.
- Partly reclaimed filter sets restore all supplied values under a parent lock
  before their TTL is renewed. Pending/building result references protect them.
- Worker maintenance rotates through classes; each unit runs in a transaction
  with a 3-second statement deadline and 250-ms lock deadline, then restores the
  normal connection settings. This is bounded reclamation, not a physical quota
  or a full graph of renewable reader pins.
- Terminal background-job counts and end-to-end duration buckets persist in a
  private RLS-enabled table with 30-day incremental retention. Authenticated
  health adds queue age, physical derived-table sizes and bounded alert codes.
  Public health reveals none of those details. These are background-job metrics,
  not persistent HTTP journey histograms or configured external notifications.
- The load harness uses the app's read-only POST transport for large filters,
  so an over-cap test reaches API validation rather than a proxy URL limit.
- Candidate migration and real function checks passed in a rolled-back live
  transaction with synthetic private rows only. CI now runs the same lifecycle
  assertions on a disposable PostgreSQL database using actual base definitions.
- Local lint/build/type checking pass; 460 tests pass, one Linux-only skip.
  Supabase advisors remain unavailable locally (connection refused on 54322).

The user has now explicitly authorized on-VPS load/failure testing while the
application is unused. Start bounded, monitor resource thresholds, isolate test
records, and confirm no active customer job before any worker restart. This
does not authorize changing backup configuration or moving production data.

## Remaining programme — not completed by these packages

### Backup failure discovered during the recovery audit

The nightly timer is installed and offsite storage is configured, but the last
backup service failed with exit 70. Recent logs repeatedly show zstd "Broken pipe"
at manifest verification, before reaching the offsite step. The early-exiting
`pg_restore --list` consumer causes this under `pipefail`.

Follow-up fix keeps stdin open, drains the remaining archive, and preserves both
the manifest-reader exit status and zstd's full-stream integrity errors. The
1 MiB synthetic pipeline test reproduces the old failure, passes the new path,
and verifies that reader/producer failures still propagate. The fix is deployed
as `bb090e4`; its CI passed. A read-only check of the latest existing archive
(`20260905T031731Z`) passed manifest reading and complete compressed-stream
verification. No restore, new backup, upload or pruning was performed.

**Recovery blocker:** a read-only restic snapshot-list attempt failed because
the configured `gdrive` rclone remote has an empty OAuth token. The existing
Google Drive connection needs user-authorized reconnection; no destination or
permissions were changed. A readable local archive does not prove offsite
protection or restorability. Actual post-fix backup/offsite success and an
isolated restore drill remain unverified. On 2026-09-06 the user explicitly
deferred backup work and requested that other application work continue.
Backup authentication, destinations and permissions are left unchanged.

| Package | Remaining work |
| --- | --- |
| V8-01 | Persistent journey/job telemetry, queue age/capacity/schema readiness, real peak arrival measurements and alerts. |
| V8-02 | Full versioned QuerySpec/canonical identity, complete transport/route coverage and typed result/count adapters. Recursive ownership, cumulative inline budgets and bounded bodies on the main query/job routes are implemented. |
| V8-03 | Storage reservations/quotas/pins, generic attempt fencing/cancellation, bounded cleanup and a shared budget including imports. Atomic round scheduling is implemented; full fairness latency SLOs are not certified. |
| V8-04 | Unified execution across both pivots, all scoped views, exports and frozen selection; complete over-cap membership path. |
| V8-05 | Dependency-version consistency, immutable snapshot inputs, resumable search evaluation and measured term-cache experiment. |
| V8-06 | Deferred exact counts, measured pagination/suggestion improvements, drift checks and safe online-index tooling. |
| V8-07 | Tier A/B mixed-load, restart/fencing tests, broader authenticated browser regression, isolated restore and rollback drills. The original 51-keyword desktop journey passed. |

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
