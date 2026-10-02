import { test, expect } from '@playwright/test';
import express from 'express';
import { createServer, type Server } from 'node:http';
import { readFileSync } from 'node:fs';

let server: Server, base: string;
test.beforeAll(async () => {
  const hosting = JSON.parse(readFileSync('../firebase.json', 'utf8'));
  const headers = hosting.hosting.headers.find((entry: { source: string }) => entry.source === '**').headers;
  const app = express();
  app.use((_req, res, next) => {
    for (const header of headers) res.setHeader(header.key, header.value);
    next();
  });
  app.use(express.static('../hosting', { extensions: ['html'] }));
  server = createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
test.afterAll(async () => { await new Promise<void>((resolve) => server.close(() => resolve())); });

for (const colorScheme of ['light', 'dark'] as const) {
  for (const width of [320, 390, 1440]) {
    test(`public pages load assets under production CSP: ${colorScheme}, ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await page.emulateMedia({ colorScheme });
      const violations: string[] = [];
      await page.addInitScript(() => {
        document.addEventListener('securitypolicyviolation', (event) => {
          console.error(`CSP violation: ${event.violatedDirective} ${event.blockedURI}`);
        });
      });
      page.on('console', (message) => { if (message.text().startsWith('CSP violation:')) violations.push(message.text()); });
      for (const route of ['/', '/support', '/privacy', '/mcp-docs', '/404']) {
        const response = await page.goto(base + route);
        expect(response?.status()).toBe(200);
        await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
        const icon = page.locator('.brand img');
        await expect(icon).toBeVisible();
        expect(await icon.evaluate((element: HTMLImageElement) => element.complete && element.naturalWidth === 1024)).toBe(true);
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        expect(await page.locator('body').evaluate((element) => getComputedStyle(element).backgroundColor))
          .toBe(colorScheme === 'light' ? 'rgb(255, 255, 255)' : 'rgb(20, 20, 20)');
        if (route === '/') {
          await expect(page.getByRole('link', { name: 'Connect your assistant' })).toHaveAttribute('href', '/mcp-docs');
          if (width === 390) await page.screenshot({ path: `test-results/public-home-${colorScheme}.png`, fullPage: true });
        }
      }
      expect(violations).toEqual([]);
    });
  }
}
