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

## Safe deletion

Imports, lists, and clients can be removed from the dashboard after confirmation. Cleanup is transactional: client-list links are removed first, and an optional orphan cleanup deletes a master prospect only when no remaining client list uses it. Companies are removed only when no master prospect references them.
