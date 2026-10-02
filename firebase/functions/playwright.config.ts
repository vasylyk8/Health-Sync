import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './test/browser', workers: 1, timeout: 30_000,
  use: { headless: true, viewport: { width: 390, height: 844 },
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH } : {},
    screenshot: 'only-on-failure', trace: 'retain-on-failure' },
});
