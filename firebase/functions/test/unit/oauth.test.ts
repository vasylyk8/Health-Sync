import { beforeEach, describe, expect, it } from 'vitest';
import type { Response } from 'express';
import { KrokOAuth, DEFAULT_SCOPES, pkceChallenge, callbackProvider } from '../../src/auth/oauth.js';
import { MemoryOAuthStore } from '../helpers/oauth.js';
import type { OAuthClientInformationFull } from '@modelcontextprotocol/sdk/shared/auth.js';
import { generateToken, hashToken } from '../../src/auth/tokens.js';

let store: MemoryOAuthStore, oauth: KrokOAuth, client: OAuthClientInformationFull, now: number;
const uid = 'existing-anonymous-user';
const callback = 'https://claude.ai/api/mcp/auth_callback';
beforeEach(async () => {
  now = Date.now(); store = new MemoryOAuthStore(); oauth = new KrokOAuth(store, 'https://krok.test', () => now);
  await store.set(`users/${uid}`, { generation: 1, deleting: false, createdAt: 1, lastVisibleAt: 10, tz: 'UTC', connections: {}, links: {} });
  client = await oauth.clientsStore.registerClient({ redirect_uris: [callback], token_endpoint_auth_method: 'none', client_name: 'Claude' });
});
async function begin(scopes = DEFAULT_SCOPES) {
  let csrf = '', id = '';
  const verifier = generateToken();
  const res = { cookie: (_key: string, value: string) => { csrf = value; }, redirect: (_status: number, url: string) => { id = new URL(url).searchParams.get('request')!; } } as unknown as Response;
  await oauth.authorize(client, { redirectUri: callback, codeChallenge: pkceChallenge(verifier), resource: new URL(oauth.resource), scopes, state: 'my-state' }, res);
  return { csrf, id, verifier };
}
async function tokens(scopes = DEFAULT_SCOPES) {
  const p = await begin(scopes);
  const url = new URL(await oauth.finishConsent(p.id, p.csrf, uid, true, false));
  const code = url.searchParams.get('code')!;
  const result = await oauth.exchangeAuthorizationCode(client, code, undefined, callback, new URL(oauth.resource));
  return { ...p, code, ...result };
}

describe('KROK OAuth identity and credential lifecycle', () => {
  it('links grants to the existing UID and preserves data and account generation', async () => {
    const t = await tokens();
    const identity = await oauth.verifyAccessToken(t.access_token);
    expect(identity.extra?.uid).toBe(uid);
    expect(await store.get(`users/${uid}`)).toMatchObject({ generation: 1, lastVisibleAt: 10 });
    expect(identity.extra?.profileId).toBeTruthy();
    expect(identity.extra?.profileId).not.toBe(uid);
    expect(await store.get(`oauthCredentials/${t.access_token}`)).toBeUndefined();
  });
  it('preserves OAuth state and checks the browser binding', async () => {
    const p = await begin();
    await expect(oauth.finishConsent(p.id, generateToken(), uid, true, false)).rejects.toThrow(/expired/);
    const url = new URL(await oauth.finishConsent(p.id, p.csrf, uid, true, false));
    expect(url.searchParams.get('state')).toBe('my-state');
    await expect(oauth.finishConsent(p.id, p.csrf, uid, true, false)).rejects.toThrow(/expired/);
  });
  it('allows cancellation without login and issues no grant', async () => {
    const p = await begin();
    expect(new URL(await oauth.finishConsent(p.id, p.csrf, undefined, false, false)).searchParams.get('error')).toBe('access_denied');
    expect([...store.docs.keys()].filter((p) => p.includes('oauthGrants'))).toHaveLength(0);
  });
  it('requires an existing KROK dataset owner; browser login cannot create one', async () => {
    const p = await begin();
    await expect(oauth.finishConsent(p.id, p.csrf, 'someone-else', true, false)).rejects.toThrow(/iPhone/);
  });
  it('refuses expired pending requests and codes', async () => {
    const p = await begin(); now += 11 * 60_000;
    await expect(oauth.describeRequest(p.id, p.csrf)).rejects.toThrow(/expired/);
    const p2 = await begin();
    const url = new URL(await oauth.finishConsent(p2.id, p2.csrf, uid, true, false));
    now += 61_000;
    await expect(oauth.exchangeAuthorizationCode(client, url.searchParams.get('code')!, undefined, callback, new URL(oauth.resource))).rejects.toThrow(/expired/);
  });
  it('enforces resource, client binding, callback and one-use codes', async () => {
    const p = await begin(); const url = new URL(await oauth.finishConsent(p.id, p.csrf, uid, true, false));
    const code = url.searchParams.get('code')!;
    await expect(oauth.exchangeAuthorizationCode(client, code, undefined, callback, new URL('https://evil.test/mcp'))).rejects.toThrow(/resource/);
    await expect(oauth.exchangeAuthorizationCode({ ...client, client_id: 'other' }, code, undefined, callback, new URL(oauth.resource))).rejects.toThrow(/invalid/);
    await expect(oauth.exchangeAuthorizationCode(client, code, undefined, 'https://evil.test', new URL(oauth.resource))).rejects.toThrow(/Callback/);
    await oauth.exchangeAuthorizationCode(client, code, undefined, callback, new URL(oauth.resource));
    await expect(oauth.exchangeAuthorizationCode(client, code, undefined, callback, new URL(oauth.resource))).rejects.toThrow(/used/);
  });
  it('requires separate explicit full-route consent', async () => {
    const t = await tokens([...DEFAULT_SCOPES, 'health:routes:full']);
    expect((await oauth.verifyAccessToken(t.access_token)).scopes).not.toContain('health:routes:full');
    const p = await begin([...DEFAULT_SCOPES, 'health:routes:full']);
    const url = new URL(await oauth.finishConsent(p.id, p.csrf, uid, true, true));
    const t2 = await oauth.exchangeAuthorizationCode(client, url.searchParams.get('code')!, undefined, callback, new URL(oauth.resource));
    expect((await oauth.verifyAccessToken(t2.access_token)).scopes).toContain('health:routes:full');
  });
  it('issues a refreshable grant even when the client never requests offline_access (ChatGPT)', async () => {
    const chatgptScopes = DEFAULT_SCOPES.filter((s) => s !== 'offline_access');
    const first = await tokens(chatgptScopes);
    expect(first.refresh_token).toBeTruthy();
    expect(first.scope.split(' ')).toContain('offline_access');
    now += 16 * 60_000;
    await expect(oauth.verifyAccessToken(first.access_token)).rejects.toThrow(/expired/);
    const second = await oauth.exchangeRefreshToken(client, first.refresh_token!, undefined, new URL(oauth.resource));
    expect(second.refresh_token).toBeTruthy();
    expect((await oauth.verifyAccessToken(second.access_token)).scopes).not.toContain('health:routes:full');
  });
  it('rotates refresh tokens and revokes the entire grant on replay', async () => {
    const first = await tokens();
    const second = await oauth.exchangeRefreshToken(client, first.refresh_token!, undefined, new URL(oauth.resource));
    expect(second.refresh_token).not.toBe(first.refresh_token);
    await expect(oauth.exchangeRefreshToken(client, first.refresh_token!, undefined, new URL(oauth.resource))).rejects.toThrow(/used/);
    await expect(oauth.verifyAccessToken(second.access_token)).rejects.toThrow(/disconnected/);
    await expect(oauth.verifyAccessToken(first.access_token)).rejects.toThrow(/disconnected/);
  });
  it('does not let concurrent refresh exchanges mint two usable token families', async () => {
    const t = await tokens();
    const results = await Promise.allSettled([0, 1].map(() => oauth.exchangeRefreshToken(client, t.refresh_token!, undefined, new URL(oauth.resource))));
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
    const winner = results.find((r) => r.status === 'fulfilled');
    if (winner?.status === 'fulfilled') await expect(oauth.verifyAccessToken(winner.value.access_token)).rejects.toThrow(/disconnected/);
  });
  it('supports refresh downscoping and refuses permission escalation', async () => {
    const t = await tokens();
    await expect(oauth.exchangeRefreshToken(client, t.refresh_token!, [...DEFAULT_SCOPES, 'health:routes:full'], new URL(oauth.resource))).rejects.toThrow(/add permissions/);
    const next = await oauth.exchangeRefreshToken(client, t.refresh_token!, ['health:workouts:read'], new URL(oauth.resource));
    expect(next.refresh_token).toBeUndefined();
    expect((await oauth.verifyAccessToken(next.access_token)).scopes).toEqual(['health:workouts:read']);
  });
  it('expires access tokens and allows refresh only within the absolute grant lifetime', async () => {
    const t = await tokens(); now += 16 * 60_000;
    await expect(oauth.verifyAccessToken(t.access_token)).rejects.toThrow(/expired/);
    const next = await oauth.exchangeRefreshToken(client, t.refresh_token!, undefined, new URL(oauth.resource));
    expect((await oauth.verifyAccessToken(next.access_token)).extra?.uid).toBe(uid);
    now += 31 * 86_400_000;
    await expect(oauth.exchangeRefreshToken(client, next.refresh_token!, undefined, new URL(oauth.resource))).rejects.toThrow(/expired/);
  });
  it.each(['deleting', 'generation', 'oauthEpochs'])('immediately blocks credentials after %s changes', async (field) => {
    const t = await tokens(); const user = await store.get<object>(`users/${uid}`);
    const patch = field === 'deleting' ? { deleting: true } : field === 'generation' ? { generation: 2 } : { oauthEpochs: { claude: 1 } };
    await store.set(`users/${uid}`, { ...user, ...patch });
    await expect(oauth.verifyAccessToken(t.access_token)).rejects.toThrow(/disconnected/);
    await expect(oauth.exchangeRefreshToken(client, t.refresh_token!, undefined, new URL(oauth.resource))).rejects.toThrow(/disconnected/);
  });
  it('revokes tokens without allowing another client to revoke the grant', async () => {
    const t = await tokens();
    await oauth.revokeToken({ ...client, client_id: 'other' }, { token: t.access_token });
    await oauth.verifyAccessToken(t.access_token);
    await oauth.revokeToken(client, { token: t.refresh_token! });
    await expect(oauth.verifyAccessToken(t.access_token)).rejects.toThrow(/disconnected/);
  });
  it('rejects arbitrary callback URLs, non-public clients and unknown scopes', async () => {
    for (const uri of ['https://evil.test/callback', 'javascript:alert(1)', 'https://claude.ai.evil.test/api/mcp/auth_callback', 'https://claude.ai/api/mcp/auth_callback#evil']) {
      await expect(oauth.clientsStore.registerClient({ redirect_uris: [uri], token_endpoint_auth_method: 'none' })).rejects.toThrow();
    }
    expect(callbackProvider('http://127.0.0.1:4321/callback', 'Claude Code')).toBe('claude');
    await expect(oauth.clientsStore.registerClient({ redirect_uris: [callback], token_endpoint_auth_method: 'client_secret_post' })).rejects.toThrow(/public PKCE/);
    await expect(begin(['admin'])).rejects.toThrow(/Unknown/);
  });
  it('retains a stable public profile ID across reconnections', async () => {
    const first = await tokens(), second = await tokens();
    expect((await oauth.verifyAccessToken(first.access_token)).extra?.profileId).toBe((await oauth.verifyAccessToken(second.access_token)).extra?.profileId);
    expect([...store.docs.keys()].some((p) => p.endsWith(hashToken(first.access_token)))).toBe(true);
  });
});
