#!/usr/bin/env bash
#
# supabase/seed/run.sh
#
# ===========================================================================
# APPLIES FIXTURE DATA. Point it at a development or throwaway database.
# ===========================================================================
# Seeds the demo tenant (supabase/seed/10_demo_tenant.sql) and then asserts the
# result (supabase/seed/99_assert_seed.sql). With --twice it applies the seed a
# second time and re-asserts, printing a fingerprint of the demo tenant before
# and after so "the seed is idempotent" is a measured claim and not a comment.
#
# It needs nothing but psql (no Node dependencies), exactly like
# supabase/test-support/run.sh, and it refuses to run against a database that
# does not look like a development one:
#   * the migrations have to be applied already (public.tenants must exist);
#   * the database must not already hold a tenant OTHER than the demo tenant —
#     that is what a real project with real vendors looks like, and the seed has
#     no business adding a fake catalogue to it (override: --force);
#   * a database reached over the network needs --allow-remote (or
#     AIJ_SEED_ALLOW_REMOTE=1) said out loud, because that is how a real Supabase
#     project is reached.
# It prints the database it is about to write to before writing anything.
#
# The seed is fixture provisioning and runs as whoever the connection
# authenticates as: the table owner (Supabase's `postgres`, which is what
# DATABASE_URL from the dashboard gives you) or service_role, both of which
# bypass row-level security. See the header of 10_demo_tenant.sql.
#
# Usage:
#   supabase/seed/run.sh [options]
#
#   --database-url URL   Postgres connection string. Defaults to $DATABASE_URL,
#                        or to the libpq PG* environment variables when neither
#                        is set (e.g. PGHOST/PGPORT/PGUSER/PGDATABASE).
#   --seed FILE          Default: 10_demo_tenant.sql next to this script
#   --assertions FILE    Default: 99_assert_seed.sql next to this script
#   --twice              Apply the seed twice (idempotency check, used by CI)
#   --no-assert          Skip the assertion script (seed only)
#   --force              Seed even if the database holds other tenants
#   --allow-remote       Seed a database reached over the network
#   -h | --help
#
# Local run against a throwaway Postgres 16:
#   createdb aij_dev && DATABASE_URL=postgresql://localhost/aij_dev npm run test:db
#   DATABASE_URL=postgresql://localhost/aij_dev npm run seed
#
# Against a real Supabase project (an empty one, or one you are happy to put the
# demo tenant in): create the owner through Auth, then
#   DATABASE_URL='postgresql://postgres:<password>@db.<ref>.supabase.co:5432/postgres' \
#     npm run seed -- --allow-remote
# See supabase/seed/README.md.

set -euo pipefail

PSQL="${PSQL:-psql}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DATABASE_URL_OPT="${DATABASE_URL:-}"
SEED="${SCRIPT_DIR}/10_demo_tenant.sql"
ASSERTIONS="${SCRIPT_DIR}/99_assert_seed.sql"
RUNS=1
DO_ASSERT=1
FORCE=0
ALLOW_REMOTE="${AIJ_SEED_ALLOW_REMOTE:-0}"

usage() {
  sed -n '3,53p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --database-url) DATABASE_URL_OPT="${2:-}"; shift 2 ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    --assertions) ASSERTIONS="${2:-}"; shift 2 ;;
    --twice) RUNS=2; shift ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --no-assert) DO_ASSERT=0; shift ;;
    --force) FORCE=1; shift ;;
    --allow-remote) ALLOW_REMOTE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v "$PSQL" >/dev/null 2>&1; then
  echo "psql not found. Install postgresql-client (or set PSQL=/path/to/psql)." >&2
  exit 2
fi

# psql invocation: with an explicit URL, or falling back to libpq's PG* vars.
psql_run() {
  if [ -n "$DATABASE_URL_OPT" ]; then
    "$PSQL" -v ON_ERROR_STOP=1 -X --no-psqlrc -q "$DATABASE_URL_OPT" "$@"
  else
    "$PSQL" -v ON_ERROR_STOP=1 -X --no-psqlrc -q "$@"
  fi
}

query() {
  psql_run -tAc "$1"
}

fail() {
  printf '\nFAILED: %s\n' "$1" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$1"
}

[ -f "$SEED" ] || fail "seed file not found: $SEED"
[ -f "$ASSERTIONS" ] || fail "assertion file not found: $ASSERTIONS"

# ---------------------------------------------------------------------------
# 0. Who am I about to write to?
# ---------------------------------------------------------------------------
# Print the target first: this script inserts rows, and libpq defaults silently
# to a database named after the connecting user.
target="$(query "select current_database() || ' at ' || coalesce(inet_server_addr()::text, 'local socket') || ':' || coalesce(inet_server_port()::text, '-') || ' as ' || current_user" 2>/dev/null || true)"
if [ -z "$target" ]; then
  fail "cannot connect to the target database. Pass --database-url (or set DATABASE_URL / the PG* variables)."
fi
printf 'target database: %s\n' "$target"

# The demo tenant's slug is the seed's identity for idempotency, and the guard
# below keys off it, so it is read out of the seed rather than duplicated here.
DEMO_TENANT_SLUG="$(sed -n 's/^-- seed-tenant-slug: \([a-z0-9-]*\)$/\1/p' "$SEED" | head -1)"
if [ -z "$DEMO_TENANT_SLUG" ]; then
  fail "cannot read the demo tenant slug from $SEED (expected a '-- seed-tenant-slug: <slug>' line)."
fi
printf 'demo tenant slug: %s\n' "$DEMO_TENANT_SLUG"

# ---------------------------------------------------------------------------
# 1. Guards
# ---------------------------------------------------------------------------
if ! query "select to_regclass('public.tenants') is not null" | grep -q '^t$'; then
  fail "public.tenants does not exist in the target database, so the migrations have not been applied.
Apply them first (npm run test:db for a throwaway Postgres, or supabase db push for a project),
then run this seed."
fi

if [ "$FORCE" -ne 1 ]; then
  others="$(query "select count(*) from public.tenants where slug <> '${DEMO_TENANT_SLUG}'")"
  if [ -n "$others" ] && [ "$others" != "0" ]; then
    fail "the target database already holds ${others} tenant(s) other than the demo tenant.
That is what a real project with real vendors looks like, and this seed exists to
put one fake Lagos fashion catalogue somewhere it can be thrown away. Point
DATABASE_URL at a development database (npm run test:db builds one), or re-run
with --force if you are certain this is the right target."
  fi
fi

# Which host are we connecting TO? Taken from the connection string (or PGHOST),
# not from inet_server_addr(): that reports `127.0.0.1/32` (with a netmask) for a
# TCP connection, nothing at all for a unix socket, and the container gateway
# from inside a container network — so a rule written against it would refuse
# CI's own Postgres service on localhost, and would wave through a container-to-
# container connection it cannot see.
conn_host() {
  local url="$1" h=""
  case "$url" in
    *[?\&]host=*) h="$(printf '%s' "$url" | sed -n 's/.*[?&]host=\([^&]*\).*/\1/p')" ;;
  esac
  if [ -z "$h" ]; then
    # postgresql://user:pass@host:port/db -> host
    local rest="${url#*://}"
    rest="${rest%%/*}"
    h="${rest##*@}"
    h="${h%%:*}"
  fi
  printf '%s' "$h"
}

if [ -n "$DATABASE_URL_OPT" ]; then
  CONN_HOST="$(conn_host "$DATABASE_URL_OPT")"
else
  CONN_HOST="${PGHOST:-}"
fi
server_addr="$(query "select coalesce(host(inet_server_addr()), '')")"

is_local=0
case "$(printf '%s' "$CONN_HOST" | tr 'A-Z' 'a-z')" in
  ''|'/'*|'localhost'|'127.0.0.1'|'::1'|'[::1]')
    is_local=1 # a unix socket or loopback: a throwaway database
    ;;
  *)
    # Belt and braces: if the server saw a loopback peer address, the connection
    # never left this machine, however the host was spelled.
    case "$server_addr" in
      '127.0.0.1'|'::1') is_local=1 ;;
    esac
    ;;
esac

if [ "$is_local" -ne 1 ]; then
  if [ "$ALLOW_REMOTE" != "1" ]; then
    fail "the target database is reached over the network (host ${CONN_HOST}).
This seed inserts a demo tenant, its 20 products and its channels. If that is
what you want — an empty Supabase project you are happy to put demo data in —
say so: re-run with --allow-remote (or AIJ_SEED_ALLOW_REMOTE=1)."
  fi
  printf 'WARNING: seeding a REMOTE database (host %s)\n' "$CONN_HOST"
fi


# ---------------------------------------------------------------------------
# 2. Fingerprint of the demo tenant
# ---------------------------------------------------------------------------
# Every fixture row carries a fixed uuid and no timestamp, so a re-seed that
# really is idempotent produces the same fingerprint. Row counts across the
# whole database are folded in, which is what catches a duplicate tenant or a
# stray orphan row.
fingerprint_sql="
with t as (select id from public.tenants where slug = '${DEMO_TENANT_SLUG}')
select md5(coalesce(string_agg(row_text, E'\n' order by row_text), ''))
from (
  select 'tenant|' || x.id || '|' || x.slug || '|' || x.name || '|' || x.tone_profile || '|'
                 || x.currency || '|' || coalesce(x.paystack_subaccount_code, '-') || '|' || x.active::text as row_text
    from public.tenants x where x.id in (select id from t)
  union all
  select 'product|' || p.id || '|' || p.sku || '|' || p.name || '|' || p.category || '|' || p.list_price::text
                 || '|' || p.floor_price::text || '|' || p.stock::text || '|' || p.active::text || '|' || p.photos::text
    from public.products p where p.tenant_id in (select id from t)
  union all
  select 'policy|' || o.id || '|' || o.delivery_fees::text || '|' || o.return_policy || '|' || o.discount_steps::text
                 || '|' || o.max_counter_steps::text || '|' || o.bulk_threshold::text || '|' || o.handoff_rules::text
    from public.policies o where o.tenant_id in (select id from t)
  union all
  select 'knowledge|' || k.id || '|' || k.question || '|' || k.answer || '|' || k.tags::text || '|' || k.active::text
    from public.knowledge k where k.tenant_id in (select id from t)
  union all
  select 'channel|' || c.id || '|' || c.type || '|' || c.label || '|' || coalesce(c.phone_number_id, '-') || '|'
                 || coalesce(c.instagram_account_id, '-') || '|' || c.access_token_encrypted || '|' || c.active::text
    from public.channels c where c.tenant_id in (select id from t)
  union all
  select 'tenant_user|' || u.id || '|' || u.role || '|' || u.user_id::text
    from public.tenant_users u where u.tenant_id in (select id from t)
  union all
  select 'count|' || name || '=' || n::text from (
    select 'tenants' as name, count(*)::bigint as n from public.tenants
    union all select 'products', count(*) from public.products
    union all select 'policies', count(*) from public.policies
    union all select 'knowledge', count(*) from public.knowledge
    union all select 'channels', count(*) from public.channels
    union all select 'tenant_users', count(*) from public.tenant_users
    union all select 'contacts', count(*) from public.contacts
    union all select 'conversations', count(*) from public.conversations
    union all select 'messages', count(*) from public.messages
    union all select 'offers', count(*) from public.offers
    union all select 'orders', count(*) from public.orders
    union all select 'weekly_reports', count(*) from public.weekly_reports
  ) c
) s"

fingerprint() { query "$fingerprint_sql"; }

# ---------------------------------------------------------------------------
# 3. Apply the seed (once, or twice with --twice)
# ---------------------------------------------------------------------------
before="$(fingerprint)"
printf 'fingerprint before seeding: %s\n' "$before"

run=1
while [ "$run" -le "$RUNS" ]; do
  if [ "$RUNS" -gt 1 ]; then
    step "seed ($run of $RUNS): $(basename "$SEED")"
  else
    step "seed: $(basename "$SEED")"
  fi
  if ! psql_run -f "$SEED"; then
    fail "the seed did not apply: $SEED"
  fi

  after="$(fingerprint)"
  printf 'fingerprint after run %s: %s\n' "$run" "$after"

  if [ "$run" -gt 1 ] && [ "$after" != "$first_after" ]; then
    fail "re-running the seed changed the demo tenant.
The seed must be idempotent: the same single tenant, the same 20 products, no
duplicates. Before: ${first_after}
After:  ${after}"
  fi
  if [ "$run" -eq 1 ]; then
    first_after="$after"
  fi

  run=$((run + 1))
done

# ---------------------------------------------------------------------------
# 4. Assert the result
# ---------------------------------------------------------------------------
if [ "$DO_ASSERT" -eq 1 ]; then
  step "seed assertions: $(basename "$ASSERTIONS")"
  if ! psql_run -f "$ASSERTIONS"; then
    fail "a seed assertion failed (see the message above): $ASSERTIONS"
  fi
fi

if [ "$RUNS" -gt 1 ]; then
  printf '\nOK: demo tenant seeded %s times, identical both times, assertions passed.\n' "$RUNS"
else
  printf '\nOK: demo tenant seeded, assertions passed. (--twice to prove it is idempotent.)\n'
fi
