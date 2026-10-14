import { defineWorkspace } from 'vitest/config';

// One `npm test` from the repo root runs every workspace's tests.
// Each entry is a Vitest project; a workspace may add its own config for
// environment-specific settings (see apps/dashboard/vite.config.ts).
export default defineWorkspace(['apps/api', 'apps/dashboard', 'packages/shared']);
