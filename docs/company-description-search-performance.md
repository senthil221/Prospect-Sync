# Company-description search: measured fix and scaling boundaries

Date: 2026-09-05. Workload: Company keywords with Description enabled, then See People.

## Diagnosis

The VPS has 2 vCPUs and approximately 8 GB RAM. At the initial inspection it had about 4.9 GB available memory and 56 GB free disk. PostgreSQL held 681,085 prospects and 419,214 companies (11 GB database). Low average CPU does not establish that an individual query can meet a 10-second deadline.

The existing query already had trigram indexes for company name/description and a GIN keyword index. The reported 51 phrases require many substring index probes and description rechecks. The same expensive company membership was resolved again for Companies and People requests. The original full People RPC took 9.42 seconds in the initial probe: too close to its interactive 10-second limit to be reliable.

This is self-hosted Supabase/PostgreSQL on the VPS, not evidence of a hosted Supabase plan limit.

## Implemented architecture

1. The authenticated API recognizes large description searches (at least eight contains/not-contains/Boolean values in a description-enabled filter).
2. A short enqueue/reuse RPC records the exact company search in the existing private durable result-set queue. Browser requests receive HTTP 202 with an explicit preparation state.
3. The existing operations worker prepares matching company IDs once. It uses its separate PostgreSQL connection and existing 120-second session timeout. Ordinary interactive requests keep their existing timeout.
4. Companies reads the prepared IDs for its page and exact metrics. See People joins those IDs through the existing prospect workspace function; additional People filters and client membership still apply before pagination.
5. Subsequent pages/pivots reuse the same set. Browser polling is abortable, uses backpressure and bounded delays, and stops after 15 minutes. Navigating away stops polling, not the reusable background job.

Cache identity includes owner, exact search/filter content and company data version. A 24-hour TTL is enforced by existing worker retention. Database reads reject expired, mismatched-owner, mismatched-content and stale-version sets. The browser cannot submit the private prepared ID/owner fields. Enqueueing is serialized briefly to prevent duplicate jobs, with limits of four active preparations per owner and twelve globally.

No canonical prospect, company, client or list records are rewritten. No new public table access is granted. New RPCs are service-role-only; the worker retains function-only access. The migration changes functions, not table layouts or indexes.

## Measured results

The candidate migration and verification ran against production data inside one transaction, then rolled back. These are sequential, warm-cache database measurements, not P95s, browser timings, concurrency tests or a capacity guarantee. The 100/150-term lists extend the user's original 51 with distinct related synthetic phrases; they are not additional user-supplied lists.

| Terms | Matching companies | Matching people | Old scope resolution | Prepare once | People page + exact count | Next People page | Companies page + exact metrics |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 51, supplied | 41,057 | 81,477 | 6.957 s | 7.262 s | 0.457 s | 0.269 s | 0.497 s |
| 100, expanded | 56,736 | 120,783 | 14.183 s | 14.884 s | 1.423 s | 0.443 s | 0.738 s |
| 150, expanded | 66,045 | 159,589 | 24.158 s | 24.112 s | 1.476 s | 0.464 s | 0.816 s |

Duplicate enqueue/reuse took approximately 1–3 ms. Company membership digests matched the original resolver at all three sizes. Full Companies page JSON, ordering and exact metrics matched the original RPC. The second People page did not repeat the exact count when versions were unchanged. Owner/content/version rejection tests passed.

The new first search is deliberately asynchronous, **not instant**. Queue delay, network time and polling delay add to preparation time. The improvement is eliminating repeated text work and keeping that work out of the interactive request pool, not making a 24-second scan disappear.

## Alternatives tested and rejected

- Simply rewriting all 51 terms as `lower(...) LIKE ANY`: about 20.98 seconds.
- Raw `ILIKE ANY`: about 23.02 seconds.
- One combined regular expression: cancelled at the 30-second test bound.
- A temporary compact description-only projection plus trigram index: about 5.9–6.0 seconds for the scope, but required roughly 451 MB and an additional synchronized representation. Not enough benefit to justify that complexity for this release.

All experiments were rolled back. The study scripts are investigation artifacts, not deployment migrations.

## Verification and rollout

- Production build, lint and 405 automated tests passed before release (including preparation/retry rendering and table-state preservation).
- `scripts/verify-prepared-company-search.sql` checks membership equivalence, page/count contracts, duplicate-job reuse, owner/content/version checks and worker privileges. It also includes a 51-term combined People-filter/client-scope comparison and the existing scope limit.
- Apply the migration through the normal migration runner exactly once. It preserves the old company resolver and regular worker builder as private fallback functions. The old app remains compatible during blue/green rollout.
- Verify the new image's `X-App-Version`, health, migration history and actual worker claim/build/ready behavior after deployment. A PostgreSQL transaction test alone does not prove HTTP polling or browser behavior.
- Signed-in browser verification requires an authorized session; do not bypass authentication to perform it.

### Recovery

Use the existing blue/green application rollback first. The additive database migration can remain: the old app sends no prepared fields and continues through the saved resolver. Pending preparations remain bounded by the worker timeout and expire normally.

If database functions themselves need restoration, use a new forward migration to copy `prospect_results.uncached_company_scope_ids_v1` back to `public.company_scope_ids_v2` and `prospect_results.build_regular_batch_v1` back to `prospect_results.build_batch_v1`, restoring the original names/signatures and preserving grants. Do not replay the preparation migration manually: its backup-copy step is designed for the exactly-once migration runner. Do not delete customer records or reset migration history.

## Explicit limits and next scaling work

This is a targeted reliability improvement, not a claim that arbitrary queries over unlimited data are solved.

- People pivots retain the established 250,000-company scope ceiling and existing scope-capped warning. Companies stores all matching company IDs. This release does not silently change either contract.
- First preparation is one atomic statement. If it exceeds the existing 120-second worker limit, it fails safely; interrupted builds restart. Ordinary result-set builds remain keyset-batched.
- The worker uses a separate connection pool, **not separate CPU or disk**. It shares the VPS and also handles existing bulk/export work. Queue limits bound admission but do not provide interactive fairness under sustained queue load.
- Client-company listings, reverse People-to-Companies scopes, small description searches and export resolution keep their existing paths. Do not generalize these measurements to those paths or to every filter combination.
- Frequent company writes invalidate prepared membership. The current version is intentionally conservative; result correctness takes precedence over reuse.
- This is not a new full-text tokenizer: phrase/substring, exact keyword, Boolean and exclusion semantics remain with the existing compiler.

Next, measure first-build/cache-hit P50/P95/P99, queue age/depth, invalidation frequency, timeout rate, prepared-cache disk footprint and ordinary request latency while one build is active. Test at projected row counts and representative 1/3/5-user concurrency in staging, not by flooding production. Target cached reads below two seconds P95 and no interactive timeout in the reported flow; treat these as acceptance targets until measured.

If repeated first-build scans dominate at larger scale, evaluate an incrementally maintained company search projection or dedicated search index. Preserve substring versus token semantics explicitly and verify result digests before switching. Add search-specific data versions/CDC to avoid unnecessary invalidations, cursor pagination for deep navigation, and a fair dedicated search worker if queue contention appears. Add RAM/CPU or separate the database only after query plans, I/O and concurrent-load measurements identify the limiting resource. An external search service or larger VPS is not required merely because a list contains 150 phrases.
