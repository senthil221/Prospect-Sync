# Prospect Sync Scalability and Resilience Plan

Status: implementation blueprint  
Baseline: `main` at `d8bc58d`  
Target scale: 1.5 million prospects, 750,000 companies, 20 concurrent active users

This plan turns the scalability audit into a measurable, rollback-safe engineering programme. It does not authorize implementation by itself.

The central architecture is:

```text
One validated filter contract
             |
      Query-cost classifier
       +-----+-----+
       |           |
Fast indexed    Expensive query
interactive     durable background job
       |           |
 page/count     materialized result set
       +-----+-----+
             |
 table / export / selection / bulk actions
```

This avoids promising that every theoretically possible filter combination will finish instantly while ensuring none can crash the application or silently produce the wrong result.

## 1. Non-negotiable product contract

- No silent truncation.
- Page results, counts, exports and bulk actions use exactly the same filter definition.
- Filters apply before pagination.
- Client, list, company and blocklist boundaries remain intact.
- Cancelled browser requests stop database work.
- Expensive operations never monopolize the interactive PostgREST pool.
- Overload produces a controlled response or background job, not a timeout, empty JSON response or pool collapse.
- Every performance claim requires a representative load test and an actual execution plan.

## 2. Target capacity and service-level objectives

Test against:

- 1.5 million prospects.
- 750,000 companies.
- 20 concurrent active users.
- 50 active filters.
- 10,000 exact domains or names.
- At least 100 substring terms interactively.
- Larger expensive searches through background result-set materialization.
- 250,000-row exports.
- 40,000-record client operations.
- Imports running while users browse and filter.

Acceptance targets:

| Journey | Target |
|---|---:|
| Normal indexed page | p95 < 2s, p99 < 4s |
| Complex 50-filter page | p95 < 5s, p99 < 8s |
| Filter-value suggestions | p95 < 500ms |
| Interactive database statement | Maximum 10s |
| Cancelled request removed from DB | < 2s |
| Bulk action API response | < 300ms with job ID |
| Pool acquisition failures at 20 VUs | 0 |
| Unhandled 5xx during soak test | 0 |
| Filter/count/export/action parity | 100% |
| Import throughput regression | < 10% |

At a deliberate 40-user spike, controlled `429` or `503` responses with `Retry-After` are acceptable. Crashes, corrupt data and hanging requests are not.

## 3. Phase 0: Build the performance evidence base

Before changing query architecture:

- Preserve `pg_stat_statements` snapshots instead of resetting them.
- Capture the top queries by total time, mean time, calls and temporary-file usage.
- Save raw `EXPLAIN (ANALYZE, BUFFERS, WAL)` output from staging.
- Add route timing, request IDs, filter hashes and query-family names to logs.
- Monitor:
  - PostgREST pool usage and acquisition wait.
  - Active and idle database connections.
  - Temporary bytes and spills.
  - Dead tuples, analyze and autovacuum activity.
  - Background queue depth and job duration.
- Create an anonymized staging dataset with production-like distribution and skew.
- Store baseline artifacts in the repository so later improvements are reproducible.

Exit gate: every audit measurement is reproduced, corrected or explicitly marked unverified.

## 4. Phase 1: Fix correctness before performance

### Unified filter contract

Create one versioned normalized filter AST used by:

- People listing.
- Company listing.
- Counts.
- See People and See Companies.
- Exports.
- Push to client.
- ICP verification.
- Date Contacted.
- Deletes and removals.

Each normalized filter request gets a stable hash for caching, logs and result-set identity.

### Immediate fixes

- Route all prospect exports through `search_prospect_export_v4`.
- Retire v1 after parity verification.
- Support at least 50 filters with an internal cap of 60.
- Stop slicing filters and values silently.
- Return `413` with:
  - received count;
  - allowed count;
  - affected field;
  - recommended exact, Boolean or background-search alternative.
- Add classifier fields and stored location to export parity tests.
- Ensure malformed filters fail before reaching Postgres.

Exit gate: table count, export total and selected IDs match across the complete filter catalogue.

## 5. Phase 2: Make interactive listing bounded

### People listing

Replace the materialized complete match set with:

- One early-stopping page query.
- One independent capped count query.
- `totalCapped` and `totalEstimated` response fields.
- A maximum filtered count scan of 50,001.
- Keyset pagination using every sort column plus `id` as the tie-breaker.
- No deep `OFFSET`.

### Company listing

- Preserve the current independent count and page improvement.
- Replace remaining offset pagination with keyset pagination.
- Avoid recomputing the count on page 2 and later when the filter hash has not changed.
- Cache only count metadata, with explicit invalidation after imports or mutations.

UI semantics must distinguish:

- `418,151`: exact.
- `~418,000`: estimated.
- `50,000+`: capped.

Exit gate: page plans do not materialize the entire match set and deep-page latency remains approximately constant.

## 6. Phase 3: Redesign filter execution by operator

| Filter type | Execution strategy |
|---|---|
| Exact domains or names, up to 10,000 | Normalized `filter_set_values` rows joined to indexed normalized columns |
| Indexed substring, small list | Trigram BitmapOr |
| Large substring list | Cost-classified; background result-set materialization when over the proven interactive budget |
| Boolean or token search | Stored or generated `tsvector` plus matching GIN index |
| Employee ranges | Direct range disjunctions, with no per-row `UNNEST` |
| List or client membership | Join canonical membership tables, not `array_to_string` |
| Custom fields | Indexed side table for explicitly filterable custom keys |
| Negative-only filters | Use a selective positive predicate first; otherwise background execution |
| Keywords or technologies | Existing array GIN overlap where semantics match |

### Durable filter sets

Use a private, service-only structure similar to:

```text
filter_sets
  id, owner_id, entity_type, value_count, hash, expires_at

filter_set_values
  filter_set_id, normalized_value
  primary key(filter_set_id, normalized_value)
```

Requirements:

- UUID identifiers.
- Bound to the authenticated owner or request context.
- Maximum 10,000 normalized unique values.
- TTL cleanup.
- Idempotent creation by hash.
- Never exposed directly to `anon` or `authenticated`.
- Exact-value joins use indexes.
- Do not store the values as one large array and run `UNNEST` for every row.

### Index policy

For every proposed index, record:

- Query shape it serves.
- Current execution plan.
- Expected selectivity.
- Index size.
- Import and write overhead.
- Result after staging benchmark.
- Rollback command.

Build large production indexes one at a time with `CREATE INDEX CONCURRENTLY`. Do not add trigram indexes blindly to every text column.

Exit gate: every supported interactive filter shape has either an index-backed plan or an explicit background execution path.

## 7. Phase 4: Cancellation, deadlines and admission control

- Propagate `request.signal` through every Supabase query.
- Verify cancelled HTTP requests actually disappear from `pg_stat_activity`.
- Use endpoint-specific budgets:
  - suggestions: 3s;
  - listings: 10s;
  - interactive counts: 10s;
  - background chunks: 30-60s.
- Do not reduce timeouts until the corresponding query has passed its performance gate.
- Reserve database capacity by workload:
  - interactive PostgREST pool;
  - import-worker pool;
  - operations-worker pool.
- Add an interactive concurrency gate.
- If multiple app replicas are introduced, use distributed admission control; an in-memory semaphore alone is insufficient.
- Return controlled `503` and `Retry-After` responses before the pool is exhausted.

Exit gate: a 20-user soak plus an import and export produces no acquisition timeouts.

## 8. Phase 5: Durable bulk operations and exports

Create a dedicated operations worker, not an extension of the import worker.

Job capabilities:

- Atomic claiming with `FOR UPDATE SKIP LOCKED`.
- Lease expiry and recovery.
- Idempotency keys.
- Progress and estimated completion.
- Retryable versus permanent errors.
- Cancellation.
- Bounded batch transactions.
- Audit log.
- Separate worker pool and concurrency limit.

### Stable selection semantics

For all-matching actions:

1. Validate and hash the normalized filter.
2. Resolve matching IDs into `operation_job_items`.
3. Record exclusions.
4. Freeze the resolved selection.
5. Apply the mutation in bounded batches.

This prevents records changing between clicking the button and the worker executing the operation.

### Exports

- Small exports may stream directly.
- Large exports become jobs.
- Use keyset pagination.
- Never recount on every page.
- Never accumulate hundreds of thousands of rows in Next.js memory.
- Stream to private Storage and return a short-lived signed download link.
- Delete expired export files automatically.

Exit gate: enqueue requests return quickly, retries do not duplicate work, and acted-on IDs match the original selection.

## 9. Phase 6: Derived counts and suggestions

Introduce maintained read models for:

- Prospect filter-value suggestions.
- Client-company prospect counts.
- Company coverage.
- Frequently displayed global totals.

Avoid a row-level counter update for every imported prospect where that would create contention. Prefer:

- Tracking touched `(client_id, company_id)` pairs.
- Set-based recomputation after each import or background batch.
- Periodic drift detection.
- Repair functions.
- Freshness timestamps.

Approximate values must be labelled approximate. Client-level operational counts should remain exact or explicitly capped.

Tune autovacuum and analyze thresholds for high-churn tables based on observed update volume.

## 10. Phase 7: Performance and correctness gates

The CI and staging suite must include:

- Query-plan assertions for indexed filter shapes.
- Parity tests across at least 30 representative filter combinations.
- 51-filter and 10,001-value rejection tests.
- 10,000 exact-domain test.
- 100 and 500 substring-term scenarios.
- Broad country filter.
- Negative-only filter.
- Boolean and custom-field filters.
- Deep pagination.
- 250,000-row export.
- 40,000-row client push.
- 1,875-domain blocklist with high prospect coverage.
- Browser cancellation storm.
- Concurrent import plus browsing.
- 20-VU 15-minute soak.
- 40-VU overload spike.

Every test must check both performance and correctness:

```text
grid predicate
= count predicate
= export predicate
= selected IDs
= affected IDs + excluded or blocked IDs
```

## 11. Safe rollout

Each phase should be a separate reviewable release:

1. Expand schema.
2. Backfill in bounded batches.
3. Compare old and new results in shadow mode.
4. Enable for a small percentage of traffic.
5. Monitor latency, pool usage, errors and count drift.
6. Increase traffic.
7. Remove the old path only after parity is proven.

Every release requires:

- Migration ordering check.
- RLS and `SECURITY DEFINER` review.
- Explicit revocation from `PUBLIC`, `anon` and `authenticated`.
- Forward-fix or rollback procedure.
- Backup confirmation.
- Unit tests, lint, production build and authenticated E2E.
- Before and after query-plan artifacts.

## 12. Recommended implementation sequence

1. Export v4 parity and explicit cap rejection.
2. People count and page split with cursor pagination.
3. Cancellation and structured overload responses.
4. Normalized exact-value filter sets.
5. Targeted indexes and Boolean search vectors.
6. Dedicated operations worker.
7. Streaming and background exports.
8. Client-company statistics and suggestion tables.
9. Load-test and query-plan regression gates.
10. Final pool sizing based on measured workload.

## Completion definition

Prospect Sync is considered ready for the target scale only when:

- All correctness parity tests pass.
- All interactive and background SLOs pass on the representative staging dataset.
- The 20-user soak has no pool acquisition failures or unhandled server errors.
- The 40-user spike degrades through controlled backpressure without data corruption.
- Imports, blocklists, client memberships, list memberships and ICP state retain their existing invariants.
- Production rollout has documented rollback or forward-fix procedures and observable health signals.

