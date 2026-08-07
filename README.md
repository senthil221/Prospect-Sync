# ProspectHub

ProspectHub is a centralized prospect database for cold-email agency operations. It imports client CSV lists, preserves every source field, links duplicate people to one master record, and tracks company and client-list coverage.

## Stack

- Next.js App Router
- Supabase PostgreSQL and passwordless email authentication
- Vercel hosting

## Supabase setup

1. Create a Supabase project.
2. Open the Supabase SQL Editor and run `supabase/migrations/20260807000000_initial_schema.sql`.
3. In Supabase Authentication URL Configuration, set the Site URL to your Vercel URL and add `https://YOUR-VERCEL-DOMAIN/auth/callback` as a redirect URL.
4. Copy `.env.example` to `.env.local` and enter the project values.
5. Set `ALLOWED_USER_EMAILS` to the comma-separated email addresses for the agency owner and boss.

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
