-- supabase/test-support/00_supabase_shim.sql
--
-- ===========================================================================
-- TEST-ONLY. THIS FILE IS NEVER APPLIED TO A REAL SUPABASE PROJECT.
-- ===========================================================================
-- A real Supabase project already provides all of this natively: the anon /
-- authenticated / service_role roles (with BYPASSRLS on service_role), the auth
-- schema, auth.users and auth.uid(), and permissive default privileges on the
-- public schema. Recreating them on a live project would be a mistake (and
-- pointless), so this file lives outside supabase/migrations/ and is only ever
-- piped into a throwaway database — by supabase/test-support/run.sh locally and
-- by the "database" job in .github/workflows/ci.yml.
--
-- Its purpose is narrow: make a stock Postgres 16 behave enough like Supabase
-- that supabase/migrations/*.sql can be applied completely unchanged and their
-- row-level security executed and asserted for real.
--
-- What it emulates, and what that means for the assertions:
--   * anon / authenticated / service_role exist as NOLOGIN roles.
--   * service_role has BYPASSRLS, exactly as on Supabase, so it sees every row.
--   * The auth schema with auth.users, and auth.uid() reading the request's JWT
--     claims the same way Supabase's does.
--   * Supabase's permissive default privileges on `public`: anon, authenticated
--     and service_role get SELECT/INSERT/UPDATE/DELETE on every table. This
--     matters — it means the assertions test the RLS policies rather than the
--     privilege layer. `anon` can read the tables as far as GRANTs go and still
--     sees nothing, because no policy grants it anything.
--
-- Applied first, before every migration.

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- 1. Roles
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit;
  end if;
end
$$;

-- On Supabase, service_role is created with BYPASSRLS. Without this the
-- "service_role sees everything" assertion would be meaningless.
alter role service_role bypassrls;

grant usage on schema public to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The auth schema
-- ---------------------------------------------------------------------------
create schema if not exists auth;

grant usage on schema auth to anon, authenticated, service_role;

-- A minimal stand-in for Supabase's auth.users. Real Supabase has dozens of
-- columns and its own triggers; migrations only ever need the primary key
-- (public.tenant_users references it) plus somewhere to hang test users.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table auth.users is
  'TEST-ONLY shim for Supabase''s auth.users (primary key + a few columns). Never applied to a real project.';

-- ---------------------------------------------------------------------------
-- 3. auth.uid() — copied from Supabase's implementation
-- ---------------------------------------------------------------------------
-- Reads the request's JWT claims, which is how Supabase's own auth.uid() works:
-- `request.jwt.claims` holds the decoded JWT as JSON, and `sub` is the user id.
-- PostgREST sets that GUC per request; the harness sets it with set_config(),
-- which is exactly the same mechanism.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

comment on function auth.uid() is
  'TEST-ONLY shim for Supabase''s auth.uid(): the `sub` claim of the current request''s JWT.';

grant execute on function auth.uid() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Supabase's permissive default privileges on public
-- ---------------------------------------------------------------------------
-- Supabase grants anon/authenticated/service_role broad privileges on new
-- tables in `public`, so RLS — not GRANTs — is what protects tenant data. This
-- keeps the harness honest: reversing or dropping a policy has to be what makes
-- an assertion fail.
alter default privileges in schema public
  grant select, insert, update, delete on tables to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public
  to anon, authenticated, service_role;
