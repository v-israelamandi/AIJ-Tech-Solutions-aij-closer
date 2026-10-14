import { z } from 'zod';

/**
 * Environment contract for the API service.
 *
 *  - Values the api needs in order to boot have safe development defaults.
 *  - Integration credentials stay optional until the feature that consumes them
 *    lands; each of those PRs deletes the matching `.optional()`.
 *  - Every value that IS present must still be valid, and the values a deployed
 *    service cannot run without are required once NODE_ENV=production.
 */

const logLevelSchema = z.enum([
  'fatal',
  'error',
  'warn',
  'info',
  'debug',
  'trace',
  'silent',
]);

/** Keys the deployed service cannot run without. Grows as features land. */
export const REQUIRED_IN_PRODUCTION = [
  'DATABASE_URL',
  'SUPABASE_URL',
  'SUPABASE_SERVICE_ROLE_KEY',
] as const;

export const envSchema = z
  .object({
    // Runtime
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    LOG_LEVEL: logLevelSchema.default('info'),

    // Supabase / Postgres
    SUPABASE_URL: z.url().optional(),
    SUPABASE_ANON_KEY: z.string().min(1).optional(),
    SUPABASE_SERVICE_ROLE_KEY: z.string().min(1).optional(),
    DATABASE_URL: z.url().optional(),

    // Anthropic (LLM drafting)
    ANTHROPIC_API_KEY: z.string().min(1).optional(),
    ANTHROPIC_MODEL_DEFAULT: z.string().min(1).optional(),
    ANTHROPIC_MODEL_ESCALATION: z.string().min(1).optional(),

    // Meta channels (WhatsApp Cloud API + Instagram Messaging)
    META_APP_ID: z.string().min(1).optional(),
    META_APP_SECRET: z.string().min(1).optional(),
    META_VERIFY_TOKEN: z.string().min(1).optional(),
    WHATSAPP_PHONE_NUMBER_ID: z.string().min(1).optional(),
    INSTAGRAM_ACCOUNT_ID: z.string().min(1).optional(),

    // Paystack
    PAYSTACK_SECRET_KEY: z.string().min(1).optional(),
    PAYSTACK_WEBHOOK_SECRET: z.string().min(1).optional(),

    // Speech to text (voice notes)
    STT_PROVIDER: z.string().min(1).optional(),
    STT_API_KEY: z.string().min(1).optional(),

    // Encryption key for channel access tokens at rest (32 bytes)
    CHANNEL_TOKEN_ENCRYPTION_KEY: z.string().min(32).optional(),
  })
  .superRefine((env, ctx) => {
    if (env.NODE_ENV !== 'production') return;

    for (const key of REQUIRED_IN_PRODUCTION) {
      if (!env[key]) {
        ctx.addIssue({
          code: 'custom',
          path: [key],
          message: `${key} is required when NODE_ENV=production`,
        });
      }
    }
  });

export type Env = z.infer<typeof envSchema>;

/** Log levels are case-insensitive in the environment ("DEBUG " -> "debug"). */
function normaliseLogLevel(value: string | undefined): string | undefined {
  return typeof value === 'string' ? value.trim().toLowerCase() : value;
}

/**
 * Parses and validates the process environment. Fails loudly: the thrown error
 * lists every problem at once, so a misconfigured deploy never starts half-alive.
 */
export function loadEnv(source: NodeJS.ProcessEnv = process.env): Env {
  const parsed = envSchema.safeParse({
    ...source,
    LOG_LEVEL: normaliseLogLevel(source.LOG_LEVEL),
  });

  if (!parsed.success) {
    const problems = parsed.error.issues
      .map((issue) => `  - ${issue.path.join('.') || '(root)'}: ${issue.message}`)
      .join('\n');

    throw new Error(`Invalid environment configuration:\n${problems}`);
  }

  return parsed.data;
}
