# Prospect Sync Scalability and Resilience Plan (Final Blueprint, v7)

Status: implementation blueprint; this document does not authorize implementation by itself.
Baseline: `main` at `d8bc58d`; production database reported applied through migration `20260902000030` (from the audit's read-only `schema_migrations` query on 2026-09-02; Codex must re-query before relying on it).
Target scale: 1.5 million prospects, 750,000 companies, 20 concurrent active users, controlled degradation at 40 users.

Evidence base: the read-only audit dated 2026-09-02 (final function definitions, `pg_stat_statements`, index catalogue, plans A–M), the active repository, and the existing correctness tests. Every production claim not independently reproduced is **UNVERIFIED** until Phase 0 records its raw evidence.

Corrections from v4 (v5): cache identity includes authorization scope and dependency-aware version vectors; filter-set UUIDs no longer affect logical identity; entity-version contention is treated as measurable rather than impossible; worker logins retain narrow roles and never assume `service_role`; sensitive mutations use fresh authorization; candidate indexes remain evidence-gated; Release 1 is split into 1A/1B/1C.

Corrections from v6 (v7): classifier cache keys include `classifier_version` (§6.1); the client-company count reference names the actual trigger lineage — row-level in `20260815010000`, statement-level with transition tables since `20260825000000` (§10.1, §5.5); the migration baseline is phrased as reported by the audit, not independently confirmed.

Corrections from v5 (v6): `result_sets` and job audit fields use the same content hash + version vector as the cache identity (§7, §9.2); authorization scope is documented as a constant in the current single-tenant deployment (§4.1, §5.5); the Release 1B index evaluation names the specific high-selectivity columns with plan evidence and the expected outcome, so evidence-gating cannot become deferral (§6.7, §13).

## 0. Architecture

```text
UI filters
    |
    v
parseFilters: one validator, versioned normalized AST, content identity (+ ownership and authorization scope)
    |
    v
Rule-based query classifier, calibrated offline from staging plans and timings
    |
    +-------------------+--------------------+
    |                   |                    |
    v                   v                    v
interactive        interactive-capped    background job
indexed page       page + 50,001 count    durable result set
maximum 10s        maximum 10s            isolated worker pool / login role
    |                   |                    |
    +-------------------+--------------------+
                        |
                        v
   page / count / pivot / export / selection / bulk action
   all use the same predicate or the same frozen result set
```

The classifier never runs `EXPLAIN` on the request path. Plans and cost-to-latency relationships are measured offline, versioned with the filter compiler, and used to calibrate deterministic runtime rules.

## 1. Non-negotiable product and data contract

- No silent truncation. Over-cap requests are rejected with a structured response before database execution.
- Page, count, export, pivot scope, selection and bulk actions use one normalized predicate or one frozen result set.
- Client, list, company, permission and blocklist predicates apply before pagination.
- The same real-world prospect may exist across different clients according to the product identity model; within one client, retries and concurrent imports cannot create duplicate canonical prospects or memberships.
- A prospect may belong to multiple lists without cloning the canonical prospect; removing a list membership does not delete the canonical prospect unless an explicitly approved product operation requests it.
- A cancelled browser request stops its database statement and releases its connection.
- Expensive work cannot monopolize the interactive PostgREST pool.
- Overload returns controlled `429`/`503` with `Retry-After`, or a background job ID.
- Every displayed count is explicitly exact, estimated or capped.
- Performance work cannot change filter semantics. A semantic change requires a separate product decision and a separate parity baseline.
- No performance claim is accepted without a representative staging test and a saved execution plan.

## 2. Capacity and service-level objectives

Representative environment: 1.5 M prospects; 750 k companies; production-like skew for titles, countries, company sizes, keywords, clients, lists, blocklists and custom fields; 20 sustained users; a separate 40-user spike; 50 active filters; 10,000 exact domains/names; up to 100 substring terms interactively; a 500-term substring search via background result set; a 250,000-row export; a 40,000-record client push; browsing while an import runs.

| Journey | Required target |
|---|---:|
| Normal indexed page | p95 < 2 s, p99 < 4 s |
| Complex 50-filter page | p95 < 5 s, p99 < 8 s |
| Normal / complex page during import | p95 < 3 s / < 7 s |
| Filter-value suggestions | p95 < 500 ms |
| Interactive database statement | hard maximum 10 s |
| Cancelled request gone from `pg_stat_activity` | < 2 s |
| Bulk action enqueue response | < 300 ms with job ID |
| Job enqueue to start | < 5 s under target load |
| 40,000-row push job | goal < 60 s; measured before becoming a gate |
| Export throughput | goal ≥ 5,000 rows/s without application-memory growth |
| Suggestion staleness | ≤ 24 h, timestamp displayed |
| Count cache correctness | Current dependency-version vector after a completed mutation |
| Pool acquisition failures at 20 users | 0 |
| Unhandled 5xx during sustained load | 0 |
| Predicate parity | 100 % |
| Import throughput regression | < 10 % |

At 40 users, controlled backpressure is acceptable. Crashes, corrupt data, silent narrowing, empty proxy responses and hung requests are not.

## 3. Phase 0 — Reproducible evidence

### 3.1 Preserve and expose evidence
- Stop resetting `pg_stat_statements` (`deploy/scripts/maintenance.sh`); snapshot into a retained performance schema with size limits.
- `auto_explain` on staging first; in production only after measuring overhead, sampled, minimum duration 2 s.
- `log_temp_files = 0`; attribute temporary-file growth (32 GB / 310 files in the audit window) to query families.
- Route logs: request ID, route, query family, content hash, compiler version, duration, rows, outcome.
- Expose pool usage and wait, connections by login role, temp bytes, dead tuples, analyze/autovacuum timestamps (`prospect_index` shows `autovacuum_count = 0`), queue depth, job duration.

### 3.2 Representative staging data
- Prefer an anonymized production clone; otherwise `scripts/perf/` generators preserving cardinality, MCV distributions, null rates, widths and fan-out, including wide/narrow `all_data`, large clients, multi-list prospects, blocklisted domains and common custom keys.
- Baselines under `perf/baseline/`: top statements, plans with `ANALYZE, BUFFERS, WAL`, table/index sizes, index scan counts, pool and temp-file metrics.

### 3.3 Questions Phase 0 must settle
- Does PostgREST 12.2.12 cancel database work when the HTTP client disconnects?
- Does `pg_trgm` serve `ILIKE ANY(array)` on this Postgres version and data?
- Actual inline, TOAST and heap sizes of `prospect_index.all_data`.
- Which dynamic `ORDER BY` shapes prevent sort indexes from being selected.
- Costs of `dashboard_workspace`, `client_summaries`, unfiltered company totals and dropdown suggestions.
- Import/reindex overhead of each candidate GIN/trigram index.
- Selectivity distribution of real Boolean queries (top terms from logs), to decide whether any tsvector index can beat an early-stopping scan (§6.2).
- Measured latency of the per-request `getUser()` call (§4.3).

Exit gate: every audit number is reproduced, corrected or marked unverified with an owner and follow-up test.

## 4. Phase 1 — Correctness and one filter contract

### 4.1 Versioned normalized AST and two hashes
`parseFilters` remains the only request validator. The normalized AST contains `version, entity, client scope, field, operator, values | setId, scopes`.

- Reject unknown built-in fields; permit `custom:` fields only when present in the field catalogue (`prospect_fields`).
- Validate Boolean syntax, ranges, scope names and value normalization in Node before Postgres.
- Produce a canonical serialization.
- **Filter-content identity** = compiler version + entity + client scope + canonical AST. If the AST references a `setId`, canonicalization uses that set's immutable content hash and normalization version, never the random UUID.
- **Authorization scope** = a stable permission-scope identifier/version derived from the user's actual permitted dataset. Count/result caches may be shared only when this scope is identical. **Today this is a constant:** every user is an allow-listed email (`ALLOWED_USER_EMAILS`) with identical server-side access and there is no per-user data partition. Keep the field in the key (a fixed value such as `global:1`) so caches are ready for per-user permissions, but do not build a permission-scope service for a product that does not yet have permissions.
- **Cache identity** = filter-content identity + authorization scope + the dependency-version vector required by the compiled query.
- **Ownership** (owner ID) is stored on `filter_sets`, `result_sets` and jobs and checked on every use. Neither a hash nor a cache hit is an authorization decision.

### 4.2 Immediate correctness fixes
- Route every prospect export through `search_prospect_export_v4` with optional company scope; retire `search_prospect_export_v1` after parity; add title-classifier fields and stored location to parity coverage.
- Support ≥ 50 filters with an internal hard limit of 60; keep the per-filter value cap until durable filter sets exist.
- Replace `.slice(...)` truncation with `413 { received, allowed, field, alternative }`.
- Validate saved views during migration; flag over-cap views for review rather than changing or deleting them.

### 4.3 Authentication
- This deployment signs tokens with a shared HS256 secret (`GOTRUE_JWT_SECRET` = `PGRST_JWT_SECRET` = `JWT_SECRET` in `deploy/docker-compose.yml`). Every API route currently makes a GoTrue round-trip via `supabase.auth.getUser()`; Phase 0 measures its cost.
- If justified: verify the access token locally with that secret (same signing trust, no network hop), keep the approved-email check server-side, and never expose the secret to browser code.
- Read-only authorization caching is bounded to `min(60 seconds, remaining token lifetime)`. Destructive mutations, bulk-operation enqueue, exports and permission changes require a fresh or revocation-aware authorization check.
- Account for refresh-token rotation and session revocation. Re-evaluate the implementation if signing migrates to asymmetric keys/JWKS, using current Supabase documentation at that time.
- Never use user-editable metadata for authorization.

Exit gate: grid count, export total and resolved IDs match across ≥ 30 shapes, including classifier fields, location, Boolean, custom, list/client membership, ranges and negative-only filters.

## 5. Phase 2 — Bounded interactive listing and pagination

### 5.1 People page and count
- Replace the shared materialized match set with one independent page query and one independent capped-count query (the `20260902000010` pattern).
- Cap filtered counts at 50,001 → `totalCapped`; keep the unscoped planner estimate → `totalEstimated`.
- Hydrate only visible grid columns; do not read `all_data` unless a visible custom column requires it.

### 5.2 Static sort shapes before indexes
The current dynamic `CASE` ordering can prevent sort indexes from being used. Generate a static, allowlisted SQL branch per sort/direction with an `id` tie-breaker; match index column order, direction and null ordering to the emitted SQL; prove each index with the actual plan. Candidates: `(lower(full_name), id)`, `(lower(company_name), id)`, `(lower(title), id)`, `(last_contacted_at, id)` with matching null ordering, existing `(created_at desc, id)`.

### 5.3 Pagination contract
- OFFSET only for shallow pages whose measured cost stays within budget; cursor/keyset for deep traversal, exposed as Next/Previous.
- If arbitrary deep jumps are a product requirement, add explicit cursor checkpoints rather than simulating them with OFFSET.

### 5.4 Company listing
- Preserve the independent page/count shape; move remaining deep OFFSET paths to cursor pagination.
- Remove the per-request client aggregate only after the maintained client-company count path (§10.1) passes drift and write-contention tests.

### 5.5 Count-cache invalidation: dependency-aware version vectors
```text
data_versions(entity_type primary key, version bigint, updated_at)
```
- Begin with independently maintained `prospect` and `company` versions.
- The `prospect` version can be bumped from the existing statement-level count triggers on `prospect_index` (`20260825000000`). **`companies` has no equivalent today:** the only trigger ever created on it (`20260831210000`, `search_tsv` maintenance) was reverted in `20260831230000`, so company imports, merges and enrichment write to `companies` with no trigger to hook. The `company` version therefore needs a new statement-level trigger on `companies` (insert/update/delete, transition tables) added in Release 1B; until it exists, company-dependent cache entries must be treated as uncacheable.
- The filter compiler declares its data dependencies. A People query with company scope and a Company query with People scope depend on both versions; their cache key includes both. A single-entity query includes only the version it actually reads.
- Add an authorization-scope version only if per-user permitted datasets are ever introduced (see §4.1 — the scope is a constant today).
- Bump versions once per relevant statement using transition-table triggers, and test imports, reindex backlog, push, delete, merge, blocklist and membership operations.
- Updating one version row can serialize concurrent writers. Benchmark this explicitly. If contention or cache invalidation is excessive, move to scoped/bucketed versions or an append-only invalidation event design.
- Never serve a cached count after a completed mutation unless its complete dependency-version vector still matches.

UI states: `418,151` exact · `~418,000` estimated · `50,000+` capped.

Exit gate: no full-set CTE scan in page plans; cursor page latency stable at deep positions; counts invalidate after every relevant mutation.

## 6. Phase 3 — Filter execution by operator

### 6.1 Runtime classifier without per-request EXPLAIN
Inputs: normalized AST + compiler version; a versioned matrix of index-served `(entity, field, operator)` shapes; offline selectivity buckets; offline cost-to-latency calibration; cached classification keyed by content hash **plus `classifier_version`** — a monotonically increasing epoch bumped whenever the index-served matrix, selectivity buckets or calibration table change. Classification does not depend on data versions, but it does change after an index build, `ANALYZE`, or recalibration even when the filter content is identical, and a stale classification would route a now-indexed shape to background (or, worse, a now-unindexed shape to interactive).

Rules:
1. Unsupported or proven-unindexed expensive shape → background.
2. Substring list > 100 terms → background.
3. Negative-only filter set → background unless a separately proven bounded plan exists.
4. Broad indexed predicate may stay interactive-capped: a sequential scan with early stop is the correct plan at low selectivity.
5. Boolean → interactive-capped early-stop scan by default (see §6.2); background only when combined with other unindexed shapes or when calibration shows the scan exceeds budget at 1.5 M.
6. Everything else uses the calibrated rule table.

Recalibrate after schema, index or material distribution changes.

### 6.2 Operator strategies

| Filter type | Strategy |
|---|---|
| Exact domains/names, ≤ 10,000 | Normalize into `filter_set_values`; join to indexed normalized columns (`companies.normalized_domain/name`; new reindex-maintained `prospect_index.normalized_domain`) |
| Indexed substring, ≤ 40 terms | Constant-pattern trigram BitmapOr |
| Substring 41–100 terms | `ILIKE ANY` only if Phase 0 proves index service; otherwise proven constant-pattern chunks |
| Substring > 100 terms | Background result set |
| Boolean/token | **Default: interactive-capped early-stop scan with the inline `to_tsvector('simple', …)` predicate, semantics unchanged.** `20260831210000` added a stored companies `search_tsv` and `20260831230000` reverted it because common keywords sit at ~67 % selectivity where GIN loses to a seq scan and the column's maintenance cost exceeded the gain. Any new vector index is therefore gated: only on high-selectivity columns (title, company name), only as an expression index that reproduces the existing candidate text exactly, and only if the Phase 0 Boolean-term study shows real queries are selective enough for the planner to choose it. Column-boundary/phrase behaviour does not change; a per-column Boolean is a separate product feature. |
| Employee/founded ranges | Direct range disjunctions; no per-row `UNNEST` |
| List/client membership | Canonical membership joins or existing indexed arrays; no joined-string equality |
| Custom fields | Indexed side table for approved keys only (§6.5) |
| Keywords/technologies | Existing array GIN overlap where semantics match |
| Negative-only | Selective positive precondition or background result set |

### 6.3 Durable filter sets
```text
filter_sets        id uuid, owner_id, entity_type, client_scope, compiler_version,
                   normalization_version, content_hash, value_count, expires_at
filter_set_values  filter_set_id, normalized_value   pk (filter_set_id, normalized_value)
```
Private schema where possible, else RLS + explicit revoke from `PUBLIC/anon/authenticated`; bound to owner, entity, client scope and normalization version; ≤ 10,000 unique normalized values; idempotent per owner/scope; values sent once at creation, then only `setId`; ownership and scope validated on every use; TTL cleanup and storage monitoring.

### 6.4 One complete SQL compiler
One compiler per entity emits the complete allowlisted predicate (values quoted as data, fields/operators from allowlists, no raw SQL). Migrate listing, counts, pivots, exports and bulk resolvers first; retire `prospect_prefilter_sql`, `company_prefilter_sql`, `prospect_index_matches_v1` and `company_matches_filters_v1` only after a caller inventory and parity prove no active dependency; keep a forward-fix path during transition.

### 6.5 Custom-field index design
`prospect_custom_values(prospect_id, key, raw_value, normalized_value)` for approved filterable keys only. Candidate indexes, each gated on a staging plan: B-tree `(key, normalized_value, prospect_id)` for exact; B-tree `(key, prospect_id)` plus trigram on `raw_value` for substring; partial indexes for a few hot keys when materially smaller. Do not expand every raw JSON key without cardinality and storage measurements.

### 6.6 Conditional `all_data` restructuring
Measure first: `pg_column_size` percentiles, TOAST size, inline width, buffer reads attributable to the column, export/detail join cost, import/reindex write amplification. If justified: add raw table → dual-write → bounded backfill → verify custom fields, detail and exports → switch reads → remove duplicate after parity and rollback readiness. The goal is a bounded hot working set, not "the table fits in shared buffers".

### 6.7 Index policy
Per candidate index record: exact shape, before/after plan and buffers, selectivity, size, write/import overhead, build and rollback procedure, observation-period usage. Build large production indexes one at a time with `CREATE INDEX CONCURRENTLY`; check `pg_index.indisvalid` and remove invalid leftovers. Drop zero-scan indexes only after an unreset observation window and dependency review.

**Contains-column trigram indexes are evaluated in Release 1B against a named list, not an open-ended candidate pool.** The audit recorded `Parallel Seq Scan` plans for `contains` on `full_name` (plan A) and `company_country` (plan F), and `idx_prospect_index_company_domain_lower` is the precedent (`20260901000030`: 765 ms → 9.9 ms on a 500-domain list).

Tier 1 — expected to pass; build unless the staging plan or import-cost measurement says otherwise: `full_name`, `first_name`, `last_name`, `personal_email`, `linkedin_url`, `company_domain` (substring form), `tag_text`. These are high-cardinality columns where a substring is selective by construction.

Tier 2 — evaluate, expect a mixed result: `company_city`, `company_state`, `company_country`; `lower()` B-trees for `esp` and `email_provider_type`. Broad values ("united states") will correctly prefer an early-stopping sequential scan and must not be indexed merely because they appear in a filter; narrow values (a city) may still benefit.

Each build still follows this policy: selective fixture, before/after plan, size, import/reindex cost, `CONCURRENTLY`, one at a time. A Tier 1 column that is skipped requires a recorded reason in `perf/baseline/`.

Exit gate: every interactive shape has a proven bounded plan; every other supported shape has a durable background path; semantic parity is green.

## 7. Phase 4 — Durable background result sets

```text
result_sets        id uuid, owner_id, entity_type, client_scope, compiler_version,
                   content_hash text, authorization_scope text,
                   version_vector jsonb   -- e.g. {"prospect": 812, "company": 344}
                   status, row_count, created_at, expires_at
result_set_items   result_set_id, ordinal bigint, entity_id text
                   pk (result_set_id, entity_id), unique (result_set_id, ordinal)
```
- `content_hash`, `authorization_scope` and `version_vector` are exactly the cache identity from §4.1 / §5.5 — one definition, reused. A scoped result set (People with company scope, Companies with people scope) records both entity versions; the staleness check compares the full vector, so a company-side write cannot be missed on a people result set.
- Normalized items, not ID arrays; indexed for `(result_set_id, ordinal)` paging and `(result_set_id, entity_id)` membership.
- Bound to owner and client scope; private schema or RLS + revocations; built in bounded batches with progress; TTL cleanup and capacity alerts.
- Page, count, pivot, export and bulk actions consume the same frozen items. If any component of the version vector has moved, show "results as of T" and offer refresh; never silently add rows.
- **Pivots:** See People / See Companies currently cap the scope at 250,000 companies and flag `scope_capped`. Once result sets exist, a scope that would exceed the cap is classified as a background result set instead of a truncated-but-flagged scope; the cap remains only as the interactive threshold.
- Classification happens before attempting a known-expensive interactive query; the 10-second timeout is a fallback for misclassification, not the normal decision path.

Exit gate: a 500-term search and an over-cap pivot both produce paginatable result sets without using the interactive pool for the long scan.

## 8. Phase 5 — Cancellation, deadlines and admission control

### 8.1 Cancellation
- Propagate `request.signal` to every Supabase query; verify PostgREST cancellation in Phase 0.
- If insufficient, move only the affected hot RPC/query paths to a direct server-side `pg` pool where the driver owns and cancels its specific query.
- No general route permission to call `pg_cancel_backend`; no ambiguous `application_name` matching.

### 8.2 Deadlines
Suggestions 3 s; listings and interactive counts 10 s; background chunks 30–60 s. Lower a function's timeout only after its shape passes its gate. Functions currently without any timeout (`linked_prospect_total_v1`, `prospect_filter_values_v3`, `search_prospect_export_v1`) get one in Phase 1.

### 8.3 Workload isolation and login roles
- **Today the import worker logs in as `authenticator`** (`PGUSER=authenticator` in `deploy/docker-compose.yml`) — the same login role PostgREST uses, carrying `statement_timeout = 120s`. Per-role connection limits cannot separate the pools until this changes.
- Create dedicated login roles: `prospect_import_worker`, `prospect_ops_worker` (and, if §8.1 chooses a direct pool, `prospect_interactive`), each with its own `statement_timeout`, `idle_in_transaction_session_timeout` and `CONNECTION LIMIT`.
- Each login inherits only a narrow NOLOGIN capability role such as the existing `prospect_importer` or a new `prospect_operator`. Never grant worker logins the ability to `SET ROLE service_role`.
- Privileged operations are exposed through audited, narrowly scoped functions with fixed `search_path`, explicit caller/scope checks and revoked public execution.
- Pools: interactive PostgREST pool; import-worker pool; operations/result-set worker pool. Size from measured CPU, RAM and connection behaviour; login-role connection limits are the DB-side backstop.
- In-process semaphore is a fast-fail guard only; with blue/green both slots run during a deploy, so DB-side limits are the authority. Add distributed admission if multiple replicas become normal.

### 8.4 Client behaviour
Controlled `429`/`503` with `Retry-After` before pool exhaustion; retry idempotent reads with bounded jittered backoff; never retry mutations without an idempotency key; never cache overload responses.

Exit gate: 20-user soak plus import, export and cancellation storm → zero acquisition timeouts; cancelled statements disappear within 2 s.

## 9. Phase 6 — Durable operations and exports

### 9.1 Dedicated operations worker
Separate process, pool and login role, reusing the import worker's queue primitives: `FOR UPDATE SKIP LOCKED` claim, lease and heartbeat, expired-lease recovery, progress/ETA, retryable vs permanent errors, cancellation, bounded transactions, audit log, retention cleanup.

### 9.2 Request idempotency
Client-generated request UUID per mutation enqueue, unique per actor/action/request UUID; action, content hash, authorization scope, exclusions and the version vector at freeze time kept as audit fields. Never deduplicate solely by content hash.

### 9.3 Frozen selection
Authorize → validate and hash → resolve IDs into `operation_job_items` (or reuse an authorized result set) → record exclusions and blocklist hits → freeze with the version vector and timestamp → mutate in bounded, retry-safe batches. The job never silently expands; the UI offers explicit re-resolve.

### 9.4 Export path
Direct streaming vs background chosen by estimated bytes as well as rows; requested columns only; keyset pagination, no per-page count; no whole-CSV accumulation in Next.js; large exports to private Storage with short-lived signed links and automatic expiry; Storage RLS, owner scope and service-role boundaries validated. Company export gets its own keyset function.

Exit gate: enqueue < 300 ms; retry does not duplicate work; affected IDs = frozen selection − exclusions − blocked; bounded memory during export.

## 10. Phase 7 — Counts, suggestions and maintenance

### 10.1 Client-company prospect counts
Prototype starting from the existing `prospect_index` count triggers that already maintain `companies.prospect_count/client_count` — introduced as a `FOR EACH ROW` trigger in `20260815010000` and replaced in `20260825000000` by three statement-level triggers over transition tables (`trg_sync_company_counts_insert/update/delete` → `sync_company_counts_statement()` → `recompute_company_counts_bulk()`): derive touched old/new `(client_id, company_id)` pairs from transition tables; cover insert, update, delete, company reassignment, blocklist removal, push and membership changes; compare set-based recomputation against a touched-pair delta; measure lock contention and import regression; adopt only under the 10 % budget; add to drift reporting with a repair function.

### 10.2 Suggestions
`prospect_value_suggestions` mirroring the company pattern; refresh after imports and on schedule; client-specific summaries only where measured; live table only with a typed, bounded search term; refresh time displayed.

### 10.3 Global totals
Maintained counters for operationally exact totals; `reltuples` only for explicitly estimated unfiltered totals; searched totals capped; timeouts applied.

### 10.4 Vacuum and statistics
Per-table autovacuum/analyze thresholds for `prospect_index`, `companies`, `client_prospects`, job items and result-set items; analyze after large imports/backfills; monitor dead tuples and estimate drift.

Exit gate: count drift zero; repair works; suggestions meet p95 and freshness; unfiltered company load p95 < 1 s.

## 11. Phase 8 — Regression gates (run from Phase 1 onward)

### 11.1 Correctness parity
≥ 30 shapes satisfying `grid = count = export = selected IDs = affected + excluded + blocked`, including classifier fields, location, Boolean, custom keys, list/client membership, ranges, negatives and combinations.

### 11.2 Plan assertions without planner dogma
Assert index-backed plans only for selective fixtures designed to be index-served; do not fail on a legitimately chosen seq scan for broad filters — enforce latency, rows examined, buffers and temp-file budgets there; verify sort indexes against the exact static order clause; compare material plan regressions, not raw cost numbers.

### 11.3 Scale scenarios
51 filters and 10,001 values reject; saved view above cap flagged; 10,000 exact domains; 100 interactive substring terms; 500 terms as a result set; over-cap pivot as a result set; broad country; negative-only; Boolean and custom; deep cursor pagination; 250,000-row export; 40,000-row push; 1,875-domain blocklist with high coverage; cancellation storm; import plus browsing; 20-user 15-minute soak; 40-user spike; data change between enqueue and execution; retry after lease expiry.

### 11.4 Product invariants
Cross-client duplicates permitted per identity policy; within-client duplicate prevention idempotent under retries; multi-list memberships preserved; deleting a list does not delete canonical prospects; blocklists affect only the intended client and protect future imports/actions; company ICP state and Date Contacted remain client-scoped; browser clients never receive service-role credentials.

## 12. Safe rollout

Per phase: expand schema → bounded backfill → shadow-compare counts and ID sets by content hash → small traffic slice → monitor latency, pool, errors, storage, write regression, drift → widen → remove old path after parity and rollback readiness.

Per release: migration order verification; Supabase changelog review for affected features; RLS and `SECURITY DEFINER` review; fixed `search_path` and explicit revocation from `PUBLIC/anon/authenticated`; Data API exposure review for new tables; forward-fix or rollback including invalid-index cleanup; backup confirmation; targeted tests, lint, type check, production build, authenticated E2E; before/after plan evidence; final diff review for secrets, unrelated edits and permission expansion.

## 13. Implementation sequence

Phase 0 evidence capture starts immediately and continues throughout the programme. Release 1A does not wait for the full synthetic staging generator because its changes are small, correctness-critical and independently testable.

### Release 1A — Immediate correctness hotfix

1. Route unscoped and scoped prospect exports through v4; add classifier/location parity; retire v1 only after parity.
2. Replace silent filter/value slicing with explicit structured rejection; validate saved views.
3. Add missing statement timeouts and actionable API errors.
4. Add focused parity tests and deploy this release independently.

Exit gate: no stale export path, no silent truncation and no untimed hot function targeted by the audit.

### Release 1B — Bounded interactive listings

1. Rewrite static sort branches.
2. Split People page and count.
3. Add capped/estimated total semantics.
4. Add cursor pagination and dependency-aware version-vector caching.
5. Evaluate the §6.7 Tier 1 columns (`full_name`, `first_name`, `last_name`, `personal_email`, `linkedin_url`, `company_domain`, `tag_text`) one at a time with the `20260901000030` precedent as the expected outcome; build each that passes; record a reason for any that is skipped. Then evaluate Tier 2.

Exit gate: bounded page/count plans, stable deep pagination, correct invalidation, and every audit-cited Seq Scan shape (plans A, F) either index-served or documented as a correct early-stopping scan.

### Release 1C — Immediate pool-collapse protection

1. Verify cancellation and propagate abort signals.
2. Add controlled admission/backpressure and client retry behaviour.
3. Separate the import worker's login role and pool.
4. Capture pool/cancellation load evidence.

Release 1C protects the interactive pool but does not claim to remove every root cause: synchronous bulk operations remain until Release 2.

### Release 2 — Large inputs and durable work

1. Durable exact-value filter sets and `prospect_index.normalized_domain`.
2. Rule-based classifier and normalized background result sets, including over-cap pivots.
3. Dedicated least-privilege operations worker.
4. Client request UUID idempotency and frozen selections.
5. Bulk resolvers on the complete compiler; retire prefilters/row functions only after parity.
6. Streaming/background exports.
7. Boolean vector experiment only if the Phase 0 term study supports it.

### Release 3 — Derived data and storage

1. Approved custom-value side table.
2. Conditional `all_data` restructuring only when TOAST/buffer evidence supports it.
3. Client-company counts with contention and drift testing.
4. Prospect suggestion tables and global-total improvements.

### Release 4 — Hygiene and capacity proof

1. Index-usage review and safe removals.
2. Autovacuum/analyze tuning.
3. Final pool sizing.
4. Full 20-user soak and 40-user backpressure rehearsal.
5. Staged production rollout with rollback/forward-fix rehearsal.

## 14. Completion definition

Ready for target scale only when: parity is 100 % across the catalogue; all interactive SLOs pass with and without a concurrent import; the 20-user soak has zero pool acquisition failures and zero unhandled server errors; the 40-user spike degrades only through controlled backpressure or background execution; a 500-term search and an over-cap pivot complete through durable result sets without starving interactive traffic; a 250,000-row export completes with bounded memory and correct authorization; bulk-operation retries and lease recovery do not duplicate mutations; imports, identities, blocklists, client/list memberships, ICP state and Date Contacted retain their invariants; every new index and high-volume function has saved before/after evidence; every privileged schema object has reviewed grants, RLS/exposure posture and scope checks; rollback or forward-fix procedures are documented and rehearsed.


