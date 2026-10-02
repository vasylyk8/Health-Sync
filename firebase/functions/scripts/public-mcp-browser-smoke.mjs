import { chromium } from 'playwright';
import { createHash, randomBytes } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import assert from 'node:assert/strict';

const base = 'https://krok-1d60a.firebaseapp.com';
const browser = await chromium.launch();
const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
const page = await context.newPage();
const pageErrors = [];
page.on('pageerror', error => pageErrors.push(error.message));
try {
  const callback = 'https://claude.ai/api/mcp/auth_callback';
  const registration = await context.request.post(base + '/register', { data: {
    redirect_uris: [callback], client_name: 'KROK live browser verification (no account access)', token_endpoint_auth_method: 'none',
  } });
  assert.equal(registration.status(), 201);
  const client = await registration.json();
  const challenge = createHash('sha256').update(randomBytes(48)).digest('base64url');
  const query = new URLSearchParams({ response_type: 'code', client_id: client.client_id, redirect_uri: callback,
    code_challenge: challenge, code_challenge_method: 'S256', resource: base + '/mcp', state: randomBytes(16).toString('hex') });
  const authorization = await context.request.get(base + '/authorize?' + query, { maxRedirects: 0 });
  assert.equal(authorization.status(), 302);
  const consentURL = authorization.headers().location;
  const requestId = new URL(consentURL).searchParams.get('request');
  await page.goto(consentURL);
  await page.locator('#sign-in').waitFor({ state: 'visible', timeout: 45000 });
  assert.match(await page.locator('#status').innerText(), /same Apple Account/);
  assert.equal(await page.locator('#approve').isDisabled(), true);
  assert.equal(await page.locator('#full-route-option').isVisible(), false);
  assert.deepEqual(pageErrors, []);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await mkdir('public-live-screenshots', { recursive: true });
  await page.screenshot({ path: 'public-live-screenshots/production-consent.png', fullPage: true });
  console.log('PASS deployed consent page boots the real Firebase SDK, loads bound permissions and requires login');
  await page.locator('#sign-in').click();
  await page.waitForURL(url => url.hostname === 'appleid.apple.com', { timeout: 45000 });
  const apple = new URL(page.url());
  assert.ok(apple.searchParams.get('client_id'));
  assert.equal(new URL(apple.searchParams.get('redirect_uri')).origin, base);
  console.log('PASS real Apple sign-in redirect reaches Apple with a configured client and same-origin callback');
  console.log('No Apple credentials were entered and no user login or health access was performed.');
  const cancel = await context.request.post(base + '/oauth/consent', { data: { request: requestId, approve: false }, headers: { Origin: base } });
  assert.equal(cancel.status(), 200);
  assert.equal(new URL((await cancel.json()).redirect).searchParams.get('error'), 'access_denied');
  console.log('PASS live browser verification request cancelled without issuing a grant');
} finally {
  await browser.close();
}
