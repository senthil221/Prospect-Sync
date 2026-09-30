# Database production-readiness programme

Status: active engineering programme, prepared 2026-10-01 from repository
`cfce643`. This is a dependency map and release backlog. It is not a claim that
the whole application has been audited, load tested, or certified for a future
record count.

Prospect Sync's product is the People and Companies database. Email
verification, ICP checks and reply blocklisting are downstream capabilities:
they may read or publish database state, but they must not define a second
identity, query, authorization, or workload-control model.

## Current measured snapshot

The following is a read-only production sample, not a benchmark:

- PostgreSQL 15.8, about 13 GB of database storage and `max_connections=100`.
- `pg_stat_user_tables` estimated approximately 826,496 `prospects`, 826,694
  `prospect_index` rows, 446,524 `companies`, 871,154 `client_prospects` and
  228,750 `client_companies`. These are planner estimates, not exact counts;
  the small difference between the first two values is not evidence of index
  drift.
- Main public tables had recent `ANALYZE` timestamps. One sample saw about 12
  aggregate connections and they were idle. That is neither a peak observation
  nor capacity proof.
- Since the 2026-09-01 `pg_stat_statements` reset, aggregated function shapes
  recorded People v13 at 470 calls / 410.73 ms mean / 9,732.57 ms historical
  maximum; People v12 at 1,866 / 524.29 ms / 94,607.04 ms; prospect filter
  values at 80 / 770.97 ms / 8,278.41 ms; and company filter values at 127 /
  527.34 ms / 10,987 ms. These samples span deployments and dataset sizes.
  They identify query families to measure next; they do not establish current
  p95 latency or explain a particular timeout.
- `run_queue_unit_v1` has about 2.145 million calls at 0.62 ms average, but this
  includes empty polling. It is not background-job throughput evidence.
- The production `prospect-backup.service` last exited with status 1 at
  2026-09-30 09:36:52 IST and is currently failed. Its sanitized journal for
  the surrounding 30 minutes contains 12 remote `Quota exceeded` / requests per
  minute / HTTP 403 events and no `storageQuotaExceeded` or `invalid_grant`
  event. That supports remote API request-rate quota as the present failure,
  rather than storage capacity or OAuth, but does not prove whether an earlier
  offsite copy exists. A successful offsite verification plus an isolated
  restore proof is a critical production-readiness gate.

No customer rows, filter values, SQL text, credentials, write load, stress run,
worker restart or restore was used for this snapshot.

## Dependency map

| Layer | Authoritative paths | Consumers and contract |
| --- | --- | --- |
| Canonical records | `public.prospects`, `public.companies` from `20260807000000_initial_schema.sql` | A person/company identity is global. Client or list removal must not delete another membership or the canonical record. |
| Memberships | `public.client_prospects`, `public.client_companies`, `public.lists`, `public.list_memberships`, company import memberships | Client, company, list and import membership are distinct facts. Imports, pushes, removals and recently-added batches depend on them. |
| Search projections | `public.prospect_index`, `public.company_summaries`, reindex functions and backlog | Listings and filters may read projections; canonical writes must publish/invalidate projection state before a completed mutation is reported as fresh. |
| Query input | `lib/prospect-filters.ts`, `lib/workspace-scopes.ts`, `lib/filter-sets.ts`, `lib/client-workspace-completeness.ts` | Bounded parsing, stored-set ownership, client completeness and parent pivots are server contracts. UI payloads do not grant scope. |
| Interactive People | `app/api/prospects/route.ts` → `search_prospect_workspace_v13` or the guarded cursor RPC | Master/client listing, counts, sorting and Company → People navigation. Client views inject the complete/incomplete partition on the server. |
| Interactive Companies | `app/api/companies/route.ts` → `client_company_workspace_v2`, `filter_companies_v4` or prepared company listing | Master/client listing and People → Companies navigation. Client company membership must remain explicit rather than inferred from any linked person. |
| Durable membership | `app/api/result-sets/route.ts`, `lib/result-sets.ts`, `prospect_results.result_sets`, operations worker | Exact count and all-matching actions freeze authorized IDs. The final server-applied question must be authorized, hashed and stored consistently. |
| Exports | `app/api/prospects/export/route.ts`, `app/api/companies/route.ts`, `app/api/exports/route.ts`, `lib/export-runner.ts` | Streaming and background exports must enumerate the same membership as the screen and keep memory bounded. |
| Mutations | client prospect/company routes, `app/api/operations/route.ts`, frozen operation functions | Explicit IDs or an owned frozen set; retries must be idempotent and must not re-resolve a changed live query. |
| Imports and repair | people/company import routes, import worker, completion RPCs, reindex backlog | Staged, resumable writes publish memberships and data versions. A failed completion remains diagnosable and recoverable. |
| Summaries and health | dashboard/client summary RPCs, `app/api/data-quality/route.ts`, `app/api/health/route.ts` | Summaries expose freshness; health distinguishes app, database and worker dependencies without running a full scan. |
| Email verification addon | verification routes, `prospect_verification.*`, verification worker | Reads an authorized/frozen People scope and labels the unchanged work email. It receives bounded capacity and does not exclude records automatically. |
| ICP addon | ICP routes, `icp_validation_*`, ICP worker | Reads selected client companies and writes scoped verdicts/validation state. Incomplete Info remains a database partition, not a second company store. |
| Reply blocklist addon | integration routes/worker, `prospect_integrations.*`, `public.client_blocklist` | Maps provider replies to one client and publishes block entries. Tombstones, account generations and manual removal remain independent of search membership. |

The current process layout is PostgreSQL/PostgREST plus Next.js, an import
worker, operations worker, verification worker, ICP worker and integration
worker (`deploy/docker-compose.yml`). Separate processes improve ownership and
recovery, but they still compete for the same PostgreSQL CPU, I/O and connection
budget.

## Query-contract boundaries found in the current code

- People result sets support a `companyScope`. A company result set carrying a
  `companyScope` is rejected explicitly by `app/api/result-sets/route.ts`.
- Durable result sets have no `peopleScope` contract. The Companies UI refuses
  a background single-file export under a People pivot instead of dropping the
  pivot. A general People → Companies frozen-membership path remains backlog.
- The durable Company builder compiles filters but does not independently apply
  its stored `client_scope`. Client-scoped result-set and background-export API
  questions are therefore normalized with the established
  `__company_client_ids contains <client>` predicate before authorization,
  hashing and persistence. A contradictory caller filter is retained and
  intersected; it cannot replace the server-owned scope. A read-only production
  check found zero currently stored client-scoped Company sets lacking this
  predicate. That does not establish historical immunity or full filter parity.
- `__company_client_ids` uses `client_companies`, matching client Company
  membership. Per-client `__company_coverage` semantics have not yet been
  proved equal between the interactive client workspace and the general
  compiler; that catalogue case remains P0.
- The people-per-company limit is represented by
  `__max_people_per_company`; the current durable People builder has an explicit
  ranked-candidate path in
  `20260924205130_client_workspace_feature_pack.sql`. It needs equivalence
  coverage before broader planner routing.
- The interactive People route does not add the client completeness predicate
  inside a nested `companyScope`; the originating client Company screen also
  submits that hidden predicate only to its own listing request. This package
  keeps background behavior equal to the current People listing and records
  parent-scope completeness as a parity question. It must be resolved across
  listing, count, export and selection together.
- An empty `/api/result-sets` request remains forbidden even for a client. A
  server-injected completeness filter cannot turn an accidental empty request
  into a full client-database build.

## Regression matrix

`Present` means the named evidence exists in this checkout. `Package` means the
current bounded change covers it. `Required` or `Gap` means it remains a release
gate; it is not implied by a passing build.

| Journey | Code contract | Unit/component evidence | SQL equivalence/recovery | Authenticated UI | Live evidence |
| --- | --- | --- | --- | --- | --- |
| Global People | Present: People route and v13/cursor RPCs | Present: filter, cursor and failure-mode tests | Present for selected compiler/cursor contracts; full catalogue required | Required: fresh multi-filter, paging, count, pivot | Historical aggregate only; no current p95 |
| Global Companies | Present: Companies route and v4/prepared paths | Present: company filters, pivot and export tests | Present for selected filter/pivot fixtures; full catalogue required | Required: filters, paging, People pivot | No workflow run in this package |
| Client People / Companies | Present: client scope plus membership RPCs | Present: client operations and Incomplete Info tests | Present: Incomplete Info segregation fixture | Required: normal/incomplete partition and enrichment transition | No workflow run in this package |
| Company → People | Present: `companyScope` carried by listing/export/result set | Present: scope/auth/result-set tests | Partial: selected prepared-search fixtures | Required: result parity through page, exact count, export, all matching | Prior single journeys exist in the v8 ledger; not repeated here |
| People → Companies | Present for interactive listing; durable membership unsupported | Present: pivot honesty tests | Gap: complete frozen-set equivalence | Required: listing plus bounded export behavior | Not certified |
| Exact count / all matching | Package: client completeness and Company membership normalized before authorize/hash/store | Package: behavioral normalization, contradictory Company scope, idempotency, identity and guard-order checks | Package fixture compares complete/incomplete People and Company interactive IDs/counts with built sets; exact-head CI run pending | Required: normal and Incomplete Info all-matching actions | Read-only check found no stored affected Company sets; no writes performed |
| Streaming/background export | Present: separate bounded paths | Present: streaming export tests | Partial: result-set/export worker fixtures | Required: downloaded IDs/fields equal selected query | Not certified under concurrent import |
| Imports / push / membership removal | Present: staged routes and bounded workers | Present: import, client operation and retry tests | Present for selected import fixtures; concurrent retry catalogue required | Required: resume, duplicate and removal journeys | No write/recovery drill here |
| Blocklist | Present: scoped bulk/share/reply paths | Present: blocklist and Smartlead tests | Present for selected migrations; account/retry recovery required | Required: add/update/delete/export/share/reply sync | Addon, not a core-query certification |
| Email verification | Present: frozen selection and dedicated worker | Present: provider, worker and bounded-run tests | Present for selected run/reconcile fixtures | Required: create/pause/resume/reuse/result labels | Addon, not a core-query certification |
| ICP | Present: selected company queues and worker | Present: ICP route/model/clear tests | Present for selected queue and selection fixtures | Required: selected run, review and retry | Addon, not a core-query certification |
| Health / backup / restore | Present: health route and deployment scripts | Present: failure visibility and backup script tests | Restore SQL exists | Required: operator-facing degraded states | **Red:** latest run hit remote request-rate quota; remediation, offsite-copy verification and isolated restore remain open |

## Ranked implementation backlog and release gates

### P0 — close query parity defects before expansion

1. Apply server-owned client completeness to result-set filters before filter-set
   authorization, content hashing and persistence; retain the caller-intent
   guard. This package implements that item.
2. Run the extended disposable SQL equivalence fixture in exact-head CI. It
   compares client interactive membership with the actual result-set builder
   for complete and incomplete People/Company slices, includes out-of-client
   Company controls, and verifies unchanged Master People membership.
3. Decide parent-pivot completeness once, then implement the same rule in
   People listing, count, export and result-set creation. Do not patch only one
   consumer.
4. Catalogue every supported filter/operator/scope combination and make each
   consumer either preserve it or return a stable unsupported error.
5. Prove or correct per-client company-coverage semantics between
   `client_company_workspace_v2` and the general Company compiler before
   certifying client Company result sets beyond the covered fixture catalogue.

Gate: identical ordered ID digest (or identical membership digest when order is
not part of the contract), count state and authorization outcome across listing,
export and frozen selection. Existing features pass unit/build checks and an
authenticated smoke journey.

### P1 — one versioned server query contract

Introduce a normalized QuerySpec at the server boundary covering entity,
client/list scope, search, filters, pivots, completeness, saved filter-set
dependencies, people-per-company and membership-version dependencies. Keep
page sort/cursor identity explicit. Migrate one consumer at a time behind
adapters; remove no existing RPC until caller inventory and equivalence are
complete.

Gate: the regression matrix has executable route and database parity cases for
all core journeys. Unsupported input is rejected and never silently dropped.

### P2 — measured execution planning

Calibrate `lib/query-classifier.ts` from captured, redacted query shapes and
saved `EXPLAIN (ANALYZE, BUFFERS)` evidence in staging. Route affordable pages
to bounded interactive SQL and expensive valid membership to resumable result
sets. Separate first-page delivery from expensive exact counts while keeping
count state explicit.

Gate: agreed p95 first-page target under a mixed staging workload, no statement
timeouts for the supported catalogue, exact-result parity, bounded refusals for
unsupported/capacity-limited work.

### P3 — workload isolation and fair recovery

Account for actual SQL connections and heavy statements across import,
operations, export, verification, ICP, integration and maintenance workers.
Use one shared heavy-work budget on the current VPS, bounded queue units,
leases/fencing, per-class aging and reserved interactive capacity. Add storage
reservations and incremental cleanup for disposable result data.

Gate: concurrent browse/import/export/addon scenarios meet the agreed latency
and queue-age limits; killed workers resume without duplicate mutations; status
polling remains available during overload.

### P4 — production operations

Version journey metrics, alerts and capacity dashboards. Exercise backup
restore into an isolated database, migration forward-fix, blue/green rollback,
worker restart, queue draining and reindex repair. Record recovery time and
data-loss objectives.

Gate: a dated runbook and successful drills with evidence. Passing CI alone is
not production-readiness certification.

### P5 — scale certification, one tier at a time

Define the next realistic record and concurrency tier from growth forecasts.
Generate privacy-safe representative data and test cold varied filter
combinations, deep navigation, imports, exact counts, large exports and addon
traffic. Tune indexes and resource limits from measured plans. Repeat for the
next tier; record the certified envelope and refusal behavior.

Gate: correctness plus latency, throughput, storage, recovery and overload
criteria pass at the named tier. A VPS upgrade or new service is introduced
only when the measured bottleneck and operating cost justify it.

## Evidence rules

- Code review establishes intended wiring, not database equivalence.
- Unit tests establish local contracts, not PostgreSQL plans or production
  capacity.
- Disposable SQL fixtures establish semantics on their fixture data, not p95.
- Authenticated UI tests establish the user journey, not sustained load.
- Read-only production samples establish current observations, not a future
  guarantee.
- A live write, load test, worker restart, restore or deployment needs its own
  explicit release step and recorded result.
