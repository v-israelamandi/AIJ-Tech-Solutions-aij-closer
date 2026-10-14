import Fastify, { type FastifyInstance } from 'fastify';
import type { MetaWebhookConfig } from './webhooks/meta/routes.js';
import { metaWebhookRoutes } from './webhooks/meta/routes.js';
import { healthRoutes } from './routes/health.js';

export interface BuildAppOptions {
  /** Fastify/Pino logger setting. Off by default so tests stay quiet. */
  logger?: boolean | { level: string };
  /**
   * Meta webhook wiring (app secret, verify token, message store). Omitted when
   * a deployment has no Meta credentials or no database, in which case
   * `/webhooks/meta` is not registered at all rather than half-working — see
   * `webhooks/meta/config.ts`.
   */
  meta?: MetaWebhookConfig;
}

/**
 * Builds the Fastify instance with every route registered.
 * Pure factory: it never listens and never reads the environment.
 */
export function buildApp(options: BuildAppOptions = {}): FastifyInstance {
  const app = Fastify({ logger: options.logger ?? false });

  app.register(healthRoutes);

  if (options.meta) {
    app.register(metaWebhookRoutes, options.meta);
  }

  return app;
}
