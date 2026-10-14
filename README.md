# AIJ Closer

[![CI](https://github.com/v-israelamandi/AIJ-Tech-Solutions-aij-closer/actions/workflows/ci.yml/badge.svg)](https://github.com/v-israelamandi/AIJ-Tech-Solutions-aij-closer/actions/workflows/ci.yml)

A multi-tenant AI sales agent service for Lagos online vendors (first market:
fashion and beauty). The agent lives in each vendor's WhatsApp and Instagram DMs:
it answers product questions, negotiates price within owner-set limits, sends
Paystack payment links, confirms orders, follows up with buyers who go quiet, and
hands off to a human when needed. One deployment serves many client businesses
("tenants").

**Core principle, non-negotiable:** the LLM drafts conversation; **code makes every
commitment**. The model may only state prices, stock, discounts, delivery fees and
payment links returned by a server-side tool call. Floor prices, discount steps and
payment amounts are enforced in code and never trusted from the model.

## Status

This repository is the foundation, not a product. There is no agent, no webhook,
no payment flow and no revenue yet — see [Not in this PR](#not-in-this-pr). The
full plan lives in [`docs/PROJECT_BRIEF.md`](docs/PROJECT_BRIEF.md), which is the
source of truth for scope and standards.

## Repository layout

```
apps/
  api/                    Node 20 + TypeScript + Fastify service
    src/app.ts              Fastify factory (routes registered, never listens)
    src/server.ts           entrypoint: loads env, listens, shuts down cleanly
    src/config/env.ts       Zod-validated environment contract
    src/routes/health.ts    GET /health -> { "status": "ok" }
  dashboard/              React + Vite + TypeScript owner dashboard
    src/App.tsx             shell rendered today; features land later
packages/
  shared/                 Zod schemas + inferred types for every domain enum
docs/
  PROJECT_BRIEF.md        the brief: scope, stack, standards
supabase/
  migrations/             the schema: tables, constraints, RLS (see its README)
  test-support/           test-only harness that executes the RLS and asserts it
.github/workflows/ci.yml  CI: npm ci -> typecheck -> lint -> test -> build, and
                          Postgres 16 -> migrations -> RLS assertions
```

## Prerequisites

- **Node.js 20.19+** — `.nvmrc` pins the major version (`nvm use`)
- **npm 10** — ships with Node 20; the repo uses npm workspaces (`packageManager: npm@10`)
- Optional: the [Supabase CLI](https://supabase.com/docs/guides/cli) once migrations exist

## Local setup

From a clean clone:

```bash
git clone https://github.com/v-israelamandi/AIJ-Tech-Solutions-aij-closer.git
cd AIJ-Tech-Solutions-aij-closer
cp .env.example .env        # placeholders only; the api boots with them as-is
npm ci
npm run dev
```

`npm run dev` starts both workspaces through the same process:

- api — http://localhost:3000 (`GET /health` returns `{"status":"ok"}`)
- dashboard — http://localhost:5173

Check the api from another terminal:

```bash
curl http://localhost:3000/health
```

Never commit `.env` (it is gitignored). `.env.example` holds placeholders only —
put real values in `.env` locally and in the hosting provider's environment
variables when deployed.

## Scripts

| Script | What it does |
| --- | --- |
| `npm run dev` | Runs every workspace's dev server together (api + dashboard) |
| `npm run build` | Builds every workspace that has a build: `@aij/shared` and `@aij/api` to `dist/` (tsc), `@aij/dashboard` to `apps/dashboard/dist` (vite) |
| `npm run typecheck` | `tsc --noEmit` in every workspace, against the shared `tsconfig.base.json` (strict) |
| `npm run lint` | ESLint 9 (flat config at the repo root) over the whole repo |
| `npm test` | Vitest once, all workspaces, from the root config (`vitest.workspace.ts`) |
| `npm run test:watch` | Vitest in watch mode |
| `npm run test:db` | Applies the migrations to a throwaway Postgres and asserts the RLS (needs `DATABASE_URL`; see [Database](#database)) |

Single workspace (any script works this way):

```bash
npm run dev --workspace @aij/api
npm run build --workspace @aij/api     # then: npm start --workspace @aij/api
npm test --workspace @aij/dashboard    # run only that workspace's tests
```

Tests are wired up once, at the repo root: `vitest.workspace.ts` lists the api, the
dashboard and `@aij/shared` as Vitest projects, so a single `npm test` covers all
of them with the right environment (node for the api and shared, jsdom for the
dashboard — configured in `apps/dashboard/vite.config.ts`).

Two toolchain notes, so nobody rediscovers them the hard way:

- Vitest is pinned to 3.x. npm 10 crashes while resolving the dependency graph of
  Vitest 4 (`Cannot read properties of null (reading 'edgesOut')`) — in this repo
  and in an empty one. Vitest 3.2 prints a one-line deprecation notice about the
  workspace file; when Vitest 4 becomes installable the migration is to move the
  same three project entries into `test.projects` in a root `vitest.config.ts`.
- `npm ci` warns that ESLint 9 is no longer supported upstream. ESLint 9 flat
  config is what this scaffold was specified with, and `typescript-eslint@8`
  already accepts ESLint 10, so the bump is a two-line change when we want it.

## Environment variables

`.env.example` documents every variable the finished product needs; the api reads
them through one Zod schema (`apps/api/src/config/env.ts`) and refuses to start on
an invalid value, listing every problem at once.

Required-ness today: values the api needs in order to boot have development
defaults; integration credentials are optional until the feature that consumes
them lands (that PR removes the matching `.optional()`); and when
`NODE_ENV=production` the deployment-critical keys below are required —
`DATABASE_URL`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`.

| Variable | Purpose | Where it comes from |
| --- | --- | --- |
| `NODE_ENV` | Runtime mode: `development`, `test` or `production`. Default `development`. | You, per environment |
| `PORT` | Port the api listens on. Default `3000`. | You; Render injects its own in production |
| `LOG_LEVEL` | Fastify/Pino log level: `fatal`…`silent` (case-insensitive). Default `info`. | You |
| `SUPABASE_URL` | Supabase project URL (Postgres, Auth, Storage). | Supabase dashboard → Project Settings → API |
| `SUPABASE_ANON_KEY` | Public anon key, for the dashboard once Supabase Auth is wired (later PR). Safe in a browser. | Supabase dashboard → Project Settings → API |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-side key that bypasses RLS. Used by the api only — never sent to the browser. | Supabase dashboard → Project Settings → API |
| `DATABASE_URL` | Direct Postgres connection string: migrations, raw SQL and jobs. | Supabase dashboard → Project Settings → Database → Connection string |
| `ANTHROPIC_API_KEY` | Drafts buyer replies (the model may only state values returned by a tool). | console.anthropic.com → API keys |
| `ANTHROPIC_MODEL_DEFAULT` | Model ID for routine chats — Claude Haiku, so it stays cheap per message. | Anthropic docs (current model IDs); default in `.env.example` is a placeholder |
| `ANTHROPIC_MODEL_ESCALATION` | Model ID for long or difficult negotiations — Claude Sonnet. | Anthropic docs (current model IDs); placeholder in `.env.example` |
| `META_APP_ID` | The Meta app that owns both the WhatsApp and the Instagram channel. | developers.facebook.com/apps |
| `META_APP_SECRET` | Verifies `X-Hub-Signature-256` on every webhook. | Meta app → Settings → Basic |
| `META_VERIFY_TOKEN` | Shared string Meta echoes back during webhook verification. | You — paste the same value into the Meta app's webhook settings |
| `WHATSAPP_PHONE_NUMBER_ID` | Business phone number the agent sends and receives WhatsApp messages on. | Meta app → WhatsApp → API Setup |
| `INSTAGRAM_ACCOUNT_ID` | Instagram professional account the agent replies from. | Meta app → Instagram → API setup |
| `PAYSTACK_SECRET_KEY` | Creates payment links in the vendor's own subaccount. Server-side only. | Paystack dashboard → Settings → API Keys & Webhooks |
| `PAYSTACK_WEBHOOK_SECRET` | Verifies `x-paystack-signature` (HMAC SHA512) on payment webhooks. Paystack signs with your secret key by default; set a separate value here if you configure one. | Paystack dashboard → Settings → API Keys & Webhooks |
| `STT_PROVIDER` | Adapter key for the speech-to-text provider that transcribes buyer voice notes (e.g. `openai`, `deepgram`). | You — must match an adapter implemented behind the STT interface |
| `STT_API_KEY` | Credential for that speech-to-text provider. | The provider's dashboard |
| `CHANNEL_TOKEN_ENCRYPTION_KEY` | 32-byte key (base64) used to encrypt channel access tokens at rest. | Generate your own: `openssl rand -base64 32` |

## Database

The schema lives in [`supabase/migrations/`](supabase/migrations/) — versioned
SQL, applied in filename order. [`supabase/migrations/README.md`](supabase/migrations/README.md)
covers how migrations are named and applied; the short version is
`supabase db push` for a linked project, or `psql "$DATABASE_URL" -v
ON_ERROR_STOP=1 -f <migration>` in order for anything else.

| Table | One line |
| --- | --- |
| `tenants` | One row per client business (vendor): name, slug, tone profile, currency, Paystack subaccount. |
| `tenant_users` | Membership: which Supabase `auth.users` row belongs to which tenant, with a role. What RLS reads. |
| `channels` | A WhatsApp or Instagram inbox belonging to a tenant. Holds the Meta token **encrypted** (`access_token_encrypted`), plus the webhook routing keys `phone_number_id` / `instagram_account_id` (globally unique). |
| `products` | Catalog: `list_price`, `floor_price`, `stock`, `photos` (jsonb), `active`. `floor_price <= list_price` is enforced by the database. |
| `policies` | One row per tenant: `delivery_fees` (jsonb), `return_policy`, `discount_steps` (jsonb), `max_counter_steps`, `bulk_threshold`, `handoff_rules` (jsonb). |
| `knowledge` | Per-tenant FAQ entries (question/answer/tags) used as grounding. Never a source of prices. |
| `contacts` | A buyer on one channel; unique per `(tenant_id, channel, external_id)`. |
| `conversations` | One thread with one buyer: `status` (`bot` \| `human` \| `closed`, defaults to `bot`), `window_expires_at` (Meta's 24-hour window), `handoff_reason`. |
| `messages` | Every inbound/outbound message: `direction`, `type` (`text` \| `voice` \| `image`), `content`, `tool_calls` (jsonb audit trail), `meta_message_id` (unique when set, for webhook dedupe). |
| `offers` | Each price the agent put on the table: `price`, `quantity`, `counter_step`, `status`. The record that no offer ever went below the floor. |
| `orders` | The money record: `unit_price`, `delivery_fee`, `amount`, `paystack_reference` (unique when set), `payment_status`. |
| `weekly_reports` | One generated report per tenant per week, `payload` jsonb. |

**Money is an integer count of kobo** (NGN minor units) in every money column
and inside every jsonb field that holds an amount: ₦25,000 is `2500000`. Never a
float, never a formatted string — the product's core principle is that code,
not the model, makes every price commitment, and integers keep those
commitments exact. Column comments carry the unit; `orders.amount` is
constrained to `(unit_price * quantity) + delivery_fee`.

**Tenant isolation is enforced by row-level security**, and asserted, not
assumed. Every table has RLS enabled; every tenant-scoped policy is written
against `public.is_tenant_member(uuid)` (a `security definer`, `stable` helper
with a locked-down `search_path`, reading `auth.uid()` from `tenant_users`).
`authenticated` users see and write only their own tenant's rows, `anon` has no
policy anywhere and therefore reads nothing, and `service_role` bypasses RLS and
is used server-side only. Child rows reference their parents on
`(tenant_id, id)`, so a row cannot be attached to another tenant's conversation
even by code that bypasses RLS. See
[`supabase/test-support/`](supabase/test-support/).

### Running the database tests

The migrations are executed and the RLS assertions run against a throwaway
Postgres (16, same as CI). `DATABASE_URL` points at it:

```bash
createdb aij_test
export DATABASE_URL=postgresql://localhost/aij_test
npm run test:db        # shim -> migrations -> RLS assertions, exits non-zero on failure
```

`npm run test:db` is `supabase/test-support/run.sh`, which needs nothing but
`psql` (no Node dependencies for the database tests). It refuses to run against
a database that already has tables in `public`, so it cannot be pointed at a
real project by accident — and it must never be, because
`supabase/test-support/` is test-only scaffolding that stands in for Supabase's
own bootstrap.

### Demo seed data
The one demo tenant every later feature is built against lives in
[`supabase/seed/`](supabase/seed/): **Sisi Lagos Fashion**, slug
`sisi-lagos-fashion` — 20 products with `list_price` and `floor_price` in kobo,
its `policies` row (delivery fees by zone, the discount ladder, the handoff
rules), 16 buyer FAQs, its owner and both Meta channels (WhatsApp
`phone_number_id = 109876543210987`, Instagram
`instagram_account_id = 17841400000000001` — the values PR 4's webhook routing
resolves tenants by).

```bash
createdb aij_dev
export DATABASE_URL=postgresql://localhost/aij_dev
npm run test:db               # shim -> migrations -> RLS assertions
npm run seed                  # the demo tenant, then 188 assertions on it
npm run seed -- --twice       # seed it twice and compare fingerprints (what CI runs)
```

`npm run seed` is `supabase/seed/run.sh`, `psql`-only like the database tests. It
is idempotent — the seed deletes and re-inserts only the tenant whose slug is
`sisi-lagos-fashion`, so running it twice leaves one tenant, not two — and it
refuses to write to a database that already holds any other tenant, or to one
reached over the network, unless you say so out loud (`--force`,
`--allow-remote`). It runs as whatever the connection authenticates as, which for
`DATABASE_URL` is the table owner or `service_role`: seeding bypasses RLS on
purpose, because provisioning a tenant is not product traffic.
[`supabase/seed/README.md`](supabase/seed/README.md) covers running it against a
real Supabase project, the fixed uuid range the fixtures use, and the edge-case
products (`stock = 0`, `active = false`) the out-of-stock and withdrawn paths
test against.

## CI

`.github/workflows/ci.yml` runs on every push and pull request and has two jobs,
each of which fails on the first broken step.

`verify` (Node 20, from `.nvmrc`):

```bash
npm ci
npm run typecheck
npm run lint
npm test
npm run build
```

`database` (Postgres 16 service container): the shim, then every migration, then
the RLS assertions — `supabase/test-support/run.sh` — then the demo seed applied
twice and asserted on, `npm run seed -- --twice`. A schema whose RLS has never
been executed is not verified, so this job is what makes the tenant-isolation
claims in this README mean something; a seed that has only ever run on one
machine is not verified either, which is why CI re-runs it and compares
fingerprints.

## Conventions

- **TypeScript strict everywhere**, from one shared `tsconfig.base.json`; each
  workspace extends it. Relative imports inside a workspace use ESM `.js`
  specifiers (NodeNext) so the compiled output runs directly on Node.
- **Zod validates every external input** — environment variables today, webhook
  bodies and tool inputs as those land.
- **`@aij/shared` is the only place domain enums live** and is consumed as
  TypeScript source inside the monorepo (`tsconfig.base.json` maps it to
  `packages/shared/src`), so typechecking never depends on build order. It also
  builds to `dist/` for services that ship compiled JavaScript.
- Small PRs on a branch, never directly to `main`. README and `.env.example` are
  updated in the same PR as the change they describe. No secrets in the repo.

## Not in this PR

Deliberately out of scope so far, in the order they are planned: webhook ingestion
(WhatsApp/Instagram), the outbound send service, the agent tool implementations,
the agent orchestrator, negotiation logic, Paystack integration, speech-to-text,
the dashboard UI and Supabase Auth, the conversation simulator, and deployment.
The schema and the demo tenant have landed — see [Database](#database),
`supabase/migrations/` and `supabase/seed/`.
