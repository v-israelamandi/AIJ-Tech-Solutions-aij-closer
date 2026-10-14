# supabase/test-support

**Test-only. Never apply anything in this directory to a real Supabase project.**
A real project provides the roles, the `auth` schema, `auth.uid()` and the
project's default privileges natively; this directory exists only so that the
migrations in `supabase/migrations/` can be *executed* and their row-level
security *asserted* against a throwaway Postgres — locally and in CI. The
migrations themselves are Supabase-compatible and are applied unchanged.

A schema whose RLS has never run is a schema whose RLS is unverified, which is
why this is here at all: the product's entire security boundary is that one
vendor can never see another vendor's customer conversations or money.

| File | What it is |
| --- | --- |
| `00_supabase_shim.sql` | Stands in for Supabase's own bootstrap: creates `anon`, `authenticated` and `service_role` (with `BYPASSRLS`), the `auth` schema, `auth.users`, `auth.uid()` reading `current_setting('request.jwt.claims')->>'sub'`, and Supabase's permissive default privileges on `public`. |
| `99_assertions.sql` | Two tenants, separate users, one row per table per tenant, then ~144 assertions executed through `set role`. Any failure raises and exits non-zero. |
| `run.sh` | Applies shim → every migration in filename order → assertions, with `psql -v ON_ERROR_STOP=1`. Refuses to run against a database that already has tables in `public`. |

## Running it

```bash
# A throwaway database. Postgres 16 is what CI uses.
createdb aij_test
DATABASE_URL=postgresql://localhost/aij_test supabase/test-support/run.sh

# or, equivalently, with libpq's PG* variables:
PGDATABASE=aij_test supabase/test-support/run.sh

# from the repo root:
npm run test:db
```

Options: `--database-url URL`, `--migrations-dir DIR`, `--shim FILE`,
`--assertions FILE`, `--force`. `run.sh` prints the database it is about to
modify before touching anything.

## What the assertions prove

The whole file runs inside one transaction that ends in `ROLLBACK`, so nothing
is left behind and it is safe to re-run. In outline:

- **Structure** — every table in the brief's data model exists; every table in
  `public` has RLS enabled; every table with a `tenant_id` column has at least
  one policy (RLS enabled with no policy is deny-all: safe, but broken);
  `FORCE ROW LEVEL SECURITY` is not set anywhere.
- **Constraints** — the enum `CHECK`s reject the values `@aij/shared` rejects
  (`status`, `direction`, `type`, `payment_status`, channel type); a price below
  the floor, a negative price, and an order `amount` that is not
  `unit_price * quantity + delivery_fee` are all rejected.
- **Indexes** — `messages.meta_message_id` and `orders.paystack_reference` are
  unique *when set* and allow many NULLs; a duplicate of either is rejected.
- **Tenant A's user** — every tenant-scoped table returns exactly A's one row
  and zero rows of any other tenant; a cross-tenant `SELECT` returns nothing;
  inserting a row stamped with tenant B's id raises `42501`; a message of A's
  cannot be attached to B's conversation (composite FK, `23503`); updating or
  deleting B's row by primary key affects zero rows; A's own inserts, updates
  and deletes still work (isolation must not be deny-all).
- **Tenant B's user** — the mirror image, so a policy that only ever worked for
  one tenant cannot pass.
- **Authenticated non-member** — sees nothing in any table.
- **anon** — sees nothing and writes nothing, *including while carrying tenant
  A's JWT claim*, since that is what an attacker would try.
- **service_role** — `BYPASSRLS` is granted, all 11 tenant-scoped tables expose
  both tenants' rows, and it can write for either tenant.
- **Cascade** — deleting a tenant removes every row it owns and leaves the other
  tenant intact.

`run.sh` reports the number of checks executed, so a suite that silently stopped
early is visible.

## Negative controls (evidence the suite can fail)

Deleting or weakening a policy must break it. Both of these were run against
scratch copies of `supabase/migrations/` and both exit non-zero:

- `products_tenant_isolation`'s `using (public.is_tenant_member(tenant_id))`
  replaced with `using (true)` →
  `ASSERTION FAILED: [tenant A read] public.products: expected 1 own row(s) and 0
  foreign rows, got 2 visible of which 1 belong to another tenant`.
- `messages_tenant_isolation` deleted entirely (RLS enabled, no policy) →
  `ASSERTION FAILED: tables with RLS enabled but no policy (deny-all): {messages}`.

One thing worth knowing: for a `FOR ALL` policy, Postgres uses the `USING`
expression as the `WITH CHECK` expression when `WITH CHECK` is omitted, so
deleting the `with check` line alone is not a hole. The explicit `with check` in
the migrations is kept because it survives the policy being narrowed to
`FOR SELECT` later.
