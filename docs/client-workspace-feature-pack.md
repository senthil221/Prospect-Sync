# Client workspace feature pack

This checklist is the implementation and release contract for the 25 September
2026 client-workspace feature pack. Database changes are additive and are kept
in `20260924205130_client_workspace_feature_pack.sql`.

## Implementation status

- [x] 1. Clients can be placed in one named folder, archived, restored, and
  viewed in an Archived section without deleting any client data.
- [x] 2. Every client has an Incomplete Info view for companies with both no
  keywords and no short description, plus the people attached to those
  companies.
- [x] 3. People and companies can be pushed from one client database to another;
  the server verifies that every selected source record belongs to the source
  client.
- [x] 4. Blocklist supports page/all-result selection, bulk delete, bulk reason
  updates, Type and Date Added filters, and CSV export.
- [x] 5. Recently Added is grouped into durable, retry-safe batches and shows
  source and time. Import batches name the source file; pushes distinguish the
  master database from a source client.
- [x] 6. Client directory and client header show company count beside prospect
  count.
- [x] 7. Uploaded Lists can be searched by list name and Recently Added can be
  searched by record name/email/domain.
- [x] 8. Leads and Contactable are mutually exclusive quick views.
- [x] 9. Leads and Contactable appear once, inside People DB, as All / Leads /
  Contactable.
- [x] 10. People and company import completion screens name the imported list or
  collection and provide a direct navigation action.
- [x] 11. Every block operation requires exactly one of Client Provided, ICP
  Invalid, or Campaign Reply; bulk reason edits use the same vocabulary.
- [x] 12. An authenticated operator can create and revoke a submission-only
  client blocklist link. Tokens are stored only as hashes and public submissions
  are rate limited.
- [x] 13. Search and export share one server-side Maximum People per Company cap.
  The cap is applied after filters and client/company scope, before counts,
  pagination, result-set freezing, or export cursors.

## Release guidance

1. Apply the migration in a disposable schema/database and run its assertions.
2. Run unit tests, lint, and a production build.
3. Deploy the migration before the application/worker release. The application
   intentionally reports a migration-required error if the new RPCs are absent.
4. Verify archive/restore, one cross-client people push, one cross-client company
   push, a blocklist share submit/revoke cycle, and a capped search/export in the
   authenticated staging UI.
5. Watch request/error logs for the new client folder, batch, share, blocklist,
   and capped-search routes. No production data reset or RLS relaxation is part
   of this release.

## Release verification gates

The implementation boxes above mean the code paths are present. They do not
mean every behavior gate has passed. The latest migration compiled and committed
against a fresh disposable schema, but the complete behavior fixture has not
yet reached its final success marker, so the combined gates remain unchecked.

- [ ] Company import navigation reads `company_import_memberships`, not the
  purgeable `company_import_rows` staging table. The SQL fixture must delete the
  staging rows and still resolve the same imported collection through the
  current v3 company compiler.
- [ ] People imports and people pushes record only companies whose client
  membership was actually inserted, with the same stable request identity as
  the people batch. Replays must not create a second logical batch.
- [ ] Incomplete Info compiles company fields as `__keywords` and
  `__short_description`, people fields as `__company_keywords` and
  `__company_description`, and its people side requires a real linked
  `company_id`. Entity/list pivot controls remain hidden in this locked view.
- [ ] Import completion and reload use persisted `clientId`, `listId`, and
  `listName`; navigation fetches the exact client/list IDs and also works for
  the special unassigned-import client. Company navigation uses its durable
  import membership.
- [ ] Blocklist all-matching update/delete is bounded by the captured
  `selectedBefore` cutoff and explicit exclusions. The fixture inserts a later
  row and proves it is untouched.
- [ ] The per-company cap is set-based and applied after all authorized people
  and company scopes. Grid, direct export, frozen result-set/bulk operations,
  client/company pivots, and the explicit selected-row export override must all
  preserve the quota. The 100,000-row fixture and an analyzed query remain the
  performance proof.
- [ ] `npm run lint`, `npm run test:unit`, `npm run build`, the disposable SQL
  compile/behavior suite, and available route-mocked browser checks are green.
  Live-auth and production-data mutations are explicitly outside validation.

## Verification record

- `npm run lint`: passed on 25 September 2026.
- `npm run test:unit`: 663 passed, 2 intentionally skipped, 0 failed.
- `npm run build`: passed; TypeScript, production compilation, and all 45 pages
  completed.
- Route-mocked public link browser smoke: 2 passed in system Chrome. It covers
  explicit reason selection, generic acceptance, fragment removal, no token in
  the request URL, and invalid/revoked-link messaging.
- Authenticated dashboard browser validation: not run because this workspace has
  no `E2E_*` login credentials. No test-only authentication bypass was added.
- Fresh-schema SQL compile: passed. A row-free schema-only baseline was loaded
  into `prospect-migration-check-20260925`, database `schema_check`, with
  PostgreSQL data on tmpfs at `/var/lib/postgresql/data`; the current migration
  ran with `ON_ERROR_STOP` through its final `COMMIT`. The container has zero
  production mounts and contains no production row data.
- Expanded SQL behavior fixture: partial pass only. It completed the null-company
  cap check, 100,000-person cap/grid/export assertions, cap-limit rejection,
  frozen blocklist export selection checks, and submission-link enqueue/replay,
  revoked/expired rejection, client scoping, durable completion, bounded retry,
  and role-grant assertions. It then stopped on a synthetic `prospect_index`
  row because an existing classifier trigger replaced a required default with
  null. The fixture now disables triggers around that synthetic insert, but the
  corrected fixture has not been rerun. Incomplete Info, frozen result-set
  invariance, durable company-import membership, import/push provenance, the
  final analyzed query, and the `client_workspace_feature_pack_ok` marker remain
  unverified by the disposable database run.
- Production deployment or mutation: not performed.
