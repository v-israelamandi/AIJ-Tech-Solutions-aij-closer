import { describe, expect, it } from 'vitest';
import { buildApp } from './app.js';

describe('buildApp', () => {
  it('answers GET /health with 200 and { status: "ok" }', async () => {
    const app = buildApp();

    try {
      const response = await app.inject({ method: 'GET', url: '/health' });

      expect(response.statusCode).toBe(200);
      expect(response.headers['content-type']).toMatch(/application\/json/);
      expect(response.json()).toEqual({ status: 'ok' });
    } finally {
      await app.close();
    }
  });

  it('returns 404 for unknown routes', async () => {
    const app = buildApp();

    try {
      const response = await app.inject({ method: 'GET', url: '/not-a-route' });

      expect(response.statusCode).toBe(404);
    } finally {
      await app.close();
    }
  });
});
