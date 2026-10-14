import { describe, expect, it } from 'vitest';
import { loadEnv } from './env.js';

const productionEnv = {
  NODE_ENV: 'production',
  DATABASE_URL: 'postgresql://postgres:pw@db.example.supabase.co:5432/postgres',
  SUPABASE_URL: 'https://example.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'service-role-key',
};

describe('loadEnv', () => {
  it('applies development defaults when nothing is set', () => {
    expect(loadEnv({})).toEqual({
      NODE_ENV: 'development',
      PORT: 3000,
      LOG_LEVEL: 'info',
    });
  });

  it('coerces PORT and keeps the integration values it is given', () => {
    const env = loadEnv({
      NODE_ENV: 'test',
      PORT: '8080',
      LOG_LEVEL: 'debug',
      SUPABASE_URL: 'https://example.supabase.co',
      ANTHROPIC_MODEL_DEFAULT: 'claude-haiku-4-5',
    });

    expect(env.PORT).toBe(8080);
    expect(env.LOG_LEVEL).toBe('debug');
    expect(env.SUPABASE_URL).toBe('https://example.supabase.co');
    expect(env.ANTHROPIC_MODEL_DEFAULT).toBe('claude-haiku-4-5');
  });

  it('accepts LOG_LEVEL in any case, trimming surrounding whitespace', () => {
    expect(loadEnv({ LOG_LEVEL: 'DEBUG ' }).LOG_LEVEL).toBe('debug');
    expect(loadEnv({ LOG_LEVEL: 'Warn' }).LOG_LEVEL).toBe('warn');
  });

  it('fails loudly, naming the variable, when a value is invalid', () => {
    expect(() => loadEnv({ PORT: 'not-a-port' })).toThrowError(/Invalid environment configuration/);
    expect(() => loadEnv({ PORT: 'not-a-port' })).toThrowError(/PORT/);
    expect(() => loadEnv({ LOG_LEVEL: 'loud' })).toThrowError(/LOG_LEVEL/);
    expect(() => loadEnv({ SUPABASE_URL: 'not-a-url' })).toThrowError(/SUPABASE_URL/);
  });

  it('reports every problem at once', () => {
    let message = '';

    try {
      loadEnv({ PORT: 'nope', LOG_LEVEL: 'loud' });
    } catch (error) {
      message = error instanceof Error ? error.message : '';
    }

    expect(message).toMatch(/PORT/);
    expect(message).toMatch(/LOG_LEVEL/);
  });

  it('requires the production-critical keys when NODE_ENV=production', () => {
    expect(() => loadEnv({ NODE_ENV: 'production' })).toThrowError(/DATABASE_URL/);
    expect(() => loadEnv({ NODE_ENV: 'production' })).toThrowError(/SUPABASE_URL/);
    expect(() => loadEnv({ NODE_ENV: 'production' })).toThrowError(/SUPABASE_SERVICE_ROLE_KEY/);
  });

  it('accepts a complete production environment', () => {
    const env = loadEnv(productionEnv);

    expect(env.NODE_ENV).toBe('production');
    expect(env.SUPABASE_SERVICE_ROLE_KEY).toBe('service-role-key');
  });
});
