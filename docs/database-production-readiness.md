# Database production-readiness programme

Status: active engineering programme, updated 2026-10-06. This is a dependency
map and release backlog. It is not a claim that
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
- A bounded, read-only 2026-10-04 aggregate for Krishify found 939 complete,
  SEG-eligible client companies: 841 with a person in that client and 98
  without. Of those 98 client-without companies, 50 had people globally. The
  old global-coverage compiler therefore dropped 50 legitimate results from
  that client-relative `Without prospects` view. The single warm aggregate
  completed in 93.489 ms; that is defect evidence, not a latency benchmark or
  load-test result.
- On 2026-10-04 a local database dump completed at about 1.07 GB, but its
  offsite upload failed with an HTTP 500/quota response. A separate read-only
  snapshot probe throttled to one request per second still returned HTTP 403.
  There is no verified offsite receipt, so no remote-copy or restore claim can
  be made. A successful offsite verification plus an isolated restore proof is
  still a critical production-readiness gate; this query package does not alter
  backup configuration or prune any copy.

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
| Imports and repair | people/company import routes, import worker, completion RPCs, reindex backlog | Protocol-2 background imports use a rotating claim token, connection-local COPY, fenced durable publication/batches/completion and an atomic cancel lock. Browser/company imports retain their legacy entry points. |
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
  its stored `client_scope`. Client-origin Company questions are therefore
  rebound by the server to the internal `__client_company_scope` predicate
  before authorization, hashing, persistence or execution. It checks
  `client_companies` membership and makes `__company_coverage` client-relative.
  A caller's ordinary `__company_client_ids` filter remains visible and is
  intersected; it cannot replace the origin. Master questions carry no internal
  origin and retain global coverage semantics.
- The people-per-company limit is represented by
  `__max_people_per_company`; the current durable People builder has an explicit
  ranked-candidate path in
  `20260924205130_client_workspace_feature_pack.sql`. It needs equivalence
  coverage before broader planner routing. The new disposable parity case
  covers it together with a normalized Company → People scope; broader filter
  catalogue and scale evidence remain required.
- Client-origin nested `companyScope` is now normalized once with membership,
  completeness, SEG policy and client-relative coverage before interactive
  People listing, streamed export or frozen selection consumes it. Empty
  server-only scopes do not manufacture caller intent, malformed internal
  values fail closed, and old Master payloads containing the pre-existing SEG
  predicate remain backward compatible.
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
| Client People / Companies | Present: client scope plus membership RPCs; client People adjacent pages have an independently gated cursor v2 | Present: client operations, legacy-filter UI, cursor bootstrap/next/previous/reset/fallback, cap paging and Incomplete Info tests | Package: listing/stream/frozen/selection parity, client cursor full ordered IDs/version/cap/grant checks, stored-count write authority, >50k paging/export, enrichment and SEG transitions | Required: authenticated normal/incomplete cursor canary after deployment | Stored-count parity proved on all 17,025 rows of one live client; bounded cursor comparisons are single-session observations, not deployed-RPC or p95 evidence |
| Company → People | Present: normalized `companyScope` carried by listing/export/result set | Present: scope/auth/result-set/identity tests | Package: actual People listing, export and frozen builder with max-people cap | Required: authenticated page/export/all-matching parity | Read-only source counts only; no write journey |
| People → Companies | Present for interactive listing; durable membership unsupported | Present: pivot honesty tests | Gap: complete frozen-set equivalence | Required: listing plus bounded export behavior | Not certified |
| Exact count / all matching | Package: client completeness and Company origin normalized before authorize/hash/store | Package: behavioral normalization, contradictory scope, idempotency, identity and guard-order checks | Package fixture compares interactive, explicit/all-matching and frozen IDs/counts; exact-head CI pending | Required: normal and Incomplete Info all-matching actions | No writes performed |
| Streaming/background export | Present: direct and background paths carry the real origin client | Present: streaming/export wiring tests | Package: client Company stream and nested People stream equal their listings in disposable SQL | Required: authenticated downloaded IDs/fields | Not certified under concurrent import |
| Imports / push / membership removal | Package: v2 token fence, private stage, bounded renewal and direct receipt-bearing completion | Package: lease budget, blocked renewal, API, rollback and worker wiring tests | Package: independent-session claim/reclaim, stale writes, COPY publication, replay, cancellation, completion, ACL and real-worker consecutive-import fixture | Required: authenticated resume, duplicate and removal journeys | No production write/recovery drill; disposable PostgreSQL only |
| Blocklist | Present: scoped bulk/share/reply paths | Present: blocklist and Smartlead tests | Present for selected migrations; account/retry recovery required | Required: add/update/delete/export/share/reply sync | Addon, not a core-query certification |
| Email verification | Present: frozen selection and dedicated worker | Present: provider, worker and bounded-run tests | Present for selected run/reconcile fixtures | Required: create/pause/resume/reuse/result labels | Addon, not a core-query certification |
| ICP | Present: selected company queues and worker | Present: ICP route/model/clear tests | Present for selected queue and selection fixtures | Required: selected run, review and retry | Addon, not a core-query certification |
| Health / backup / restore | Present: health route and deployment scripts | Present: failure visibility and backup script tests | Restore SQL exists | Required: operator-facing degraded states | **Red:** the 2026-10-04 local dump succeeded, but offsite upload returned HTTP 500/quota and the read-only snapshot probe returned HTTP 403; offsite-copy verification and an isolated restore remain open |

## Ranked implementation backlog and release gates

### P0 — close query parity defects before expansion

1. Run the extended disposable SQL equivalence fixture in exact-head CI. It
   compares client interactive, streaming, pivot, explicit/all-matching and
   frozen IDs; includes global-but-not-client coverage, shared/out-of-client,
   completeness, SEG, enrichment, max-people and unchanged Master controls.
2. Complete the authenticated Company UI and Company → People smoke after
   deployment. The deterministic browser fixture covers selector cleanup,
   negative/multi-value legacy filters and selection reset without customer
   writes.
3. Catalogue every supported filter/operator/scope combination and make each
   consumer either preserve it or return a stable unsupported error.
4. Add representative staging plans and mixed-load evidence before certifying
   latency or a future record tier; the production aggregate above is not that
   evidence.

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

The current package closes the background People import fencing prerequisite:
the database owns a versioned rotating token; stale workers cannot publish,
merge, retry or complete; cancellation and merge serialize on the import row;
completion returns an idempotent receipt and creates import verification work
once. The worker renews on an independent bounded connection and checks the
authoritative cursor after an ambiguous batch. CI uses synthetic rows and a
fake local Storage server. It does not establish production throughput, and a
live import/restart drill remains a separate release gate.

The client Company DB count path now reads the exact `client_companies.prospect_count`
maintained by the existing `prospect_index` statement trigger instead of
aggregating or laterally recounting the projection during every page request.
On 2026-10-05 a read-only production comparison found zero drift across all
17,025 client/company memberships for the measured client. In one paired warm,
read-only session with identical rows and all five summary fields, the complete
13,111-company view changed from 924.00 ms to 303.46 ms and the 3,914-company
Incomplete Info view from 164.17 ms to 72.85 ms. This is not a p95 or a
cold-cache certification: a first cold complete read still exceeded five
seconds, so storage warmth and broader client-summary timeouts remain explicit
P2/P4 work rather than being hidden by this change.
Disposable PostgreSQL also exercises import, push, block/unblock, removal and
company reassignment, plus a 50,051-row capped listing whose keyset export still
traverses the full client scope.

The client-summary cache now treats directory and single-client misses as two
different workloads. A valid complete cache still serves either request. A
directory miss still computes every client and replaces the one complete cache
row; a single-client miss instead reads the existing inlined
`client_summaries` view with `WHERE id = p_client_id` and never publishes its
partial object to that global row. In a bounded same-session production read on
2026-10-05, the exact all-client count object took 2,206.10 ms, the selected
client's equal count object took 734.06 ms, and a smaller client's equal object
took 301.16 ms. A custom canonical aggregate was rejected after it measured
slower than the existing scoped view. These are warm observations, not p95 or
cold-cache certification. The existing five-minute cache ceiling, global
invalidations and commit-visibility limitation remain unchanged. Both client
GET routes now carry a 35-second application deadline on top of the database's
30-second statement timeout, distinguish caller cancellation (499) from a
bounded timeout (504), and expose only fixed directory/single and
counts/metadata phase labels.

Client-summary invalidation now covers every writer that moves a company into
or out of the `SEG` provider class, not only the MX scan function. A narrow
`AFTER UPDATE OF email_provider_type` row trigger advances the existing count
epoch only when the row crosses the SEG/non-SEG boundary; provider changes that
stay on the same side do not invalidate the cache. The scan function keeps its
existing conservative bump, so a scan transition can advance the epoch twice;
cache validity compares epoch equality and does not depend on exact increments.
The pre-existing visibility race also remains: PostgreSQL sequence advances are
non-transactional and visible before the company update commits, so the
five-minute cache ceiling continues to bound a read that lands in that window.

Direct client and list links now restore through ownership-scoped detail reads
instead of waiting for the complete client directory. The address bar keeps the
requested client/list ids and any fragment-carried filters while those reads are
pending; Back/Forward, refresh, archived clients, and lists beyond the first
directory page use the same guarded path. Each target change aborts the prior
read and advances a generation guard, so late responses cannot reopen or
overwrite a newer workspace. The complete dashboard and client directory load
after the initial scoped restore and remain visibly supplementary; their late
response does not reset the selected client tab or list. Invalid restoration
payloads remain fail-closed and issue no scoped client/list request.

Ordinary bounded Company Keywords substring filters now expose each selected
text field directly to the existing company name and description trigram
indexes, while keyword tags retain their existing array-overlap predicate.
Keywords-only searches, OR lists over 40 values, terms shorter than three
characters, wildcard characters, backslashes and the `|` separator keep the
previous compatibility expression. The row matcher is unchanged. In one
bounded read-only production session on 2026-10-05, description+keywords for
the selective term `blockchain` changed from 4,679 ms to 98 ms with exact
company-ID parity; all three fields for broad `software` changed from 2,858 ms
to 651 ms with exact company-ID parity. The real People predicate changed from
3,463 ms to 2,168 ms for broad Master contains, from 678 ms to 110 ms for a
selective client contains, and from a 5-second timeout to 1,027 ms for broad
Master not-contains. One name+keywords old-shape parity arm also reached the
five-second ceiling, so the disposable full-ID fixture—not a latency claim—
carries the comprehensive semantic gate. These single-session paired
observations are not a p95, concurrency, warm/cold-cache, or plan certification;
no cache flush or `EXPLAIN (ANALYZE, BUFFERS)` capture was performed.

MX retry selection also has a disposable saturated-backlog fixture: 500 fresh
rows fill a 500-row claim before a stale retry, and the retry appears once
fresh capacity is released. The already-applied `20261005120000` migration's
inline proof assumes the database has fewer than 500 pre-existing fresh rows;
the later fixture documents and tests that limitation but cannot repair replay
of that immutable historical migration on an arbitrarily saturated database.

Client People adjacent pages now have a separate, default-off
`CLIENT_PROSPECT_CURSOR_PAGINATION` rollout. Page one still comes from v13;
only an in-session next page carrying a query- and client-bound v2 token uses
the new RPC. Master People remains controlled by the older, independent global
flag. Alternate sorts, Company → People pivots, max-people-per-company queries
and numeric deep links remain on OFFSET. The v2 RPC keeps the effective v12
membership, completeness, SEG, company-filter dependency-vector and bounded
count contracts, with a 10-second database deadline. A cursor is navigation,
not a snapshot: concurrent writes can move the boundary between requests.

The production evidence is deliberately narrow. In one bounded read-only
session on 2026-10-05, a plain complete-client predicate at depth 10,000 changed
from 181.948 ms / 66,903 shared buffer hits with OFFSET to 1.606 ms / 572 hits
with a boundary; an incomplete predicate at depth 2,222 changed from 149.312 ms
/ 43,136 hits to 1.118 ms / 384 hits. Those two comparisons did not reproduce
the materialized RPC candidate shape. A broad mixed company-keyword case did:
the client-first materialized OFFSET candidate took 684.977 ms / 213,266 hits,
while the same candidate with its boundary inside the materialized CTE took
300.402 ms / 108,182 hits. Each compared next 50 IDs exactly. A naive global
B-tree mixed-filter probe reached the five-second ceiling and was rejected as
the implementation shape. These are single-session paired observations, not a
controlled warm/cold comparison, load test, p95, first-page guarantee or live
v2 RPC canary. Disposable PostgreSQL remains the semantic gate for tied
timestamps, full ordered traversal, exact multiples, dependency invalidation,
service-role-only grants and the >50,000 capped-count contract.

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
