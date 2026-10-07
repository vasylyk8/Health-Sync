import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import express from 'express';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { KrokOAuth, DEFAULT_SCOPES, OAUTH_SCOPES, pkceChallenge } from '../../src/auth/oauth.js';
import { createOAuthRouter } from '../../src/auth/oauth-router.js';
import { generateToken } from '../../src/auth/tokens.js';
import { handleMcp, TOOL_NAMES, toolScopes } from '../../src/mcp/server.js';
import { MemoryOAuthStore } from '../helpers/oauth.js';
import { makeEnv, type Env } from '../helpers/memory.js';

let server: Server, base: string, store: MemoryOAuthStore, oauth: KrokOAuth, env: Env;
let allowed = true;
let router: ReturnType<typeof createOAuthRouter>;
beforeAll(async () => {
  const app = express();
  app.use(express.json());
  app.use('/mcp', (req, res) => handleMcp(Object.assign(req, { url: '/mcp' }), res, {
    oauth, meta: env.meta, data: env.data, tokens: { resolve: async () => null },
    limiter: { hit: async () => allowed }, connections: { touch: async () => undefined },
    accessLog: { record: async () => undefined },
  }));
  app.use((req, res, next) => router(req, res, next));
  server = createServer(app);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
afterAll(() => server.close());
beforeEach(async () => {
  env = makeEnv(Date.now()); store = new MemoryOAuthStore(); allowed = true;
  oauth = new KrokOAuth(store, 'https://krok.test');
  router = createOAuthRouter(oauth, async (token) => {
    if (token === 'bad') throw new Error('invalid token');
    return { uid: env.uid, apple: token === 'apple', reviewer: token === 'reviewer' };
  }, { hit: async () => allowed });
  await store.set(`users/${env.uid}`, await env.meta.getUser(env.uid) ?? { generation: 1, connections: {} });
});
const callback = 'https://claude.ai/api/mcp/auth_callback';
async function post(path: string, body: object, headers: Record<string, string> = {}) {
  return fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body), redirect: 'manual' });
}
async function begin(scopes = DEFAULT_SCOPES) {
  const registration = await post('/register', { redirect_uris: [callback], client_name: 'Claude', token_endpoint_auth_method: 'none' });
  expect(registration.status).toBe(201);
  const { client_id } = await registration.json() as { client_id: string };
  const verifier = generateToken();
  const params = new URLSearchParams({ response_type: 'code', client_id, redirect_uri: callback, resource: oauth.resource,
    code_challenge: pkceChallenge(verifier), code_challenge_method: 'S256', scope: scopes.join(' '), state: 'state-preserved' });
  const response = await fetch(`${base}/authorize?${params}`, { redirect: 'manual' });
  expect(response.status).toBe(302);
  expect(response.headers.get('set-cookie')).toMatch(/HttpOnly/);
  expect(response.headers.get('set-cookie')).toMatch(/Secure/);
  expect(response.headers.get('set-cookie')).toMatch(/SameSite=Lax/i);
  const cookie = response.headers.get('set-cookie')!.split(';')[0]!;
  const request = new URL(response.headers.get('location')!).searchParams.get('request')!;
  return { client_id, verifier, cookie, request };
}
async function authorize(login = 'apple', scopes = DEFAULT_SCOPES) {
  const pending = await begin(scopes);
  const response = await post('/oauth/consent', { request: pending.request, approve: true, fullRoutes: false },
    { origin: 'https://krok.test', cookie: pending.cookie, authorization: `Bearer ${login}` });
  return { ...pending, response };
}
async function token(scopes = DEFAULT_SCOPES) {
  const pending = await authorize('apple', scopes);
  expect(pending.response.status).toBe(200);
  const { redirect } = await pending.response.json() as { redirect: string };
  const url = new URL(redirect);
  expect(url.searchParams.get('state')).toBe('state-preserved');
  const response = await post('/token', { grant_type: 'authorization_code', client_id: pending.client_id,
    code: url.searchParams.get('code'), redirect_uri: callback, code_verifier: pending.verifier, resource: oauth.resource });
  expect(response.status).toBe(200);
  return { ...pending, ...await response.json() as { access_token: string; refresh_token: string } };
}

describe('Public OAuth HTTP boundary', () => {
  it('publishes authorization and resource metadata with public PKCE authentication', async () => {
    const metadata = await (await fetch(`${base}/.well-known/oauth-authorization-server`)).json();
    expect(metadata).toMatchObject({ issuer: 'https://krok.test/', token_endpoint_auth_methods_supported: ['none'], code_challenge_methods_supported: ['S256'] });
    const resource = await (await fetch(`${base}/.well-known/oauth-protected-resource/mcp`)).json();
    expect(resource).toMatchObject({ resource: oauth.resource, authorization_servers: [oauth.issuer] });
    expect(resource.scopes_supported).toEqual(OAUTH_SCOPES);
  });
  it('uses a Secure HttpOnly Firebase-forwarded session binding', async () => {
    const pending = await begin();
    expect(pending.cookie).toMatch(/^__session=/);
    const response = await fetch(`${base}/oauth/request/${pending.request}`, { headers: { cookie: pending.cookie } });
    expect(response.status).toBe(200);
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(await response.json()).toMatchObject({ clientName: 'Claude', callbackHost: 'claude.ai' });
    expect((await fetch(`${base}/oauth/request/${pending.request}`)).status).toBe(400);
  });
  it.each(['https://evil.test', 'null', ''])('rejects consent from an untrusted Origin %s', async (origin) => {
    const pending = await begin();
    const response = await post('/oauth/consent', { request: pending.request, approve: true }, { origin, cookie: pending.cookie, authorization: 'Bearer apple' });
    expect(response.status).toBe(403);
  });
  it.each(['ordinary-password', 'bad', ''])('refuses untrusted or missing login %s', async (login) => {
    const pending = await authorize(login);
    expect(pending.response.status).not.toBe(200);
    expect([...store.docs.keys()].some((key) => key.includes('oauthGrants'))).toBe(false);
  });
  it('allows only the explicit reviewer identity as a password-login exception', async () => {
    expect((await authorize('reviewer')).response.status).toBe(200);
  });
  it('enforces PKCE at the actual SDK token endpoint', async () => {
    const pending = await authorize();
    const { redirect } = await pending.response.json() as { redirect: string };
    const fields = { grant_type: 'authorization_code', client_id: pending.client_id, code: new URL(redirect).searchParams.get('code'), redirect_uri: callback, resource: oauth.resource };
    expect((await post('/token', { ...fields, code_verifier: generateToken() })).status).toBe(400);
    expect((await post('/token', { ...fields, code_verifier: pending.verifier })).status).toBe(200);
    expect((await post('/token', { ...fields, code_verifier: pending.verifier })).status).toBe(400);
  });
  it('rotates and revokes credentials through the HTTP endpoints', async () => {
    const first = await token();
    const refresh = await post('/token', { grant_type: 'refresh_token', client_id: first.client_id, refresh_token: first.refresh_token, resource: oauth.resource });
    expect(refresh.status).toBe(200);
    const next = await refresh.json() as { access_token: string; refresh_token: string };
    expect(next.refresh_token).not.toBe(first.refresh_token);
    expect((await post('/revoke', { client_id: first.client_id, token: next.refresh_token })).status).toBe(200);
    await expect(oauth.verifyAccessToken(next.access_token)).rejects.toThrow();
  });
  it('returns a refresh token to a client that asks only for data scopes (ChatGPT)', async () => {
    const first = await token(DEFAULT_SCOPES.filter((s) => s !== 'offline_access'));
    expect(first.refresh_token).toBeTruthy();
    const refresh = await post('/token', { grant_type: 'refresh_token', client_id: first.client_id, refresh_token: first.refresh_token, resource: oauth.resource });
    expect(refresh.status).toBe(200);
    expect((await refresh.json() as { refresh_token?: string }).refresh_token).toBeTruthy();
  });
  it('logs rejected token requests without logging credentials', async () => {
    const first = await token();
    const lines: string[] = [];
    const write = process.stdout.write.bind(process.stdout);
    const hsLog = process.env.HS_LOG; delete process.env.HS_LOG;
    process.stdout.write = ((chunk: string | Uint8Array) => { lines.push(String(chunk)); return true; }) as typeof process.stdout.write;
    try {
      const response = await post('/token', { grant_type: 'refresh_token', client_id: first.client_id, refresh_token: generateToken(), scope: 'health:daily:read' });
      expect(response.status).toBe(400);
    } finally { process.stdout.write = write; if (hsLog !== undefined) process.env.HS_LOG = hsLog; }
    const entry = lines.map((l) => { try { return JSON.parse(l) as Record<string, unknown>; } catch { return undefined; } })
      .find((e) => e?.message === 'oauth request rejected');
    expect(entry).toMatchObject({ severity: 'WARNING', op: '/token', status: 400, code: 'refresh_token', note: 'resource=false scope=health:daily:read' });
    expect(lines.join('')).not.toContain(first.refresh_token);
  });
  it('rate limits public authorization and MCP traffic', async () => {
    const credentials = await token(); allowed = false;
    expect((await fetch(`${base}/.well-known/oauth-authorization-server`)).status).toBe(429);
    expect((await post('/mcp', {}, { authorization: `Bearer ${credentials.access_token}` })).status).toBe(429);
  });
  it('provides an authentication discovery challenge, not a secret URL', async () => {
    const response = await post('/mcp', {});
    expect(response.status).toBe(401);
    expect(response.headers.get('www-authenticate')).toContain(`${oauth.issuer}.well-known/oauth-protected-resource/mcp`);
  });
  it('lists all tools without duplicate profile names and returns the account identity', async () => {
    const credentials = await token();
    const client = new Client({ name: 'test', version: '1' });
    await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), { requestInit: { headers: { authorization: `Bearer ${credentials.access_token}` } } }));
    try {
      const { tools } = await client.listTools();
      expect(tools.map((tool) => tool.name).sort()).toEqual([...TOOL_NAMES, 'get_account'].sort());
      expect(tools.every((tool) => tool.annotations?.readOnlyHint === true && tool.annotations?.destructiveHint === false)).toBe(true);
      const result = await client.callTool({ name: 'get_account', arguments: {} });
      expect(result.structuredContent).toMatchObject({ nickname: 'KROK account' });
      expect(result.structuredContent?.id).not.toBe(env.uid);
      const profile = await client.callTool({ name: 'get_profile', arguments: {} });
      expect(profile.isError).toBe(true);
      expect(profile._meta).toHaveProperty('mcp/www_authenticate');
      const events = await client.callTool({ name: 'get_health_events', arguments: { start_date: '2026-10-01', end_date: '2026-10-02' } });
      expect(events.isError).toBe(true);
    } finally { await client.close(); }
  });
  it('does not expose or execute removed tools even with all OAuth permissions', async () => {
    const credentials = await token(OAUTH_SCOPES);
    const client = new Client({ name: 'test', version: '1' });
    await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), { requestInit: { headers: { authorization: `Bearer ${credentials.access_token}` } } }));
    try {
      const { tools } = await client.listTools();
      expect(tools).toHaveLength(18);
      expect(client.getInstructions()).not.toMatch(/get_glucose|get_health_events/);
      for (const name of ['get_glucose', 'get_health_events']) {
        expect(tools.some((tool) => tool.name === name)).toBe(false);
        const result = await client.callTool({ name, arguments: { start_date: '2024-01-01', end_date: '2024-01-07' } });
        expect(result.isError).toBe(true);
        expect(result.content).toEqual(expect.arrayContaining([expect.objectContaining({ type: 'text', text: expect.stringContaining('not found') })]));
      }
    } finally { await client.close(); }
  });
  it('separates sensitive event and profile permission from workout-only grants', () => {
    expect(TOOL_NAMES.every((name) => toolScopes(name).length > 0)).toBe(true);
    expect(() => toolScopes('undeclared_future_tool')).toThrow(/Declare OAuth permissions/);
    expect(toolScopes('get_profile')).toEqual(['health:profile:read']);
    expect(() => toolScopes('get_health_events')).toThrow(/Declare OAuth permissions/);
    expect(() => toolScopes('get_glucose')).toThrow(/Declare OAuth permissions/);
    expect(toolScopes('get_nutrition_log')).toContain('health:events:read');
    expect(DEFAULT_SCOPES).not.toContain('health:events:read');
    expect(DEFAULT_SCOPES).not.toContain('health:profile:read');
  });
});
