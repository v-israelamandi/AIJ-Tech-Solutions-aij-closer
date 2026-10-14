#!/usr/bin/env bash
#
# supabase/test-support/run.sh
#
# ===========================================================================
# TEST-ONLY. NEVER POINT THIS AT A REAL SUPABASE PROJECT.
# ===========================================================================
# It creates the anon/authenticated/service_role roles, an `auth` schema, two
# tenants of fixture data and a pile of probe rows, then executes the RLS
# policies to prove tenant isolation. A real Supabase project already has all of
# that natively and must never receive this file.
#
# It applies, in order, to a throwaway database:
#   1. 00_supabase_shim.sql   — the Supabase compatibility shim (test-only)
#   2. supabase/migrations/*.sql — every migration, in filename order, exactly
#      as they run on Supabase (unchanged)
#   3. 99_assertions.sql      — the RLS assertions; any failure raises, psql is
#      run with `-v ON_ERROR_STOP=1`, and this script exits non-zero
#
# Usage:
#   supabase/test-support/run.sh [options]
#
#   --database-url URL   Postgres connection string. Defaults to $DATABASE_URL,
#                        or to the libpq PG* environment variables when neither
#                        is set (e.g. PGHOST/PGPORT/PGUSER/PGDATABASE).
#   --migrations-dir DIR Default: <repo>/supabase/migrations
#   --shim FILE          Default: 00_supabase_shim.sql next to this script
#   --assertions FILE    Default: 99_assertions.sql next to this script
#   --force              Run even if the target database already has tables in
#                        `public` (otherwise this refuses, to protect a real one)
#   -h | --help
#
# Local run against a throwaway Postgres 16:
#   createdb aij_test
#   DATABASE_URL=postgresql://localhost/aij_test supabase/test-support/run.sh

set -euo pipefail

PSQL="${PSQL:-psql}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

DATABASE_URL_OPT="${DATABASE_URL:-}"
MIGRATIONS_DIR="${REPO_ROOT}/supabase/migrations"
SHIM="${SCRIPT_DIR}/00_supabase_shim.sql"
ASSERTIONS="${SCRIPT_DIR}/99_assertions.sql"
FORCE=0

usage() {
  sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --database-url) DATABASE_URL_OPT="${2:-}"; shift 2 ;;
    --migrations-dir) MIGRATIONS_DIR="${2:-}"; shift 2 ;;
    --shim) SHIM="${2:-}"; shift 2 ;;
    --assertions) ASSERTIONS="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
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

fail() {
  printf '\nFAILED: %s\n' "$1" >&2
  exit 1
}

step() {
  printf '\n==> %s\n' "$1"
}

# ---------------------------------------------------------------------------
# 0. Refuse to touch a database that already looks real
# ---------------------------------------------------------------------------
# Print the target first: this script creates roles and schema objects, and
# libpq defaults silently to a database named after the connecting user.
target="$(psql_run -tAc "select current_database() || ' at ' || coalesce(inet_server_addr()::text, 'local socket') || ':' || coalesce(inet_server_port()::text, '-')" 2>/dev/null || true)"
if [ -z "$target" ]; then
  fail "cannot connect to the target database. Pass --database-url (or set DATABASE_URL / the PG* variables)."
fi
printf 'target database: %s\n' "$target"

if [ "$FORCE" -ne 1 ]; then
  existing="$(psql_run -tAc "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r'" 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "0" ]; then
    fail "the target database already has ${existing} table(s) in schema public.
This harness is TEST-ONLY and expects an empty, throwaway database — it creates
roles, an auth schema and fixture rows, and must never be pointed at a real
Supabase project. Create a fresh database (createdb aij_test) and pass it with
--database-url, or re-run with --force if you are certain."
  fi
fi

# ---------------------------------------------------------------------------
# 1. Shim, 2. migrations, 3. assertions
# ---------------------------------------------------------------------------
step "supabase shim (test-only): $(basename "$SHIM")"
if ! psql_run -f "$SHIM"; then
  fail "the Supabase shim did not apply: $SHIM"
fi

if [ ! -d "$MIGRATIONS_DIR" ]; then
  fail "migrations directory not found: $MIGRATIONS_DIR"
fi

migration_count=0
while IFS= read -r migration; do
  step "migration: $(basename "$migration")"
  if ! psql_run -f "$migration"; then
    fail "migration did not apply: $migration"
  fi
  migration_count=$((migration_count + 1))
done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' | sort)

if [ "$migration_count" -eq 0 ]; then
  fail "no .sql migrations found in $MIGRATIONS_DIR"
fi

step "RLS assertions: $(basename "$ASSERTIONS")"
if ! psql_run -f "$ASSERTIONS"; then
  fail "an RLS assertion failed (see the message above): $ASSERTIONS"
fi

printf '\nOK: shim + %s migration(s) + RLS assertions passed.\n' "$migration_count"
