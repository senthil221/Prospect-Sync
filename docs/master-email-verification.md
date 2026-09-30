# Master work-email verification

This feature verifies `work_email` with the dedicated Prospect Sync MailTester Ninja account. Results are labels only. They do not change Contactable/Lead membership, client pushes, exports, Smartlead eligibility, or any existing outreach rule.

## Runtime contract

- **Master People** freezes the entire Master People selection. It ignores the current page, search, filters, and company pivot.
- **Current search & filters** freezes the complete authorized filter/search/company scope across all pages, including the people-per-company limit.
- Manual runs default to a 10,000-distinct-email cap. The setup screen also offers 100, 1,000, a custom limit from 1 to 200,000, and an explicit **All eligible** choice with no cap. Review the scope and limit before creating a run. The database applies a cap only after building the complete authorized candidate set, orders distinct normalized addresses deterministically, and keeps every matching person who shares a selected address.
- A completed result for the same unchanged normalized work email is reused by default, preserving its original `checked_at`. Reverify is an advanced setup option and is shown again on the review screen.
- Pause prevents new allocation and dispatch for that run. An already-started provider request may settle and is reconciled truthfully. Continue resumes the same run ID.
- Cancel preserves results already reconciled and marks unfinished targets cancelled in bounded reconciliation.
- Verify on Import freezes canonical memberships for that import only, including linked duplicates, after the import commits successfully.
- There is no scheduled re-verification cycle. Another run starts only when an authorized user requests it or opts into verification for an import. Provider start/pause controls remain administrator-only.

For a controlled 10,000-email batch, apply any desired People filters (use **Last Verified → Never Verified** for a fresh batch), open **Verify work emails**, select **Current search & filters**, leave **10,000** selected, then choose **Review verification → Create run**. Provider dispatch has a separate **Start provider** control. The run card records eligible unique emails, selected unique emails, selected people, and the requested limit. Because unchanged completed results are reused by default, the number of paid provider calls can be lower than the selected-email count. Repeating the same broad capped scope can select the same deterministic addresses; use Last Verified or another filter to advance to a fresh batch.

The queue is Postgres-backed. Snapshot preparation, shared-check allocation, provider settlement, and canonical projection reconciliation are separate fenced phases. Provider calls never run inside a database transaction. Redis, BullMQ, Waterfall Verifier, and paid fallback providers are not dependencies.

## Secrets and least privilege

Provision two separate credentials:

1. `VERIFICATION_WORKER_DB_PASSWORD` — a strong random database password used only by the `prospect_verification_worker` login. Never reuse `POSTGRES_PASSWORD`.
2. `MTN_API_KEY` — the provider-issued key from the dedicated Prospect Sync MailTester Ninja plan. Never reuse the Waterfall Verifier key.

Put both values only in the server's mode-600 `deploy/.env`. The browser and Next.js application do not receive either value. Do not paste either secret into tickets, CI logs, chat, screenshots, or client-side environment variables.

The worker login inherits only `prospect_verifier`, whose grants are limited to fenced verification capability functions. The private queue tables have RLS enabled and no access for `PUBLIC`, `anon`, or `authenticated`.

## Safe rollout

1. Back up the database and confirm the backup is readable.
2. Add a unique `VERIFICATION_WORKER_DB_PASSWORD` to `deploy/.env`. `update.sh` and `restore.sh` stop before changing services if it is missing.
3. Add `MTN_API_KEY` to `deploy/.env`, or leave it empty for a healthy idle worker during schema/UI validation.
4. Deploy normally. Bootstrap provisions the narrow login by forwarding the named environment variable into the existing database container; adding this feature does not require recreating the database container.
5. Apply the migration and start the worker. The provider remains database-disabled and manually paused after migration.
6. Confirm the worker heartbeat appears as configured/online in the Master People verification panel.
7. With dispatch still paused, create a very small filtered run and confirm its exact frozen count.
8. Start provider dispatch manually. Confirm checks, projection labels, original reuse timestamps, Pause/Continue, and Cancel on the small run.
9. Only then use Verify all work emails.

Forward releases require the worker file and health endpoint. An explicit rollback to an image that predates the worker stops the newer worker instead of failing the application rollback. Database migrations are additive and are not removed by an application rollback.

## Operational controls

The account is on MailTester Ninja's Ultimate plan, documented as 200,000/day and "23 emails every 10 seconds" (one per 430 ms; https://mailtester.ninja/api/). The pace sits just under that (20260930190000); a 25-per-10-second pace was throttled with HTTP 429 on 2026-09-30:

- daily rolling limit: 190,000 starts (retries included);
- start spacing: 450 ms, with a 22-per-10-second rolling guard (~132/minute = ~190,000/day);
- HTTP concurrency: 12 (starts are what the plan limits; 12 in flight sustains 132/minute at ~4.4 s a check);
- provider timeout: 45 seconds;
- maximum attempts: 4.

HTTP 429 and provider outages cause a bounded cooldown. Repeated transport/protocol failures open a five-minute circuit. Account/authentication failures manually pause provider dispatch until an administrator fixes the key/account and explicitly continues. Malformed responses, email mismatches, network failures, and timeouts never become invalid-email labels.

The worker continues expired-lease recovery and bounded result reconciliation while the provider is disabled, paused, missing a key, or cooling down. A long Master snapshot uses one dedicated pool connection while heartbeat, reconciliation, allocation, and claims continue on the other connection.

## Verification and release evidence

Before enabling production dispatch, require:

- the synthetic PostgreSQL migration/runtime contract;
- the multi-session concurrency harness;
- unit tests, lint, and production build;
- the hydrated component interaction fixture and visual review;
- a final secret/grant/diff review.

No live MailTester Ninja call is part of CI. A successful build proves code and synthetic database behavior, not provider-account validity or production throughput.
