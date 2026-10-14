# AIJ Closer – Project Brief

## What we're building
A multi-tenant AI sales agent service for Lagos online vendors (first market: fashion
and beauty). The agent lives in each vendor's WhatsApp and Instagram DMs. It answers
product questions, negotiates price within owner-set limits, sends Paystack payment
links, confirms orders, follows up with buyers who go quiet, and hands off to a
human when needed. One deployment serves many client businesses ("tenants").

## Core principle (non-negotiable)
The LLM drafts conversation; CODE makes every commitment. The model may only state
prices, stock, discounts, delivery fees and payment links returned by a tool call.
Floor prices, discount steps and payment amounts are enforced server-side. Never
trust a price or amount produced by the model.

## Stack
- Backend: Node.js 20 + TypeScript, Fastify, deployed on Render (web service + cron jobs)
- Database/auth: Supabase (Postgres, row-level security, Storage for product photos)
- LLM: Anthropic API. Default model: Claude Haiku (routine chats). Escalation model:
  Claude Sonnet (long or difficult negotiations). Model names come from env vars.
- Channels: WhatsApp Cloud API and Instagram Messaging API (same Meta app)
- Payments: Paystack (one subaccount per tenant; money goes to the vendor, never held by us)
- Speech-to-text for voice notes: provider behind an interface, configured by env var
- Owner dashboard: React + Vite + TypeScript + Supabase Auth, deployed on Netlify
- Monorepo: /apps/api, /apps/dashboard, /packages/shared, /supabase/migrations

## Data model (all tenant-scoped tables have tenant_id + RLS)
tenants, tenant_users, channels (tokens encrypted at rest), products (list_price,
floor_price, stock, photos, active), policies (delivery_fees, return_policy,
discount_steps, max_counter_steps, bulk_threshold, handoff_rules), knowledge (FAQ),
contacts, conversations (status: bot | human | closed; window_expires_at),
messages (direction, type text|voice|image, content, tool_calls, meta_message_id
unique), offers, orders (paystack_reference, payment_status), weekly_reports.

## Agent tools
search_catalog, get_product, make_offer, create_payment_link, check_payment,
log_order, handoff_to_human. Each validates input, enforces tenant policies, and
logs to messages.tool_calls.

## Negotiation rules (per-tenant config)
1st "last price" → hold price, add value. 2nd → first discount step. 3rd → floor
price tied to paying now. Below floor → decline, suggest cheaper item. Never below
floor_price. Max counter steps from policy.

## Automatic handoff
Angry or complaining buyer, refund or wrong-item issue, bulk order above
threshold, two unanswerable questions in a row, or explicit request for a human.
On handoff: conversation.status = human, agent stops replying, owner is alerted.

## Buyer behaviour to support
Voice notes (transcribe, then answer), screenshots of products (match to catalog),
Pidgin and mixed English, replies in the tenant's own tone (tone_profile on tenant).

## Meta rules
Verify X-Hub-Signature-256 on every webhook. Deduplicate by meta_message_id (Meta
retries). Respect the 24-hour customer service window: outside it, only approved
template messages may be sent.

## Security
Secrets only in env vars, never committed. Verify Paystack webhook signatures
(x-paystack-signature, HMAC SHA512). Encrypt channel access tokens at rest.
RLS on every tenant table; the service role is used only server-side.
No PII in logs beyond IDs.

## Engineering standards
TypeScript strict mode. Zod validation on all external input. Vitest tests for
every tool and webhook handler. A conversation simulator that runs scripted chats
against the agent with a mocked LLM. README and .env.example kept up to date with
each PR. Small, reviewable PRs.
