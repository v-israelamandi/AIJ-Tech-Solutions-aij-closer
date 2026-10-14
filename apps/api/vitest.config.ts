import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      // `@aij/shared` is consumed as TypeScript **source** inside the monorepo —
      // the same mapping `tsconfig.base.json` uses — so a test run does not
      // depend on the package having been compiled to `dist/` first. (Its
      // package.json `exports` point at `dist`, which is what Node and a
      // production install use, because there is no TypeScript in a deploy.)
      '@aij/shared': fileURLToPath(new URL('../../packages/shared/src/index.ts', import.meta.url)),
    },
  },
  test: {
    environment: 'node',
  },
});
