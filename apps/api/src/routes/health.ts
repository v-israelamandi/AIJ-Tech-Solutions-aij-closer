import type { FastifyPluginAsync } from 'fastify';
import { z } from 'zod';

/** Response contract for `GET /health`. */
export const healthResponseSchema = z.object({
  status: z.literal('ok'),
});

export type HealthResponse = z.infer<typeof healthResponseSchema>;

export const healthRoutes: FastifyPluginAsync = async (app) => {
  app.get('/health', async (): Promise<HealthResponse> => ({ status: 'ok' }));
};
