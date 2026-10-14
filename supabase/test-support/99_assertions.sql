-- supabase/test-support/99_assertions.sql
--
-- ===========================================================================
-- TEST-ONLY. NEVER APPLY THIS FILE TO A REAL SUPABASE PROJECT.
-- ===========================================================================
-- It creates a schema called test_support, two tenants of fixture data and a
-- lot of probe rows, then executes the RLS policies to prove tenant isolation.
-- Supabase would not thank you for any of it; it is run only against a
-- throwaway database (supabase/test-support/run.sh).
--
-- What it proves, per the PR that introduced it:
--   1. Every table in the brief's data model exists and has RLS enabled, and
--      every tenant_id-bearing table has a policy (RLS on with no policy is
--      deny-all, which is safe but useless).
--   2. As tenant A's authenticated user, every tenant-scoped table returns
--      exactly A's rows and zero rows of any other tenant.
--   3. Inserting a row stamped with another tenant's id is rejected.
--   4. Updating or deleting another tenant's row by primary key affects zero
--      rows.
--   5. A row of tenant A cannot be linked to a parent row of tenant B.
--   6. anon sees nothing — even carrying a JWT claim — and cannot write.
--   7. An authenticated user with no membership sees nothing.
--   8. service_role sees every tenant's rows (server-side only).
--   9. The enum CHECK constraints match @aij/shared, and the money invariants
--      (order total = arithmetic on stored values, floor <= list) hold.
--  10. Deleting a tenant cascades to every row it owns.
--
-- The whole file runs inside ONE transaction that ends in ROLLBACK: assertions
-- never leave anything behind, and the script is safe to re-run.
--
-- Any failure raises an exception, and run.sh runs psql with
-- `-v ON_ERROR_STOP=1`, so the process exits non-zero.

\set ON_ERROR_STOP on

begin;

-- ===========================================================================
-- Assertion helpers (schema: test_support — created by this file, test-only)
-- ===========================================================================
create schema if not exists test_support;

grant usage on schema test_support to anon, authenticated, service_role;

create or replace function test_support.fail(msg text)
returns void
language plpgsql
as $fn$
begin
  raise exception 'ASSERTION FAILED: %', msg;
end;
$fn$;

-- The only assertion primitive: every check in this file goes through it.
-- It also counts checks so run.sh can report how much was actually executed
-- (a suite that silently stops after three checks is not evidence).
create or replace function test_support.assert_true(condition boolean, msg text)
returns void
language plpgsql
as $fn$
begin
  perform set_config(
    'test_support.checks',
    (coalesce(nullif(current_setting('test_support.checks', true), ''), '0')::int + 1)::text,
    false
  );
  if condition is not true then
    perform test_support.fail(msg);
  end if;
end;
$fn$;

-- Runs `stmt` and asserts it is rejected with `expected_sqlstate`.
-- Used to prove the negative cases (cross-tenant inserts, enum violations).
create or replace function test_support.assert_rejected(stmt text, expected_sqlstate text, label text)
returns void
language plpgsql
as $fn$
declare
  rejected boolean := false;
  seen text;
begin
  begin
    execute stmt;
  exception when others then
    rejected := true;
    seen := sqlstate;
  end;
  perform test_support.assert_true(
    rejected and seen = expected_sqlstate,
    format('[%s] expected SQLSTATE %s, got rejected=%s sqlstate=%s :: %s',
           label, expected_sqlstate, rejected, coalesce(seen, 'none'), left(stmt, 200))
  );
end;
$fn$;

-- Runs a write statement and asserts how many rows it touched. Reads only the
-- caller's own view of the table, so under RLS "another tenant's row" shows up
-- as zero rows affected.
create or replace function test_support.assert_affected(stmt text, expected bigint, label text)
returns void
language plpgsql
as $fn$
declare
  touched bigint := -1;
begin
  begin
    execute stmt;
    get diagnostics touched = row_count;
  exception when others then
    perform test_support.fail(
      format('[%s] statement raised SQLSTATE %s instead of affecting %s rows :: %s',
             label, sqlstate, expected, left(stmt, 200)));
  end;
  perform test_support.assert_true(
    touched = expected,
    format('[%s] expected %s rows affected, got %s :: %s', label, expected, touched, left(stmt, 200)));
end;
$fn$;

-- The tables that carry a tenant_id (all of them must isolate).
create or replace function test_support.tenant_scoped_tables()
returns text[]
language sql
stable
as $fn$
  select array[
    'channels', 'contacts', 'conversations', 'knowledge', 'messages',
    'offers', 'orders', 'policies', 'products', 'tenant_users', 'weekly_reports'
  ]::text[];
$fn$;

-- Every table in public that has a tenant_id column, read from the catalogue so
-- a table added later cannot quietly escape the matrix.
create or replace function test_support.discovered_tenant_scoped_tables()
returns text[]
language sql
stable
as $fn$
  select coalesce(array_agg(c.table_name order by c.table_name), '{}'::text[])
  from information_schema.columns c
  where c.table_schema = 'public' and c.column_name = 'tenant_id';
$fn$;

-- The core read-isolation check: for every tenant-scoped table, as the caller,
-- exactly `expected_rows` rows of `own` are visible and zero rows of anyone else.
create or replace function test_support.assert_own_rows_only(own uuid, expected_rows bigint, label text)
returns void
language plpgsql
as $fn$
declare
  t text;
  total bigint;
  foreign_rows bigint;
  checked int := 0;
begin
  for t in select unnest(test_support.discovered_tenant_scoped_tables()) loop
    execute format('select count(*), count(*) filter (where tenant_id <> %L) from public.%I', own, t)
      into total, foreign_rows;
    perform test_support.assert_true(
      total = expected_rows and foreign_rows = 0,
      format('[%s] public.%s: expected %s own row(s) and 0 foreign rows, got %s visible of which %s belong to another tenant',
             label, t, expected_rows, total, foreign_rows));
    checked := checked + 1;
  end loop;
  perform test_support.assert_true(
    checked = array_length(test_support.tenant_scoped_tables(), 1),
    format('[%s] read-isolation matrix covered %s tables, expected %s (a table was skipped, so it was never tested)',
           label, checked, array_length(test_support.tenant_scoped_tables(), 1)));
end;
$fn$;

-- The mirror image: as `anon` or a non-member, no tenant row is visible at all.
create or replace function test_support.assert_nothing_visible(label text)
returns void
language plpgsql
as $fn$
declare
  t text;
  visible bigint;
  checked int := 0;
begin
  for t in select unnest(test_support.discovered_tenant_scoped_tables()) loop
    execute format('select count(*) from public.%I', t) into visible;
    perform test_support.assert_true(
      visible = 0,
      format('[%s] public.%s exposed %s row(s) that should have been invisible', label, t, visible));
    checked := checked + 1;
  end loop;
  execute 'select count(*) from public.tenants' into visible;
  perform test_support.assert_true(
    visible = 0,
    format('[%s] public.tenants exposed %s row(s)', label, visible));
  perform test_support.assert_true(
    checked = array_length(test_support.tenant_scoped_tables(), 1),
    format('[%s] visibility matrix covered %s tables, expected %s', label, checked,
           array_length(test_support.tenant_scoped_tables(), 1)));
end;
$fn$;

grant execute on all functions in schema test_support to anon, authenticated, service_role;

do $do$ begin perform set_config('test_support.checks', '0', false); end $do$;

-- Fixture ids, used literally throughout so a reader can follow any probe:
--   tenant A  a0000000-0000-4000-8000-000000000001   user A a0000000-0000-4000-8000-0000000000a1
--   tenant B  b0000000-0000-4000-8000-000000000001   user B b0000000-0000-4000-8000-0000000000b1
--   user C (authenticated, member of nothing)        c0000000-0000-4000-8000-0000000000c1
--   channel A ...000101  channel B ...000102   product A ...000201  product B ...000202
--   policy A  ...000301  policy B  ...000302   knowledge A ...000401 knowledge B ...000402
--   contact A ...000501  contact B ...000502   conversation A ...000601 conversation B ...000602
--   message A ...000701  message B ...000702   offer A ...000801  offer B ...000802
--   order A   ...000901  order B   ...000902   weekly report A ...000a01 weekly report B ...000a02

-- ===========================================================================
-- Fixtures — inserted as the session user (the database owner), which is the
-- equivalent of the service role provisioning a real tenant.
-- ===========================================================================
\echo '--- fixtures: two tenants, two owners, one outsider'

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-0000000000a1', 'owner-a@example.test'),
  ('b0000000-0000-4000-8000-0000000000b1', 'owner-b@example.test'),
  ('c0000000-0000-4000-8000-0000000000c1', 'outsider@example.test');

insert into public.tenants (id, name, slug, tone_profile, paystack_subaccount_code) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada Fashion Lagos', 'ada-fashion',
   'warm, playful, uses light Pidgin in greetings', 'ACCT_test_tenant_a'),
  ('b0000000-0000-4000-8000-000000000001', 'Bisi Beauty', 'bisi-beauty',
   'polite and brisk', 'ACCT_test_tenant_b');

insert into public.tenant_users (tenant_id, user_id, role) values
  ('a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-0000000000a1', 'owner'),
  ('b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-0000000000b1', 'owner');

insert into public.channels (id, tenant_id, type, label, phone_number_id, access_token_encrypted) values
  ('a0000000-0000-4000-8000-000000000101', 'a0000000-0000-4000-8000-000000000001', 'whatsapp',
   'Ada WhatsApp', 'phone-number-id-a-1001', 'v1:fake-ciphertext:aaaa'),
  ('b0000000-0000-4000-8000-000000000102', 'b0000000-0000-4000-8000-000000000001', 'whatsapp',
   'Bisi WhatsApp', 'phone-number-id-b-1002', 'v1:fake-ciphertext:bbbb');

insert into public.products (id, tenant_id, name, sku, list_price, floor_price, stock, photos) values
  ('a0000000-0000-4000-8000-000000000201', 'a0000000-0000-4000-8000-000000000001',
   'Ankara wrap dress', 'ADA-001', 2500000, 2000000, 7, '["products/ada-001/1.jpg"]'::jsonb),
  ('b0000000-0000-4000-8000-000000000202', 'b0000000-0000-4000-8000-000000000001',
   'Shea body butter', 'BIS-001', 800000, 650000, 22, '["products/bis-001/1.jpg"]'::jsonb);

insert into public.policies
  (tenant_id, delivery_fees, return_policy, discount_steps, max_counter_steps, bulk_threshold, handoff_rules) values
  ('a0000000-0000-4000-8000-000000000001',
   '{"Lagos mainland": 150000, "outside Lagos": 450000}'::jsonb,
   'Exchange within 3 days, unworn.', '[3, 5]'::jsonb, 2, 10,
   '{"angry": true, "refund": true, "unanswerable_in_a_row": 2}'::jsonb),
  ('b0000000-0000-4000-8000-000000000001',
   '{"Lagos": 120000}'::jsonb, 'No returns on opened items.', '[5]'::jsonb, 1, 6,
   '{"angry": true}'::jsonb);

insert into public.knowledge (id, tenant_id, question, answer) values
  ('a0000000-0000-4000-8000-000000000401', 'a0000000-0000-4000-8000-000000000001',
   'Do you deliver to Abuja?', 'Yes, 3-4 working days outside Lagos.'),
  ('b0000000-0000-4000-8000-000000000402', 'b0000000-0000-4000-8000-000000000001',
   'Is it suitable for sensitive skin?', 'Yes, unscented and fragrance free.');

insert into public.contacts (id, tenant_id, channel, external_id, display_name) values
  ('a0000000-0000-4000-8000-000000000501', 'a0000000-0000-4000-8000-000000000001',
   'whatsapp', '2348011110001', 'Chika'),
  ('b0000000-0000-4000-8000-000000000502', 'b0000000-0000-4000-8000-000000000001',
   'instagram', '17841400000000002', 'Tunde');

insert into public.conversations (id, tenant_id, contact_id, channel, window_expires_at, handoff_reason) values
  ('a0000000-0000-4000-8000-000000000601', 'a0000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000501', 'whatsapp', now() + interval '20 hours', null),
  ('b0000000-0000-4000-8000-000000000602', 'b0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000502', 'instagram', now() + interval '23 hours', 'bulk order');

insert into public.messages
  (id, tenant_id, conversation_id, direction, type, content, tool_calls, meta_message_id) values
  ('a0000000-0000-4000-8000-000000000701', 'a0000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000601', 'inbound', 'text', 'How much is the wrap dress?',
   '[]'::jsonb, 'wamid.TEST-TENANT-A-1'),
  ('b0000000-0000-4000-8000-000000000702', 'b0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000602', 'inbound', 'voice', 'Abeg how much be this one?',
   '[{"name": "get_product", "ok": true}]'::jsonb, 'wamid.TEST-TENANT-B-1');

insert into public.offers
  (id, tenant_id, conversation_id, product_id, price, quantity, counter_step, status) values
  ('a0000000-0000-4000-8000-000000000801', 'a0000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000601', 'a0000000-0000-4000-8000-000000000201',
   2500000, 1, 0, 'proposed'),
  ('b0000000-0000-4000-8000-000000000802', 'b0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000602', 'b0000000-0000-4000-8000-000000000202',
   760000, 2, 1, 'accepted');

insert into public.orders
  (id, tenant_id, conversation_id, contact_id, product_id, quantity, unit_price,
   delivery_fee, amount, paystack_reference, payment_status) values
  ('a0000000-0000-4000-8000-000000000901', 'a0000000-0000-4000-8000-000000000001',
   'a0000000-0000-4000-8000-000000000601', 'a0000000-0000-4000-8000-000000000501',
   'a0000000-0000-4000-8000-000000000201', 1, 2500000, 150000, 2650000, 'PSK-TEST-A-1', 'pending'),
  ('b0000000-0000-4000-8000-000000000902', 'b0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000602', 'b0000000-0000-4000-8000-000000000502',
   'b0000000-0000-4000-8000-000000000202', 2, 800000, 0, 1600000, null, 'pending');

insert into public.weekly_reports (id, tenant_id, week_start, week_end, payload) values
  ('a0000000-0000-4000-8000-000000000a01', 'a0000000-0000-4000-8000-000000000001',
   '2026-10-05', '2026-10-11', '{"orders": 1, "revenue_kobo": 2650000}'::jsonb),
  ('b0000000-0000-4000-8000-000000000a02', 'b0000000-0000-4000-8000-000000000001',
   '2026-10-05', '2026-10-11', '{"orders": 1, "revenue_kobo": 1600000}'::jsonb);

-- ===========================================================================
-- 1. Structure: the data model exists, and RLS is on everywhere
-- ===========================================================================
\echo '--- structure: data model present, RLS enabled, policies defined'

do $do$
declare
  missing text[];
  tables_without_rls text[];
  tables_forced text[];
  tenant_tables text[];
  tables_without_policy text[];
begin
  select array_agg(t order by t) into missing
  from unnest(array[
    'tenants', 'tenant_users', 'channels', 'products', 'policies', 'knowledge',
    'contacts', 'conversations', 'messages', 'offers', 'orders', 'weekly_reports'
  ]::text[]) t
  where not exists (
    select 1 from information_schema.tables it
    where it.table_schema = 'public' and it.table_name = t and it.table_type = 'BASE TABLE'
  );
  perform test_support.assert_true(
    missing is null,
    format('tables missing from the brief''s data model: %s', missing));

  select coalesce(array_agg(c.relname order by c.relname), '{}'::text[]) into tables_without_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  perform test_support.assert_true(
    tables_without_rls = '{}'::text[],
    format('public tables without ROW LEVEL SECURITY: %s', tables_without_rls));

  -- FORCE RLS on tenant_users would remove the owner exemption that
  -- public.is_tenant_member() relies on, and the helper would recurse.
  select coalesce(array_agg(c.relname order by c.relname), '{}'::text[]) into tables_forced
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relforcerowsecurity;
  perform test_support.assert_true(
    tables_forced = '{}'::text[],
    format('FORCE ROW LEVEL SECURITY is set on %s; is_tenant_member() depends on the owner exemption', tables_forced));

  tenant_tables := test_support.discovered_tenant_scoped_tables();
  perform test_support.assert_true(
    tenant_tables = test_support.tenant_scoped_tables(),
    format('tenant_id-bearing tables are %s, expected %s', tenant_tables, test_support.tenant_scoped_tables()));

  -- RLS enabled with no policy is deny-all: safe, but the product would not
  -- work. Every tenant table must have at least one policy.
  select coalesce(array_agg(t order by t), '{}'::text[]) into tables_without_policy
  from unnest(test_support.tenant_scoped_tables()) t
  where not exists (
    select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = t
  );
  perform test_support.assert_true(
    tables_without_policy = '{}'::text[],
    format('tables with RLS enabled but no policy (deny-all): %s', tables_without_policy));
end
$do$;

-- ===========================================================================
-- 2. Enums and money invariants — the database refuses values the code never
--    produces. (These mirror the Zod enums in packages/shared.)
-- ===========================================================================
\echo '--- constraints: enums match @aij/shared, money invariants hold'

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  conv_a constant uuid := 'a0000000-0000-4000-8000-000000000601';
  contact_a constant uuid := 'a0000000-0000-4000-8000-000000000501';
  product_a constant uuid := 'a0000000-0000-4000-8000-000000000201';
begin
  -- conversations.status default (bot) and enum membership
  perform test_support.assert_true(
    (select status from public.conversations where id = conv_a) = 'bot',
    'conversations.status should default to ''bot''');

  perform test_support.assert_rejected(
    format('insert into public.conversations (tenant_id, contact_id, channel, status) values (%L, %L, ''whatsapp'', ''paused'')', tenant_a, contact_a),
    '23514', 'conversations.status outside bot|human|closed');

  perform test_support.assert_rejected(
    format('insert into public.messages (tenant_id, conversation_id, direction, type, content) values (%L, %L, ''incoming'', ''text'', ''x'')', tenant_a, conv_a),
    '23514', 'messages.direction outside inbound|outbound');

  perform test_support.assert_rejected(
    format('insert into public.messages (tenant_id, conversation_id, direction, type, content) values (%L, %L, ''outbound'', ''video'', ''x'')', tenant_a, conv_a),
    '23514', 'messages.type outside text|voice|image');

  perform test_support.assert_rejected(
    format('insert into public.orders (tenant_id, quantity, unit_price, delivery_fee, amount, payment_status) values (%L, 1, 100, 0, 100, ''abandoned'')', tenant_a),
    '23514', 'orders.payment_status outside pending|paid|failed|refunded');

  perform test_support.assert_rejected(
    format('insert into public.channels (tenant_id, type, access_token_encrypted) values (%L, ''telegram'', ''x'')', tenant_a),
    '23514', 'channels.type outside whatsapp|instagram');

  -- A channel with no routing key could never receive a webhook.
  perform test_support.assert_rejected(
    format('insert into public.channels (tenant_id, type, access_token_encrypted) values (%L, ''whatsapp'', ''x'')', tenant_a),
    '23514', 'whatsapp channel without phone_number_id');

  -- One Meta inbox belongs to one tenant, globally.
  perform test_support.assert_rejected(
    format('insert into public.channels (tenant_id, type, phone_number_id, access_token_encrypted) values (%L, ''whatsapp'', ''phone-number-id-a-1001'', ''x'')', tenant_a),
    '23505', 'duplicate channels.phone_number_id (routing must be unambiguous)');

  -- Money: the agent can never quote below the floor, and an order total is
  -- arithmetic over stored columns, never a number the model chose.
  perform test_support.assert_rejected(
    format('insert into public.products (tenant_id, name, list_price, floor_price) values (%L, ''probe'', 200000, 300000)', tenant_a),
    '23514', 'products.floor_price above list_price');

  perform test_support.assert_rejected(
    format('insert into public.orders (tenant_id, quantity, unit_price, delivery_fee, amount) values (%L, 1, 2500000, 150000, 1)', tenant_a),
    '23514', 'orders.amount that is not (unit_price * quantity) + delivery_fee');

  -- Negative prices and out-of-range counters.
  perform test_support.assert_rejected(
    format('insert into public.products (tenant_id, name, list_price, floor_price) values (%L, ''probe'', -1, -1)', tenant_a),
    '23514', 'negative product price');

  perform test_support.assert_rejected(
    format('insert into public.offers (tenant_id, conversation_id, product_id, price) values (%L, %L, %L, -1)', tenant_a, conv_a, product_a),
    '23514', 'negative offer price');
end
$do$;

-- ===========================================================================
-- 3. Partial unique indexes: NULLs stay allowed, set values stay unique
-- ===========================================================================
\echo '--- indexes: meta_message_id and paystack_reference are unique when set, NULL-friendly'

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'b0000000-0000-4000-8000-000000000001';
  conv_a constant uuid := 'a0000000-0000-4000-8000-000000000601';
  probe_message_1 uuid;
  probe_message_2 uuid;
  probe_order uuid;
begin
  -- Our own outbound messages have no Meta id; many may coexist.
  insert into public.messages (tenant_id, conversation_id, direction, type, content, meta_message_id)
    values (tenant_a, conv_a, 'outbound', 'text', 'probe: agent reply 1', null)
    returning id into probe_message_1;
  insert into public.messages (tenant_id, conversation_id, direction, type, content, meta_message_id)
    values (tenant_a, conv_a, 'outbound', 'text', 'probe: agent reply 2', null)
    returning id into probe_message_2;

  perform test_support.assert_true(
    (select count(*) from public.messages where id in (probe_message_1, probe_message_2)) = 2,
    'messages.meta_message_id should allow several NULLs (agent-sent messages have none)');

  perform test_support.assert_rejected(
    format('insert into public.messages (tenant_id, conversation_id, direction, type, content, meta_message_id) values (%L, %L, ''inbound'', ''text'', ''duplicate webhook'', ''wamid.TEST-TENANT-A-1'')', tenant_a, conv_a),
    '23505', 'duplicate messages.meta_message_id (Meta retries webhooks)');

  -- Unpaid orders have no Paystack reference. Tenant B's fixture order already
  -- has none, so this second NULL proves NULLs really are many.
  insert into public.orders (tenant_id, quantity, unit_price, delivery_fee, amount, paystack_reference)
    values (tenant_b, 1, 1000, 0, 1000, null)
    returning id into probe_order;

  perform test_support.assert_true(
    (select count(*) from public.orders where id = probe_order) = 1,
    'orders.paystack_reference should allow several NULLs (unpaid orders have none)');

  perform test_support.assert_rejected(
    format('insert into public.orders (tenant_id, quantity, unit_price, delivery_fee, amount, paystack_reference) values (%L, 1, 1000, 0, 1000, ''PSK-TEST-A-1'')', tenant_b),
    '23505', 'duplicate orders.paystack_reference (a payment must not be recorded twice)');

  -- Undo the probes (by id — never by "where the column is null", which would
  -- take the fixture rows with them) so the read matrices below see exactly one
  -- row per tenant per table.
  delete from public.messages where id in (probe_message_1, probe_message_2);
  delete from public.orders where id = probe_order;
end
$do$;

-- ===========================================================================
-- 4. Tenant A's authenticated user
-- ===========================================================================
\echo '--- authenticated user of tenant A'

do $do$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-0000000000a1', 'role', 'authenticated')::text,
    false
  );
end
$do$;

set role authenticated;

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'b0000000-0000-4000-8000-000000000001';
begin
  perform test_support.assert_true(current_user = 'authenticated', format('expected to be running as authenticated, not %s', current_user));
  perform test_support.assert_true(auth.uid() = 'a0000000-0000-4000-8000-0000000000a1'::uuid, 'auth.uid() did not resolve user A from the JWT claims');

  -- the helper itself
  perform test_support.assert_true(public.is_tenant_member(tenant_a), 'is_tenant_member(A) should be true for user A');
  perform test_support.assert_true(not public.is_tenant_member(tenant_b), 'is_tenant_member(B) should be false for user A');

  -- reads: exactly its own row in every tenant table, zero foreign rows
  perform test_support.assert_own_rows_only(tenant_a, 1, 'tenant A read');

  -- tenants: own row only
  perform test_support.assert_true((select count(*) from public.tenants) = 1, 'tenant A should see exactly one tenant row');
  perform test_support.assert_true(
    (select count(*) from public.tenants where id = tenant_b) = 0,
    'tenant A can read tenant B''s tenant row');

  -- tenant_users: own membership row only
  perform test_support.assert_true((select count(*) from public.tenant_users) = 1, 'tenant A should see exactly one membership row');
  perform test_support.assert_true(
    (select count(*) from public.tenant_users where tenant_id = tenant_b) = 0,
    'tenant A can read tenant B''s membership row');
end
$do$;

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'b0000000-0000-4000-8000-000000000001';
  conv_b constant uuid := 'b0000000-0000-4000-8000-000000000602';
  product_b constant uuid := 'b0000000-0000-4000-8000-000000000202';
  product_a constant uuid := 'a0000000-0000-4000-8000-000000000201';
  own_probe uuid;
begin
  -- WRITES ACROSS THE BOUNDARY -------------------------------------------------
  -- a row stamped with another tenant's id cannot be created ...
  perform test_support.assert_rejected(
    format('insert into public.products (tenant_id, name, list_price, floor_price) values (%L, ''intruder'', 100, 50)', tenant_b),
    '42501', 'tenant A inserting a product for tenant B');

  perform test_support.assert_rejected(
    format('insert into public.messages (tenant_id, conversation_id, direction, type, content) values (%L, %L, ''outbound'', ''text'', ''intruder'')', tenant_b, conv_b),
    '42501', 'tenant A inserting a message for tenant B');

  -- ... and a row of ours cannot be attached to another tenant's parent
  -- (foreign-key checks are not subject to RLS, so the composite FK is what
  -- stops this).
  perform test_support.assert_rejected(
    format('insert into public.messages (tenant_id, conversation_id, direction, type, content) values (%L, %L, ''outbound'', ''text'', ''intruder'')', tenant_a, conv_b),
    '23503', 'tenant A attaching a message to tenant B''s conversation');

  -- another tenant's row cannot be updated or deleted, even by primary key
  perform test_support.assert_affected(
    format('update public.products set stock = 999 where id = %L', product_b),
    0, 'tenant A updating tenant B''s product by primary key');

  perform test_support.assert_affected(
    format('delete from public.products where id = %L', product_b),
    0, 'tenant A deleting tenant B''s product by primary key');

  perform test_support.assert_affected(
    format('update public.tenants set tone_profile = ''hijacked'' where id = %L', tenant_b),
    0, 'tenant A updating tenant B''s tenant row');

  -- a row cannot be moved out of the caller's tenant either
  perform test_support.assert_rejected(
    format('update public.products set tenant_id = %L where id = %L', tenant_b, product_a),
    '42501', 'tenant A moving its own product into tenant B');

  -- WRITES INSIDE THE BOUNDARY still work (RLS must not be deny-all)
  insert into public.products (tenant_id, name, list_price, floor_price, stock)
    values (tenant_a, 'probe: knee-length dress', 1800000, 1500000, 3)
    returning id into own_probe;

  perform test_support.assert_true(
    (select count(*) from public.products where id = own_probe) = 1,
    'tenant A cannot read back the product it just inserted');

  perform test_support.assert_affected(
    format('update public.products set stock = 9 where id = %L', own_probe),
    1, 'tenant A updating its own product');

  perform test_support.assert_affected(
    format('delete from public.products where id = %L', own_probe),
    1, 'tenant A deleting its own product');

  -- and the insert of a child row into our own conversation is fine
  insert into public.messages (tenant_id, conversation_id, direction, type, content)
    values (tenant_a, 'a0000000-0000-4000-8000-000000000601', 'outbound', 'text', 'probe')
    returning id into own_probe;

  perform test_support.assert_affected(
    format('delete from public.messages where id = %L', own_probe),
    1, 'tenant A deleting its own message');
end
$do$;

reset role;

-- ===========================================================================
-- 5. Tenant B's authenticated user (the mirror image: a policy that only ever
--    worked for tenant A would pass section 4 and fail here)
-- ===========================================================================
\echo '--- authenticated user of tenant B'

do $do$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', 'b0000000-0000-4000-8000-0000000000b1', 'role', 'authenticated')::text,
    false
  );
end
$do$;

set role authenticated;

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'b0000000-0000-4000-8000-000000000001';
begin
  perform test_support.assert_true(auth.uid() = 'b0000000-0000-4000-8000-0000000000b1'::uuid, 'auth.uid() did not resolve user B');
  perform test_support.assert_true(public.is_tenant_member(tenant_b), 'is_tenant_member(B) should be true for user B');
  perform test_support.assert_true(not public.is_tenant_member(tenant_a), 'is_tenant_member(A) should be false for user B');

  perform test_support.assert_own_rows_only(tenant_b, 1, 'tenant B read');
  perform test_support.assert_true((select count(*) from public.tenants) = 1, 'tenant B should see exactly one tenant row');
  perform test_support.assert_true(
    (select count(*) from public.tenants where id = tenant_a) = 0,
    'tenant B can read tenant A''s tenant row');

  perform test_support.assert_rejected(
    format('insert into public.products (tenant_id, name, list_price, floor_price) values (%L, ''intruder'', 100, 50)', tenant_a),
    '42501', 'tenant B inserting a product for tenant A');
end
$do$;

reset role;

-- ===========================================================================
-- 6. An authenticated user who is a member of nothing
-- ===========================================================================
\echo '--- authenticated user with no membership'

do $do$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', 'c0000000-0000-4000-8000-0000000000c1', 'role', 'authenticated')::text,
    false
  );
end
$do$;

set role authenticated;

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
begin
  perform test_support.assert_true(auth.uid() = 'c0000000-0000-4000-8000-0000000000c1'::uuid, 'auth.uid() did not resolve user C');
  perform test_support.assert_true(not public.is_tenant_member(tenant_a), 'is_tenant_member should be false for a non-member');
  perform test_support.assert_nothing_visible('authenticated non-member');
end
$do$;

reset role;

-- ===========================================================================
-- 7. anon — not just logged out, but carrying tenant A's JWT claim, since that
--    is the case an attacker would actually try.
-- ===========================================================================
\echo '--- anon (with a forged tenant A claim)'

do $do$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', 'a0000000-0000-4000-8000-0000000000a1', 'role', 'anon')::text,
    false
  );
end
$do$;

set role anon;

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  conv_a constant uuid := 'a0000000-0000-4000-8000-000000000601';
begin
  perform test_support.assert_true(current_user = 'anon', format('expected to be running as anon, not %s', current_user));

  perform test_support.assert_nothing_visible('anon');

  -- writes are rejected too, including into tenant A's own conversation
  perform test_support.assert_rejected(
    format('insert into public.products (tenant_id, name, list_price, floor_price) values (%L, ''intruder'', 100, 50)', tenant_a),
    '42501', 'anon inserting a product');

  perform test_support.assert_rejected(
    format('insert into public.messages (tenant_id, conversation_id, direction, type, content) values (%L, %L, ''inbound'', ''text'', ''intruder'')', tenant_a, conv_a),
    '42501', 'anon inserting a message');

  perform test_support.assert_affected(
    'delete from public.tenants',
    0, 'anon deleting tenants');

  perform test_support.assert_affected(
    'update public.products set stock = 0',
    0, 'anon updating products');
end
$do$;

reset role;

-- ===========================================================================
-- 8. service_role — server-side only, bypasses RLS, sees every tenant
-- ===========================================================================
\echo '--- service_role (server-side, BYPASSRLS)'

set role service_role;

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'b0000000-0000-4000-8000-000000000001';
  t text;
  total bigint;
  checked int := 0;
  probe uuid;
begin
  perform test_support.assert_true(current_user = 'service_role', format('expected to be running as service_role, not %s', current_user));
  perform test_support.assert_true(
    (select rolbypassrls from pg_roles where rolname = 'service_role'),
    'service_role must have BYPASSRLS (the api, webhooks and cron jobs rely on it)');

  perform test_support.assert_true(
    (select count(*) from public.tenants) = 2,
    'service_role should see both tenants');

  -- every table, both tenants
  for t in select unnest(test_support.tenant_scoped_tables()) loop
    execute format('select count(*) from public.%I', t) into total;
    perform test_support.assert_true(
      total = 2,
      format('service_role sees %s rows in public.%s, expected both tenants'' rows (2)', total, t));
    execute format('select count(*) from public.%I where tenant_id = %L', t, tenant_b) into total;
    perform test_support.assert_true(
      total = 1,
      format('service_role cannot see tenant B''s rows in public.%s', t));
    checked := checked + 1;
  end loop;
  perform test_support.assert_true(
    checked = array_length(test_support.tenant_scoped_tables(), 1),
    format('service_role matrix covered %s tables, expected %s', checked, array_length(test_support.tenant_scoped_tables(), 1)));

  -- and it can write on behalf of any tenant (this is how webhooks and tools
  -- persist data)
  insert into public.channels (tenant_id, type, label, instagram_account_id, access_token_encrypted)
    values (tenant_b, 'instagram', 'probe', 'instagram-account-probe-1003', 'v1:fake-ciphertext:cccc')
    returning id into probe;

  perform test_support.assert_true(
    (select count(*) from public.channels where id = probe and tenant_id = tenant_b) = 1,
    'service_role cannot write a channel for tenant B');

  delete from public.channels where id = probe;
end
$do$;

-- ===========================================================================
-- 9. Cascade: deleting a tenant removes everything it owns, and nothing else
--    (also proves the orders -> conversations/product/contact foreign keys do
--    not block a tenant deletion).
-- ===========================================================================
\echo '--- cascade: deleting tenant B removes its rows only'

do $do$
declare
  tenant_a constant uuid := 'a0000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'b0000000-0000-4000-8000-000000000001';
begin
  delete from public.tenants where id = tenant_b;

  perform test_support.assert_true(
    (select count(*) from public.tenants) = 1,
    'deleting tenant B should leave exactly tenant A');

  -- tenant A's data is fully intact and tenant B's is fully gone
  perform test_support.assert_own_rows_only(tenant_a, 1, 'cascade aftermath');
  perform test_support.assert_true(
    (select count(*) from public.tenant_users where tenant_id = tenant_b) = 0,
    'tenant B''s membership rows survived the cascade');
end
$do$;

reset role;

-- ===========================================================================
-- Summary
-- ===========================================================================
do $do$
begin
  raise notice 'RLS assertion script: % checks executed, all passed', current_setting('test_support.checks');
end
$do$;

-- Nothing above is kept: no fixtures, no probe rows, no deleted tenant.
rollback;
