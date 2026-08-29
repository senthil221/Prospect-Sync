# Prospect Sync

Prospect Sync is a centralized prospect database for cold-email agency operations. It imports client CSV lists, preserves every source field, links duplicate people to one master record, and tracks company and client-list coverage.

## Stack

- Next.js App Router
- Supabase PostgreSQL and email/password authentication
- Vercel hosting

## Supabase setup

1. Create a Supabase project.
2. Open the Supabase SQL Editor and run the files in `supabase/migrations` in filename order.
3. In Supabase Authentication, open **Users** and create one user for each approved team member with an email and permanent password.
4. Copy `.env.example` to `.env.local` and enter the project values.
5. Set `ALLOWED_USER_EMAILS` to the comma-separated email addresses for the agency owner and boss. These must match the Supabase users.

## Vercel environment variables

Add these to Production, Preview, and Development:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `ALLOWED_USER_EMAILS`

Never expose the service-role key in client-side code or commit it to Git.

## Local development

```bash
npm install
npm run dev
```

## Deduplication rules

A CSV row matches an existing master prospect when any normalized identifier matches:

1. Work email
2. Personal email
3. LinkedIn URL
4. Full name plus company domain

The original row remains attached to its client list. Missing master fields are filled from later imports, while existing non-empty master values are preserved.

Duplicate import counts and duplicate-review candidates are client-aware: an existing person is counted as an overlap only when that person already belongs to a different client. Repeated appearances within the same client remain ordinary list memberships and are not reported as cross-client duplicates.

## Data workspace

The master database exposes every uploaded CSV field through a configurable horizontal table. Name, company, email, title, and list memberships are visible by default; additional standard or uploaded fields can be shown or hidden. Search and multi-field filters run on the server before pagination. Filter-value suggestions are queried from the complete database (or the complete client scope), rather than inferred from the current page, so every saved list, client, and field value remains discoverable.

Each client workspace includes Uploaded lists, Master DB, and Company DB tabs. The client databases are scoped through indexed server queries and prefetched when a client is opened for seamless tab switching.

Each import records its complete header set and preserves every valid source row in `list_rows`, including repeated prospects within the same client list. The import preview and client-list summary show how many fields were detected and stored.

## ESP and secure email gateway detection

Apply `supabase/migrations/20260809000000_email_provider_enrichment.sql`, then open the master database and choose **Detect ESPs**. The server resolves each unique company domain once, falls back to Cloudflare DNS-over-HTTPS when direct DNS is unavailable, stores the observed MX hosts on the company, and exposes the exact detected provider in the **ESP** prospect column.

Use the **Email provider type** filter with `SEG` to isolate MX-visible secure email gateways, or filter **ESP** for a provider such as Mimecast, Proofpoint, Barracuda, Cisco Secure Email, Sophos Email, Trend Micro Email Security, or Hornetsecurity. Google Workspace, Microsoft 365, and other direct mailbox providers are classified separately.

MX records only reveal services that receive mail for the domain. API-only or post-delivery security products do not change MX records and therefore cannot be identified reliably by this scan; those domains retain their visible mailbox provider instead of being guessed.

## Master data isolation

The People database and the Company database are storage. Clients and lists are views onto that storage, held together by `list_memberships` and `list_rows`.

**Deleting anything on the client side can never delete a master record.** Removing a client, a list, an import, or a single person from a list removes only the links; the prospect and the company stay exactly as they are, available to every other client. This is enforced in the database, not just in the UI: `delete_client_with_cleanup`, `delete_list_with_cleanup`, and `delete_import_with_cleanup` have no code path that reaches `prospects` or `companies`, and the `cleanup_orphaned_master_records` function that used to delete "orphaned" master rows has been dropped outright. Their `p_delete_orphans` argument is still accepted, for older deployed builds that pass it, but is inert.

The reverse direction is unchanged and intended: deleting a person from the People database also removes their list links, and deleting a company unlinks its people (they survive, without a company).

### Pushing people from master into a list

Select people in the People database - a page, a selection across pages, or everything matching the current filters - and choose **Add to client list**. They are linked into the chosen list (new or existing); anyone already on it is left alone rather than duplicated, and nothing about the master record changes.

Each push is recorded as an import row, so it appears in the Imports panel with its provenance and can be undone in one click exactly like a CSV upload.

## Company duplicate handling

A company row in an upload matches a stored company by normalized website first, then by normalized name when at least one of the two has no website. Every company upload chooses what happens on a match:

| Mode | Behaviour |
| --- | --- |
| **Fill in what's missing** (default) | Only blanks are filled. Nothing already stored is changed. |
| **Let this file win** | Stored values are replaced wherever this file supplies one. Fields the file does not have are left alone, so a narrow CSV cannot blank out data you already collected. |
| **Skip matches entirely** | Matched companies are untouched and counted as skipped. Only new companies are written. |

The mode is stored on the import, so a resumed upload continues under the mode it started with.

## Job title classifier

Every prospect's raw job title is classified into a department (one of 18), an optional sub-department, and a seniority tier (`owner` · `c_suite` · `vp` · `director` · `manager` · `senior_ic` · `entry`). It is deterministic - two keyword scans over a normalized copy of the title, no AI and no network call - and it runs automatically on every write.

The raw title is never modified. Results land in separate columns (`title_seniority`, `title_department`, `title_sub_department`, `title_is_former`) beside the `Seniority`/`Departments` columns that came with the upload, so the imported values are preserved and the classifier can be re-run at any time without destroying data. Filter on them under **From job title** in the filter panel, add them as table columns, or include them in a CSV export.

### Improving the keyword lists

The lists are data, in `data/seniority_map.csv` and `data/department_map.csv`. Editing them needs no deploy.

1. See which titles are not resolving, worst first:
   ```bash
   curl -s "$APP_URL/api/prospects/classify?missing=any&limit=200"
   ```
2. Add keywords to the CSVs. Longest phrase wins (up to eight tokens), so `assistant manager` overrides `manager` and `executive assistant to the md` overrides `md`. A `none` tier consumes tokens without contributing a rank, which is how `lead generation` stops `lead` from firing. Prefer precise phrases over ambiguous bare words: the Undefined log is safer than a confident false positive.
3. Push the lists to the database (upserts what is present, deletes what you removed):
   ```bash
   node scripts/sync-title-keywords.mjs
   ```
4. Re-classify the prospects the change affects. Repeat while `remaining` is `true`:
   ```bash
   curl -s -X POST "$APP_URL/api/prospects/classify"
   ```

Any keyword change timestamps the lists, and step 4 only revisits prospects classified before that timestamp - it is not a full-table rebuild.

Known limitations, accepted by design: `md` is read as Managing Director except at a company that looks like a healthcare provider; bare function words (`Sales`) carry a department but no seniority; multi-department titles take the earliest-mentioned department; and non-Latin scripts are out of scope and land in the gaps report.
