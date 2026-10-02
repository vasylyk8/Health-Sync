import { test, expect, type Page } from '@playwright/test';
import { createServer, type Server } from 'node:http';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import express from 'express';
import { build } from 'esbuild';
import { initializeApp, getApps } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { KrokOAuth, DEFAULT_SCOPES } from '../../src/auth/oauth.js';
import { createOAuthRouter } from '../../src/auth/oauth-router.js';
import { MemoryOAuthStore } from '../helpers/oauth.js';

let server: Server, base: string, oauth: KrokOAuth;
const store = new MemoryOAuthStore();
const reviewer = 'reviewer@example.test', password = 'Emulator-only-password-123';
const callback = 'https://claude.ai/api/mcp/auth_callback';

test.beforeAll(async () => {
  if (!process.env.FIREBASE_AUTH_EMULATOR_HOST) throw new Error('Browser tests require the Auth emulator, never a live project.');
  if (!getApps().length) initializeApp({ projectId: 'demo-health-sync' });
  await getAuth().createUser({ uid: 'browser-reviewer', email: reviewer, password });
  await getAuth().setCustomUserClaims('browser-reviewer', { krokReviewer: true });
  await getAuth().createUser({ uid: 'browser-ordinary', email: 'ordinary@example.test', password });
  await store.set('users/browser-ordinary', { generation: 1, connections: {}, createdAt: 1 });
  await store.set('users/browser-reviewer', { generation: 1, connections: {}, createdAt: 1 });
  const bundle = await build({ entryPoints: ['../../web/connect.ts'], bundle: true, write: false, format: 'esm', platform: 'browser',
    plugins: [{ name: 'auth-emulator-only', setup(builder) {
      builder.onResolve({ filter: /functions\/node_modules\/firebase\/auth$/ }, () => ({ path: path.resolve('test/browser/firebase-auth.ts') }));
    } }] });
  const app = express();
  const hosting = JSON.parse(readFileSync('../firebase.json', 'utf8'));
  const policy = hosting.hosting.headers.flatMap((entry: { headers: { key: string; value: string }[] }) => entry.headers)
    .find((header: { key: string }) => header.key === 'Content-Security-Policy').value
    .replace("connect-src 'self'", "connect-src 'self' http://127.0.0.1:9099")
    .replace("frame-src 'self'", "frame-src 'self' http://127.0.0.1:9099");
  app.get('/__/firebase/init.json', (_req, res) => res.json({ apiKey: 'fake-api-key', projectId: 'demo-health-sync', authDomain: 'localhost' }));
  app.get('/connect.js', (_req, res) => res.type('js').send(bundle.outputFiles[0]!.text));
  app.get('/connect', (_req, res) => res.setHeader('Content-Security-Policy', policy).type('html').send(readFileSync('../hosting/connect.html', 'utf8')));
  app.get('/style.css', (_req, res) => res.type('css').send(readFileSync('../hosting/style.css', 'utf8')));
  app.get('/icon.png', (_req, res) => res.type('png').send(readFileSync('../hosting/icon.png')));
  app.use((req, res, next) => router(req, res, next));
  server = createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  oauth = new KrokOAuth(store, base);
  const router = createOAuthRouter(oauth, async (token) => {
    const identity = await getAuth().verifyIdToken(token, true);
    return { uid: identity.uid, apple: identity.firebase.sign_in_provider === 'apple.com', reviewer: identity.krokReviewer === true && identity.firebase.sign_in_provider === 'password' };
  }, { hit: async () => true });
});
test.afterAll(async () => { server.close(); await getAuth().deleteUser('browser-reviewer'); await getAuth().deleteUser('browser-ordinary'); });

async function begin(page: Page, scopes = DEFAULT_SCOPES, name = 'Claude') {
  const register = await page.request.post(`${base}/register`, { data: { redirect_uris: [callback], token_endpoint_auth_method: 'none', client_name: name } });
  expect(register.status()).toBe(201);
  const { client_id } = await register.json();
  const params = new URLSearchParams({ client_id, response_type: 'code', redirect_uri: callback, resource: oauth.resource,
    code_challenge: 'A'.repeat(43), code_challenge_method: 'S256', scope: scopes.join(' '), state: 'browser-state' });
  await page.goto(`${base}/authorize?${params}`);
  await expect(page.locator('#consent')).toBeVisible();
}
async function signIn(page: Page) {
  await page.getByText('Directory reviewer access').click();
  await page.getByLabel('Email', { exact: true }).fill(reviewer);
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in to review account' }).click();
  await expect(page.getByRole('button', { name: 'Allow access' })).toBeEnabled();
}

test('consent renders safely on mobile, requires sign-in and makes exact routes opt-in', async ({ page }) => {
  await begin(page, [...DEFAULT_SCOPES, 'health:routes:full'], '<img src=x onerror=alert(1)>');
  await expect(page.locator('#client')).toContainText('<img src=x onerror=alert(1)>');
  await expect(page.locator('#client img')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Allow access' })).toBeDisabled();
  await expect(page.getByRole('checkbox')).not.toBeChecked();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.screenshot({ path: 'test-results/consent-mobile.png', fullPage: true });
});
test('real Firebase reviewer login authorizes only the existing dataset and returns a bound code', async ({ page }) => {
  await begin(page);
  await signIn(page);
  let redirect = '';
  await page.route('https://claude.ai/**', async (route) => { redirect = route.request().url(); await route.fulfill({ body: 'Returned to assistant.' }); });
  await page.getByRole('button', { name: 'Allow access' }).click();
  await expect(page).toHaveURL(/claude\.ai/);
  expect(new URL(redirect).searchParams.get('code')).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(new URL(redirect).searchParams.get('state')).toBe('browser-state');
});
test('cancel works without Apple login and preserves state', async ({ page }) => {
  await begin(page);
  await page.route('https://claude.ai/**', (route) => route.fulfill({ body: 'Cancelled.' }));
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page).toHaveURL(/error=access_denied/);
  expect(new URL(page.url()).searchParams.get('state')).toBe('browser-state');
});
test('failed Apple callback retains retry and cancel without granting access', async ({ page }) => {
  await page.addInitScript(() => sessionStorage.setItem('test-apple-redirect-failure', '1'));
  await begin(page);
  await expect(page.locator('#status')).toContainText('Apple sign-in did not complete');
  await expect(page.locator('#status')).not.toContainText('Firebase: Error');
  await expect(page.getByRole('button', { name: 'Sign in with Apple', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Allow access' })).toBeDisabled();
  await page.route('https://claude.ai/**', (route) => route.fulfill({ body: 'Cancelled.' }));
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(page).toHaveURL(/error=access_denied/);
});
test('reviewer can recover from a failed Apple callback using real emulator login', async ({ page }) => {
  await page.addInitScript(() => sessionStorage.setItem('test-apple-redirect-failure', '1'));
  await begin(page);
  await expect(page.locator('#status')).toContainText('Apple sign-in did not complete');
  await signIn(page);
  await expect(page.locator('#status')).toContainText('Signed in.');
});
test('expired browser binding gives actionable recovery and no consent controls', async ({ page }) => {
  await page.goto(`${base}/connect?request=${'Z'.repeat(43)}`);
  await expect(page.locator('#status')).toContainText('Start again');
  await expect(page.locator('#consent')).toBeHidden();
});
test('wrong reviewer password stays signed out with a recoverable error', async ({ page }) => {
  await begin(page);
  await page.getByText('Directory reviewer access').click();
  await page.getByLabel('Email', { exact: true }).fill(reviewer);
  await page.getByLabel('Password', { exact: true }).fill('wrong-password');
  await page.getByRole('button', { name: 'Sign in to review account' }).click();
  await expect(page.locator('#status')).toContainText('Reviewer sign-in failed');
  await expect(page.getByRole('button', { name: 'Allow access' })).toBeDisabled();
});

test('ordinary Firebase password accounts cannot authorize health access without the reviewer claim', async ({ page }) => {
  await begin(page);
  await page.getByText('Directory reviewer access').click();
  await page.getByLabel('Email', { exact: true }).fill('ordinary@example.test');
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in to review account' }).click();
  await expect(page.getByRole('button', { name: 'Allow access' })).toBeEnabled();
  await page.getByRole('button', { name: 'Allow access' }).click();
  await expect(page.locator('#status')).toContainText('Use Sign in with Apple');
  await expect(page).toHaveURL(/\/connect\?request=/);
});

test('switching accounts signs out and disables authorization', async ({ page }) => {
  await begin(page);
  await signIn(page);
  await page.getByRole('button', { name: 'Use a different account' }).click();
  await expect(page.getByRole('button', { name: 'Allow access' })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Sign in with Apple', exact: true })).toBeVisible();
});

test('dark consent page stays within a small mobile viewport', async ({ page }) => {
  await page.setViewportSize({ width: 320, height: 568 });
  await page.emulateMedia({ colorScheme: 'dark' });
  await begin(page);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.getByRole('button', { name: 'Cancel', exact: true }).scrollIntoViewIfNeeded();
  await expect(page.getByRole('button', { name: 'Cancel', exact: true })).toBeInViewport();
  await page.screenshot({ path: 'test-results/consent-dark-small.png', fullPage: true });
});
