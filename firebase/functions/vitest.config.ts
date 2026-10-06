import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    env: { HS_LOG: 'off' },
    testTimeout: 30_000,
    coverage: {
      provider: 'v8',
      include: ['src/**'],
      reporter: ['text-summary', 'json-summary'],
      // Floors sit just under today's numbers (82/78/80/85 overall) so coverage cannot quietly slip.
      // index.ts, store/firestore.ts, auth/tokens.ts and auth/oauth-store.ts are exercised by the emulator
      // suite (test:emulator), which is not counted here, so they pull the overall number down.
      thresholds: {
        statements: 80, branches: 75, functions: 77, lines: 83,
        'src/query/**': { statements: 92, branches: 80, functions: 95, lines: 95 },
        'src/readiness/**': { statements: 92, branches: 85, functions: 95, lines: 95 },
        'src/ingest/**': { statements: 88, branches: 82, functions: 70, lines: 94 },
      },
    },
  },
});
