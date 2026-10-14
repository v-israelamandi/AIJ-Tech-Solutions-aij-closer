import type { ReactElement } from 'react';

/**
 * Dashboard shell. Conversations, catalog and orders land in later PRs;
 * today this only proves the React + Vite + Vitest wiring works.
 */
export function App(): ReactElement {
  return (
    <main
      style={{
        fontFamily: 'system-ui, -apple-system, Segoe UI, sans-serif',
        margin: '0 auto',
        maxWidth: '40rem',
        padding: '3rem 1.5rem',
      }}
    >
      <h1 style={{ margin: '0 0 0.5rem' }}>AIJ Closer</h1>
      <p style={{ color: '#444', margin: 0 }}>
        Owner dashboard scaffold — sign-in, conversations, catalog and orders come next.
      </p>
    </main>
  );
}
