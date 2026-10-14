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
  migrations/             SQL migrations (schema lands in the next PR)
.github/workflows/ci.yml  CI: npm ci -> typecheck -> lint -> test -> build
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

## CI

`.github/workflows/ci.yml` runs on every push and pull request on Node 20 (from
`.nvmrc`) and fails the job on the first broken step:

```bash
npm ci
npm run typecheck
npm run lint
npm test
npm run build
```

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

Deliberately out of scope for the scaffold, in the order they are planned:
webhook ingestion (WhatsApp/Instagram), the agent tool implementations,
negotiation logic, Paystack integration, speech-to-text, the dashboard UI and
Supabase Auth, the conversation simulator, and the SQL schema plus seed data
(which land in `supabase/migrations/` next — see its
[README](supabase/migrations/README.md)).
