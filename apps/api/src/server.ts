import { config as loadDotenv } from 'dotenv';
import { buildApp } from './app.js';
import { loadEnv } from './config/env.js';
import { createPgInboundMessageStore } from './db/inbound-messages.js';
import { createPool } from './db/pool.js';
import { resolveMetaWebhookConfig } from './webhooks/meta/config.js';

// Local development reads .env, and the file wins over anything the shell has
// already exported (a stray PORT/LOG_LEVEL must not shadow it). Deployed
// environments have no .env, so their injected values are used untouched.
loadDotenv({ quiet: true, override: process.env.NODE_ENV !== 'production' });

async function main(): Promise<void> {
  const env = loadEnv();

  // The one privileged, RLS-bypassing connection the api holds: webhook ingress
  // has no JWT to scope by, so tenants are resolved by the channel lookup in the
  // repository. See db/pool.ts.
  const pool = env.DATABASE_URL ? createPool(env.DATABASE_URL) : null;
  const store = pool ? createPgInboundMessageStore(pool) : null;
  const meta = resolveMetaWebhookConfig(env, store);

  const app = buildApp({ logger: { level: env.LOG_LEVEL }, meta });

  if (!meta) {
    app.log.warn(
      'Meta webhook routes are disabled: META_APP_SECRET, META_VERIFY_TOKEN and DATABASE_URL are all required ' +
        '(mandatory once NODE_ENV=production)',
    );
  }

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      app.log.info({ signal }, 'shutting down');
      void app
        .close()
        .then(() => pool?.end())
        .then(() => process.exit(0));
    });
  }

  await app.listen({ port: env.PORT, host: '0.0.0.0' });
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
