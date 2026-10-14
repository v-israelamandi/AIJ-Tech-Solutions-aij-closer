# Database migrations

This directory holds the versioned SQL that defines the AIJ Closer schema in
Supabase (Postgres). **No SQL exists yet** — the schema lands in the next PR.

## What goes here

- One forward-only migration per change: `<timestamp>_<snake_case_name>.sql`
  (create them with `supabase migration new <name>` so the timestamp is generated).
- Every tenant-scoped table: `tenants`, `tenant_users`, `channels`, `products`,
  `policies`, `knowledge`, `contacts`, `conversations`, `messages`, `offers`,
  `orders`, `weekly_reports` — each with `tenant_id` and row-level security
  policies so a tenant user can only ever read or write their own rows.
- Channel access tokens are stored encrypted (see `CHANNEL_TOKEN_ENCRYPTION_KEY`);
  the service role key is used server-side only, never in the dashboard.

## How they are applied

Migrations are applied in filename order, exactly as written — a migration that
has already been applied is never edited; the fix is a new migration.

```bash
# Local development (Docker required)
supabase start          # boots a local Postgres + Studio
supabase db reset       # re-applies every migration from scratch

# Linked remote project
supabase link --project-ref <project-ref>
supabase db push        # applies migrations that are not yet on the remote
```

The Supabase CLI reads its access token from `SUPABASE_ACCESS_TOKEN` (or a prior
`supabase login`). That token is a secret: keep it in the environment, never in
the repo, and never commit a migration that contains a real credential.
