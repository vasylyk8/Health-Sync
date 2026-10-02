// Real production OAuth/browser/tool rehearsal on the dedicated synthetic account.
// No browser traces, screenshots, recordings, credentials or health values are saved.
import { strict as assert } from 'node:assert';
import { createHash, randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { chromium } from '@playwright/test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const base = 'https://krok-1d60a.firebaseapp.com';
const resource = base + '/mcp';
const email = process.env.KROK_REVIEWER_EMAIL, password = process.env.KROK_REVIEWER_PASSWORD;
assert.equal(process.env.GCP_PROJECT_ID, 'krok-1d60a');
assert.equal(process.env.KROK_REVIEWER_UID, 'krok-reviewer-directory');
assert(email && password);
const outcomes = [];
let current = 'browser launch';
const mask = (value) => { if (process.env.GITHUB_ACTIONS === 'true' && value) console.log('::add-mask::' + value); };
const passed = (label) => { outcomes.push({ check: label, status: 'passed' }); console.log('PASS: ' + label); };
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHROMIUM_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH } : {}) });
const grants = [];
let client;

async function jsonRequest(path, options = {}) {
  const response = await fetch(base + path, { signal: AbortSignal.timeout(60_000), ...options });
  assert(response.ok, 'request status');
  return response.json();
}
async function formRequest(path, body) {
  const response = await fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body), signal: AbortSignal.timeout(60_000) });
  assert(response.ok, 'form status');
  const text = await response.text();
  const result = text ? JSON.parse(text) : {};
  mask(result.access_token); mask(result.refresh_token);
  return result;
}
async function connect(provider, scope, testWrongPassword = false) {
  current = provider + ' registration and browser login';
  const callback = provider === 'Claude' ? 'https://claude.ai/api/mcp/auth_callback' : 'https://chatgpt.com/connector_platform_oauth_redirect';
  const registration = await jsonRequest('/register', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_name: 'KROK synthetic ' + provider + ' reviewer rehearsal', redirect_uris: [callback], token_endpoint_auth_method: 'none' }) });
  const verifier = randomBytes(48).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const state = randomBytes(16).toString('base64url');
  const context = await browser.newContext();
  const page = await context.newPage();
  let redirected;
  await page.route(callback + '**', (route) => { redirected = new URL(route.request().url()); return route.fulfill({ body: 'Synthetic OAuth callback captured. No request sent to assistant.' }); });
  await page.goto(base + '/authorize?' + new URLSearchParams({ client_id: registration.client_id, redirect_uri: callback,
    response_type: 'code', resource, code_challenge: challenge, code_challenge_method: 'S256', scope, state }));
  await page.locator('#consent').waitFor({ state: 'visible', timeout: 60_000 });
  await page.getByText('Directory reviewer access').click();
  await page.getByLabel('Email', { exact: true }).fill(email);
  if (testWrongPassword) {
    await page.getByLabel('Password', { exact: true }).fill(password + '-invalid');
    await page.getByRole('button', { name: 'Sign in to review account' }).click();
    await page.locator('#status').filter({ hasText: 'Reviewer sign-in failed' }).waitFor();
    assert(await page.getByRole('button', { name: 'Allow access' }).isDisabled());
    passed('production wrong-password refusal');
  }
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: 'Sign in to review account' }).click();
  await page.waitForFunction(() => !document.querySelector('#approve').disabled, null, { timeout: 60_000 });
  assert.equal(await page.getByLabel('Password', { exact: true }).inputValue(), '');
  await page.getByRole('button', { name: 'Allow access' }).click();
  await page.waitForURL(callback + '**', { timeout: 60_000 });
  assert.equal(redirected.searchParams.get('state'), state);
  const code = redirected.searchParams.get('code'); mask(code);
  assert(code);
  const grant = { ...await formRequest('/token', { grant_type: 'authorization_code', client_id: registration.client_id,
    code, redirect_uri: callback, code_verifier: verifier, resource }), client_id: registration.client_id };
  grants.push(grant);
  await context.close();
  passed(provider + ' production browser login, consent and PKCE exchange');
  return grant;
}
async function mcp(grant) {
  const connection = new Client({ name: 'KROK reviewer verification', version: '1.0.0' });
  await connection.connect(new StreamableHTTPClientTransport(new URL(resource), { requestInit: { headers: { Authorization: 'Bearer ' + grant.access_token } } }));
  return connection;
}
async function call(name, args) {
  current = 'tool ' + name;
  const result = await client.callTool({ name, arguments: args });
  assert(!result.isError, 'tool returned error');
  const data = result.structuredContent ?? JSON.parse(result.content.find((c) => c.type === 'text').text);
  assert(data && typeof data === 'object');
  if (name !== 'get_account') assert.equal(typeof data.complete, 'boolean');
  if (name === 'get_recovery') {
    assert(Object.values(data.metrics).every((metric) => metric.status !== 'within normal range'));
    assert(data.notes.some((note) => note.includes('personal baseline, not clinical reference ranges')));
  }
  if (name === 'get_training_load') {
    assert(data.inputs.resting_hr_source);
    assert.equal(typeof data.inputs.trimp_coefficient, 'number');
    assert(data.inputs.trimp_coefficient_source);
  }
  return data;
}
try {
  const normal = await connect('Claude', 'health:workouts:read health:daily:read health:routes:read offline_access', true);
  client = await mcp(normal);
  current = 'synthetic fixture ingestion';
  let workouts;
  for (let attempt = 0; attempt < 30; attempt++) {
    workouts = await call('get_workouts', { start_date: '2024-01-01', end_date: '2024-01-07', timezone: 'Europe/Berlin' });
    if (workouts.workouts?.some((w) => w.distance_km === 5 && w.raw_data === 'complete')) break;
    await pause(10_000);
  }
  const run = workouts.workouts?.find((w) => w.distance_km === 5 && w.raw_data === 'complete');
  assert(run, 'populated fixture workout required');
  const workout_id = run.id;
  assert(workout_id, 'returned fixture ID required');
  const splits = await call('workout_splits', { workout_id, unit: 'km' });
  assert.equal(splits.splits.length, 5);
  assert(splits.splits.every((s) => s.moving_seconds === 360));
  const route = await call('get_workout_route', { workout_id, max_points: 50 });
  assert.equal(route.trimmed_ends, true); assert(route.returned > 10);
  const daily = await call('get_daily_context', { start_date: '2024-01-01', end_date: '2024-01-07' });
  assert.equal(daily.days[0].steps, 6000);
  passed('populated reviewer: 5km workout, five 6-minute splits, trimmed route and daily fixture');
  current = 'scope boundaries';
  for (const [name, args] of [['get_workout_route', { workout_id, include_full_route: true }], ['get_profile', {}], ['get_nutrition_log', { start_date: '2024-03-01', end_date: '2024-03-02' }]]) {
    assert.equal((await client.callTool({ name, arguments: args })).isError, true);
  }
  passed('default scopes refuse exact endpoints, profile and timed nutrition');
  await client.close();
  const extended = await connect('ChatGPT', 'health:workouts:read health:daily:read health:routes:read health:events:read health:profile:read offline_access');
  client = await mcp(extended);
  current = 'tool inventory';
  const tools = (await client.listTools()).tools;
  assert.equal(tools.length, 16);
  assert(!/get_glucose|get_health_events/.test(client.getInstructions() ?? ''));
  for (const name of ['get_glucose', 'get_health_events']) {
    assert(!tools.some((tool) => tool.name === name));
    const result = await client.callTool({ name, arguments: { start_date: '2024-03-01', end_date: '2024-03-07' } });
    assert.equal(result.isError, true);
    assert(result.content.some((item) => item.type === 'text' && item.text.includes('not found')));
  }
  passed('removed glucose and detailed event tools are absent and cannot be called with extended scopes');
  for (const tool of tools) {
    assert(tool.title);
    assert.equal(tool.annotations?.readOnlyHint, true);
    assert.equal(tool.annotations?.destructiveHint, false);
    assert.equal(tool.annotations?.openWorldHint, false);
  }
  const dates = { start_date: '2024-03-01', end_date: '2024-03-07' };
  const inputs = {
    get_workouts: { ...dates, timezone: 'Europe/Berlin' }, get_workout: { workout_id },
    get_workout_series: { workout_id, stream: 'HeartRate', max_points: 30 },
    get_workout_route: { workout_id, max_points: 50 }, workout_hr_zones: { workout_id, max_hr: 200 },
    workout_splits: { workout_id, unit: 'km' }, workout_hr_drift: { workout_id },
    workout_best_efforts: { workout_id, distances_m: [1000, 3000] }, workout_elevation: { workout_id },
    get_daily_context: dates, get_hourly_series: { ...dates, series: 'HeartRate', timezone: 'Europe/Berlin' },
    get_recovery: { date: '2024-03-07', timezone: 'Europe/Berlin' },
    get_training_load: { end_date: '2024-03-07', days: 14, max_hr: 200 },
    get_nutrition_log: { ...dates, timezone: 'Europe/Berlin' }, get_profile: {}, get_account: {},
  };
  assert.deepEqual(new Set(tools.map((t) => t.name)), new Set(Object.keys(inputs)));
  for (const tool of tools) { await call(tool.name, inputs[tool.name]); passed('live MCP tool: ' + tool.name); }
  passed('all 16 production tools respond with supported schemas and read-only annotations');
  current = 'refresh token rotation';
  const refreshed = await formRequest('/token', { grant_type: 'refresh_token', client_id: extended.client_id, refresh_token: extended.refresh_token, resource });
  grants.push({ ...refreshed, client_id: extended.client_id });
  assert(refreshed.refresh_token && refreshed.refresh_token !== extended.refresh_token);
  passed('production refresh credential rotation');
  current = 'revoke and access rejection';
  await formRequest('/revoke', { client_id: extended.client_id, token: refreshed.refresh_token });
  const refused = await fetch(resource, { method: 'POST', headers: { Authorization: 'Bearer ' + refreshed.access_token,
    'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
  assert.equal(refused.status, 401);
  passed('production revocation rejects previously authorized access');
} catch {
  outcomes.push({ check: current, status: 'failed' });
  console.error('FAIL: ' + current + ' (credentials and response values withheld)');
  process.exitCode = 1;
} finally {
  await client?.close().catch(() => undefined);
  for (const grant of grants) {
    await fetch(base + '/revoke', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: grant.client_id, token: grant.refresh_token ?? grant.access_token }), signal: AbortSignal.timeout(30_000) }).catch(() => undefined);
  }
  await browser.close();
  writeFileSync('/tmp/krok-reviewer-verification.json', JSON.stringify({ checkedAt: new Date().toISOString(),
    syntheticOnly: true, endpoint: resource, browserCallbacksIntercepted: true,
    actualChatGPTClaudeHostCases: 'Not run; real recordings remain required.', outcomes }, null, 2));
}
