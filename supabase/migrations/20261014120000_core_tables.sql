-- 20261014120000_core_tables.sql
--
-- AIJ Closer — core tenant configuration tables.
--
-- Conventions used by every migration in this directory (see README.md):
--   * `uuid` primary keys defaulting to `gen_random_uuid()` (built in to
--     Postgres 13+, which is what Supabase runs — no extension needed).
--   * every timestamp is `timestamptz`, and every table carries
--     `created_at` / `updated_at` maintained by `public.set_updated_at()`.
--   * MONEY IS AN INTEGER COUNT OF KOBO (NGN minor units). Column names and
--     units are documented on each column with a `comment on column`. There is
--     no float/numeric money anywhere in this schema: code — never the model —
--     is the only thing allowed to produce a price, and integers make that
--     exact.
--   * every tenant-scoped table carries
--     `tenant_id uuid not null references public.tenants(id) on delete cascade`.
--   * child rows reference their parent on `(tenant_id, id)`, not `id` alone,
--     so a row can never be linked into another tenant's data even though the
--     service role bypasses RLS.

begin;

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger function: stamps updated_at on every write. Attached to every table in this schema.';

-- ---------------------------------------------------------------------------
-- tenants — one row per client business (a "vendor")
-- ---------------------------------------------------------------------------
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 200),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{0,63}$'),
  -- How the agent should sound for this vendor (e.g. "warm, playful, uses
  -- light Pidgin for greetings"). Injected into the system prompt verbatim.
  tone_profile text not null default '',
  -- With money stored in minor units, the currency has to be pinned somewhere.
  currency text not null default 'NGN' check (currency = 'NGN'),
  -- Vendor's own Paystack subaccount: buyer money settles there, never with us.
  paystack_subaccount_code text unique,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.tenants is
  'A client business (vendor). Root of the multi-tenant hierarchy; every other tenant-scoped table hangs off tenants.id.';
comment on column public.tenants.slug is
  'URL/tenant-routing handle. Lowercase alphanumeric with hyphens.';
comment on column public.tenants.tone_profile is
  'Free-text description of the vendor''s voice, fed to the LLM when drafting replies.';
comment on column public.tenants.currency is
  'ISO 4217 code for every money column in this schema. All amounts are integers in this currency''s minor unit (kobo for NGN).';
comment on column public.tenants.paystack_subaccount_code is
  'Paystack subaccount (ACCT_...) that receives this vendor''s customer payments. Null until provisioned.';

create trigger tenants_set_updated_at
  before update on public.tenants
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- tenant_users — links a Supabase auth user to a tenant, with a role
-- ---------------------------------------------------------------------------
create table public.tenant_users (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  -- auth.users is Supabase's own user table; the FK is what makes this row a
  -- real login.
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner', 'staff')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tenant_users_tenant_id_user_id_key unique (tenant_id, user_id)
);

comment on table public.tenant_users is
  'Membership: which Supabase auth users may see which tenant''s data. The RLS helper public.is_tenant_member() reads this table.';
comment on column public.tenant_users.role is
  'owner = the vendor (full access); staff = someone the vendor added. RLS currently treats both the same.';

create index tenant_users_user_id_idx on public.tenant_users (user_id);

create trigger tenant_users_set_updated_at
  before update on public.tenant_users
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- channels — a WhatsApp or Instagram inbox the agent answers on
-- ---------------------------------------------------------------------------
create table public.channels (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  type text not null check (type in ('whatsapp', 'instagram')),
  label text not null default '',
  -- Routing keys: the webhook body identifies the channel with one of these.
  phone_number_id text,
  instagram_account_id text,
  -- NEVER plaintext. App code encrypts with CHANNEL_TOKEN_ENCRYPTION_KEY and
  -- only ever writes the ciphertext here.
  access_token_encrypted text not null,
  access_token_expires_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint channels_routing_key_present check (
    (type = 'whatsapp' and phone_number_id is not null)
    or (type = 'instagram' and instagram_account_id is not null)
  )
);

comment on table public.channels is
  'A Meta messaging inbox (WhatsApp Cloud API or Instagram Messaging) belonging to one tenant. Webhook tenant routing resolves a channel by phone_number_id or instagram_account_id.';
comment on column public.channels.access_token_encrypted is
  'ENCRYPTED IN THE APPLICATION, never plaintext: the Meta page/user access token, encrypted with CHANNEL_TOKEN_ENCRYPTION_KEY (AES-256-GCM) before it reaches the database. Plaintext must never be written to this column.';
comment on column public.channels.phone_number_id is
  'WhatsApp Cloud API phone_number_id from the webhook payload. Globally unique: one inbox can belong to only one tenant.';
comment on column public.channels.instagram_account_id is
  'Instagram professional account id from the webhook payload. Globally unique: one inbox can belong to only one tenant.';

create index channels_tenant_id_idx on public.channels (tenant_id);
-- Unique when set: two tenants can never claim the same Meta inbox, but a
-- tenant may hold many channels of the other type.
create unique index channels_phone_number_id_key
  on public.channels (phone_number_id) where phone_number_id is not null;
create unique index channels_instagram_account_id_key
  on public.channels (instagram_account_id) where instagram_account_id is not null;

create trigger channels_set_updated_at
  before update on public.channels
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- products — the catalog the agent may quote from, with the owner's floor
-- ---------------------------------------------------------------------------
create table public.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 300),
  sku text,
  description text not null default '',
  category text,
  -- KOBO. list_price is what the agent may quote; floor_price is the hard
  -- limit it may never go below (enforced in SQL here and again in app code).
  list_price integer not null check (list_price >= 0),
  floor_price integer not null check (floor_price >= 0),
  stock integer not null default 0 check (stock >= 0),
  -- Array of photo URLs (Supabase Storage paths), e.g. ["products/x/1.jpg"].
  photos jsonb not null default '[]'::jsonb
    check (jsonb_typeof(photos) = 'array'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_floor_price_lte_list_price check (floor_price <= list_price),
  -- Parent linkage stays inside the tenant (see header note).
  constraint products_tenant_id_id_key unique (tenant_id, id)
);

comment on table public.products is
  'Catalog item. Prices are integers in kobo; the agent may only ever quote values read from this table.';
comment on column public.products.list_price is
  'Asking price in KOBO (NGN minor units). 1 NGN = 100 kobo.';
comment on column public.products.floor_price is
  'Hard floor in KOBO. make_offer must never produce a price below this; enforced in SQL and again in app code.';
comment on column public.products.stock is
  'Units on hand. The agent may only state stock figures read from this column.';
comment on column public.products.photos is
  'JSON array of image URLs for the product (Supabase Storage).';

create index products_tenant_id_idx on public.products (tenant_id);
create index products_tenant_id_active_idx on public.products (tenant_id, active);
create unique index products_tenant_id_sku_key
  on public.products (tenant_id, sku) where sku is not null;

create trigger products_set_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- policies — the owner's rules, one row per tenant
-- ---------------------------------------------------------------------------
create table public.policies (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null unique references public.tenants(id) on delete cascade,
  -- JSON object keyed by delivery zone, e.g.
  -- {"Lagos mainland": 150000, "outside Lagos": 450000} — values in KOBO.
  delivery_fees jsonb not null default '{}'::jsonb
    check (jsonb_typeof(delivery_fees) = 'object'),
  return_policy text not null default '',
  -- Ordered discount steps the agent may concede, e.g. [0, 5, 10] percent.
  -- Kept as jsonb so the shape can grow without a migration.
  discount_steps jsonb not null default '[]'::jsonb
    check (jsonb_typeof(discount_steps) = 'array'),
  max_counter_steps integer not null default 2 check (max_counter_steps >= 0),
  -- Units in a single order that count as bulk => handoff to the owner.
  -- A quantity, never money.
  bulk_threshold integer not null default 0 check (bulk_threshold >= 0),
  -- JSON object of handoff triggers, e.g.
  -- {"angry": true, "refund": true, "unanswerable_in_a_row": 2}
  handoff_rules jsonb not null default '{}'::jsonb
    check (jsonb_typeof(handoff_rules) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.policies is
  'Per-tenant negotiation and delivery rules. One row per tenant; app code reads this table to enforce every price and delivery commitment.';
comment on column public.policies.delivery_fees is
  'JSON object: delivery zone -> fee in KOBO. Only fees stored here may be quoted.';
comment on column public.policies.discount_steps is
  'JSON array of concession steps in order (percentages as integers or absolute kobo amounts). The Nth "last price" gets the Nth step.';
comment on column public.policies.max_counter_steps is
  'Maximum number of counter-offers the agent may make on one negotiation.';
comment on column public.policies.bulk_threshold is
  'Order quantity (units, not money) at or above which the conversation is handed off as a bulk order. 0 disables the rule.';
comment on column public.policies.handoff_rules is
  'JSON object of automatic-handoff triggers (angry buyer, refunds, unanswerable questions, explicit request for a human).';

create trigger policies_set_updated_at
  before update on public.policies
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- knowledge — FAQ entries the agent may use as grounding
-- ---------------------------------------------------------------------------
create table public.knowledge (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  question text not null check (length(btrim(question)) > 0),
  answer text not null,
  tags text[] not null default '{}',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.knowledge is
  'Per-tenant FAQ entries (question/answer) used as grounding for the agent. Never a source of prices — those come from products and policies.';

create index knowledge_tenant_id_idx on public.knowledge (tenant_id);
create index knowledge_tenant_id_active_idx on public.knowledge (tenant_id, active);

create trigger knowledge_set_updated_at
  before update on public.knowledge
  for each row execute function public.set_updated_at();

commit;
