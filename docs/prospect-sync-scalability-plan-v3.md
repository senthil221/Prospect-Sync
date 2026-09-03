# Prospect Sync Scalability and Resilience Plan (v3 — Final Blueprint)

Status: implementation blueprint; this document does not authorize implementation by itself.  
Baseline: `main` at `d8bc58d`; production database reported through migration `20260902000030`.  
Target scale: 1.5 million prospects, 750,000 companies, 20 concurrent active users, with controlled degradation at 40 users.

Evidence base: the read-only audit dated 2026-09-02, the active repository definitions, production statistics reported by that audit, and the existing correctness tests. Every production claim not independently reproduced is **UNVERIFIED** until Phase 0 records its raw evidence.

## 0. Architecture

```text
UI filters
    |
    v
parseFilters: one validator, versioned normalized AST, stable scoped hash
    |
    v
Rule-based query classifier calibrated offline from staging plans and timings
    |
    +-------------------+--------------------+
    |                   |                    |
    v                   v                    v
interactive        interactive-capped    background job
indexed page       page + 50,001 count    durable result set
maximum 10s        maximum 10s            isolated worker pool
    |                   |                    |
    +-------------------+--------------------+
                        |
                        v
         page / count / pivot / export / selection / bulk action
         all use the same predicate or the same frozen result set
```

The classifier never runs `EXPLAIN` for every user request. Plans and cost-to-latency relationships are measured offline, versioned with the filter compiler, and used to calibrate deterministic runtime rules.

## 1. Non-negotiable product and data contract

- No silent truncation. Over-cap requests are rejected with a structured response before database execution.
- Page, count, export, pivot scope, selection and bulk actions use one normalized predicate or one frozen result set.
- Client, list, company, permission and blocklist predicates apply before pagination.
- The same real-world prospect may exist across different clients according to the product identity model.
- Within one client, retries and concurrent imports cannot create duplicate canonical prospects or memberships.
- A prospect may belong to multiple lists without cloning the canonical prospect.
- Removing a list membership does not delete the canonical prospect unless an explicitly approved product operation requests that deletion.
- A cancelled browser request stops its database statement and releases its connection.
- Expensive work cannot monopolize the interactive PostgREST pool.
- Overload returns controlled `429` or `503` responses with `Retry-After`, or returns a background job ID.
- Every displayed count is explicitly exact, estimated or capped.
- Performance work cannot change filter semantics. Any requested semantic change requires a separate product decision and separate parity baseline.
- No performance claim is accepted without a representative staging test and a saved execution plan.

## 2. Capacity and service-level objectives

The representative environment must contain:

- 1.5 million prospects.
- 750,000 companies.
- Production-like skew for titles, countries, company sizes, keywords, clients, lists, blocklists and custom fields.
- 20 concurrent active users for the sustained test.
- A separate 40-user overload spike.
- 50 active filters.
- 10,000 exact domains or company names.
- Up to 100 substring terms interactively.
- A 500-term substring search through a background result set.
- A 250,000-row export.
- A 40,000-record client push.
- Browsing and filtering while an import is running.

| Journey | Required target |
|---|---:|
| Normal indexed page | p95 < 2s, p99 < 4s |
| Complex 50-filter page | p95 < 5s, p99 < 8s |
| Normal page during import | p95 < 3s |
| Complex page during import | p95 < 7s |
| Filter-value suggestions | p95 < 500ms |
| Interactive database statement | Hard maximum 10s |
| Cancelled request gone from `pg_stat_activity` | < 2s |
| Bulk action enqueue response | < 300ms with job ID |
| Job enqueue to start | < 5s under target load |
| 40,000-row push job | Goal < 60s; must be measured before becoming a release gate |
| Export throughput | Goal >= 5,000 rows/s without application-memory growth |
| Suggestion staleness | <= 24h and timestamp displayed |
| Pool acquisition failures at 20 users | 0 |
| Unhandled 5xx during sustained load | 0 |
| Predicate parity | 100% |
| Import throughput regression | < 10% |

At 40 users, controlled backpressure is acceptable. Crashes, corrupt data, silent narrowing, empty proxy responses and hung requests are not.

## 3. Phase 0 — Reproducible evidence

### 3.1 Preserve and expose evidence

- Stop resetting `pg_stat_statements`; snapshot it into a retained performance schema on a schedule.
- Add retention and size limits to the snapshot tables.
- Enable `auto_explain` on staging first. In production, enable it only after measuring overhead, with a low sample rate and a minimum duration such as 2 seconds.
- Enable `log_temp_files` and attribute temporary-file growth to query families.
- Log request ID, route, query family, normalized filter hash, compiler version, duration, returned rows and outcome.
- Expose pool usage, pool wait, connections by login role, temporary bytes, dead tuples, analyze/autovacuum timestamps, queue depth and job duration.

### 3.2 Representative staging data

- Prefer an anonymized production clone when policy allows.
- Otherwise build `scripts/perf/` generators preserving approximate cardinality, most-common-value distributions, null rates, average widths and relationship fan-out.
- Include wide and narrow `all_data`, large clients, multi-list prospects, blocklisted domains and common custom keys.
- Store baseline outputs under `perf/baseline/`:
  - top statements;
  - raw plans with `ANALYZE, BUFFERS, WAL`;
  - table and index sizes;
  - index scan counts;
  - pool and temporary-file metrics.

### 3.3 Questions Phase 0 must settle

- Does the deployed PostgREST version cancel database work when the HTTP client disconnects?
- Does `pg_trgm` serve the proposed `ILIKE ANY` shape on this Postgres version and data distribution?
- What are the actual inline, TOAST and heap sizes of `prospect_index.all_data`?
- Which dynamic `ORDER BY` shapes currently prevent sort indexes from being selected?
- What are the costs of `dashboard_workspace`, `client_summaries`, unfiltered company totals and dropdown suggestions?
- How much overhead does each candidate GIN/trigram index add to import and reindex throughput?

Exit gate: every audit number is reproduced, corrected or marked unverified with an owner and follow-up test.

## 4. Phase 1 — Correctness and one filter contract

### 4.1 Versioned normalized AST

Keep `parseFilters` as the only request validator. Its normalized AST contains:

```text
version, entity, client scope, field, operator, values or setId, scopes
```

- Reject unknown built-in fields.
- Permit `custom:` fields only when they exist in the approved field catalogue.
- Validate Boolean syntax, ranges, scope names and value normalization in Node before Postgres.
- Produce a canonical serialization.
- Hash compiler version, authenticated owner, entity, client scope and canonical AST together.
- Use the scoped hash for logs, count caches, filter sets and job audit records.
- Do not use the hash itself as an authorization decision.

### 4.2 Immediate correctness fixes

- Route every prospect export through `search_prospect_export_v4` with optional company scope.
- Retire `search_prospect_export_v1` only after parity passes.
- Include title-classifier fields and stored location in export parity coverage.
- Support at least 50 filters with an internal hard limit of 60.
- Keep the current per-filter value cap until durable filter sets are available.
- Replace `.slice(...)` truncation with `413` containing:
  - received count;
  - allowed count;
  - affected field;
  - supported alternative.
- Validate saved views during migration. Mark over-cap views as requiring review instead of silently changing or deleting them.

### 4.3 Authentication

- Keep the current server authorization as the correctness baseline until its latency is measured.
- Do not assume the self-hosted deployment uses a shared symmetric JWT secret.
- If local verification is justified, verify the deployed signing mode against current Supabase documentation and use its supported claims/JWKS mechanism.
- Keep the approved-email check server-side.
- Use only short, bounded authorization caching and account for session revocation and signing-key rotation.
- Never use user-editable metadata for authorization.

Exit gate: grid count, export total and resolved IDs match across at least 30 filter shapes, including classifier fields, location, Boolean, custom, list/client membership, ranges and negative-only filters.

## 5. Phase 2 — Bounded interactive listing and pagination

### 5.1 People page and count

- Replace the shared materialized match set with one independent page query and one independent capped-count query.
- Cap filtered counts at 50,001 and return `totalCapped`.
- Keep the unscoped planner estimate and return `totalEstimated`.
- Hydrate only the columns required by the visible grid.
- Do not load `all_data` in the listing unless a visible requested custom column requires it.

### 5.2 Static sort shapes before indexes

The current dynamic `CASE` ordering may prevent simple sort indexes from being used. Before creating composite indexes:

- Generate a static, allowlisted SQL branch for each supported sort and direction.
- Preserve a deterministic `id` tie-breaker.
- Match index column order, direction and null ordering to the emitted SQL.
- Prove each index with the actual plan.

Candidate indexes, subject to plan proof:

- `(lower(full_name), id)`.
- `(lower(company_name), id)`.
- `(lower(title), id)`.
- `(last_contacted_at, id)` with matching null ordering.
- Existing `(created_at desc, id)`.

### 5.3 Pagination contract

- Use OFFSET only for shallow pages where its measured cost stays within budget.
- Use cursor/keyset pagination for deep traversal.
- Beyond the shallow-page boundary, expose Next/Previous rather than pretending arbitrary page jumps remain O(1).
- If arbitrary deep page jumps are a product requirement, add explicit cursor checkpoints rather than simulating them with OFFSET.

### 5.4 Company listing

- Preserve the existing independent page/count shape.
- Move remaining deep OFFSET paths to cursor pagination.
- Remove the per-request client aggregate only after the maintained client-company count path passes drift and write-contention tests.

### 5.5 Scoped count-cache invalidation

Avoid one globally updated version row. Use scoped versions or invalidation events, for example:

```text
data_versions(scope_type, scope_id, entity_type, version, updated_at)
```

- Bump only scopes affected by a write.
- Use statement-level transition tables where practical.
- Include version and compiler version in cache keys.
- Prevent a single hot version row from serializing imports.
- Confirm imports, reindexing, push, delete, merge and blocklist operations all emit the necessary invalidation.

UI states:

- `418,151`: exact.
- `~418,000`: estimated.
- `50,000+`: capped.

Exit gate: no full-set CTE scan in page plans; cursor page latency remains stable at deep positions; counts invalidate after every relevant mutation.

## 6. Phase 3 — Filter execution by operator

### 6.1 Runtime classifier without per-request EXPLAIN

Inputs:

- Normalized AST and compiler version.
- A versioned matrix of index-served `(entity, field, operator)` shapes.
- Offline selectivity buckets derived from staging and production statistics.
- Offline plan-cost-to-latency calibration.
- Cached classification by scoped filter hash when safe.

Rules:

1. An unsupported or proven unindexed expensive shape goes to background execution.
2. A substring list over 100 terms goes to background execution.
3. A negative-only filter set goes to background unless a separately proven bounded plan exists.
4. A broad indexed predicate may stay interactive-capped because a sequential scan can be the correct plan at low selectivity.
5. All other shapes use the calibrated rule table; no `EXPLAIN` is issued on the request path.

The rule table is recalibrated after schema, index or material data-distribution changes.

### 6.2 Operator strategies

| Filter type | Strategy |
|---|---|
| Exact domains/names, up to 10,000 | Normalize into `filter_set_values`; join to indexed normalized columns |
| Indexed substring, up to 40 terms | Constant-pattern trigram BitmapOr |
| Substring, 41-100 terms | Use `ILIKE ANY` only if Phase 0 proves index service; otherwise proven constant-pattern chunks |
| Substring over 100 terms | Background result set |
| Boolean/token | Stored/generated vectors whose expression exactly preserves the existing candidate text and tsquery semantics |
| Employee/founded ranges | Direct range disjunctions; no per-row `UNNEST` |
| List/client membership | Canonical membership joins or existing indexed arrays without joined-string equality |
| Custom fields | Indexed side table for approved keys only |
| Keywords/technologies | Existing array GIN overlap where semantics match |
| Negative-only | Selective positive precondition or background result set |

Boolean optimization must not change phrase or column-boundary behaviour. A new per-column Boolean interpretation, if desired, is a separate product feature with a separate name and explicit user approval.

### 6.3 Durable filter sets

```text
filter_sets
  id uuid
  owner_id uuid/text
  entity_type text
  client_scope text/null
  compiler_version integer
  normalization_version integer
  filter_hash text
  value_count integer
  expires_at timestamptz

filter_set_values
  filter_set_id uuid
  normalized_value text
  primary key(filter_set_id, normalized_value)
```

- Place the tables in a private schema where possible; otherwise enable RLS and explicitly revoke `PUBLIC`, `anon` and `authenticated`.
- Bind sets to owner, entity, client scope and normalization version.
- Allow at most 10,000 unique normalized values.
- Make creation idempotent within the same owner and scope.
- Send values once in the filter-set creation body; subsequent listing, pivot, export and job requests carry only `setId`.
- Validate ownership and scope on every `setId` use.
- Apply TTL cleanup and storage monitoring.

### 6.4 One complete SQL compiler

- One compiler per entity emits the complete allowlisted predicate.
- Quote values as data and map fields/operators from allowlists; never accept raw SQL fragments.
- Migrate listing, counts, pivots, exports and bulk resolvers before retiring old functions.
- Retire `prospect_prefilter_sql`, `company_prefilter_sql`, `prospect_index_matches_v1` and `company_matches_filters_v1` only after caller inventory and parity tests prove no active dependency.
- Keep a forward-fix path during the transition.

### 6.5 Custom-field index design

Use a side table only for approved filterable custom keys:

```text
prospect_custom_values(prospect_id, key, raw_value, normalized_value)
```

Candidate indexes, validated on staging:

- B-tree `(key, normalized_value, prospect_id)` for exact matching.
- B-tree `(key, prospect_id)` plus GIN trigram on `raw_value` for BitmapAnd substring plans.
- Partial indexes for a small number of heavily used keys when materially smaller.

Do not expand every raw JSON key into the side table without cardinality and storage measurements.

### 6.6 Conditional `all_data` restructuring

Do not move `all_data` solely because it exists on the hot table. First measure:

- average and percentile `pg_column_size`;
- TOAST table size;
- inline tuple width;
- buffer reads attributable to the column;
- export/detail join cost;
- import and reindex write amplification.

If the evidence supports a split:

1. Add the raw table.
2. Dual-write.
3. Backfill in bounded batches.
4. Verify custom fields, detail views and exports.
5. Switch reads.
6. Remove the duplicate only after parity and rollback readiness.

Do not use “the whole table fits in shared buffers” as the design requirement. The goal is a bounded hot working set and measured buffer efficiency.

### 6.7 Index policy

For every candidate index record:

- exact query shape;
- before/after plan and buffers;
- selectivity;
- index size;
- write/import overhead;
- build and rollback procedure;
- observation-period usage.

Build large production indexes one at a time with `CREATE INDEX CONCURRENTLY`. Check `pg_index.indisvalid` and remove invalid leftovers. Drop zero-scan indexes only after a representative unreset observation window and dependency review.

Exit gate: every interactive filter shape has a proven bounded plan; every other supported shape has a durable background path; semantic parity is green.

## 7. Phase 4 — Durable background result sets

Do not store hundreds of thousands of IDs in large arrays. Use normalized items:

```text
result_sets
  id uuid
  owner_id uuid/text
  entity_type text
  client_scope text/null
  compiler_version integer
  filter_hash text
  data_version bigint/text
  status text
  row_count bigint
  created_at timestamptz
  expires_at timestamptz

result_set_items
  result_set_id uuid
  ordinal bigint
  entity_id text
  primary key(result_set_id, entity_id)
  unique(result_set_id, ordinal)
```

- Store both stable ordinal order and entity uniqueness.
- Index for `(result_set_id, ordinal)` pagination and `(result_set_id, entity_id)` membership.
- Bind result sets to owner and client scope.
- Place them in a private schema or enforce RLS and explicit revocations.
- Build in bounded batches with progress.
- Apply TTL cleanup and capacity alerts.
- Page, count, pivot, export and bulk actions can consume the same frozen items.
- If source data changes, show “results as of T” and offer refresh; never silently add new rows.

Classification should happen before attempting a known-expensive interactive query. A 10-second timeout is a fallback for misclassification, not the normal way to decide that a query needs a job.

Exit gate: a 500-term search produces a paginatable result set without using the interactive pool for the long-running scan.

## 8. Phase 5 — Cancellation, deadlines and admission control

### 8.1 Cancellation

- Propagate `request.signal` to every Supabase query.
- Verify cancellation behaviour against the deployed PostgREST version in Phase 0.
- If PostgREST cancellation is insufficient, move only the affected hot RPC/query paths to a direct server-side `pg` pool where the driver owns and cancels its specific query.
- Do not grant general application routes permission to call `pg_cancel_backend` against arbitrary sessions.
- Do not depend on ambiguous `application_name` matching to identify a backend.

### 8.2 Deadlines

- Suggestions: 3 seconds.
- Listings and interactive counts: 10 seconds.
- Background chunks: 30-60 seconds.
- Lower a function timeout only after its query shape passes the relevant gate.

### 8.3 Workload isolation

- Interactive PostgREST pool.
- Dedicated import-worker pool.
- Dedicated operations/result-set worker pool.
- Size pools and database login-role limits from measured CPU, RAM and connection behaviour.
- Verify how PostgREST login roles and `SET ROLE` interact before relying on per-role connection limits.
- Use the in-process semaphore only as a fast-fail guard. It is not distributed admission control.
- When multiple application replicas become normal, add a distributed admission mechanism or central gateway limit.

### 8.4 Client behaviour

- Return controlled `429` or `503` responses with `Retry-After` before pool exhaustion.
- Retry idempotent reads with bounded exponential backoff and jitter.
- Never retry non-idempotent mutations without an idempotency key.
- Never cache overload responses.

Exit gate: 20-user soak plus import, export and cancellation storm causes zero acquisition timeouts; cancelled statements disappear within 2 seconds.

## 9. Phase 6 — Durable operations and exports

### 9.1 Dedicated operations worker

Reuse the proven queue primitives from the import worker, but run a separate process and pool:

- Atomic claim with `FOR UPDATE SKIP LOCKED`.
- Lease and heartbeat.
- Expired-lease recovery.
- Progress and ETA.
- Retryable/permanent error classes.
- Cancellation.
- Bounded transactions.
- Audit log.
- Queue and item retention cleanup.

### 9.2 Request idempotency

- Require a client-generated request UUID for mutation enqueue.
- Enforce uniqueness per actor/action/request UUID.
- Keep action, filter hash, exclusions and data version as audit fields.
- Do not deduplicate solely by semantic filter hash; users may intentionally repeat an identical operation.

### 9.3 Frozen selection

For an all-matching action:

1. Authorize client and requested operation.
2. Validate and hash the normalized filter.
3. Resolve IDs into `operation_job_items` or reuse an authorized frozen result set.
4. Record exclusions and blocklist hits.
5. Freeze the selection with source data version and timestamp.
6. Mutate in bounded, retry-safe batches.

The job never silently expands to include records created after selection. The UI can offer an explicit re-resolve action.

### 9.4 Export path

- Choose direct streaming versus background export using estimated bytes as well as row count.
- Select only requested columns.
- Use keyset pagination and no per-page count.
- Do not accumulate the complete CSV in Next.js memory.
- Write large exports to private Storage.
- Return short-lived signed links.
- Expire files and job-item rows automatically.
- Validate Storage RLS, owner scope and service-role boundaries.

Exit gate: enqueue < 300ms; retry does not duplicate work; affected IDs equal frozen selection minus exclusions/blocked rows; memory remains bounded during export.

## 10. Phase 7 — Counts, suggestions and maintenance

### 10.1 Client-company prospect counts

Prototype before committing to a trigger design:

- Derive touched old/new `(client_id, company_id)` pairs from statement-level transition tables.
- Cover insert, update, delete, company reassignment, blocklist removal, push and client membership changes.
- Compare set-based recomputation against a touched-pair queue/delta design.
- Measure lock contention and import regression.
- Select the design only after it stays under the 10% import-regression budget.
- Add the chosen count to drift reporting and provide a repair function.

Do not assume extending the existing company-count trigger is automatically cheap enough.

### 10.2 Suggestions

- Add `prospect_value_suggestions`, mirroring the proven company suggestion pattern.
- Refresh after completed imports and on a schedule.
- Add client-specific summaries only for scopes where measurements justify them.
- Use the live table only when a user types a search term and the query is bounded.
- Display refresh time.

### 10.3 Global totals

- Use maintained counters for operationally exact totals.
- Use `reltuples` only for explicitly estimated unfiltered totals.
- Cap searched totals.
- Apply timeouts.

### 10.4 Vacuum and statistics

- Tune autovacuum/analyze thresholds separately for `prospect_index`, `companies`, `client_prospects`, job items and result-set items.
- Analyze relevant columns after large imports or backfills.
- Monitor dead tuples and planner-estimate drift.

Exit gate: count drift is zero; repair works; suggestions meet p95 and freshness targets; unfiltered company load p95 < 1 second.

## 11. Phase 8 — Regression gates

Run these gates from Phase 1 onward.

### 11.1 Correctness parity

At least 30 representative shapes must satisfy:

```text
grid predicate
= count predicate
= export predicate
= selected IDs
= affected IDs + excluded IDs + blocked IDs
```

Include classifier fields, location, Boolean, custom keys, list/client membership, ranges, negative filters and combinations.

### 11.2 Plan assertions without planner dogma

- Assert index-backed plans only for selective fixtures explicitly designed to be index-served.
- Do not fail merely because PostgreSQL selected a sequential scan for a broad low-selectivity filter.
- For broad fixtures, enforce actual latency, rows examined, buffers and temporary-file budgets.
- Verify sort indexes against the exact static order clause.
- Save actual plans and compare material plan regressions, not unstable raw cost numbers alone.

### 11.3 Scale scenarios

- 51 filters and 10,001 values reject explicitly.
- Saved view above new cap is flagged.
- 10,000 exact domains.
- 100 interactive substring terms.
- 500 substring terms as a background result set.
- Broad country filter.
- Negative-only filter.
- Boolean and custom-field filters.
- Deep cursor pagination.
- 250,000-row export.
- 40,000-row client push.
- 1,875-domain blocklist with high prospect coverage.
- Cancellation storm.
- Import plus browsing.
- 20-user 15-minute soak.
- 40-user overload spike.
- Data change between enqueue and execution.
- Retry after worker lease expiry.

### 11.4 Product invariants

- Cross-client duplicates remain permitted according to current identity policy.
- Within-client duplicate prevention remains idempotent under retries.
- Multi-list memberships are preserved.
- Deleting a list does not delete canonical prospects.
- Blocklists affect only the intended client and protect future imports/actions.
- Company ICP state remains client-scoped.
- Date Contacted remains client-scoped.
- Browser clients never receive service-role credentials.

## 12. Safe rollout

Every phase follows:

1. Expand schema.
2. Backfill in bounded batches.
3. Shadow-compare old and new counts and ID sets by filter hash.
4. Enable for a small traffic slice.
5. Monitor latency, pool usage, errors, storage, write regression and drift.
6. Increase traffic gradually.
7. Remove the old path only after parity and rollback readiness.

Every release requires:

- Migration order verification.
- Current Supabase changelog/documentation review for affected features.
- RLS and `SECURITY DEFINER` review.
- Fixed `search_path` and explicit revocation from `PUBLIC`, `anon` and `authenticated` for privileged functions.
- Data API exposure review for new tables.
- Forward-fix or rollback procedure, including invalid-index cleanup.
- Backup confirmation.
- Targeted tests, lint, type checking, production build and authenticated E2E.
- Before/after plan evidence.
- Final diff review for secrets, unrelated edits and permission expansion.

## 13. Implementation sequence

1. Evidence capture, representative staging data and open-question experiments.
2. Correctness/parity and plan regression harnesses.
3. Export v4 parity, explicit cap rejection, saved-view validation and auth measurement.
4. Static sort SQL, People page/count split, bounded totals and cursor pagination.
5. Cancellation verification and controlled admission/backpressure.
6. Durable exact-value filter sets and normalized prospect domain.
7. Targeted measured indexes and semantics-preserving Boolean vectors.
8. Rule-based classifier and normalized background result sets.
9. Dedicated operations worker, request idempotency and frozen selections.
10. Streaming/background exports.
11. Approved custom-value side table; conditional `all_data` restructuring only if proven.
12. Client-company counts, suggestions and global-total improvements.
13. Index hygiene, autovacuum tuning and final pool sizing.
14. Full 20-user soak, 40-user backpressure rehearsal and staged rollout.

## 14. Completion definition

Prospect Sync is ready for the target scale only when:

- Correctness parity is 100% across the complete catalogue.
- All interactive SLOs pass with and without a concurrent import.
- The 20-user soak has zero pool acquisition failures and zero unhandled server errors.
- The 40-user spike degrades only through controlled backpressure or background execution.
- A 500-term search completes through a durable result set without starving interactive traffic.
- A 250,000-row export completes with bounded memory and correct authorization.
- Bulk-operation retries and lease recovery do not duplicate mutations.
- Imports, identities, blocklists, client/list memberships, company ICP state and Date Contacted retain their invariants.
- Every new index and high-volume function has saved before/after evidence.
- Every privileged schema object has reviewed grants, RLS/exposure posture and scope checks.
- Rollback or forward-fix procedures are documented and rehearsed.

