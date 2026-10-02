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
  await store.set('users/browser-reviewer', { generation: 1, connections: {}, createdAt: 1 });
  const bundle = await build({ entryPoints: ['../../web/connect.ts'], bundle: true, write: false, format: 'esm', platform: 'browser',
    plugins: [{ name: 'auth-emulator-only', setup(builder) {
      builder.onResolve({ filter: /functions\/node_modules\/firebase\/auth$/ }, () => ({ path: path.resolve('test/browser/firebase-auth.ts') }));
    } }] });
  const app = express();
  app.get('/__/firebase/init.json', (_req, res) => res.json({ apiKey: 'fake-api-key', projectId: 'demo-health-sync', authDomain: 'localhost' }));
  app.get('/connect.js', (_req, res) => res.type('js').send(bundle.outputFiles[0]!.text));
  app.get('/connect', (_req, res) => res.type('html').send(readFileSync('../hosting/connect.html', 'utf8')));
  app.get('/style.css', (_req, res) => res.type('css').send(readFileSync('../hosting/style.css', 'utf8')));
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
test.afterAll(async () => { server.close(); await getAuth().deleteUser('browser-reviewer'); });

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
