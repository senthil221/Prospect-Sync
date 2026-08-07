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

## Data workspace

The master database exposes every uploaded CSV field through a configurable horizontal table. Name, company, email, and title are visible by default; additional standard or uploaded fields can be shown or hidden. Search and multi-field filters run on the server with pagination, so the workflow remains usable as the database grows.

Each import records its complete header set and preserves every valid source row in `list_rows`, including repeated prospects within the same client list. The import preview and client-list summary show how many fields were detected and stored.

## Safe deletion

Imports, lists, and clients can be removed from the dashboard after confirmation. Cleanup is transactional: client-list links are removed first, and an optional orphan cleanup deletes a master prospect only when no remaining client list uses it. Companies are removed only when no master prospect references them.
