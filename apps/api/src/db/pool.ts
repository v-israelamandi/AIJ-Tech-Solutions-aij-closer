import { Pool } from 'pg';

/**
 * The api's Postgres connection pool.
 *
 * `DATABASE_URL` is a plain Postgres connection string — a local or CI Postgres
 * while we build, a Supabase project's direct connection string later. Nothing
 * here knows about Supabase's HTTP API, so the same code runs against both, and
 * the pooling/query behaviour is ordinary `pg`.
 *
 * This pool is the api's one privileged connection: the server-side role that
 * owns the tables (or Supabase's `service_role`) and therefore **bypasses RLS**.
 * Using it is correct for the webhook ingress and the background jobs — Meta
 * does not send a JWT, so there is no `auth.uid()` to scope a SELECT by, and the
 * tenant a payload belongs to is established by the channel lookup in the
 * repository, not by RLS. It must never be used to answer a dashboard request:
 * those go through Supabase Auth and RLS, so a vendor can only ever read their
 * own rows.
 */
export interface DatabaseOptions {
  /** Connections kept open at once. Each webhook transaction borrows one. */
  max?: number;
}

export function createPool(databaseUrl: string, options: DatabaseOptions = {}): Pool {
  return new Pool({
    connectionString: databaseUrl,
    max: options.max ?? 10,
    idleTimeoutMillis: 30_000,
    // Fail fast rather than hanging a webhook: Meta retries, and a 500 is the
    // honest answer when the database cannot be reached.
    connectionTimeoutMillis: 10_000,
    application_name: 'aij-closer-api',
  });
}
