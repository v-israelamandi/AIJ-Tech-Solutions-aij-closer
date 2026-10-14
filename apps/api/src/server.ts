import { config as loadDotenv } from 'dotenv';
import { buildApp } from './app.js';
import { loadEnv } from './config/env.js';

// Local development reads .env, and the file wins over anything the shell has
// already exported (a stray PORT/LOG_LEVEL must not shadow it). Deployed
// environments have no .env, so their injected values are used untouched.
loadDotenv({ quiet: true, override: process.env.NODE_ENV !== 'production' });

async function main(): Promise<void> {
  const env = loadEnv();
  const app = buildApp({ logger: { level: env.LOG_LEVEL } });

  for (const signal of ['SIGINT', 'SIGTERM'] as const) {
    process.once(signal, () => {
      app.log.info({ signal }, 'shutting down');
      void app.close().then(() => process.exit(0));
    });
  }

  await app.listen({ port: env.PORT, host: '0.0.0.0' });
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
