# Smartlead direct delivery

## Available workflow

1. An integration administrator connects the agency Smartlead account.
2. Refresh campaigns and map a campaign to a Prospect Sync client, or create a
   draft campaign for that client in Integrations. Successful creation maps the
   destination automatically. Account replacement invalidates old approvals.
3. Check 1–400 prospects across pages, open **Preview Smartlead delivery**, choose
   the client/campaign, and map canonical or imported fields. Custom targets use
   `custom:field_name`. The recipient must be work or personal email.
4. Freeze and inspect the preview. Missing emails, duplicates and local
   suppressions are counted separately. Duplicate recipients retain all source
   IDs privately; the first source by stable ID supplies personalization.
5. Confirm transfer and push. Active campaigns require separate explicit consent
   because adding leads can trigger immediate outreach. Saved drafts pushed from
   job history permit draft/paused/stopped campaigns only.
6. Follow progress in Integrations and download the per-email CSV outcome report.
   Cancel stops future batches; it cannot retract uploads or guarantee stopping
   an in-flight request. No campaign-start endpoint is used.

## Execution and recovery

- Dedicated worker: one connection, two-connection role ceiling, 192 MB memory
  ceiling and quarter-core CPU limit; no interactive PostgREST pool consumption.
- Private database queue, actor-scoped submission/report access, explicit client
  destination binding, encrypted server-only credentials, narrow worker grants.
- Shared connection reservation serializes this app's provider work and observes
  connection-check cooldowns. Other apps sharing the same key remain outside it.
- At most 400 leads and 512 KiB per provider upload; drafts split by byte size.
- Fresh campaign status and local suppression checks precede each upload.
  Smartlead global blocklist, unsubscribe and cross-campaign duplicate protections
  remain enabled. Status can change externally after the check; we cannot make a
  remote campaign-state check and upload one atomic operation.
- Each claim has a fencing token and 120-second lease. Expired or uncertain POSTs
  stop for review and are **not automatically replayed**. Reconciliation is manual:
  inspect Smartlead membership or the created campaign before a new attempt.
- 429 responses and safe read failures use bounded backoff/Retry-After, eight
  attempts maximum and a one-day deadline. Credential rejection pauses delivery.
- Full receipt accounting is required. Unknown response shapes, lost replies and
  incomplete skipped-row details do not become false success.
- Completed/cancelled reports are retained for 30 days, cleaned ten jobs at a
  time. Unresolved jobs are retained. Admission limits: ten active drafts/jobs,
  1,000 retained jobs, and a live payload byte cap; pressure fails explicitly.

## Deliberately excluded

Verifier delivery and credit spending; automatic campaign launch; campaign
sequence/schedule/mailbox editing; all-matching uploads and selections over 400.
These controls do not silently truncate a larger selection.

## Verification and release

Mocked provider tests cover credential envelopes, active-state consent, exact
upload accounting, suppression/cancellation preflight, ambiguous writes,
creation receipts, rate delays, fixed origins and sanitized errors. SQL checks
exercise ownership, duplicate intent, single claims, fencing, suppression changes,
creation mapping and private role grants inside ROLLBACK. CI repeats against a
disposable PostgreSQL database. Deployment waits for the new worker to be healthy
before switching application traffic and supports rollback to older images.

Live provider creation/upload tests were explicitly deferred by the user. No
successful real upload is claimed from mocked or SQL-only tests. Backups remain
unchanged. Local Supabase advisor is unavailable without a running local database.

Provider contracts used: [create campaign](https://api.smartlead.ai/api-reference/campaigns/create)
and [add leads](https://api.smartlead.ai/api-reference/leads/add-to-campaign).
