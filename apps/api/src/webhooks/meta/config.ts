import type { Env } from '../../config/env.js';
import type { InboundMessageStore } from '../../db/inbound-messages.js';
import type { MetaWebhookConfig } from './routes.js';

/**
 * Builds the Meta webhook wiring from the environment.
 *
 * Returns `undefined` — and the routes are then simply not registered — when
 * the deployment has not been given the Meta credentials and a database yet, so
 * `npm run dev` still boots on a half-filled `.env` and answers `/health`.
 * `REQUIRED_IN_PRODUCTION` in `config/env.ts` is what stops a real deployment
 * from ending up in that state.
 */
export function resolveMetaWebhookConfig(
  env: Env,
  store: InboundMessageStore | null,
): MetaWebhookConfig | undefined {
  if (!env.META_APP_SECRET || !env.META_VERIFY_TOKEN || !store) return undefined;

  return {
    appSecret: env.META_APP_SECRET,
    verifyToken: env.META_VERIFY_TOKEN,
    store,
  };
}
