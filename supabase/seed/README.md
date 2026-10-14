# supabase/seed

The demo tenant: **one** Lagos fashion vendor with 20 products, its policies,
its FAQs, its owner and both messaging channels. Every later feature is built
and tested against this data — the webhook ingress routes Meta payloads to it,
the agent tools read its prices and stock, and the conversation simulator
negotiates against its policy row.

| File | What it is |
| --- | --- |
| `10_demo_tenant.sql` | The seed. One tenant, deleted and re-inserted on every run so the file is idempotent. |
| `99_assert_seed.sql` | 188 assertions on the result: 20 products, `floor_price <= list_price`, the negotiation ladder never breaking the floor, a complete policy row, 10+ FAQs with no money in them, both channels with the routing keys PR 4 resolves tenants by. Runs in a transaction that ends in `ROLLBACK`. |
| `run.sh` | Applies the guard → the seed (once, or twice with `--twice`) → the assertions, with `psql -v ON_ERROR_STOP=1`. Prints a fingerprint of the demo tenant so idempotency is measured, not asserted. |

## Running it

```bash
# A throwaway database with the migrations applied. npm run test:db builds one:
# the shim, every migration, then the RLS assertions (test-only scaffolding).
createdb aij_dev
export DATABASE_URL=postgresql://localhost/aij_dev
npm run test:db
npm run seed                  # seed + assert
npm run seed -- --twice       # seed twice, same fingerprint, then assert (what CI runs)
```

Nothing here needs Node packages beyond `npm run` itself: `run.sh` is `psql`
only, like `supabase/test-support/run.sh`.

### Against a real Supabase project

The seed is Supabase-compatible SQL. Point `DATABASE_URL` at the project's
**direct** Postgres connection string (dashboard → Project Settings → Database →
Connection string), which authenticates as the table owner and therefore
bypasses RLS — which is what a seed needs:

```bash
DATABASE_URL='postgresql://postgres:<password>@db.<project-ref>.supabase.co:5432/postgres' \
  npm run seed -- --allow-remote
```

Two things to know before doing that:

1. **`--allow-remote` is deliberate.** `run.sh` refuses a database reached over
   the network, and refuses a database that already holds any tenant other than
   the demo one, because that is what a real project with real vendors looks
   like. Seeding is for development databases; say `--allow-remote` (or set
   `AIJ_SEED_ALLOW_REMOTE=1`) only when you mean it, and `--force` only for the
   "other tenants" guard.
2. **The owner login.** `public.tenant_users` references `auth.users`, so the
   seed inserts a minimal `auth.users` row for the owner
   (`owner@sisi-lagos-fashion.test`). On a real project, create the owner
   through Supabase Auth instead (sign up, or dashboard → Authentication → Add
   user) and keep its uuid: the seed's `on conflict (id) do nothing` leaves an
   existing row alone, so either edit the uuid in `10_demo_tenant.sql` to the
   real user's, or run just the membership insert:

   ```sql
   insert into public.tenant_users (tenant_id, user_id, role)
   select id, '<auth-user-uuid>', 'owner' from public.tenants where slug = 'sisi-lagos-fashion';
   ```

If you use the Supabase CLI, `supabase db reset` looks for `supabase/seed.sql`
by default. It can be pointed at this file instead, in `supabase/config.toml`:

```toml
[db.seed]
enabled = true
sql_paths = ["./seed/10_demo_tenant.sql"]
```

`99_assert_seed.sql` is not part of that path — it is a check, not data.

## The demo tenant

| | |
| --- | --- |
| Name | Sisi Lagos Fashion |
| **Slug (identity for idempotency)** | `sisi-lagos-fashion` |
| Currency / money | NGN, every amount an integer count of **kobo** (₦24,500 = `2450000`) |
| WhatsApp route | `channels.phone_number_id = 109876543210987` |
| Instagram route | `channels.instagram_account_id = 17841400000000001` |
| Products | 20, SKUs `SLF-001` … `SLF-020`, list ₦12,000–₦62,000 |
| FAQs | 16 in `knowledge`, tagged `sizing`, `fabric`, `delivery`, `payment`, `returns`, `bulk`, `location`, `custom`, `care`, `security`, `orders`, `complaint`, `aso-ebi` |
| Owner | one `tenant_users` row, role `owner` |

Every fixture row carries a fixed uuid in the
`5eed0000-0000-4000-8000-0000000000xx` range, so a feature can hard-code
`5eed0000-0000-4000-8000-000000000206` (the senator kaftan) and get the same
garment every time. `tenant_users` and the seed's `auth.users` row live under
`…00a1` / `…00b1`.

The catalogue deliberately contains the shapes the edge-case paths need:

- `SLF-009` — active, `stock = 0`: the "sold out" reply.
- `SLF-019` — `active = false`, `stock = 3`: withdrawn, so the agent must not
  offer it even though stock remains.
- `SLF-020` — `active = false`, `stock = 0`: discontinued.

Stock across the 20 rows runs 0–20 with 11 distinct levels.

## How the seed stays idempotent

`public.tenants.slug = 'sisi-lagos-fashion'` is the stable identity. The seed is
a scoped `DELETE` by that slug followed by an `INSERT`, and every tenant-scoped
table cascades from `tenants`, so re-running it leaves exactly one demo tenant
with the same 20 products — never two, never a duplicate-key error.

`run.sh --twice` applies the seed twice and compares an md5 fingerprint of every
demo row (ids, prices, stock, JSON, channel routing keys) plus the row counts of
all twelve tables in the database. Identical fingerprints mean the second run
changed nothing. CI runs exactly that.

`run.sh` also refuses to run when `public.tenants` does not exist (migrations
first), and it prints the target database before writing anything.

## What this is not

- **Not a migration.** It never runs as part of `supabase/migrations/`, and it is
  never applied by `npm run test:db`.
- **Not production data.** It is a fixture. Do not put it on a project that holds
  real vendors, and do not treat the products, prices or the tone profile as a
  real catalogue.
- **Not test-only scaffolding** like `supabase/test-support/` (which stands in
  for Supabase's own bootstrap and must never touch a real project). This seed
  *is* Supabase-compatible SQL; it is still fixture data, and it still says so.
