import { defineConfig } from 'vitest/config';
export default defineConfig({ test: { env: { HS_LOG: 'off' }, testTimeout: 30_000 } });
