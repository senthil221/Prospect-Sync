# Prospect Sync integrations — implementation contract

Status: implementation in progress; external lead delivery remains disabled.

Implementation update: the Integrations navigation/panel, encrypted server-side
connection storage, explicit administrator gate, same-origin write checks,
cross-instance read cooldown and read-only campaign discovery are implemented
locally. The candidate database privilege/cooldown/fencing test passed inside a
rolled-back VPS transaction. Prospect Sync lint/build passed; 470 tests passed
with one skip. No integration release is deployed yet. A capabilities-only
service-auth endpoint is prepared in the isolated verifier checkout; submissions
remain explicitly disabled. The full delivery workflow below remains unfinished.

## Existing Campaign Launcher reuse review

Inspected `senthil221/Campaign-Launcher-Copy` at
`02dfd359fa654a767357143b93d13ed4b20460d0`, without running the app or invoking
its Smartlead proxy. It supplies useful reference implementations for schedule
presets (IANA time zones), campaign settings/payloads, sequence construction,
inbox tag grouping, and human-readable step progress. Revalidate provider enum
values before reusing payloads. Sequence/mailbox/schedule editing is not silently
added to the initial draft-create/push scope.

Do not reuse its execution/security layer unchanged:
- `api/smartlead.js` accepts caller-selected methods/paths with a server key and
  has no authentication/authorization check in the handler. Deployment-level
  protection is unknown; this is not evidence of actual public exploitation.
- `src/lib/pipeline.ts` runs in the browser with in-memory progress, not a durable
  worker. Retrying the leads step replays batches, including earlier successes.
- After partial upload failure it may mark the step done if any lead succeeded;
  execution can reach activation even after upload errors. Missing added counts
  are replaced with the batch length rather than treated as an unknown outcome.
- `uploadLeadBatch` drops all but five fields; custom personalization columns
  would be silently lost. Keep an explicit, validated custom-field mapping.
- Upload retries use fixed waits rather than a shared connection budget, and
  cannot reconcile a successful upstream write whose response was lost.
- Legacy config helpers store API keys in localStorage/VITE configuration even
  though the current proxy uses a server-side key. Do not import those helpers.
- Inbox normalization treats missing SMTP/IMAP status as successful. Unknown
  readiness must remain unknown, not eligible by default.

Use the launcher as a workflow/payload reference; do not mount its unrestricted
proxy or auto-activation pipeline inside Prospect Sync. No launcher changes made.

Follow-up implementation: the isolated launcher checkout now contains a shared
hashed-token access gate on all three API handlers, a tab-memory-only access form,
an exact mutation allowlist, fixed provider origin, disabled redirects and private
cache headers. Unused browser provider-key storage helpers were removed. Custom
fields are preserved and failed/uncertain uploads stop without activation or blind
retry. Six mocked auth/pipeline regression tests and TypeScript/build passed.
One independent security-boundary review found no concrete bypass; its noted
10,000-account bound on the unused tag aggregation endpoint is intentional and
fails explicitly instead of truncating. No standalone launcher deployment occurred.
Its browser runner is still not a durable queue and is not the new integration's
execution engine. Configure its separate access token before any future deployment.

The new private integration ledger supports bounded draft snapshots, stable
request identity, actor-scoped status, and cancellation. SQL tests passed in a
rolled-back VPS transaction; dispatch/enqueue is intentionally not exposed yet.
Pure delivery contracts enforce mapping, batch/byte caps, valid-only email-specific
freshness and complete upload accounting. Prospect Sync now has 478 passing tests
and one skip. The verifier has 68 passing tests and a successful build with existing
BullMQ optional-module warnings. Its API currently supports capabilities only.

User-approved integration administrator: `senthil@b2bdrive.net`.
User-designated test campaign: `3909297`; draft/paused state and controlled test
addresses still require verification before any upload. No credentials received.

## Confirmed scope

- One agency Smartlead account, with explicit client-specific campaign choices.
- No2Ninja-Verifier remains on its separate VPS at https://app.betterlanebase.link/.
- An Integrations workspace manages connections, client mappings and job history.
- Prospect selections offer **Push to Smartlead** and **Verify then push**.
- Create a draft campaign or choose an existing campaign. Campaign sequences,
  mailbox assignment and automatic campaign launch are outside this first release.
- Backups remain deferred; mobile-specific refinements come last.

## Evidence and prerequisites

The local Waterfall-Verifier checkout matches upstream HEAD
`2e1ecca777cd30f0f60d5c312be5310b25be66e1`. Its real implementation has session
authentication (the README's no-auth warning is stale). Upload/start operations
are Next server actions. The exposed list status/export routes require a browser
session. There is no inspected machine-authenticated submission API. Its CSV
export reads an entire list into memory: do not use this as the bulk integration
transport. The deployed verifier revision has not been checked.

Smartlead documents API-key authentication, up to 400 leads per upload, and
plan-dependent rate limits. Do not hard-code a guessed requests-per-second rate.
The provider documentation is not proof of idempotency or exact response shapes:
contract-test them with a designated non-sending campaign before enabling writes.

Sources:
- https://helpcenter.smartlead.ai/en/articles/125-full-api-documentation
- https://api.smartlead.ai/api-reference/leads/add-to-campaign
- https://api.smartlead.ai/api-reference/campaigns/create

Needed before live integration: verifier VPS SSH/deployment access, Smartlead API
access enabled, a securely configured Smartlead key, and a designated test campaign.
Never request raw keys in chat. Confirm the account's rate allowance and whether
other tools share its key; our limiter cannot control requests made by those tools.

## User journey

1. Connect Smartlead and verifier; test authentication without transmitting leads.
2. Map each Prospect Sync client to its verifier client and permitted Smartlead
   client/campaign IDs. Enforce mappings on the server, not just in dropdowns.
3. Select checked prospects or all matching records, preserving exclusions and
   the complete company/client/list filter scope.
4. Choose direct push or verification-first, then campaign/draft creation.
5. Map columns and preview a bounded sample. Require one email mapping. Support
   first/last name, company, website, phone, location and custom fields. Reject
   duplicate target keys, invalid types and excessive field/value sizes.
6. Review frozen selection size, duplicate emails, missing emails, suppression
   exclusions, destination, verification policy and possible paid second pass.
7. Confirm once; a durable job continues when the browser closes. Show queued,
   verifying, uploading, waiting-to-retry, needs-review and terminal states.
8. Show an auditable outcome breakdown and downloadable rejected-row reasons.

Adding leads to a running campaign can trigger outreach even without calling a
start endpoint. Require a prominent explicit confirmation for that case. New
campaigns stay draft; never silently launch a campaign or alter its sending rules.

## Selection and data correctness

Freeze IDs and the mapped outbound values into a bounded, paginated job snapshot.
Record selection/query version, exclusions, mapping version, email hash and client
scope. Preserve the product's global canonical people and independent memberships.
Do not use visible-page rows for all-matching operations or truncate capped scopes.
Fail closed until the full selection is available and counted accurately.

Complete the prepared-scope reuse and selection correctness gaps identified in
the performance programme before enabling all-matching integrations. Explicit
small selections may be delivered earlier if independently validated.

Deduplicate by normalized email per job/campaign, preserving an audit link to all
selected prospect IDs. Show conflicting values and apply a documented deterministic
precedence rule; never unpredictably overwrite an existing campaign lead.
Preserve unsubscribe, blocklist and client suppression rules in both paths.
Recheck suppressions immediately before each upload batch.

Verification results attach to the exact verified email, provider, timestamp and
policy version, not blindly to a mutable prospect ID. An email changed after the
snapshot does not inherit verification. Send only email plus opaque row reference
to the verifier; keep names and other personalization fields in Prospect Sync.

## Verification service API to add

Proposed versioned endpoints (not existing APIs):
- Connection health/capabilities: version, maximum batch, supported statuses.
- Create a job with an idempotency key and client binding; no paid work yet.
- Append bounded email batches with unique batch IDs and payload hashes.
- Finalize/start after accepted count/hash validation and explicit spend approval.
- Read lightweight progress and cursor-paginated row outcomes.
- Stop future work; acknowledge in-flight/provider work may finish and cost credits.

Use revocable scoped service credentials, hashed at rest on the verifier. Every
endpoint checks the service principal, authorized client and job ownership.
Do not reuse session cookies or expose general admin/browser actions to the key.
Bound body size, row count, concurrency, retention and polling frequency.
Use stable opaque correlation IDs and reject duplicate IDs with different payloads.

Preserve the existing MTN→No2Bounce queue and cache logic. Default to valid-only;
invalid, risky/catch-all, unknown and unresolved results do not advance. A provider
outage must never fall back to the direct-push path. Fresh cached results can be
reused under the verifier's documented policy; freshness is not unlimited.
Add per-job provider-credit ceilings and pause before exceeding them, including
paid fallback. Track attempts versus billable usage separately where available.

## Reliable Smartlead dispatch

Use a separate durable integration worker and database ledger, not a long-running
browser request. Do not hold a DB transaction/lock while waiting on external APIs.
Claim bounded batches with leases and fencing tokens; persist request intent and
outcomes. Use no more than 400 leads per batch and also enforce a byte-size bound.

Throttle per agency connection across all jobs, with fairness across clients.
Use configurable conservative concurrency, Retry-After when present, exponential
backoff with jitter, a retry deadline, attempt cap and an outage circuit breaker.
Authentication failures pause the connection instead of endlessly retrying.
Validation errors become per-row/actionable failures; unknown response schemas
become needs-review rather than falsely reported success.

Duplicate clicks reuse the same internal request. An external timeout after a
POST may mean Smartlead accepted it: reconcile campaign membership before retry.
Do not promise exactly-once delivery unless the provider contract supports it.
If reconciliation is inconclusive, stop as needs-review. Apply the same rule to
campaign creation; never create a second campaign just because the reply was lost.

Record selected, excluded, eligible, verified, added, skipped, rejected and
uncertain counts separately. Provider skipped rows are not successes. Completion
requires every snapshot item to have a terminal accounted-for outcome.
Cancellation stops unsent batches; it does not retract already uploaded leads.

## Security and operations

Store outbound credentials encrypted server-side with a separately provisioned
master key and key version; mask all readbacks and support rotation/revocation.
Smartlead puts its key in the query string: redact URLs, errors and HTTP traces.
Do not log email payloads, credentials or provider response bodies indiscriminately.

Restrict connection edits to authorized administrators and enforce client mappings
on every preview, submit, poll, result download and campaign lookup. Keep private
tables out of the public API and apply explicit service-only privileges/RLS.
Allow only configured HTTPS provider origins; no arbitrary user-supplied URLs,
redirect following to untrusted hosts, or private-network fetch targets.

Bound queued jobs, outstanding emails, snapshot bytes and per-client activity.
Keep database connections and worker CPU/memory bounded to protect interactive
search. Persist queue age, latency, 429s, failures, uncertain batches and credit
usage without sensitive payloads. Expose connection health and actionable alerts.
Retention removes payloads incrementally while preserving minimal delivery audit.

## Release sequence and gates

1. Add/test verifier service API against its actual deployed version.
2. Add secure connections, client mappings and read-only campaign discovery.
3. Implement snapshot/mapping validation and preview, with no external dispatch.
4. Add ledger/worker, direct push to a designated draft test campaign, then
   verification-first using an explicitly approved small paid test.
5. Enable real writes only after authentication isolation, rate limiting, partial
   responses, duplicate clicks, ambiguous timeouts, cancellation and restart tests.
6. Verify all-matching/pivot selection completeness before exposing large batches.

Test 0/1/400/401 rows, duplicate/missing/changed emails, custom-field conflicts,
wrong-client campaigns, expired credentials, 429/5xx, lost acknowledgements and
malformed outcomes. Kill/restart during verification and dispatch in isolated
fixtures, verify no silent loss or blind duplicate submission. Ensure suppression
and valid-only policies hold during retries. Exercise keyboard/error/progress UX.

No production lead upload, paid verification, campaign creation or email launch
has been performed as part of this design inspection.
