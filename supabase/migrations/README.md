# Database migrations

This directory holds the versioned SQL that defines the AIJ Closer schema in
Supabase (Postgres). It is the whole data contract for the product — and, since
one deployment serves many vendors, it is also where tenant isolation is
enforced.

| Migration | What it creates |
| --- | --- |
| `20261014120000_core_tables.sql` | `set_updated_at()`, `tenants`, `tenant_users`, `channels`, `products`, `policies`, `knowledge` |
| `20261014120100_conversation_tables.sql` | `contacts`, `conversations`, `messages`, `offers`, `orders`, `weekly_reports` |
| `20261014120200_rls_tenant_isolation.sql` | `is_tenant_member()`, and row-level security on every table |

## What goes here

- One forward-only migration per change: `<timestamp>_<snake_case_name>.sql`
  (create them with `supabase migration new <name>` so the timestamp is
  generated). Migrations are applied in filename order, exactly as written — a
  migration that has already been applied is never edited; the fix is a new
  migration.
- Every tenant-scoped table carries
  `tenant_id uuid not null references public.tenants(id) on delete cascade`, and
  a row-level security policy in `20261014120200_rls_tenant_isolation.sql`.
  Migrations must leave no table in `public` without RLS.
- Child rows reference their parent on `(tenant_id, id)`, not `id` alone (for
  example `messages (tenant_id, conversation_id) references conversations
  (tenant_id, id)`). Foreign-key checks are *not* filtered by RLS, so without
  this a row of one tenant could be attached to another tenant's conversation.
- Channel access tokens are stored encrypted, in `channels.access_token_encrypted`.
  The column name is the contract: plaintext must never be written to it. App
  code encrypts with `CHANNEL_TOKEN_ENCRYPTION_KEY` before writing.

## Money is an integer count of kobo

Every monetary column in this schema — `products.list_price`,
`products.floor_price`, `offers.price`, `orders.unit_price`,
`orders.delivery_fee`, `orders.amount`, the values inside
`policies.delivery_fees` and `weekly_reports.payload` — is an `integer` in
**kobo**, the minor unit of NGN (1 NGN = 100 kobo). ₦25,000 is stored as
`2500000`. There is no floating point or decimal money anywhere, and no
formatted string: the core principle of the product is that code, never the
model, makes every price commitment, and integers make those commitments exact.
`tenants.currency` pins the currency; `orders_amount_matches_line` enforces
`amount = (unit_price * quantity) + delivery_fee`, so a total can only ever be
arithmetic over stored values. Each column carries the unit in its column
comment (`\d+ public.orders` in psql, or the Supabase table editor).

## Row-level security

- `public.is_tenant_member(uuid)` is `security definer`, `stable`, with
  `search_path` locked to empty. It returns true when `auth.uid()` is a member
  of the given tenant according to `tenant_users`. Every tenant-scoped policy is
  written against it.
- `authenticated` (a logged-in dashboard user) sees and writes only its own
  tenant's rows: `using` filters reads and `with check` refuses writes that name
  another tenant. `tenants` and `tenant_users` are narrower — a member reads its
  own tenant row and its own membership row only.
- `anon` has no policy on any table, so it reads nothing and writes nothing.
- `service_role` has `BYPASSRLS` and is used server-side only (webhooks, agent
  tools, cron jobs).
- Do not `ALTER TABLE ... FORCE ROW LEVEL SECURITY` on `tenant_users`:
  `is_tenant_member()` relies on the table owner's exemption, and forcing RLS
  there would make it recurse. The assertion script fails if FORCE RLS is set.

## How they are applied

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

### Applying them without the CLI

Any Postgres will do, in filename order:

```bash
# DATABASE_URL is the direct Postgres connection string, from
# Supabase dashboard -> Project Settings -> Database -> Connection string.
for f in supabase/migrations/*.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
```

Two things to know if you take this path against something that is not Supabase:
`gen_random_uuid()` needs Postgres 13+ (Supabase runs newer), and the roles
`anon` / `authenticated` / `service_role` plus the `auth` schema only exist on
Supabase. Without them the `auth.users` foreign key and the RLS policies cannot
be created — which is exactly what the test-support shim below stands in for.
Against a real project, use the CLI (`supabase db push`).

## supabase/test-support/ — what it is, and what it is NOT

`test-support/` is a **test-only** harness: a Supabase-compatibility shim plus an
assertion script that proves the RLS policies actually isolate tenants by
running them (`shim -> migrations -> assertions`, `psql -v ON_ERROR_STOP=1`), and
a `run.sh` that ties the three together and exits non-zero on any failure.

**Never apply it to a real Supabase project.** A real project already has the
roles, the `auth` schema and `auth.uid()` natively; the shim exists only so the
migrations can be executed and asserted against a throwaway Postgres (locally,
and in CI's `database` job). The migrations themselves never import anything
from `test-support/` and run unchanged on Supabase.

```bash
createdb aij_test
DATABASE_URL=postgresql://localhost/aij_test supabase/test-support/run.sh
```

See `supabase/test-support/README.md` for what the assertions cover.
## supabase/seed/ — the demo tenant (not a migration)
`supabase/seed/` holds fixture data, not schema: one demo fashion tenant with 20
products, its policies, its FAQs, its owner and both Meta channels. It is applied
*after* the migrations, by `supabase/seed/run.sh` (`npm run seed`), which is
idempotent and asserts the result. It is never applied by `supabase db push` or
by `npm run test:db`. See `supabase/seed/README.md`.
