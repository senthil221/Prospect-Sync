# Prospect Sync — System-wide performance and reliability plan, v8

Date: 2026-09-05. Repository baseline: `417f67c`.

Status: **revised implementation plan; not implemented or capacity-certified.** The prior company-description fix is deployed. This document replaces v7 as the current forward roadmap and broadens the narrow company-description performance report. Historical reports remain evidence, not promises.

## 1. Decision and definition of success

Keep Supabase/PostgreSQL as the system of record. Build on the existing SQL compiler, durable sets, worker roles, streaming exports and blue/green deployment. Close their integration and operational gaps before adding another database or search service.

Deliver one coordinated programme covering search, counts, navigation, imports, exports, bulk operations, suggestions, storage, overload and recovery. Deliver it through independently reversible releases. **No honest plan can guarantee every unknown issue in one deployment.** Completion means the supported workload passes explicit correctness, performance and failure tests; unsupported loads receive a controlled outcome instead of a crash or misleading result.

The principal changes are:

1. One server-enforced query plan for every data view, including both pivot directions and client/list scopes.
2. Reusable, dependency-aware search work instead of repeatedly resolving the same text filters.
3. Bounded and fair scheduling across search, imports, exports and mutations.
4. Explicit live-versus-snapshot semantics, exact-count states and complete over-limit results.
5. Physical storage budgets, honest observability, recovery drills and representative capacity tests.

This plan does not authorize purchasing infrastructure, transferring production data elsewhere, granting new access, destructive operations or a production stress test. Those require the appropriate separate authorization. Defaults below are proposed initial operating policies, not measured optimal settings.

## 2. Evidence and holes to close

Previous live inspection: 681,085 prospects, 419,214 companies, approximately 11 GB PostgreSQL database on a 2-vCPU / 8-GB VPS. Re-inventory before implementation; these are dated measurements.

The deployed description preparation returned identical company membership for 51/100/150 phrases. Initial preparation measured approximately 7.3/14.9/24.1 seconds. Subsequent production People page-plus-count calls measured approximately 0.57/1.37/1.28 seconds. The larger lists were synthetic extensions of the supplied 51 terms, not independent customer workloads. Three concurrent cached backend HTTP reads completed in approximately 0.66–0.95 seconds. These are **not** end-to-end P95s or proof of sustained capacity. See [the measured report](company-description-search-performance.md).

| ID | Evidence in this checkout | Gap and required closure |
| --- | --- | --- |
| H01 | `lib/prepared-search.ts`, listing routes | Preparation is selected by a narrow description-value threshold. General classifier rules are not enforced by the main listing routes. Unify execution decisions on the server. |
| H02 | `app/api/companies/route.ts`, `workspace-scopes.ts` | Client-company and reverse-pivot paths remain separate; pivots clamp at 250,000 IDs. Add complete result-set execution without pretending a capped scope is complete. |
| H03 | `app/api/result-sets/route.ts`, `app/api/exports/route.ts` | Cached company membership is not a shared dependency across every downstream set/export. Authorize nested scopes consistently and reuse validated dependencies. |
| H04 | `worker/operations-worker.mjs` | Operations drain before exports, which drain before result sets. A continuing workload can starve another class. Schedule bounded work units with aging and shared resource limits. |
| H05 | Preparation migration | A large company preparation is one atomic statement with a 120-second worker deadline. Add resumable bounded work and a truthful snapshot contract; do not just extend the deadline. |
| H06 | Preparation migration and result-set retention | TTL and pending-job limits do not bound completed-cache size or cleanup cost. Add byte/item reservations, admission budgets, pins and incremental reclamation. |
| H07 | `lib/admission.ts` | Admission is per app process; the waiting array has a time limit but no explicit length limit. Browser abort is not proof that PostgREST stopped its SQL. Bound waiters and account for actual DB work. |
| H08 | `lib/observability.ts`, `app/api/health/route.ts` | Counters reset on deploy; 202 currently looks like ordinary success; readiness checks import worker but not operations/search work. Add journey metrics and separate dependency health. |
| H09 | Preparation builder `completed_at=now()` | Transaction-start time is being used as completion time. It can report an almost-zero build duration. Fix in a new forward migration and retain independent elapsed measurements. |
| H10 | `deploy/scripts/maintenance.sh` | Concurrent reindex failure falls back to blocking reindex; statement statistics are reset. Remove that fallback and retain bounded historical evidence. |
| H11 | `scripts/load-test.mjs` | Existing harness does not complete the new 202 workflow; 503 is excluded from unexpected errors regardless of target load. Measure successful journeys, queue delay and refusal budgets, not quick enqueues alone. |
| H12 | v7 and `docs/README.md` | Older assumptions about exact counts, filter limits, cancellation and release completion have drifted. Version route contracts and let current executable tests override historical prose. |

These are source-supported design gaps, not a completed security audit of the whole application. The 405 passing tests and successful deployment are useful baseline evidence; they do not close H01–H12.

## 3. Product and correctness contract

### 3.1 Preserve this application's actual identity model

- Preserve global canonical prospects and independent client/list memberships. Do not migrate to one canonical copy per client merely because a generic CRM template recommends it.
- Client membership and list membership are different relations. Retry/concurrent imports must not duplicate either. Removing a list/client link must not delete a global person or another client's membership.
- Preserve company identity normalization, client blocklists, ICP validation, Date Contacted and existing duplicate-review semantics.
- An agency client's ID is a data scope, not automatically a tenant authorization boundary. Preserve the actual approved-agency-user access model; introducing multi-tenant customer access would need its own authorization design.

### 3.2 One query identity

Introduce a versioned `QuerySpec` shared by the server planner and existing consumers. It contains entity, client/list scope, search, parsed filter AST, parent pivot specification, dependency versions, compiler version and server-derived authorization scope. Keep sort/cursor separate from membership identity; retain them in page identity.

Canonicalize only semantically commutative structures. Dedupe and sort literal OR-value sets where proven equivalent; preserve Boolean tree grouping, order-sensitive values, case rules, NULL/empty behavior and exact-tag versus substring matching. Never treat input as raw SQL.

Maintain two identities: logical membership hash and transport/reference identity. Resolving a stored filter set must preserve the logical content hash while separately validating its owner, scope, expiry and immutable content. Do not re-key logically identical searches on arbitrary transport UUIDs.

Time-relative predicates also depend on evaluation time and timezone. Freeze their effective cutoff for snapshots; for live queries use an explicitly bounded time bucket/expiry even when no records change. Otherwise a cached "eligible today" or "stale after 180 days" count can be wrong without any data-version increment.

All server routes validate the full nested query, including filter-set references inside company/people scopes. Read, count, detail, download, freeze and mutation handlers reauthorize their own operation. Client-provided owner IDs, versions or cache IDs never grant access. Use opaque public handles resolved by the server, not browser-trusted private execution fields.

### 3.3 Output contract

Use a discriminated response model, adapted to existing clients during migration:

- `ready`: rows, cursor, query ID, membership version, count state and freshness.
- `pending`: durable query ID, stage, polling hint and whether cancellation is available.
- `refresh_required`: a changed live result; do not quietly carry the old total forward.
- `capacity_limited`: bounded refusal, reason and retry guidance; no partial result represented as complete.
- `failed`: stable error code and retryability; no raw SQL or private data in the user message.

Count state is `exact`, `pending`, `estimated` or `capped`, not an ambiguous number. Keep existing exact-count behavior on cheap paths. For expensive counts, show rows plus "counting" only under the new explicit contract; do not silently replace an exact total with an estimate. A count must match the page's query and membership version.

The current parser permits 60 filters and 5,000 values per filter. Those are validation limits, not evidence that the worst cross-product is affordable. Add total request-byte, normalized-value-byte, AST-node/depth and aggregate-term budgets. Determine their initial values from the supported workload tests; don't inherit obsolete v7 numbers or silently slice input.

## 4. Route coverage: nothing is complete until its consumers are covered

| Journey | Required execution and consistency | Main integration points |
| --- | --- | --- |
| Global People | Server planner chooses bounded direct page or prepared membership; additional filters stay global-before-pagination | `app/api/prospects/route.ts`, `ProspectsWorkspace.tsx` |
| Global Companies | Same planner, count state and reusable membership | `app/api/companies/route.ts`, `CompaniesWorkspace.tsx` |
| Company → People | Resolve matching company IDs once, then apply People predicates; dependencies survive pages, export and selection | `workspace-scopes.ts`, company-scope RPCs |
| People → Companies | Resolve People membership, derive distinct companies, then apply company constraints; never widen to all companies | `parsePeopleScope`, company listing/result-set APIs |
| Client People / Client Companies | Retain the current membership definitions; do not substitute "companies with any prospect" for pushed client companies | `ClientsPanel.tsx`, client workspace RPCs |
| Lists / company details | Preserve list ownership and requested parent scope; bounded details and pagination | `app/api/lists/[id]`, `app/api/companies/[id]/prospects` |
| Suggestions | Debounced/cancelable, explicit scope, limited result size; cached dictionaries may lag but predicates do not depend on them | Both `filter-values` routes and suggestion RPCs |
| Export | Same authorized membership as the selected query; bounded memory and pinned dependencies | `app/api/prospects/export`, `app/api/exports`, company streaming path |
| Select all / bulk mutations | Freeze the intended complete membership plus exclusions; execution never re-runs a live predicate | `app/api/operations`, result-set and operation RPCs |
| Overview / client totals | Read maintained or version-cached aggregates; expose freshness rather than fan out to repeated full scans | `app/api/dashboard`, client summary functions |
| Coverage / Data quality | Budget upload/scan size, use jobs for expensive scans, separately authorize repair mutations | `app/api/coverage`, `app/api/data-quality` |
| Imports / reindex / deduplication | Independent idempotent work, bounded batches, version publication and drift repair | Import worker, import routes, reindex functions |

Every row requires a route-level test, a database equivalence test, an authenticated UI test where visible, and a overload/failure test. Merely creating a shared helper does not satisfy coverage.

## 5. Unified execution architecture

```text
Authorized QuerySpec → normalize + budget + classify on server
                          ├─ bounded direct page ─────────────┐
                          └─ durable dependency graph         │
                              company/people match set        │
                                  → scoped final membership ──┤
                                                             ↓
                             versioned page / count / pivot / frozen selection
                                                             ↓
                                                   export / authorized mutation
```

### 5.1 Server planner, not a frontend hint

Extend the existing classifier into a shared server-enforced planner. Input must include entity, operator, cumulative terms across filters, enabled text fields, Boolean AST size, negative-only patterns, custom fields, parent scopes, sort/count requirements and versioned offline cost classes. A 150-clause Boolean expression stored in one value must not look cheaper than eight plain phrases.

Use existing query statistics and staging plans to calibrate small stable rules. No `EXPLAIN` or expensive exact count on every user request. Cache plans by normalized shape plus classifier/compiler/index-calibration version, not by an assumption that "has an index" means cheap.

Route unsupported heavy combinations directly to preparation. If a nominally cheap read times out, allow at most one transition to the durable path after its prior execution is known to have ended or is conservatively budgeted until its DB deadline. Never issue an uncontrolled second expensive query on browser retry. If no correct prepared implementation exists for that operator, fail explicitly and mark that query family as an unresolved release blocker.

Keep the proven SQL compiler authoritative. Translate to direct predicates or set operations without changing semantics; preserve fallback functions only as measured, explicitly routed compatibility paths.

### 5.2 Reuse matching work across edits and consumers

Treat reusable text matching as a dependency of final results, not as an export-specific or Companies-specific computation. Store acyclic dependencies with ownership, content identity, reference pins, expiry and failure propagation. Dependents wait for their parents without occupying a database connection. Limit graph nodes/depth and reject cycles.

For common description searches, prototype an **admission-controlled term/subexpression membership cache** over the existing trigram/tag indexes:

- Key entries by field scopes, exact operator semantics, normalized term/AST, compiler version, authorization scope and relevant data versions.
- Evaluate only missing terms after adding a keyword to an existing list. Compose OR as union, AND as intersection, and exclusions against the explicit authorized/scoped universe. Preserve SQL NULL semantics with differential tests.
- Use private indexed membership rows initially; do not introduce a custom bitmap extension without demonstrated need. Broad terms can exceed their cache budget: evaluate those within a bounded job instead of caching millions of redundant IDs.
- Cache only sufficiently reused/admitted subexpressions. Cap its storage separately inside the overall disposable-search budget. Cold, unrelated queries still pay the matching cost.
- Promote only if the 51 → 100 → 150 edit sequence materially improves total database work (target at least 30% less cumulative execution time) without more than 10% cold-query regression, excess I/O or incorrect membership. If the prototype fails, ship the unified prepared path without this optimization and document the unmet first-search/edit latency target.

Do not reuse the rejected 451-MB compact-description experiment as a predetermined solution. A richer typed projection is justified only when measured TOAST/recheck costs and repeated query families pay for its synchronization, disk and write overhead. Keep descriptions separate from fields where matching across concatenation boundaries would create false positives. `pg_trgm` supports substring matching, but low-information patterns can still scan a whole index; full-text token matching is not a drop-in semantic replacement. [PostgreSQL trigram documentation](https://www.postgresql.org/docs/15/pgtrgm.html).

### 5.3 Do not prescribe a new search service prematurely

No Elasticsearch/OpenSearch, Redis, vector search, sharding or read replica is required for the first release. Consider a dedicated search engine only if optimized SQL/preparation fails the agreed cold-search target at certified concurrency and scale. Any proposal must include measured candidate latency, RAM/disk cost, incremental change feed, deletes, lag detection, rebuild, authorization, full-result enumeration and equivalence for substrings/Boolean/negatives. PostgreSQL remains authoritative for membership and mutations. Added infrastructure requires a cost/operations decision, not an automatic installation.

## 6. Scheduling, overload and cancellation

### 6.1 Resource isolation with fairness

Create a dedicated least-privilege search worker role/process; keep bulk mutations and exports out of its claim loop. This separates scheduling and credentials, not physical CPU/disk. Do not simply add another unbounded process on the 2-vCPU VPS.

Introduce a cross-process DB-work budget shared by search, expensive export and import phases. Initial staging policy: **one heavy DB work unit at a time** on the present VPS, with reserved capacity for bounded interactive reads. Inventory each work unit's actual SQL connections; worker-process count is not a concurrency budget. Test a second heavy permit only if mixed-load SLOs improve without memory, I/O or lock regression.

Use weighted fair scheduling and aging across search, mutation, export, import and maintenance classes. Start with a round of one eligible unit per class, prioritize work a user is awaiting, and promote aging jobs; tune weights from measurements. A class cannot drain to empty before others receive service. Interactive reads do not wait for this background queue.

Refactor full-job loops into resumable units. Aim for 1–3-second work units, bounded by a five-second quantum where feasible; keep the proven single-statement description build until its replacement passes parity. Do not claim preemption of an existing 24-second SQL statement. Snapshot capture and other unavoidable atomic units need separate declared deadlines and admitted resource reservations.

Claims use atomic `FOR UPDATE SKIP LOCKED` plus a lease, unique attempt/fencing token, worker identity and attempt limit. All progress/publish/failure writes require the current fencing token. Heartbeat/control work uses a tightly bounded separate connection so a busy data statement cannot prevent lease renewal. Reclaim only expired leases; a late worker cannot overwrite a successor's state. [PostgreSQL locking semantics](https://www.postgresql.org/docs/15/sql-select.html#SQL-FOR-UPDATE-SHARE).

### 6.2 Deadline hierarchy and refusal

Keep interactive SQL capped at ten seconds; normal accepted queries should finish well below it. Specify pool acquisition, SQL, HTTP and browser deadlines together so the caller does not time out first and launch a duplicate. Avoid a new per-request `pg` connection or a second pooler layered on PostgREST without need.

Bound the admission waiting array by length as well as duration. Add per-owner/job-class outstanding limits and global limits encompassing *all* work, not only description jobs. Query/poll admission must be cheap and have a small reserved budget so job status remains usable during overload. Reserve administrative/recovery connections; count each Supabase service pool separately rather than assuming Auth, Storage and PostgREST all share one pool.

Validate concurrency/deadline environment variables as positive bounded numbers and fail startup for invalid settings. Budget the overlap of both app slots during deployment. On HTTP 429/503, expose typed capacity errors, jittered `Retry-After`, a finite retry budget and one in-flight request per query in each tab. Cap subscribers/polls per owner; do not deduplicate requests across users in an unsafe response cache.

### 6.3 Cancellation truth

Aborting browser polling releases that subscriber; it does not automatically cancel a shared job or its database statement. Add an explicit cancel action for an owned, unpinned disposable search. Cancel a dependency only when no live dependent/subscriber needs it; durable export/mutation jobs keep their own consent and cancellation policy.

Cancellation of DB work must use a vetted worker control path tied to job ID, attempt token, connection/backend identity and execution start, never an arbitrary browser-supplied PID. Test PostgreSQL cancellation separately from HTTP abort. If cancellation cannot be guaranteed on the deployed PostgREST version, account for the statement until its hard deadline; do not claim v7's two-second DB cancellation gate passed.

## 7. Storage-bounded caches and lifecycle

TTL is insufficient. Add physical item/byte accounting, admission reservations and incremental cleanup.

Initial staging budgets for the present 100-GB disk:

- Disposable search membership/subexpression cache: 2 GiB global soft budget, 4 GiB hard budget; 512 MiB soft share per owner, borrowable only with global headroom.
- Optional term cache uses at most 25% of that budget; it is not an extra allowance.
- Snapshot input staging: a separate maximum 4 GiB reservation pool, one admitted capture initially.
- Durable export/operation dependencies are separately metered and pinned. Define their reservation from the tested maximum export/push footprint before enabling them; do not let "pinned" mean unlimited.
- Preserve at least the greater of 20 GiB or 20% disk free, plus specifically reserved WAL, backup, migration and index-build space. Reject new expensive jobs if projected peak violates headroom; existing acknowledged mutations get recovery priority.

These are starting limits to validate, not measured per-row sizes. Estimate with actual table+index bytes per item, reserve pessimistically before work, and reconcile during every committed batch. A single atomic build needs a conservative upper bound before execution because a batch-time quota cannot interrupt its growth safely. Sample physical sizes and free disk independently: row deletion can free reusable pages without immediately shrinking files.

Evict expired/unpinned least-recently-used disposable generations in bounded item batches, then remove metadata. Never cascade-delete millions of items in the request path. Reader/export pins have leases and bounded renewal; cleanup skips active dependencies and recovers abandoned pins. Update last-used timestamps at coarse intervals to avoid hot-row writes on every poll.

Use unique active-build identity for single-flight per owner/authorization/content/version. Prefer per-key locks plus a brief global budget-reservation transaction over serializing every cache hit behind a global advisory lock. Keep ready reads lock-light. Distinguish transient failures from invalid queries; finite backoff and a circuit breaker prevent repeated expensive failures.

Current 24-hour TTL may remain for reusable memberships, but disk pressure can shorten disposable retention. Permission revocation always overrides TTL. Never expose stale cached results merely because recomputation would be expensive.

## 8. Results during writes: live queries versus durable snapshots

### 8.1 Live mode

Use a small dependency registry: company searchable attributes, company/prospect relationships, prospect searchable attributes, relevant client/list memberships, and authorization policy. Attribute edits invalidate membership; count-only metadata changes should invalidate displayed aggregates without discarding expensive text matches unnecessarily.

Version changes must be transactionally tied to the actual mutation/derived-data publication. Do not increment on no-op updates or every imported row. If an outbox maintains a projection, track publication of a **contiguous committed** watermark, with gap handling, tombstones and replay idempotency; `MAX(sequence_id)` is not a safe claim that earlier transactions committed. Benchmark version-counter contention and import throughput.

For a multi-batch live build, record the relevant start vector, check dependencies at each checkpoint and before publishing. A changed dependency invalidates that attempt. Retry at most once automatically; repeated changes return an explicit refresh/snapshot option rather than rebuilding forever. Never publish mixed-version IDs as a current exact answer.

### 8.2 Snapshot mode for stable bulk work and write-heavy searches

Introduce a clear product mode: "Matching records as of [capture time]". This is proposed new behavior, not an assertion about today's exports. Membership freeze is not the same as freezing every field value.

Capture the IDs and **all inputs required to evaluate the chosen predicates/sort and render the requested snapshot columns** into a private, job-owned input stage in one admitted, bounded database statement/snapshot. For selective queries capture the valid candidate universe first; for broad negatives it may be the whole authorized universe. Include required relationship inputs. Reserve bytes before capture and verify the ten-million-wide-field case cannot sneak past an ID-only estimate. Render snapshot pages from captured values; a separately opened live detail panel must identify its newer data rather than pretend to be the same snapshot.

After atomic capture commits, filter and assemble results from immutable staged inputs in resumable batches. New imports do not force restarts. This avoids holding a read transaction open for the entire potentially multi-minute job. If capture itself cannot meet its declared deadline/disk budget at target scale, this design has not passed: optimize its input projection or obtain a separately approved resource/replica strategy; never silently take independently committed chunks and call them one snapshot.

For exports choose and display one contract: default to matching membership and requested exported values captured at the same snapshot, then stream immutable parts. If a product decision chooses "frozen membership, current values at export" instead, label it and test it explicitly. Match counts and downloaded-row counts must refer to the same membership. At download and mutation execution, recheck current authorization; a snapshot does not override revocation.

For bulk mutations, freeze intended IDs/exclusions and revalidate current safety rules such as blocklists and client ownership. Report applied/skipped/failed counts against that frozen selection. Never add newly matching IDs during a retry.

Independent Read Committed statements can observe different data; Repeatable Read guarantees a transaction snapshot but has operational costs if kept open. The staging contract above is an engineering choice to bound that lifetime. [PostgreSQL transaction isolation](https://www.postgresql.org/docs/15/transaction-iso.html).

## 9. Counts, pagination, suggestions and large results

- Keep page fetching independent of an expensive exact count where the versioned output contract permits it. Cache exact counts by membership/dependency version, and reuse prepared-set cardinality when no further predicate changes membership. Never label a planner estimate exact.
- For over-250,000-company pivots, build/use a complete authorized result set and join it directly; no giant browser ID array or huge `IN (...)`. Until this path passes, retain explicit capped warnings and prevent "all matching" from meaning a silent subset. Distinguish unsupported input size from a legitimate large output size.
- Use stable ordering with explicit NULL placement and ID tie-breaker. Retain shallow OFFSET when measured within budget. For deep traversal, add signed query-bound cursors with the full ordering tuple and version, or ordinal pagination over a frozen set. Do not promise cursor pagination is constant-time for every selective join or unindexed sort. Avoid replacing proven incremental-sort plans with redundant composite indexes.
- Live sort-key changes require refresh/version handling to avoid skipped or duplicate rows across pages. Frozen sets support stable ordinal pages and arbitrary page jumps within their declared ordering. Exports already using keysets must not regress to OFFSET.
- Suggestions get a separate low-latency budget and bounded top-K results. Use typed, scope-aware dictionaries for common values; build custom-field summaries only for demonstrated demand. Global dictionaries cannot masquerade as client-specific counts. Display dictionary freshness; allow typed values absent from the dictionary.
- Maintain company/client/global aggregates through existing batched mutation paths where possible. Add drift reconciliation and repair jobs with budgets. Do not add a separate per-prospect count query to every company row.
- Select only displayed fields in listing pages; fetch raw import data and deep details on demand. Keep export rows streaming, file manifests/checksums verified, and expired downloads explicit.

## 10. Observability, maintenance, health and recovery

### 10.1 Measure the user journey

Extend `lib/observability.ts` with request/query/job correlation IDs, query-family labels, compiler version, cache hit/miss, queue wait, build duration, first page, count completion, bytes/rows, cancellation outcome and typed failure. Avoid logging full filters, emails, row values or credentials. Bound metric label cardinality; do not use raw query IDs as histogram labels.

Retain bounded aggregated histograms and structured logs across app-slot restarts. A 202 is `accepted/pending`, not a completed fast search. Count overload refusals and user-visible failures even when retry later succeeds. Sample `pg_stat_statements` deltas rather than resetting it before evidence is retained.

Fix completion timestamps with `clock_timestamp()` in a forward migration; measure worker elapsed duration using a monotonic clock as well. `now()` is transaction-start time, so subtracting it from a prior claim timestamp undercounts a long single-statement build. [PostgreSQL date/time semantics](https://www.postgresql.org/docs/15/functions-datetime.html#FUNCTIONS-DATETIME-CURRENT).

Initial alerts: preparation P95 >30 seconds, oldest runnable search >60 seconds, failed searches >1% over a meaningful sample, repeated lease expiry, DB/pool saturation, reindex drift, cache above soft budget, and disk approaching reserved headroom. Tune windows using observed traffic; low-volume single events need explicit critical alerts rather than misleading percentages.

### 10.2 Health is more than app HTTP 200

Separate liveness, app/core readiness and background-feature readiness. Check search/operations and import worker heartbeats, queue age, available capacity, schema compatibility and projection freshness. A search-worker outage should mark preparation degraded and avoid accepting endless new jobs, without needlessly taking healthy ordinary browsing offline. Deployment gates check required feature readiness and the exact image version. Detailed health/metrics stay authenticated; public health exposes only minimal state.

### 10.3 Safe database operations

Remove automatic fallback from concurrent to blocking `REINDEX`. Failure should stop that maintenance action and alert. Use statistics/bloat/plan evidence to choose reindex or ANALYZE targets; no weekly rebuild solely because a table is large. Tune autovacuum per measured churn, especially disposable membership tables, and track temp spills and long transactions.

Do not globally raise `work_mem` to fix one sort: it can be consumed by multiple operations and concurrent sessions. Set workload-local budgets from measured peak memory and account for parallel workers. [PostgreSQL resource settings](https://www.postgresql.org/docs/15/runtime-config-resource.html).

The current migration runner wraps each file in a transaction. `CREATE INDEX CONCURRENTLY` therefore needs a dedicated resumable nontransactional deployment step with preflight disk checks, lock/statement bounds, validity verification and explicit cleanup of failed invalid indexes. Never place it inside the ordinary runner and assume it is online. [PostgreSQL index-build restrictions](https://www.postgresql.org/docs/15/sql-createindex.html).

Inventory pinned PostgreSQL/Supabase components and supported patch upgrades; stage upgrades independently of query changes. Do not replace this application's customized deployment with the latest upstream Compose file. Current upstream self-hosting gateway defaults changed; assess applicability to this Caddy-based stack instead of blindly adopting them. [Supabase self-hosting change](https://supabase.com/changelog/48048-self-hosted-supabase-envoy-becomes-the-default-api-gateway-b). The reviewed extension-version policy explicitly excludes self-hosting. [Scope of that policy](https://supabase.com/changelog/extension-version-pinning-ignored).

### 10.4 Recoverability is a gate

Verify backup timers, offsite success, retention, encryption/access controls and actual restore on an isolated environment. A readable dump manifest is not a restore drill. Include authentication configuration, storage objects and required deployment secrets through their existing secure recovery process, not just application tables. Do not assume offsite backup is configured because `backup.sh` supports it.

Record actual RPO/RTO from the drill. Set business targets before certification; nightly-only backups cannot promise minute-level recovery. If required, propose WAL/PITR separately with storage and operational costs. Disposable search caches may rebuild; pinned selections and acknowledged operations require an explicit durable recovery policy.

## 11. Capacity and acceptance tests

### 11.1 Certification tiers, not invented capacity

**Tier A:** current-scale data and 1/3/5 active users on the present VPS, including different cold searches and normal browsing during an import/export. This is the immediate reliability target, not a claim already passed.

Define the arrival envelope as well as user count. Initial Tier A certification fixture: up to three ordinary page/suggestion requests per second in aggregate, one new broad description search per minute sustained, and a separate burst of five distinct 150-term cold searches. These are explicit initial assumptions, not measured agency usage. Record observed real peak rates in V8-01; if they exceed this envelope, expand the test and resource plan rather than claiming Tier A covers them.

**Tier B:** retain v7's intended 1.5-million-prospect / 750,000-company dataset and 20-user sustained workload, with a 40-user overload test. Passing Tier A does not certify Tier B. If Tier B fails on 2 vCPUs, identify the bottleneck and present the measured hardware/architecture options rather than weakening the test or calling it complete.

Generate representative staging data with skew, realistic description lengths and missingness, concentrated large companies, varied client overlap, custom fields and blocklists. Use synthetic data by default. Any production-derived copy needs approved destination, access and sanitization. No cache flush, restart, write-load or large soak against production as part of this plan.

### 11.2 Required test matrix

1. Supplied 51 phrases; separate realistic 100/150 lists; the synthetic expansion as a repeatable regression case. Description on/off, common abbreviations, Unicode, punctuation, missing text, duplicate values, phrases, OR/AND/NOT and exclusions.
2. Few expensive filters, many cheap filters, aggregate term count across filters, a large Boolean expression in one value, broad negatives and selective positives, custom fields and exact bulk domains. Test 60/61 filters and 5,000/5,001 values under current limits; reject request/AST over-budget cases before SQL.
3. Both pivot directions, client and list scopes, no matches, high-match results, and 249,999/250,000/250,001 company membership. Verify complete-result path, flags, all-matching semantics and exact totals.
4. Add/remove/reorder terms and revisit saved views; prove permitted cache reuse, invalidation, owner separation and stable UI selections. Test GET/POST equivalence, long request bodies, interrupted polling and changed authorization.
5. Company edits/deletes, imports and relationship changes during enqueue/build/page/count/export/freeze. Verify live invalidation and snapshot contracts independently. Compare full membership digests, not just identical row counts.
6. Kill/restart a worker, expire a lease, run a late old attempt, cancel a parent, revoke a download, fill cache/disk reservations, break the backend connection and replay a mutation request ID. No double application, mixed snapshot or silent partial file.
7. Sustained different-user/different-query load; simultaneous cold misses; shared-cache stampede; pagination while a 150-term build runs; import + 250,000-row export + browsing; 40,000-record client push in staging.
8. Authenticate through the actual Next.js → PostgREST path and finish pending jobs. A backend service-role RPC test is supplemental, not an end-to-end pass. Test real browser rendering, keyboard operation, selection and retry states.
9. Ordinary request latency during maintenance, cleanup, backup and blue/green overlap. Test no blocking reindex fallback and the nontransactional index-runner recovery path.

Extend the existing load harness: separate HTTP latency from **time to usable result**, follow 202 to a terminal result, count incomplete jobs as failures, report refusals at target load, use distinct sessions/owners, and include both think-time users and bounded arrival-rate bursts to avoid hiding queueing. Explicitly opt in to staging writes. Recognize that search GETs can now create derived cache jobs; "GET-only" is no longer a zero-write guarantee.

### 11.3 Proposed release gates

| Measure | Gate at the declared certification tier |
| --- | --- |
| Exact membership, permissions and mutation idempotency | 100% fixture/differential parity; zero confirmed scope leaks or duplicate application |
| Ordinary page, including cached prepared membership | End-to-end P95 <2 s, P99 <4 s |
| Complex prepared page after readiness | P95 <3 s, P99 <5 s; exact count pending separately if contract says so |
| New 51/100/150-term search | Job acknowledgement P95 <500 ms; usable-page P95 <30 s with no prior heavy-job queue; separately measure queue+build latency under mixed load |
| Five distinct cold 150-term searches | All five reach correct usable results within 150 s at Tier A, while ordinary browsing retains its SLO; this burst is not five instant searches |
| Suggestions | P95 <500 ms within the declared scope/freshness contract |
| Target-load reliability | Zero unhandled 5xx/timeouts and zero unexpected capacity refusals in acceptance runs; no unfinished admitted jobs |
| Overload tier | Explicit bounded backpressure, no OOM/pool collapse, every admitted job terminal or explicitly resumable |
| Fairness | Every eligible background class receives work within the configured aging bound; Tier A first-progress wait P95 <15 s sustained, ≤30 s in the cold burst after bounded-unit scheduling is enabled |
| Mixed import/export/browsing | Ordinary page P95 <3 s; import throughput regression <10%; correct complete export with bounded memory |
| Storage/recovery | Quotas respected including indexes/staging; acknowledged-job recovery and restore drills pass |

These are targets, not present measurements. The first-search and queue targets must be evaluated together; accepting twelve cold 24-second jobs onto one serial worker cannot magically give all twelve a five-second start. Admission must reflect the certified rate or the hardware/scheduler must change. At the sustained Tier A arrival envelope, also require queue+build+usable-page P95 <60 s; report the five-query burst separately so it cannot be hidden inside a good average. Tier B needs an explicit cold-search arrival rate before its test can be signed off.

Run each performance profile at least three times; include warm and cache-miss cases. Use at least 1,000 successful samples per common query family for percentile gates and report sample size/confidence; expensive cold jobs get a separately reported bounded sample, not an invented P99. Include a two-hour mixed soak and a cleanup/TTL-boundary rehearsal. Retain raw timings, plans, versions and hardware details, with sensitive values removed.

## 12. Implementation packages and dependencies

| Package | Deliverables | Dependencies and exit evidence |
| --- | --- | --- |
| V8-01 — Evidence and safety | Journey metrics; real completion timestamps; feature health; capped admission waiters; maintenance fallback removal; corrected load harness | First. Forward migrations and source/runtime tests. No new heavy search architecture yet. |
| V8-02 — Shared contract | QuerySpec, canonical identity, recursive authorization, typed response/count states, complete route inventory and compatibility adapters | V8-01. Differential fixtures across all route families; old app/new schema compatibility. |
| V8-03 — Bounded lifecycle | Quotas/reservations/pins; attempt fencing; typed failures/cancellation; fair scheduler and search role; background resource budget | V8-01/02. Disk-pressure, worker-death, late-attempt and starvation tests. |
| V8-04 — All-path execution | Server planner; prepared People/Companies/client/list/reverse-pivot execution; shared dependencies for export/selection; complete over-cap path | V8-02/03. Every row in §4 passes; no giant ID transport or repeated parent scans. |
| V8-05 — Consistency and first-search efficiency | Dependency versions; immutable snapshot input stage; resumable evaluation; bounded term-cache experiment; targeted indexes/projections only when justified | V8-03/04. Concurrent-write parity, snapshot/expiry recovery, cold/edit-sequence measurements. |
| V8-06 — Count/suggestion/storage finish | Explicit deferred exact counts; measured deep-pagination changes; suggestion/aggregate summaries; vacuum/statistics and safe index-runner work | Can develop after V8-02 but release only against V8-04/05 contracts. Drift and memory/maintenance tests. |
| V8-07 — Certification and rollout | Tier A then Tier B load evidence; authenticated UI; migration/worker recovery; restore drill; capacity report and rollback rehearsal | All preceding gates. Every failed/skipped gate stays visible; do not relabel deferred work completed. |

One implementation programme, several small compatible releases. The same approved programme can continue through these gates without re-planning each feature, but a failed gate changes the implementation—not the definition of success. Preserve historical immutable migrations; create new migration files through the Supabase CLI. Read installed Next.js documentation before route/component changes.

Estimate effort only after V8-01/02 establish query coverage and staging readiness. This is multi-release engineering, not a credible single-patch promise. Staging access, authorized browser login, infrastructure budget if Tier B requires it, and business RPO/RTO remain inputs—not reasons to postpone the unblocked code and test work.

## 13. Rollout, rollback and completion checklist

Add independent feature flags for planner routing, dependency reuse, snapshot mode and term caching; default off until their schemas/workers are ready. Compare selected old/new results on synthetic/staging workloads; bounded production shadow reads only with explicit load approval. Never shadow mutations.

Migration order: expand private schema/contracts → deploy compatible workers → enable metrics/quotas → deploy API adapters → enable one read query family → all read families → export/freeze consumers → optional cache optimization. Validate minimum schema/worker capabilities at startup. Maintain worker claims that old/new deployments cannot both own.

For rollback, turn off optional optimizations first. Stop admitting new incompatible jobs, drain or fence/recover active work, then switch the app image. Leave expanded schema/data until old consumers are gone. Do not enable a fallback known to exceed the interactive budget; use typed degraded responses instead. Pinned/frozen jobs survive rollback with a compatible worker or remain visibly resumable. Rehearse this, including a worker running during slot switch.

Completion requires checked evidence for:

- [ ] H01–H12 resolved or explicitly rejected with measured rationale and a user-visible remaining limitation.
- [ ] All §4 route consumers use the authorized contract; all §11 correctness tests pass.
- [ ] A stated certification tier passes the latency, fairness, capacity, refusal and mixed-load gates.
- [ ] Search first-load latency and reuse are measured separately; no 202 masquerades as a completed search.
- [ ] No unbounded waits, cache growth, dangling pins, mutation retry loops or blocking maintenance fallback.
- [ ] Authenticated browser flows, failed/expired/retry states and table-state preservation verified.
- [ ] Backup/restore and app/schema/worker rollback drills recorded; RPO/RTO stated honestly.
- [ ] Report lists shipped commits, applied migrations, test datasets, measurements, resource cost and remaining limits.

If a target fails, the final report must say which one and why. "All tests green" and "10/10" are not substitutes for this checklist.

## 14. Mobile — last, as requested

Desktop workflows and backend correctness/capacity take priority. After those gates pass, verify preparation, pagination, filter editing, cancellation, retry and download behavior on narrow screens and real mobile hardware. Keep table rendering bounded and inputs usable; avoid background polling storms when returning from a suspended tab. Do not launch a visual redesign or add mobile-only features as part of the database programme. Core keyboard/accessibility correctness remains required throughout, not deferred to mobile QA.
