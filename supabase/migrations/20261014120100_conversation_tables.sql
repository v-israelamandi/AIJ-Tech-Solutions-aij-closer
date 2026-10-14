-- 20261014120100_conversation_tables.sql
--
-- AIJ Closer — the conversation, negotiation and money tables.
--
-- Same conventions as 20261014120000_core_tables.sql: uuid keys, timestamptz,
-- MONEY IS AN INTEGER COUNT OF KOBO, tenant_id on every row.
--
-- Child rows reference their parent on (tenant_id, id) rather than id alone.
-- That is deliberate: the service role bypasses RLS, and a plain single-column
-- FK would let a row of tenant A be attached to a conversation of tenant B
-- (foreign-key checks are not filtered by row-level security).

begin;

-- ---------------------------------------------------------------------------
-- contacts — a buyer the tenant has talked to on one channel
-- ---------------------------------------------------------------------------
create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  channel text not null check (channel in ('whatsapp', 'instagram')),
  -- WhatsApp wa_id (phone number) or Instagram-scoped id (IGSID). Not a user id
  -- we control: it is whatever Meta sends.
  external_id text not null check (length(btrim(external_id)) > 0),
  display_name text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- The hot lookup: find or create the buyer for an inbound webhook.
  constraint contacts_tenant_id_channel_external_id_key
    unique (tenant_id, channel, external_id),
  constraint contacts_tenant_id_id_key unique (tenant_id, id)
);

comment on table public.contacts is
  'A buyer (customer of the tenant) on one channel. Namespaced per tenant: the same phone number can be a contact of two different vendors.';
comment on column public.contacts.external_id is
  'Meta-side identifier: WhatsApp wa_id or Instagram IGSID. Never a value we generate.';
comment on column public.contacts.display_name is
  'Profile name Meta reports for the contact, when it reports one.';

create index contacts_tenant_id_idx on public.contacts (tenant_id);

create trigger contacts_set_updated_at
  before update on public.contacts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- conversations — one thread with one buyer
-- ---------------------------------------------------------------------------
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contact_id uuid not null,
  channel text not null check (channel in ('whatsapp', 'instagram')),
  -- bot = the agent is answering; human = an owner took over and the agent
  -- must not send anything; closed = done.
  status text not null default 'bot' check (status in ('bot', 'human', 'closed')),
  -- End of Meta's 24-hour customer service window: outside it, only approved
  -- template messages may be sent.
  window_expires_at timestamptz,
  handoff_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conversations_tenant_id_contact_id_fkey
    foreign key (tenant_id, contact_id)
    references public.contacts (tenant_id, id) on delete cascade,
  constraint conversations_tenant_id_id_key unique (tenant_id, id)
);

comment on table public.conversations is
  'One conversation thread with one buyer. status drives everything: while status = human the agent is forbidden from replying.';
comment on column public.conversations.status is
  'bot | human | closed. Mirrors conversationStatusSchema in @aij/shared.';
comment on column public.conversations.window_expires_at is
  'When Meta''s 24-hour customer service window closes for this thread. Past it, only approved template messages may be sent.';
comment on column public.conversations.handoff_reason is
  'Why the thread was handed to a human (angry buyer, refund, bulk order, ...). Null while the agent is handling it.';

create index conversations_tenant_id_idx on public.conversations (tenant_id);
create index conversations_tenant_id_status_idx on public.conversations (tenant_id, status);
create index conversations_contact_id_idx on public.conversations (contact_id);

create trigger conversations_set_updated_at
  before update on public.conversations
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- messages — every inbound and outbound message, plus the agent's tool calls
-- ---------------------------------------------------------------------------
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  conversation_id uuid not null,
  direction text not null check (direction in ('inbound', 'outbound')),
  type text not null default 'text' check (type in ('text', 'voice', 'image')),
  -- Text body, or the transcript of a voice note. Never a price the model
  -- invented: prices only ever arrive through tool_calls.
  content text not null default '',
  media_url text,
  -- The tool calls the agent made to produce/justify this reply, in order.
  tool_calls jsonb not null default '[]'::jsonb
    check (jsonb_typeof(tool_calls) = 'array'),
  -- Meta's message id: the webhook dedupe key. NULL for anything we send
  -- ourselves (only Meta can name an inbound message).
  meta_message_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint messages_tenant_id_conversation_id_fkey
    foreign key (tenant_id, conversation_id)
    references public.conversations (tenant_id, id) on delete cascade
);

comment on table public.messages is
  'Every inbound and outbound message. Inbound rows are deduplicated on meta_message_id because Meta retries webhooks.';
comment on column public.messages.direction is
  'inbound = from the buyer; outbound = from the agent or the owner. Mirrors messageDirectionSchema in @aij/shared.';
comment on column public.messages.type is
  'text | voice | image. Mirrors messageTypeSchema in @aij/shared. For voice, content holds the transcript.';
comment on column public.messages.content is
  'Message text, or the speech-to-text transcript of a voice note.';
comment on column public.messages.media_url is
  'Storage URL of the media (screenshot, voice note) when there is one.';
comment on column public.messages.tool_calls is
  'JSON array of the server-side tool calls recorded for this message, in order. The audit trail proving which values were read from the database.';
comment on column public.messages.meta_message_id is
  'Meta''s message id (webhook payload). Null for our own outbound messages; unique when set, so a retried webhook cannot create a duplicate.';

create index messages_tenant_id_idx on public.messages (tenant_id);
create index messages_conversation_id_created_at_idx
  on public.messages (conversation_id, created_at);
-- Partial unique index: enforced when set, NULLs stay allowed (and many).
create unique index messages_meta_message_id_key
  on public.messages (meta_message_id) where meta_message_id is not null;

create trigger messages_set_updated_at
  before update on public.messages
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- offers — every price the agent put on the table
-- ---------------------------------------------------------------------------
create table public.offers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  conversation_id uuid not null,
  -- Nullable so the offer survives the product being removed; deactivate a
  -- product (active = false) rather than deleting it.
  product_id uuid,
  -- KOBO. Never below the product's floor_price — enforced in app code and
  -- asserted by the conversation simulator.
  price integer not null check (price >= 0),
  quantity integer not null default 1 check (quantity > 0),
  -- Which counter-offer this was (0 = first price quoted). Capped by
  -- policies.max_counter_steps.
  counter_step integer not null default 0 check (counter_step >= 0),
  status text not null default 'proposed'
    check (status in ('proposed', 'accepted', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint offers_tenant_id_conversation_id_fkey
    foreign key (tenant_id, conversation_id)
    references public.conversations (tenant_id, id) on delete cascade,
  constraint offers_tenant_id_product_id_fkey
    foreign key (tenant_id, product_id)
    references public.products (tenant_id, id) on delete cascade
);

comment on table public.offers is
  'Price offers made during a negotiation: what the agent said, to whom, and at which step. The written record that no offer ever went below floor_price.';
comment on column public.offers.price is
  'Offered unit price in KOBO (NGN minor units). Must be >= the product''s floor_price.';
comment on column public.offers.counter_step is
  'Counter-offer index: 0 for the first price quoted, 1 for the first discount step, and so on. Bounded by policies.max_counter_steps.';
comment on column public.offers.status is
  'proposed | accepted | rejected. No matching enum exists in @aij/shared yet.';

create index offers_tenant_id_idx on public.offers (tenant_id);
create index offers_conversation_id_idx on public.offers (conversation_id);
create index offers_product_id_idx on public.offers (product_id);

create trigger offers_set_updated_at
  before update on public.offers
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- orders — the money record
-- ---------------------------------------------------------------------------
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  conversation_id uuid,
  contact_id uuid,
  product_id uuid,
  quantity integer not null default 1 check (quantity > 0),
  -- KOBO. unit_price is the price agreed in the negotiation; delivery_fee comes
  -- from policies.delivery_fees; amount is what Paystack charges.
  unit_price integer not null check (unit_price >= 0),
  delivery_fee integer not null default 0 check (delivery_fee >= 0),
  amount integer not null check (amount >= 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  -- Paystack reference. NULL until a payment link has been created.
  paystack_reference text,
  payment_status text not null default 'pending'
    check (payment_status in ('pending', 'paid', 'failed', 'refunded')),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- An order is a financial record: the parents it points at cannot be deleted
  -- while it exists (deactivate products, close conversations instead), but a
  -- whole tenant can still be deleted — see the notes in README.md.
  constraint orders_tenant_id_conversation_id_fkey
    foreign key (tenant_id, conversation_id)
    references public.conversations (tenant_id, id) on delete no action,
  constraint orders_tenant_id_contact_id_fkey
    foreign key (tenant_id, contact_id)
    references public.contacts (tenant_id, id) on delete no action,
  constraint orders_tenant_id_product_id_fkey
    foreign key (tenant_id, product_id)
    references public.products (tenant_id, id) on delete no action,
  -- The total is arithmetic on stored values, never a number the model chose.
  constraint orders_amount_matches_line check (
    amount = (unit_price * quantity) + delivery_fee
  )
);

comment on table public.orders is
  'A confirmed order and its payment state. amount is arithmetic over stored columns only, so no model output can ever reach a Paystack amount.';
comment on column public.orders.unit_price is
  'Agreed unit price in KOBO. Comes from products/offers, never from the model.';
comment on column public.orders.delivery_fee is
  'Delivery fee in KOBO, read from policies.delivery_fees.';
comment on column public.orders.amount is
  'Total charged, in KOBO: (unit_price * quantity) + delivery_fee. Enforced by orders_amount_matches_line.';
comment on column public.orders.paystack_reference is
  'Paystack transaction reference. Null until a payment link exists; unique when set, so a payment cannot be recorded twice.';
comment on column public.orders.payment_status is
  'pending | paid | failed | refunded. Mirrors orderPaymentStatusSchema in @aij/shared.';

create index orders_tenant_id_idx on public.orders (tenant_id);
create index orders_tenant_id_payment_status_idx on public.orders (tenant_id, payment_status);
create index orders_conversation_id_idx on public.orders (conversation_id);
create index orders_contact_id_idx on public.orders (contact_id);
create index orders_product_id_idx on public.orders (product_id);
-- Partial unique index: enforced when set, NULLs stay allowed (and many).
create unique index orders_paystack_reference_key
  on public.orders (paystack_reference) where paystack_reference is not null;

create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- weekly_reports — the owner's summary of the week
-- ---------------------------------------------------------------------------
create table public.weekly_reports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  week_start date not null,
  week_end date not null,
  -- Generated summary: conversations handled, offers made, orders, revenue.
  -- Shape is app-owned (jsonb) so it can grow without a migration.
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint weekly_reports_tenant_id_week_start_key unique (tenant_id, week_start),
  constraint weekly_reports_week_range check (week_end >= week_start)
);

comment on table public.weekly_reports is
  'One generated report per tenant per week. The unique (tenant_id, week_start) index doubles as the tenant_id index.';
comment on column public.weekly_reports.payload is
  'JSON object with the week''s numbers. Any money inside it is in KOBO, like every other amount in this schema.';

create trigger weekly_reports_set_updated_at
  before update on public.weekly_reports
  for each row execute function public.set_updated_at();

commit;
