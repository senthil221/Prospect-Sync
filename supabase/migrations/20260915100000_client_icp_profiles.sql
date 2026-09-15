-- Somewhere to paste a client's ICP descriptions.
--
-- WHY A TABLE AND NOT A COLUMN ON clients. The request is for "text boxes",
-- plural, and an agency routinely runs several ICPs for one client - "UK
-- mid-market SaaS" and "US enterprise fintech" are two different targeting
-- briefs with two different descriptions. A single text column on clients
-- answers today's request and has to be migrated the first time somebody wants
-- a second one.
--
-- WHY tag_id IS HERE ALREADY. An ICP is a thing you describe AND a thing you
-- label prospects and companies with. The tag request and this one are the name
-- and the body of one object, so a profile can own the tag that assigns it -
-- create "Enterprise SaaS" as an ICP and the tag you apply is that ICP, rather
-- than a second unrelated string that happens to match.
--
-- The column is nullable and unused until the tag work lands, which is what
-- keeps this migration independent: nothing else in the system reads this table
-- yet, so it can ship on its own and be wrong about nothing.
--
-- WHY description IS UNBOUNDED text. These are pasted paragraphs, sometimes
-- pages. The cap belongs in the API, where going over it can be answered with a
-- number, rather than in the column, where it would silently truncate somebody's
-- brief. That is this codebase's stated convention - see the FilterLimitError
-- comment in lib/prospect-filters.ts: "Nothing is silently trimmed."
--
-- NOT "position": it is a SQL function name, and a column called position has
-- to be quoted everywhere it is used or it reads as a call. sort_order says the
-- same thing and never needs quoting.
-- ---------------------------------------------------------------------------

create table if not exists public.client_icp_profiles (
  id text primary key,
  client_id text not null references public.clients(id) on delete cascade,
  name text not null default '',
  description text not null default '',
  tag_id text references public.prospect_tags(id) on delete set null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.client_icp_profiles is
  'Named ICP definitions for one client: a name, a pasted description, and optionally the tag that assigns it.';

-- The only read this table has: one client's ICPs, in display order.
create index if not exists idx_client_icp_profiles_client
  on public.client_icp_profiles (client_id, sort_order, id);

-- Same posture as every other client-scoped table in this schema. There are no
-- policies anywhere here and none is added: this app has no client logins, the
-- allowlist in lib/auth.ts gates agency staff, and every read goes through
-- service_role. RLS is the wall that stops anon/authenticated reaching
-- PostgREST directly, not a tenancy mechanism.
alter table public.client_icp_profiles enable row level security;
revoke all on public.client_icp_profiles from public, anon, authenticated;
grant select, insert, update, delete on public.client_icp_profiles to service_role;

-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.client_icp_profiles') is null then
    raise exception 'client_icp_profiles was not created';
  end if;

  if not exists (
    select 1 from pg_class where relname = 'client_icp_profiles' and relrowsecurity
  ) then
    raise exception 'client_icp_profiles must have row level security enabled';
  end if;

  -- The grant that would matter if it were ever wrong: a client-scoped table
  -- readable by anon is reachable from the public PostgREST endpoint.
  if has_table_privilege('anon', 'public.client_icp_profiles', 'SELECT')
     or has_table_privilege('authenticated', 'public.client_icp_profiles', 'SELECT') then
    raise exception 'client_icp_profiles must not be readable by anon or authenticated';
  end if;

  -- Deleting a client takes its ICPs with it; deleting a tag leaves the ICP and
  -- only forgets which tag assigned it.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.client_icp_profiles'::regclass
       and confrelid = 'public.clients'::regclass and confdeltype = 'c'
  ) then
    raise exception 'client_icp_profiles.client_id must cascade on client delete';
  end if;
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.client_icp_profiles'::regclass
       and confrelid = 'public.prospect_tags'::regclass and confdeltype = 'n'
  ) then
    raise exception 'client_icp_profiles.tag_id must null out when its tag is deleted';
  end if;
end $$;
