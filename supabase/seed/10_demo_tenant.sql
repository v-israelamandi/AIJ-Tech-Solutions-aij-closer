-- supabase/seed/10_demo_tenant.sql
--
-- AIJ Closer — the demo tenant: one Lagos fashion vendor, its catalogue,
-- policies, FAQs, owner and both messaging channels.
--
-- seed-tenant-slug: sisi-lagos-fashion
--
-- WHAT THIS CREATES (exactly one tenant, nothing else)
--   public.tenants       1 row  — "Sisi Lagos Fashion", tone profile, NGN
--   auth.users           1 row  — the owner's login (see the note below)
--   public.tenant_users  1 row  — that login as the tenant's owner
--   public.channels      2 rows — one WhatsApp, one Instagram inbox
--   public.products      20 rows — list_price / floor_price in kobo, stock spread
--   public.policies      1 row  — delivery fees, discount ladder, handoff rules
--   public.knowledge     16 rows — the FAQs this vendor's buyers actually send
--
-- Every later feature is built against this data: the webhook ingress routes
-- incoming Meta payloads to a tenant by the channel routing keys below, the
-- agent tools read prices and stock from these products, and the conversation
-- simulator negotiates against this policy row. The seed is therefore part of
-- the test surface, not just convenience data — which is why supabase/seed/
-- 99_assert_seed.sql asserts its shape and why CI re-runs the seed to prove it
-- is idempotent.
--
-- WHY THIS MUST CONNECT AS A PRIVILEGED ROLE (READ THIS FIRST)
--   Run this file with a connection that BYPASSES row-level security: the
--   table owner (Supabase's `postgres` role — what DATABASE_URL from the
--   dashboard gives you) or `service_role`. Fixture provisioning is exactly the
--   big hammer the schema reserves for server-side code. The RLS policies in
--   supabase/migrations/20261014120200_rls_tenant_isolation.sql grant an
--   `authenticated` user only its own tenant's rows, so a session running as
--   `authenticated` (or `anon`) has no policy that would let it insert a new
--   tenant and would fail here. That is the schema working as designed: RLS is
--   the product's security boundary and seeds are provisioning, not product
--   traffic. supabase/seed/run.sh does not set a role, so it inherits whatever
--   the connection string authenticates as — the owner or service_role.
--
-- IDEMPOTENCY — HOW THE DEMO TENANT IS IDENTIFIED
--   public.tenants.slug = 'sisi-lagos-fashion' is the stable identity. The seed
--   is a scoped DELETE followed by an INSERT: it deletes only the tenant with
--   that slug (`on delete cascade` removes every row it owns) and re-inserts it.
--   Running the file twice therefore leaves exactly one demo tenant with the
--   same 20 products — never two, and never a duplicate-key error. Every row
--   also carries a fixed uuid in the 5eed0000-0000-4000-8000-0000000000xx range
--   so that the demo tenant is byte-identical after a re-seed; a later feature
--   can hard-code e.g. product 5eed0000-0000-4000-8000-000000000206 and it will
--   still be the same garment tomorrow.
--
-- MONEY IS AN INTEGER COUNT OF KOBO
--   Every price and fee here is kobo (NGN minor units): NGN 24,500 is 2450000.
--   floor_price is what the owner will not go below and is enforced in SQL and
--   again in app code; nothing in this file gives the model a number to quote.
--
-- THE CATALOGUE SHAPES THE EDGE CASES ON PURPOSE
--   * SLF-009 is active with stock = 0      -> the "sold out" reply path
--   * SLF-019 is inactive with stock = 3    -> "not in the catalogue any more"
--   * SLF-020 is inactive with stock = 0    -> discontinued, nothing on hand
--   The other 17 are active and in stock, with a spread from 1 to 20 units.
--
-- NO PRICES IN THE FAQS
--   public.knowledge is grounding for the agent, never a source of money: the
--   core principle is that prices, delivery fees and discounts reach a buyer
--   only through a server-side tool call. The FAQ answers here therefore
--   describe how the vendor answers ("send me your address and I will confirm
--   the fee") rather than quoting figures; 99_assert_seed.sql fails if a naira
--   amount ever appears in one of them.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. Drop the previous copy of the demo tenant, and only that copy
-- ---------------------------------------------------------------------------
-- Scoped by slug: the demo tenant's children all cascade, and no other tenant's
-- row can be touched by this statement. This is what makes the file re-runnable.
delete from public.tenants where slug = 'sisi-lagos-fashion';

-- ---------------------------------------------------------------------------
-- 2. The vendor
-- ---------------------------------------------------------------------------
-- tone_profile is injected into the system prompt verbatim, so it is written as
-- an instruction to the model rather than a description of one. Pidgin and mixed
-- English are supported by design (the brief lists them as buyer behaviour).
-- paystack_subaccount_code stays null: subaccount provisioning is not yet
-- sequenced, and money must only ever move to a real account.
insert into public.tenants (id, name, slug, tone_profile, currency, active)
values (
  '5eed0000-0000-4000-8000-000000000001',
  'Sisi Lagos Fashion',
  'sisi-lagos-fashion',
  $tone$You are Sisi Lagos Fashion's own shop assistant on WhatsApp and Instagram, writing the way the owner writes to a customer: warm, quick and street-smart Lagos English with light Pidgin in greetings and small talk ("Hey dear, how far?", "no wahala", "abeg", "omo", "sha"). Mixing English and Pidgin in one message is normal; keep it natural and never more than one Pidgin phrase per message.

Call the buyer "dear" or "sweetie" — never "ma'am", never "sir", never "customer". Keep replies short: one to three sentences, like a real chat, not a letter. At most one emoji per message, usually a smile, sparkle or heart; never a wall of emoji. Never sound corporate or robotic: no "Dear customer", no "Kindly note", no "We apologise for any inconvenience", no signature blocks.

Answer the question that was actually asked first, in the buyer's own words, then add one short helpful nudge (a size tip, a colour suggestion, an offer of a photo). Prices are always written in naira with a comma, like N18,500 — never in kobo, never as a bare number. Only state a price, a stock figure, a delivery fee, a discount or a payment link that a tool call returned in this conversation; if a tool did not return it, say you will confirm it.

When a buyer haggles, stay friendly and hold the price with a smile, offering value (fit, fabric, free styling advice, a gele match) before any discount, and never go below the floor a tool returned. Bulk orders, aso-ebi and bridal parties go to the owner for a quote. If a buyer is angry, complaining, or has a refund or wrong-item issue, drop all playfulness: be calm, plain, short and apologetic, and hand over to the owner immediately.

Never pressure a buyer, never invent scarcity or a deadline, and never claim a discount is about to expire. Never lie about stock to close a sale.$tone$,
  'NGN',
  true
);

-- ---------------------------------------------------------------------------
-- 3. The owner's login and membership
-- ---------------------------------------------------------------------------
-- public.tenant_users references auth.users, so the demo needs a user row. On a
-- real Supabase project that row is normally created by the Auth API (sign up,
-- or the dashboard's "invite user") — this insert is the minimum auth.users row
-- the foreign key needs, with a .test address that can never receive mail. It is
-- `on conflict do nothing` so an owner created through Auth keeps its own
-- credentials. See supabase/seed/README.md for the one place this may need a
-- hand on a real project.
insert into auth.users (id, email)
values ('5eed0000-0000-4000-8000-0000000000a1', 'owner@sisi-lagos-fashion.test')
on conflict (id) do nothing;

insert into public.tenant_users (id, tenant_id, user_id, role)
values (
  '5eed0000-0000-4000-8000-0000000000b1',
  '5eed0000-0000-4000-8000-000000000001',
  '5eed0000-0000-4000-8000-0000000000a1',
  'owner'
);

-- ---------------------------------------------------------------------------
-- 4. Channels — the routing keys the webhook ingress resolves tenants by
-- ---------------------------------------------------------------------------
-- PR 4 (Meta webhook ingress) receives a payload, reads the WhatsApp
-- `metadata.phone_number_id` or the Instagram `recipient.id`, and looks up the
-- channel row that owns it. These two values are that lookup key, so they are
-- what PR 4's tests route against:
--     WhatsApp  phone_number_id      = 109876543210987
--     Instagram instagram_account_id = 17841400000000001
-- Both columns are globally unique when set, so no other tenant can claim them.
--
-- access_token_encrypted holds a seed marker, NOT a token and NOT usable
-- ciphertext: app code writes real ciphertext here, encrypted with
-- CHANNEL_TOKEN_ENCRYPTION_KEY (AES-256-GCM), and plaintext must never be
-- stored. The marker is deliberately un-decryptable so a demo never pretends to
-- hold a live Meta credential; 99_assert_seed.sql asserts this column still
-- starts with the marker, which is what stops a real token being committed into
-- the seed in a later edit.
insert into public.channels
  (id, tenant_id, type, label, phone_number_id, instagram_account_id, access_token_encrypted, active)
values
  (
    '5eed0000-0000-4000-8000-000000000101',
    '5eed0000-0000-4000-8000-000000000001',
    'whatsapp',
    'Sisi Lagos Fashion — WhatsApp Business',
    '109876543210987',
    null,
    'seed-fixture:not-a-real-token',
    true
  ),
  (
    '5eed0000-0000-4000-8000-000000000102',
    '5eed0000-0000-4000-8000-000000000001',
    'instagram',
    'Sisi Lagos Fashion — Instagram DM',
    null,
    '17841400000000001',
    'seed-fixture:not-a-real-token',
    true
  );

-- ---------------------------------------------------------------------------
-- 5. Catalog — 20 pieces, list_price and floor_price in kobo
-- ---------------------------------------------------------------------------
-- floor_price is 12-18% below list_price on every row, which is deliberate: the
-- policy row below concedes at most 10% (the last discount step), so the last
-- step always lands at or above the floor and the floor itself stays reachable
-- only as the final "pay now" rung. 99_assert_seed.sql checks
-- floor_price * 100 <= list_price * 90 (i.e. a 10% concession never breaks the
-- floor) on every row, so an edit that breaks the ladder fails CI.
--
-- photos are Supabase Storage paths (public bucket `product-photos`); nothing
-- uploads them yet, so most rows carry one or two plausible paths and a few
-- carry none, which is the shape the send service has to cope with.
insert into public.products
  (id, tenant_id, name, sku, description, category, list_price, floor_price, stock, photos, active)
values
  ('5eed0000-0000-4000-8000-000000000201', '5eed0000-0000-4000-8000-000000000001',
   'Zainab Adire Two-Piece Set', 'SLF-001',
   'Hand-dyed adire cotton two-piece: a wrap top and wide-leg trousers, cut in our Ikeja studio. Sold as a set, sizes UK 8-18.',
   'Two-piece set', 3850000, 3270000, 6,
   '["products/slf-001/1.jpg", "products/slf-001/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000202', '5eed0000-0000-4000-8000-000000000001',
   'Ogechi Ankara Wrap Dress', 'SLF-002',
   'Ankara wax-print wrap dress with a fitted bodice and a tie waist. Fully lined, midi length, pockets in the side seams.',
   'Dress', 2450000, 2080000, 9,
   '["products/slf-002/1.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000203', '5eed0000-0000-4000-8000-000000000001',
   'Aduke Chiffon Bubu Gown', 'SLF-003',
   'Lightweight chiffon bubu gown with a loose drape and inner slip. Our most requested owambe style — roomy and cool to wear.',
   'Gown', 3200000, 2720000, 4,
   '["products/slf-003/1.jpg", "products/slf-003/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000204', '5eed0000-0000-4000-8000-000000000001',
   'Lagos Nights Silk Slip Dress', 'SLF-004',
   'Bias-cut silk slip dress for evening events: cowl neck, adjustable straps, midi length. Dry clean only.',
   'Dress', 4500000, 3690000, 2,
   '["products/slf-004/1.jpg", "products/slf-004/2.jpg", "products/slf-004/3.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000205', '5eed0000-0000-4000-8000-000000000001',
   'Owambe Aso-Ebi Lace Two-Piece', 'SLF-005',
   'French lace two-piece for aso-ebi: boned corset top and a fishtail skirt. We can match your gele for the same fabric.',
   'Aso-ebi', 6200000, 5270000, 3,
   '["products/slf-005/1.jpg", "products/slf-005/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000206', '5eed0000-0000-4000-8000-000000000001',
   'Senator Kaftan with Embroidery', 'SLF-006',
   'Embroidered senator kaftan in cashmere cotton with matching trousers. Straight fit, three-quarter sleeves.',
   'Kaftan', 4800000, 4080000, 5,
   '["products/slf-006/1.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000207', '5eed0000-0000-4000-8000-000000000001',
   'Rima Palazzo Two-Piece', 'SLF-007',
   'Palazzo trousers and a sleeveless top in structured cotton. Office-ready and easy to iron; sizes UK 8-20.',
   'Two-piece set', 3500000, 2975000, 7,
   '["products/slf-007/1.jpg", "products/slf-007/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000208', '5eed0000-0000-4000-8000-000000000001',
   'Bustier Corset Top', 'SLF-008',
   'Structured bustier corset top with boning and a zip back. Wears well over a skirt, high-waist trousers or jeans.',
   'Top', 1800000, 1530000, 12,
   '["products/slf-008/1.jpg", "products/slf-008/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000209', '5eed0000-0000-4000-8000-000000000001',
   'Aso-Oke Trim Skater Skirt', 'SLF-009',
   'Skater skirt with handwoven aso-oke trim at the waist. Fully lined, sits at the knee. Restocking — take orders for the next drop.',
   'Skirt', 2200000, 1935000, 0,
   '["products/slf-009/1.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-00000000020a', '5eed0000-0000-4000-8000-000000000001',
   'Adunni Wide-Leg Jumpsuit', 'SLF-010',
   'Wide-leg jumpsuit with a wrap front and a removable belt. Pockets in the side seams; stretch crepe.',
   'Jumpsuit', 4100000, 3485000, 4,
   '["products/slf-010/1.jpg", "products/slf-010/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-00000000020b', '5eed0000-0000-4000-8000-000000000001',
   'Upcycled Adire Denim Jacket', 'SLF-011',
   'Vintage denim jacket with hand-painted adire panels. Each piece is a one-off, so the pattern varies slightly.',
   'Jacket', 2950000, 2415000, 3,
   '["products/slf-011/1.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-00000000020c', '5eed0000-0000-4000-8000-000000000001',
   'Ayo Floral Silk Kimono', 'SLF-012',
   'Floral silk kimono to throw over anything: floor length, open front, no fastening. One size.',
   'Kimono', 2600000, 2285000, 8,
   '["products/slf-012/1.jpg", "products/slf-012/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-00000000020d', '5eed0000-0000-4000-8000-000000000001',
   'Ifeoma Print Maxi Dress', 'SLF-013',
   'Print maxi dress with a smocked waist and a tiered skirt. The print placement varies slightly on each cut.',
   'Dress', 2900000, 2465000, 6,
   '["products/slf-013/1.jpg", "products/slf-013/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-00000000020e', '5eed0000-0000-4000-8000-000000000001',
   'Amaka Ruched Bodycon Dress', 'SLF-014',
   'Ruched bodycon dress in stretch crepe with a built-in lining. Midi length, mid-weight, very forgiving.',
   'Dress', 2350000, 1925000, 11,
   '["products/slf-014/1.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-00000000020f', '5eed0000-0000-4000-8000-000000000001',
   'Tola Linen Skirt Set', 'SLF-015',
   'Linen skirt set: a fitted top and a wrap midi skirt. Breathes well in Lagos heat; pairs with sandals or heels.',
   'Two-piece set', 3350000, 2945000, 5,
   '["products/slf-015/1.jpg", "products/slf-015/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000210', '5eed0000-0000-4000-8000-000000000001',
   'Nneka Adire Shirtdress', 'SLF-016',
   'Adire shirtdress with a collar, cuffed sleeves and side slits. Works to the office, to church or as a beach cover-up.',
   'Dress', 2700000, 2375000, 10,
   '["products/slf-016/1.jpg", "products/slf-016/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000211', '5eed0000-0000-4000-8000-000000000001',
   'Swiss Voile Gele and Headwrap', 'SLF-017',
   'Swiss voile gele with a matching headwrap. Stiff, easy to tie and holds a fan shape all day. Sold as a pair.',
   'Accessory', 1200000, 1020000, 20,
   '["products/slf-017/1.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000212', '5eed0000-0000-4000-8000-000000000001',
   'Beaded Owambe Clutch', 'SLF-018',
   'Hand-beaded clutch with a detachable chain. Fits a phone, a lipstick and a small purse; made in Lagos.',
   'Accessory', 1950000, 1655000, 14,
   '["products/slf-018/1.jpg", "products/slf-018/2.jpg"]'::jsonb, true),
  ('5eed0000-0000-4000-8000-000000000213', '5eed0000-0000-4000-8000-000000000001',
   'Ruffled Ankara Corset Dress', 'SLF-019',
   'Ruffled ankara corset dress with a boned bodice. Last of the season and no longer restocking — remaining stock only.',
   'Dress', 4400000, 3870000, 3,
   '["products/slf-019/1.jpg"]'::jsonb, false),
  ('5eed0000-0000-4000-8000-000000000214', '5eed0000-0000-4000-8000-000000000001',
   'Sequin Party Gown (old stock)', 'SLF-020',
   'Sequin party gown from an old collection, discontinued. Kept on file for reference; nothing on hand.',
   'Gown', 5500000, 4675000, 0,
   '[]'::jsonb, false);

-- ---------------------------------------------------------------------------
-- 6. Policies — the numbers the agent is allowed to commit to
-- ---------------------------------------------------------------------------
-- One row per tenant (public.policies.tenant_id is unique), read by every agent
-- tool. Nothing in this row is ever taken from the model's reply.
--
-- delivery_fees — zone -> fee in KOBO, and the ONLY fees the agent may quote:
--   Lagos mainland  NGN 2,500 = 250000
--   Lagos island    NGN 3,000 = 300000   (Third Mainland Bridge and the toll)
--   outside Lagos   NGN 5,000 = 500000   (courier; 2-4 working days)
--
-- discount_steps — the negotiation ladder from the brief, as ordered percent
-- concessions off list_price. The rungs the agent walks are:
--   counter 0  first quote, at products.list_price
--   counter 1  1st "last price": HOLD list_price and add value (free styling,
--              gele matching, a photo) — no discount yet
--   counter 2  2nd: the first discount step, 5% off list_price
--   counter 3  3rd: the last discount step, 10% off list_price, or the product's
--              floor_price if that is higher — whichever the agent quotes here
--              is tied to the buyer paying now
-- max_counter_steps = 3 allows exactly those three counters and no more. Below
-- floor the agent declines and suggests a cheaper piece instead; the floor is
-- never crossed, whatever the model drafts.
--
-- bulk_threshold — UNITS, not money: 6 pieces or more in one order is a bulk
-- order (bridal party, aso-ebi group) and hands off to the owner for a quote.
--
-- handoff_rules — the brief's automatic-handoff triggers, as one jsonb object
-- so PR 6 can read them without a migration:
--   angry_or_complaining      bool — angry or complaining buyer
--   refund_or_wrong_item      bool — refund or wrong-item issue
--   bulk_order_above_threshold bool — quantity >= bulk_threshold
--   unanswerable_in_a_row     int  — this many unanswerable questions in a row
--   human_requested           bool — buyer asks for a human
insert into public.policies
  (id, tenant_id, delivery_fees, return_policy, discount_steps, max_counter_steps, bulk_threshold, handoff_rules)
values (
  '5eed0000-0000-4000-8000-000000000301',
  '5eed0000-0000-4000-8000-000000000001',
  '{"Lagos mainland": 250000, "Lagos island": 300000, "outside Lagos": 500000}'::jsonb,
  $policy$Exchange within 3 days of delivery for anything unworn with the tag still on; we do not refund delivery fees.

Wrong item or damaged: send us a photo within 48 hours of delivery and we replace or refund it, and we cover the return delivery when the mistake is ours.

Sale pieces, aso-ebi orders and custom-measurement pieces are final — no exchange, no refund.

We do not refund cash to a different account: a refund, where one is due, goes back the same way the buyer paid.$policy$,
  '[5, 10]'::jsonb,
  3,
  6,
  '{"angry_or_complaining": true, "refund_or_wrong_item": true, "bulk_order_above_threshold": true, "unanswerable_in_a_row": 2, "human_requested": true}'::jsonb
);

-- ---------------------------------------------------------------------------
-- 7. Knowledge — the FAQs this vendor's buyers actually send
-- ---------------------------------------------------------------------------
-- Grounding for the agent, never a source of money: no answer here states a
-- price, delivery fee or discount (the agent gets those from a tool call), and
-- 99_assert_seed.sql fails if a naira amount ever appears in one. Questions are
-- written as buyers write them; answers are written the way a Lagos fashion
-- vendor answers on WhatsApp, not as a policy document.
insert into public.knowledge (id, tenant_id, question, answer, tags, active)
values
  ('5eed0000-0000-4000-8000-000000000401', '5eed0000-0000-4000-8000-000000000001',
   'Do you have my size? I''m a UK 16.',
   'Yes dear, most of our styles are cut from UK 8 to UK 20, and the ankara, adire and linen pieces we can sew to your own measurements at no extra cost. Tell me the style you like and I will confirm what we have in your size right now.',
   '{sizing}', true),
  ('5eed0000-0000-4000-8000-000000000402', '5eed0000-0000-4000-8000-000000000001',
   'How do I know which size to order?',
   'Send me your bust, waist and hip in inches, plus your height if it is a long style, and I will tell you the size to take. If you are between two sizes, go with the bigger one for anything fitted and the smaller one for a bubu or kimono. Custom measurements are safest for aso-ebi.',
   '{sizing}', true),
  ('5eed0000-0000-4000-8000-000000000403', '5eed0000-0000-4000-8000-000000000001',
   'What fabric is it made of?',
   'It depends on the piece: the adire and ankara styles are cotton wax print, the bubu is chiffon with a slip inside, the slip dress is silk, the aso-ebi is French lace and the kaftan is cashmere cotton. Tell me the exact style and I will confirm the fabric and how to wash it.',
   '{fabric}', true),
  ('5eed0000-0000-4000-8000-000000000404', '5eed0000-0000-4000-8000-000000000001',
   'Will the colour fade or run when I wash it?',
   'Adire and ankara will bleed a little on the first wash, that is normal. Hand wash cold with a little salt the first time, dry in the shade and never soak or bleach it. Lace and silk should be dry cleaned. Wash dark prints separately for the first three washes.',
   '{fabric,care}', true),
  ('5eed0000-0000-4000-8000-000000000405', '5eed0000-0000-4000-8000-000000000001',
   'How long will delivery take within Lagos?',
   'If payment lands before 1pm, mainland deliveries go out the same day and the island goes out the same day or first thing the next morning. Orders paid after 1pm go the next working day. I send the rider''s name and number as soon as it leaves the studio.',
   '{delivery}', true),
  ('5eed0000-0000-4000-8000-000000000406', '5eed0000-0000-4000-8000-000000000001',
   'Do you deliver outside Lagos?',
   'Yes dear, we deliver nationwide by courier, usually two to four working days, and the tracking number goes to you the same day we dispatch. Send the full address with a landmark and I will confirm the fee and the day it will reach you.',
   '{delivery}', true),
  ('5eed0000-0000-4000-8000-000000000407', '5eed0000-0000-4000-8000-000000000001',
   'How much is delivery to Lekki? And to Surulere?',
   'The fee depends on the zone — mainland, island and outside Lagos are priced differently, and Lekki and Surulere are not the same zone. Send me the full delivery address with a landmark and I will confirm the exact fee before you pay anything, so there is no surprise later.',
   '{delivery}', true),
  ('5eed0000-0000-4000-8000-000000000408', '5eed0000-0000-4000-8000-000000000001',
   'Can I pay on delivery?',
   'New buyers pay before dispatch, that is how we keep the business safe. If you are a repeat buyer on the mainland we can arrange pay on delivery. Aso-ebi and custom-measurement pieces need part payment to start cutting.',
   '{payment}', true),
  ('5eed0000-0000-4000-8000-000000000409', '5eed0000-0000-4000-8000-000000000001',
   'What payment methods do you accept?',
   'I will send you a secure payment link — card, bank transfer or USSD all work on it, and the payment goes straight into the business account. Pay in naira only. Once it shows on our side I confirm the order and we start packing.',
   '{payment}', true),
  ('5eed0000-0000-4000-8000-00000000040a', '5eed0000-0000-4000-8000-000000000001',
   'Can I just transfer to your personal account?',
   'Please only pay through the payment link I send you. We never ask for your card number, your PIN or an OTP, and no one from Sisi Lagos Fashion will ever call to ask for them. If anyone asks you for those, it is not us — tell me straight away.',
   '{payment,security}', true),
  ('5eed0000-0000-4000-8000-00000000040b', '5eed0000-0000-4000-8000-000000000001',
   'The wrong item was sent to me. What now?',
   'Ah sorry about that dear, we will sort it. Send me a photo of what arrived within 48 hours of delivery and I will arrange the swap, and we cover the cost of picking the wrong piece back up. If the exact style is finished I will offer you another piece or your money back.',
   '{returns,complaint}', true),
  ('5eed0000-0000-4000-8000-00000000040c', '5eed0000-0000-4000-8000-000000000001',
   'Can I return something if I change my mind?',
   'Yes, exchange within 3 days of delivery as long as it is unworn with the tag still on; you cover the delivery back to us. Sale pieces, aso-ebi orders and custom-measurement pieces are final. Tell me what you want to swap it for and I will hold it for you.',
   '{returns}', true),
  ('5eed0000-0000-4000-8000-00000000040d', '5eed0000-0000-4000-8000-000000000001',
   'I''m buying for my bridal party — can I get a discount?',
   'Congratulations dear! Orders of six pieces or more go to the owner for a proper quote, because the price depends on the style, the sizes and the date you need them. Send me the quantity, the sizes and your date and I will come back with the best we can do.',
   '{bulk,aso-ebi}', true),
  ('5eed0000-0000-4000-8000-00000000040e', '5eed0000-0000-4000-8000-000000000001',
   'Do you have a shop where I can come and see the clothes?',
   'Yes dear, our studio is off Awolowo Way in Ikeja and you are welcome to come and see and try things. We work by appointment so that someone is free to attend to you, Monday to Saturday. Tell me the day that suits you and I will send the address and direction.',
   '{location}', true),
  ('5eed0000-0000-4000-8000-00000000040f', '5eed0000-0000-4000-8000-000000000001',
   'Do you sew to my own measurements, or with my own fabric?',
   'Yes, we do custom. Send your measurements, or come to the Ikeja studio to be measured. Custom and aso-ebi pieces take seven to ten working days and need part payment before we start cutting, and they cannot be exchanged once they are cut to you.',
   '{custom,sizing}', true),
  ('5eed0000-0000-4000-8000-000000000410', '5eed0000-0000-4000-8000-000000000001',
   'How do I know my order is confirmed?',
   'You are confirmed once the payment shows on our side, and I will tell you immediately when it does. After that I send a picture of the piece packed, and the rider''s name and number or the courier tracking number on the day it leaves the studio.',
   '{orders,delivery}', true);

commit;

-- ---------------------------------------------------------------------------
-- Summary — printed so a human running the seed sees what landed
-- ---------------------------------------------------------------------------
\echo '--- seed: demo tenant "sisi-lagos-fashion" applied'
select
  t.slug,
  t.name,
  (select count(*) from public.products  p where p.tenant_id = t.id) as products,
  (select count(*) from public.products  p where p.tenant_id = t.id and p.active) as products_active,
  (select count(*) from public.products  p where p.tenant_id = t.id and p.stock = 0) as products_out_of_stock,
  (select count(*) from public.products  p where p.tenant_id = t.id and not p.active) as products_inactive,
  (select count(*) from public.knowledge k where k.tenant_id = t.id) as faqs,
  (select count(*) from public.channels  c where c.tenant_id = t.id) as channels,
  (select count(*) from public.policies  o where o.tenant_id = t.id) as policies,
  (select count(*) from public.tenant_users u where u.tenant_id = t.id) as owners
from public.tenants t
where t.slug = 'sisi-lagos-fashion';
