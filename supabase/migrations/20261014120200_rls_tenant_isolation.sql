-- 20261014120200_rls_tenant_isolation.sql
--
-- AIJ Closer — row-level security. THIS IS THE SECURITY BOUNDARY OF THE WHOLE
-- PRODUCT: one deployment serves many client businesses, so a leak here is a
-- leak between vendors' customer conversations and money.
--
-- Model
--   * Every table is RLS-enabled. With RLS on and no applicable policy,
--     Postgres returns zero rows and rejects writes — deny by default.
--   * `authenticated` (a logged-in dashboard user, i.e. Supabase Auth) may only
--     touch rows belonging to a tenant it is a member of, via
--     public.is_tenant_member().
--   * `anon` (not logged in) has no policy on any table, so it sees nothing —
--     including when it carries a JWT claim, because policies are scoped to the
--     `authenticated` role.
--   * `service_role` has BYPASSRLS in Supabase and is used server-side only
--     (webhooks, agent tool calls, cron jobs).
--
-- Asserted by supabase/test-support (roles are simulated by
-- 00_supabase_shim.sql there). Migrations must stay Supabase-compatible: the
-- shim is test-only and is never applied to a real project.

begin;

-- ---------------------------------------------------------------------------
-- The membership helper
-- ---------------------------------------------------------------------------
-- security definer so it can read tenant_users even though tenant_users itself
-- is protected by RLS (otherwise every policy would recurse into itself).
-- `stable` because it is evaluated once per matching row set inside a query.
-- `set search_path = ''` so nothing in it can be hijacked by a caller's
-- search_path; every object below is therefore schema-qualified.
--
-- NB: because it is security definer, this function bypasses RLS on
-- tenant_users only for as long as it is owned by the role that owns that
-- table. Do not ALTER TABLE tenant_users FORCE ROW LEVEL SECURITY — the owner
-- exemption is what keeps this from recursing.
create or replace function public.is_tenant_member(target_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.tenant_users tu
    where tu.tenant_id = target_tenant_id
      and tu.user_id = auth.uid()
  );
$$;

comment on function public.is_tenant_member(uuid) is
  'True when the caller (auth.uid()) is a member of the given tenant. Security definer so it can read public.tenant_users without recursing through its own RLS policy. Used by every tenant-scoped RLS policy.';

revoke all on function public.is_tenant_member(uuid) from public;
grant execute on function public.is_tenant_member(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
-- RLS is the boundary; these grants are only what the roles need in order for a
-- policy to be evaluated at all. `anon` is deliberately not granted anything
-- here: on Supabase it inherits the project's permissive default privileges, so
-- the "anon sees nothing" guarantee comes from there being no policy for it —
-- which is exactly what supabase/test-support asserts.
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public
  to authenticated, service_role;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- tenants
-- ---------------------------------------------------------------------------
alter table public.tenants enable row level security;

-- A member can read its own tenant row, and the owner can edit it (tone
-- profile, Paystack subaccount, active). No insert/delete policy: tenants are
-- provisioned server-side with the service role.
create policy tenants_select_own on public.tenants
  for select to authenticated
  using (public.is_tenant_member(id));

create policy tenants_update_own on public.tenants
  for update to authenticated
  using (public.is_tenant_member(id))
  with check (public.is_tenant_member(id));

-- ---------------------------------------------------------------------------
-- tenant_users
-- ---------------------------------------------------------------------------
alter table public.tenant_users enable row level security;

-- A member sees only their own membership row. Membership itself is written
-- server-side (service role) only: a user cannot add themselves to a tenant.
create policy tenant_users_select_self on public.tenant_users
  for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Tenant-scoped tables: one policy per table, identical shape.
--   using      -> what the caller may read / update / delete
--   with check -> what the caller may write, so a row cannot be created for or
--                 moved to another tenant
-- ---------------------------------------------------------------------------
alter table public.channels enable row level security;
create policy channels_tenant_isolation on public.channels
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.products enable row level security;
create policy products_tenant_isolation on public.products
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.policies enable row level security;
create policy policies_tenant_isolation on public.policies
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.knowledge enable row level security;
create policy knowledge_tenant_isolation on public.knowledge
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.contacts enable row level security;
create policy contacts_tenant_isolation on public.contacts
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.conversations enable row level security;
create policy conversations_tenant_isolation on public.conversations
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.messages enable row level security;
create policy messages_tenant_isolation on public.messages
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.offers enable row level security;
create policy offers_tenant_isolation on public.offers
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.orders enable row level security;
create policy orders_tenant_isolation on public.orders
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

alter table public.weekly_reports enable row level security;
create policy weekly_reports_tenant_isolation on public.weekly_reports
  for all to authenticated
  using (public.is_tenant_member(tenant_id))
  with check (public.is_tenant_member(tenant_id));

commit;
