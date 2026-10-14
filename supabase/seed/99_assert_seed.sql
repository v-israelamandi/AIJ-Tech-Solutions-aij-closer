-- supabase/seed/99_assert_seed.sql
--
-- AIJ Closer — assertions on the demo seed.
--
-- Run by supabase/seed/run.sh, after 10_demo_tenant.sql. It states what the
-- demo tenant must look like independently of how the seed file is written, so
-- an edit to the seed that quietly drops products, breaks the negotiation
-- ladder, fills the FAQs with prices or forgets a channel fails here and CI
-- goes red.
--
-- Everything runs in one transaction that ends in ROLLBACK, and the only helper
-- it creates is `pg_temp.assert_true` — a temporary function, so this file
-- leaves nothing behind even when it is run against a real Supabase project
-- (which is why it does not use the schema in supabase/test-support/, since
-- that harness is test-only by design).
--
-- Any failure raises, and run.sh runs psql with `-v ON_ERROR_STOP=1`, so the
-- process exits non-zero. A second pass over the same database must produce the
-- same answer: run.sh applies the seed twice and re-runs this file, which is how
-- idempotency is proved.

\set ON_ERROR_STOP on

begin;

-- ===========================================================================
-- Assertion helper (pg_temp: temporary, dropped when the session ends)
-- ===========================================================================
create or replace function pg_temp.assert_true(condition boolean, msg text)
returns void
language plpgsql
as $fn$
begin
  -- Counts every check, so a suite that silently stopped early is visible.
  perform set_config(
    'seed_check.checks',
    (coalesce(nullif(current_setting('seed_check.checks', true), ''), '0')::int + 1)::text,
    false
  );
  if condition is not true then
    raise exception 'SEED ASSERTION FAILED: %', msg;
  end if;
end;
$fn$;

do $do$ begin perform set_config('seed_check.checks', '0', false); end $do$;

\echo '--- seed assertions: the demo tenant exists, once'
-- ===========================================================================
-- 1. Exactly one tenant in the database, and it is the demo tenant
-- ===========================================================================
do $do$
declare
  demo constant text := 'sisi-lagos-fashion';
  t public.tenants%rowtype;
begin
  perform pg_temp.assert_true(
    (select count(*) from public.tenants) = 1,
    format('expected exactly 1 tenant in the database after seeding, found %s (a second run must not create a copy)',
           (select count(*) from public.tenants)));

  select * into t from public.tenants where slug = demo;
  perform pg_temp.assert_true(
    t.id is not null,
    format('no tenant with slug %L — the seed identifies the demo tenant by that slug', demo));

  perform pg_temp.assert_true(t.name = 'Sisi Lagos Fashion', format('unexpected demo tenant name: %L', t.name));
  perform pg_temp.assert_true(t.currency = 'NGN', format('demo tenant currency is %L, money is stored in kobo (NGN)', t.currency));
  perform pg_temp.assert_true(t.active, 'the demo tenant should be active');
  perform pg_temp.assert_true(
    t.paystack_subaccount_code is null,
    format('the demo tenant should not carry a Paystack subaccount code yet, found %L (money must only ever move to a real account)',
           t.paystack_subaccount_code));
  -- tone_profile is injected into the system prompt, so a placeholder would
  -- quietly produce a generic-sounding agent.
  perform pg_temp.assert_true(
    length(btrim(t.tone_profile)) >= 300,
    format('tone_profile is too thin to build a system prompt from: %s characters', length(btrim(t.tone_profile))));
  perform pg_temp.assert_true(
    t.tone_profile ilike '%pidgin%' and t.tone_profile ilike '%naira%',
    'tone_profile must cover the brief''s tone requirements (Pidgin/mixed English, prices stated in naira)');
end
$do$;

\echo '--- seed assertions: 20 products, floor <= list, out-of-stock and inactive shapes present'
-- ===========================================================================
-- 2. Catalog
-- ===========================================================================
do $do$
declare
  demo constant uuid := '5eed0000-0000-4000-8000-000000000001';
  total int;
  checked int := 0;
  r record;
  bad_floor text;
  bad_ladder text;
  stock_levels int;
begin
  select count(*) into total from public.products where tenant_id = demo;
  perform pg_temp.assert_true(total = 20, format('expected exactly 20 products for the demo tenant, found %s', total));

  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id <> demo) = 0,
    'the seed created products for a tenant other than the demo tenant');

  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and (name = '' or btrim(name) = '')) = 0,
    'every product needs a name');
  perform pg_temp.assert_true(
    (select count(distinct sku) from public.products where tenant_id = demo) = 20,
    'every product needs its own SKU');
  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and sku !~ '^SLF-[0-9]{3}$') = 0,
    'SKUs should look like SLF-001 … SLF-020');

  -- Per-row money invariants. floor_price <= list_price is a database CHECK, but
  -- the ladder invariant is not: the agent's last discount step (10% off
  -- list_price, from policies.discount_steps) must still land at or above the
  -- floor, or the ladder and the floor disagree.
  for r in
    select sku, list_price, floor_price, stock, photos, active
    from public.products where tenant_id = demo order by sku
  loop
    checked := checked + 1;
    perform pg_temp.assert_true(
      r.floor_price <= r.list_price,
      format('%s: floor_price (%s) is above list_price (%s)', r.sku, r.floor_price, r.list_price));
    perform pg_temp.assert_true(
      r.list_price > 0 and r.floor_price > 0,
      format('%s: prices must be positive kobo amounts, got list=%s floor=%s', r.sku, r.list_price, r.floor_price));
    perform pg_temp.assert_true(
      r.floor_price * 100 <= r.list_price * 90,
      format('%s: the last discount step (10%% off list_price %s) would fall below floor_price %s — the ladder and the floor disagree',
             r.sku, r.list_price, r.floor_price));
    perform pg_temp.assert_true(
      r.list_price % 100 = 0 and r.floor_price % 100 = 0,
      format('%s: prices should be whole naira (multiples of 100 kobo), got list=%s floor=%s',
             r.sku, r.list_price, r.floor_price));
    perform pg_temp.assert_true(
      r.stock >= 0 and r.stock <= 100,
      format('%s: implausible stock level %s for a boutique', r.sku, r.stock));
    perform pg_temp.assert_true(
      jsonb_typeof(r.photos) = 'array',
      format('%s: photos must be a jsonb array', r.sku));
  end loop;
  perform pg_temp.assert_true(
    checked = total,
    format('the per-product checks covered %s rows but there are %s products (a row was skipped)', checked, total));

  select string_agg(sku, ', ' order by sku) into bad_floor
  from public.products where tenant_id = demo and floor_price > list_price;
  perform pg_temp.assert_true(bad_floor is null, format('products with floor_price > list_price: %s', bad_floor));

  -- The edge cases the out-of-stock and inactive paths are built against.
  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and stock = 0) >= 1,
    'at least one product must have stock = 0 (the agent''s out-of-stock path tests against it)');
  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and stock = 0 and active) >= 1,
    'at least one product must be active with stock = 0 (sold out, not withdrawn)');
  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and not active) >= 1,
    'at least one product must have active = false (the agent must never quote it)');
  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and not active and stock > 0) >= 1,
    'at least one product must be inactive while stock remains on hand (withdrawn, not sold out)');
  perform pg_temp.assert_true(
    (select count(*) from public.products where tenant_id = demo and photos <> '[]'::jsonb) >= 1
    and (select count(*) from public.products where tenant_id = demo and photos = '[]'::jsonb) >= 1,
    'the catalogue should include both photographed and unphotographed pieces (the send service has to cope)');

  select count(distinct stock) into stock_levels from public.products where tenant_id = demo;
  perform pg_temp.assert_true(
    stock_levels >= 8,
    format('expected a realistic spread of stock levels, found only %s distinct values', stock_levels));
end
$do$;

\echo '--- seed assertions: policies complete and business-plausible'
-- ===========================================================================
-- 3. Policies — the only numbers the agent may commit to
-- ===========================================================================
do $do$
declare
  demo constant uuid := '5eed0000-0000-4000-8000-000000000001';
  p public.policies%rowtype;
  zones text[];
  step_count int;
  steps text;
begin
  perform pg_temp.assert_true(
    (select count(*) from public.policies where tenant_id = demo) = 1,
    'expected exactly one policies row for the demo tenant (one row per tenant is the schema contract)');

  select * into p from public.policies where tenant_id = demo;

  -- delivery_fees: exactly the three zones the seed promises, each a kobo
  -- integer in the range a Lagos delivery actually costs.
  select array(select k from jsonb_object_keys(p.delivery_fees) k order by k) into zones;
  perform pg_temp.assert_true(
    zones = array['Lagos island', 'Lagos mainland', 'outside Lagos'],
    format('delivery_fees must be keyed by Lagos mainland / Lagos island / outside Lagos, got %s', zones));
  perform pg_temp.assert_true(
    (select count(*) from jsonb_each(p.delivery_fees) as e(k, v) where jsonb_typeof(v) <> 'number' or (v #>> '{}')::int <= 0) = 0,
    format('every delivery fee must be a positive kobo integer, got %s', p.delivery_fees::text));
  perform pg_temp.assert_true(
    (select count(*) from jsonb_each(p.delivery_fees) as e(k, v) where (v #>> '{}')::int < 50000 or (v #>> '{}')::int > 2000000) = 0,
    format('delivery fees should be plausible naira amounts (500-20,000 NGN as kobo), got %s', p.delivery_fees::text));

  -- discount_steps: ordered, positive, below 100%, and never more steps than
  -- max_counter_steps allows (counter 1 is the "last price" hold).
  perform pg_temp.assert_true(
    jsonb_typeof(p.discount_steps) = 'array' and jsonb_array_length(p.discount_steps) >= 1,
    format('discount_steps must be a non-empty array, got %s', p.discount_steps::text));
  select jsonb_array_length(p.discount_steps) into step_count;
  perform pg_temp.assert_true(
    (select count(*) from jsonb_array_elements_text(p.discount_steps) s where s !~ '^[0-9]+$') = 0,
    format('discount steps must be whole percentages, got %s', p.discount_steps::text));
  select string_agg(s, ', ' order by i) into steps
  from jsonb_array_elements_text(p.discount_steps) with ordinality as e(s, i);
  perform pg_temp.assert_true(
    (select count(*) from jsonb_array_elements_text(p.discount_steps) s where s::int <= 0 or s::int >= 100) = 0,
    format('every discount step must be between 1%% and 99%%, got %s', steps));
  perform pg_temp.assert_true(
    (select bool_and(a::int < b::int)
       from (select s::int as a, lead(s::int) over (order by i) as b
               from jsonb_array_elements_text(p.discount_steps) with ordinality as e(s, i)) x
      where b is not null),
    format('discount steps must be strictly increasing (ordered concessions), got %s', steps));

  perform pg_temp.assert_true(
    p.max_counter_steps >= step_count,
    format('max_counter_steps (%s) must allow every discount step (%s steps) — otherwise the ladder can never be walked',
           p.max_counter_steps, step_count));
  perform pg_temp.assert_true(
    p.max_counter_steps <= 5,
    format('max_counter_steps (%s) is implausibly generous for a boutique negotiation', p.max_counter_steps));
  perform pg_temp.assert_true(
    p.max_counter_steps >= 1, 'max_counter_steps must be at least 1 (the brief''s ladder has three rungs)');

  -- bulk_threshold is a quantity. A value that looks like kobo is a unit bug.
  perform pg_temp.assert_true(
    p.bulk_threshold > 0 and p.bulk_threshold <= 100,
    format('bulk_threshold must be a plausible unit quantity (not money), got %s', p.bulk_threshold));

  -- handoff_rules: the brief's automatic-handoff triggers, with usable types.
  perform pg_temp.assert_true(
    jsonb_typeof(p.handoff_rules) = 'object', 'handoff_rules must be a jsonb object');
  perform pg_temp.assert_true(
    (select count(*) from jsonb_each(p.handoff_rules) as e(k, v)
      where k in ('angry_or_complaining', 'refund_or_wrong_item', 'bulk_order_above_threshold', 'human_requested')
        and jsonb_typeof(v) <> 'boolean') = 0,
    format('the boolean handoff triggers must be booleans, got %s', p.handoff_rules::text));
  perform pg_temp.assert_true(
    p.handoff_rules ?& array['angry_or_complaining', 'refund_or_wrong_item', 'bulk_order_above_threshold',
                              'unanswerable_in_a_row', 'human_requested'],
    format('handoff_rules is missing one of the brief''s triggers (angry, refund/wrong item, bulk order, two unanswerable, human requested): %s',
           p.handoff_rules::text));
  perform pg_temp.assert_true(
    jsonb_typeof(p.handoff_rules -> 'unanswerable_in_a_row') = 'number'
      and (p.handoff_rules ->> 'unanswerable_in_a_row') = '2',
    format('unanswerable_in_a_row must be the count 2 (two unanswerable questions in a row hand off), got %s',
           p.handoff_rules -> 'unanswerable_in_a_row'));
  perform pg_temp.assert_true(
    p.handoff_rules -> 'angry_or_complaining' = 'true'::jsonb
      and p.handoff_rules -> 'refund_or_wrong_item' = 'true'::jsonb
      and p.handoff_rules -> 'bulk_order_above_threshold' = 'true'::jsonb
      and p.handoff_rules -> 'human_requested' = 'true'::jsonb,
    'every boolean handoff trigger from the brief must be enabled for this vendor');

  perform pg_temp.assert_true(
    length(btrim(p.return_policy)) >= 100 and p.return_policy ilike '%exchange%',
    'return_policy must be a real policy, not a placeholder (it is quoted to buyers)');
end
$do$;

\echo '--- seed assertions: 10+ FAQs, Lagos-shaped and free of prices'
-- ===========================================================================
-- 4. Knowledge (FAQs) — grounding, never a source of money
-- ===========================================================================
do $do$
declare
  demo constant uuid := '5eed0000-0000-4000-8000-000000000001';
  faqs int;
  -- NB: not `tags` — that is also a public.knowledge column, and inside a DO
  -- block the plpgsql variable would shadow it ("column reference is
  -- ambiguous"). Same reason `row`/`user` are avoided as variable names here.
  faq_tags text[];
  offenders text;
begin
  select count(*) into faqs from public.knowledge where tenant_id = demo;
  perform pg_temp.assert_true(faqs >= 10, format('expected at least 10 FAQs for the demo tenant, found %s', faqs));
  perform pg_temp.assert_true(
    (select count(*) from public.knowledge where tenant_id = demo and active) = faqs,
    'every seeded FAQ should be active');
  perform pg_temp.assert_true(
    (select count(distinct question) from public.knowledge where tenant_id = demo) = faqs,
    'two FAQs share the same question text');
  perform pg_temp.assert_true(
    (select count(*) from public.knowledge
      where tenant_id = demo and (btrim(question) = '' or btrim(answer) = '')) = 0,
    'no FAQ may have an empty question or answer');
  perform pg_temp.assert_true(
    (select count(*) from public.knowledge where tenant_id = demo and coalesce(array_length(tags, 1), 0) = 0) = 0,
    'every FAQ needs at least one tag, so the agent can retrieve the right one');

  -- The core principle: a buyer may only ever receive a price, fee or discount
  -- that a server-side tool returned. Grounding text is not a tool, so an answer
  -- may explain how the vendor talks about money ("send me your address and I
  -- will confirm the fee") but must never state an amount. What is caught here
  -- is a currency marker next to a number, in either order, plus the naira sign
  -- anywhere — so "pay in naira only" passes and "naira 12,000" or "N12,000"
  -- does not.
  select string_agg(question, ' | ') into offenders
  from public.knowledge
  where tenant_id = demo
    and answer ~* '(₦|[0-9][0-9,. ]*\s*(naira|kobo|ngn)|\m(naira|kobo|ngn)\M\s*[0-9]|\mN[0-9])';
  perform pg_temp.assert_true(
    offenders is null,
    format('these FAQ answers state a money amount, which the model must never be able to quote from knowledge: %s', offenders));

  -- Coverage: the questions this vendor's buyers actually send.
  -- Every distinct tag across the tenant's FAQs, in one array. (A correlated
  -- `array(select ... unnest(k.tags) ...) from public.knowledge k` would return
  -- one array per FAQ and silently keep only the first.)
  select array(
    select distinct tag
    from public.knowledge k, unnest(k.tags) as tag
    where k.tenant_id = demo
    order by 1
  ) into faq_tags;
  perform pg_temp.assert_true(
    faq_tags @> array['sizing', 'fabric', 'delivery', 'payment', 'returns', 'bulk', 'location'],
    format('the FAQ set must cover sizing, fabric, delivery, payment, returns, bulk and location; tags present: %s', faq_tags));
  perform pg_temp.assert_true(
    (select count(*) from public.knowledge where tenant_id = demo and answer ilike '%measurement%') >= 1,
    'the FAQ set must answer custom measurements (sizing is the most common Lagos fashion question)');
end
$do$;

\echo '--- seed assertions: both channels, with the routing keys PR 4 resolves tenants by'
-- ===========================================================================
-- 5. Channels — the webhook ingress routing keys
-- ===========================================================================
do $do$
declare
  demo constant uuid := '5eed0000-0000-4000-8000-000000000001';
  wa public.channels%rowtype;
  ig public.channels%rowtype;
begin
  perform pg_temp.assert_true(
    (select count(*) from public.channels where tenant_id = demo) = 2,
    format('expected exactly 2 channels for the demo tenant, found %s',
           (select count(*) from public.channels where tenant_id = demo)));

  select * into wa from public.channels where tenant_id = demo and type = 'whatsapp';
  select * into ig from public.channels where tenant_id = demo and type = 'instagram';

  perform pg_temp.assert_true(wa.id is not null, 'the demo tenant needs a WhatsApp channel');
  perform pg_temp.assert_true(ig.id is not null, 'the demo tenant needs an Instagram channel');

  perform pg_temp.assert_true(
    wa.phone_number_id = '109876543210987',
    format('the WhatsApp channel''s phone_number_id is the webhook routing key and must stay 109876543210987, got %L',
           wa.phone_number_id));
  perform pg_temp.assert_true(
    wa.instagram_account_id is null,
    'a WhatsApp channel must not carry an instagram_account_id (the schema CHECK allows it; the seed must not)');
  perform pg_temp.assert_true(
    ig.instagram_account_id = '17841400000000001',
    format('the Instagram channel''s instagram_account_id is the webhook routing key and must stay 17841400000000001, got %L',
           ig.instagram_account_id));
  perform pg_temp.assert_true(
    ig.phone_number_id is null,
    'an Instagram channel must not carry a phone_number_id (the schema CHECK allows it; the seed must not)');

  perform pg_temp.assert_true(wa.active and ig.active, 'both demo channels should be active');

  -- Routing keys are globally unique when set: a payload must resolve to one
  -- tenant only, or a tenant would read another tenant's buyers.
  perform pg_temp.assert_true(
    (select count(*) from public.channels where phone_number_id = '109876543210987') = 1
    and (select count(*) from public.channels where instagram_account_id = '17841400000000001') = 1,
    'a channel routing key appears more than once in public.channels');

  -- No live Meta credential in the fixture, and the marker is what makes that
  -- checkable: real ciphertext is written by app code, never committed.
  perform pg_temp.assert_true(
    wa.access_token_encrypted like 'seed-fixture:%' and ig.access_token_encrypted like 'seed-fixture:%',
    format('channel access tokens must stay seed markers (seed-fixture:…), never a real token or real ciphertext, got %L / %L',
           wa.access_token_encrypted, ig.access_token_encrypted));
end
$do$;

\echo '--- seed assertions: the owner, and nothing else in the tenant''s tables'
-- ===========================================================================
-- 6. Owner membership
-- ===========================================================================
do $do$
declare
  demo constant uuid := '5eed0000-0000-4000-8000-000000000001';
  owner public.tenant_users%rowtype;
begin
  perform pg_temp.assert_true(
    (select count(*) from public.tenant_users where tenant_id = demo) = 1,
    'expected exactly one tenant_users row (the owner) for the demo tenant');
  select * into owner from public.tenant_users where tenant_id = demo;
  perform pg_temp.assert_true(owner.role = 'owner', format('the demo tenant''s user should be its owner, got %L', owner.role));
  perform pg_temp.assert_true(
    exists (select 1 from auth.users u where u.id = owner.user_id),
    'the demo owner''s user_id must exist in auth.users — RLS reads this membership row to decide who sees what');
  perform pg_temp.assert_true(
    exists (select 1 from auth.users u where u.id = owner.user_id and u.email like '%.test'),
    'the demo owner must use a .test address that can never receive mail');
end
$do$;

-- ===========================================================================
-- 7. The seed seeds configuration only — no conversations, no money
-- ===========================================================================
-- Also proves the delete-then-insert left no orphan behind, and that a second
-- run created nothing new.
do $do$
declare
  demo constant uuid := '5eed0000-0000-4000-8000-000000000001';
  t text;
  n bigint;
  checked int := 0;
  expected text[] := array['contacts', 'conversations', 'messages', 'offers', 'orders', 'weekly_reports'];
begin
  foreach t in array expected loop
    execute format('select count(*) from public.%I where tenant_id = %L', t, demo) into n;
    perform pg_temp.assert_true(
      n = 0,
      format('public.%s holds %s row(s) for the demo tenant — the seed is configuration only', t, n));
    checked := checked + 1;
  end loop;
  perform pg_temp.assert_true(
    checked = array_length(expected, 1),
    format('the empty-table matrix covered %s tables, expected %s (a table was skipped, so it was never checked)',
           checked, array_length(expected, 1)));
end
$do$;

-- ===========================================================================
-- What landed, then rollback
-- ===========================================================================
\echo '--- demo tenant'
select
  t.slug,
  t.name,
  (select count(*) from public.products p where p.tenant_id = t.id)                        as products,
  (select count(*) from public.products p where p.tenant_id = t.id and p.active)           as active,
  (select count(*) from public.products p where p.tenant_id = t.id and p.stock = 0)        as out_of_stock,
  (select count(*) from public.products p where p.tenant_id = t.id and not p.active)       as inactive,
  (select min(p.floor_price) from public.products p where p.tenant_id = t.id)              as cheapest_floor_kobo,
  (select max(p.list_price)  from public.products p where p.tenant_id = t.id)              as dearest_list_kobo,
  (select count(*) from public.knowledge k where k.tenant_id = t.id)                       as faqs,
  (select count(*) from public.channels c where c.tenant_id = t.id)                        as channels,
  (select c.phone_number_id from public.channels c where c.tenant_id = t.id and c.type = 'whatsapp')       as wa_phone_number_id,
  (select c.instagram_account_id from public.channels c where c.tenant_id = t.id and c.type = 'instagram') as ig_account_id
from public.tenants t;

do $do$
begin
  raise notice 'seed assertion script: % checks executed, all passed', current_setting('seed_check.checks');
end
$do$;

-- Nothing above is kept; not even the helper function.
rollback;
