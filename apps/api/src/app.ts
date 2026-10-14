import Fastify, { type FastifyInstance } from 'fastify';
import { healthRoutes } from './routes/health.js';

export interface BuildAppOptions {
  /** Fastify/Pino logger setting. Off by default so tests stay quiet. */
  logger?: boolean | { level: string };
}

/**
 * Builds the Fastify instance with every route registered.
 * Pure factory: it never listens and never reads the environment.
 */
export function buildApp(options: BuildAppOptions = {}): FastifyInstance {
  const app = Fastify({ logger: options.logger ?? false });

  app.register(healthRoutes);

  return app;
}
