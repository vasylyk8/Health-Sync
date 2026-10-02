import { createHash, randomUUID } from 'node:crypto';
import type { Response } from 'express';
import type { OAuthServerProvider, AuthorizationParams } from '@modelcontextprotocol/sdk/server/auth/provider.js';
import type { OAuthClientInformationFull, OAuthTokenRevocationRequest, OAuthTokens } from '@modelcontextprotocol/sdk/shared/auth.js';
import type { AuthInfo } from '@modelcontextprotocol/sdk/server/auth/types.js';
import { InvalidClientMetadataError, InvalidGrantError, InvalidRequestError, InvalidScopeError, InvalidTokenError } from '@modelcontextprotocol/sdk/server/auth/errors.js';
import { generateToken, hashToken, TOKEN_RE } from './tokens.js';
import type { OAuthStore, OAuthTransaction } from './oauth-store.js';
import type { UserDoc } from '../store/types.js';
import type { Provider } from '../config.js';

export const OAUTH_SCOPES = ['health:workouts:read', 'health:daily:read', 'health:events:read', 'health:profile:read', 'health:routes:read', 'health:routes:full', 'offline_access'];
export const DEFAULT_SCOPES = ['health:workouts:read', 'health:daily:read', 'health:routes:read', 'offline_access'];
const ACCESS_MS = 15 * 60_000;
const GRANT_MS = 30 * 86_400_000;
const REQUEST_MS = 10 * 60_000;
// Firebase Hosting forwards only __session to rewritten Cloud Functions.
export const CONSENT_COOKIE = '__session';

interface Pending {
  clientId: string; name: string; provider: Provider; redirectUri: string; state?: string;
  challenge: string; resource: string; scopes: string[]; csrfHash: string;
  expires: number; used?: boolean;
}
interface Grant {
  uid: string; clientId: string; provider: Provider; scopes: string[]; generation: number;
  epoch: number; expires: number; revoked: boolean;
}
interface Credential {
  kind: 'code' | 'access' | 'refresh'; uid: string; grantId: string; clientId: string;
  resource: string; scopes: string[]; expires: number; used?: boolean;
  challenge?: string; redirectUri?: string;
}

/** Only supported host callbacks and native loopback clients can register.
 * Never fetch client URLs: DCR avoids a client-metadata SSRF surface. */
export function callbackProvider(uri: string, name = ''): Provider {
  const u = new URL(uri);
  if (u.username || u.password || u.hash) throw new InvalidClientMetadataError('Invalid callback URL.');
  if (u.origin === 'https://claude.ai' && u.pathname === '/api/mcp/auth_callback' && !u.search) return 'claude';
  if (u.origin === 'https://chatgpt.com' && !u.search && (
    u.pathname === '/connector_platform_oauth_redirect' || /^\/connector\/oauth\/[A-Za-z0-9_-]+$/.test(u.pathname)
  )) return 'chatgpt';
  if (u.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname) && !u.search && ['/callback', '/auth/callback'].includes(u.pathname)) {
    return /claude/i.test(name) ? 'claude' : 'chatgpt';
  }
  throw new InvalidClientMetadataError('Use a supported ChatGPT, Claude, or native loopback callback.');
}

export class KrokOAuth implements OAuthServerProvider {
  readonly resource: string;
  readonly issuer: string;
  constructor(readonly store: OAuthStore, baseUrl: string, private readonly now = Date.now) {
    const base = new URL(baseUrl);
    if (base.protocol !== 'https:' && !['127.0.0.1', 'localhost'].includes(base.hostname)) throw new Error('OAuth requires HTTPS.');
    this.issuer = `${base.origin}/`;
    this.resource = `${base.origin}/mcp`;
  }
  readonly clientsStore = {
    getClient: async (id: string): Promise<OAuthClientInformationFull | undefined> => {
      if (!/^[A-Za-z0-9_-]{1,100}$/.test(id)) return undefined;
      return this.store.get(`oauthClients/${id}`);
    },
    registerClient: async (client: Omit<OAuthClientInformationFull, 'client_id' | 'client_id_issued_at'>): Promise<OAuthClientInformationFull> => {
      if (client.redirect_uris.length < 1 || client.redirect_uris.length > 5) throw new InvalidClientMetadataError('Provide 1–5 callback URLs.');
      const providers = client.redirect_uris.map((u) => callbackProvider(u, client.client_name));
      if (new Set(providers).size !== 1) throw new InvalidClientMetadataError('Do not mix assistant callbacks.');
      if (client.token_endpoint_auth_method !== 'none') throw new InvalidClientMetadataError('Use a public PKCE client (token_endpoint_auth_method=none).');
      if (client.client_name && client.client_name.length > 100) throw new InvalidClientMetadataError('Client name is too long.');
      if (client.grant_types?.some((g) => !['authorization_code', 'refresh_token'].includes(g)) || client.response_types?.some((r) => r !== 'code')) throw new InvalidClientMetadataError('Only authorization code and refresh grants are supported.');
      if (client.scope) this.scopes(client.scope.split(' '));
      const result: OAuthClientInformationFull = {
        client_id: randomUUID(), client_id_issued_at: Math.floor(this.now() / 1000),
        redirect_uris: client.redirect_uris, client_name: client.client_name ?? 'MCP client',
        token_endpoint_auth_method: 'none', grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'],
      };
      await this.store.set(`oauthClients/${result.client_id}`, result);
      return result;
    },
  };
  private scopes(values: string[]): string[] {
    const scopes = [...new Set(values.filter(Boolean))];
    if (scopes.some((s) => !OAUTH_SCOPES.includes(s))) throw new InvalidScopeError('Unknown KROK permission.');
    if (scopes.includes('health:routes:full') && !scopes.includes('health:routes:read')) throw new InvalidScopeError('Full routes also require route-read permission.');
    return scopes;
  }
  private audience(resource?: URL): void {
    if (resource?.href !== this.resource) throw new InvalidRequestError('resource must match the canonical KROK MCP endpoint.');
  }
  async authorize(client: OAuthClientInformationFull, params: AuthorizationParams, res: Response): Promise<void> {
    this.audience(params.resource);
    if (!/^[A-Za-z0-9_-]{43}$/.test(params.codeChallenge)) throw new InvalidRequestError('A valid S256 PKCE challenge is required.');
    if ((params.state?.length ?? 0) > 1024) throw new InvalidRequestError('State is too long.');
    const id = generateToken(), csrf = generateToken();
    const pending: Pending = {
      clientId: client.client_id, name: client.client_name ?? 'MCP client',
      provider: callbackProvider(params.redirectUri, client.client_name), redirectUri: params.redirectUri,
      ...(params.state ? { state: params.state } : {}), challenge: params.codeChallenge,
      resource: this.resource, scopes: this.scopes(params.scopes?.length ? params.scopes : DEFAULT_SCOPES),
      csrfHash: hashToken(csrf), expires: this.now() + REQUEST_MS,
    };
    await this.store.set(`oauthRequests/${hashToken(id)}`, pending);
    res.cookie(CONSENT_COOKIE, csrf, { httpOnly: true, secure: true, sameSite: 'lax', path: '/', maxAge: REQUEST_MS });
    res.redirect(302, `${this.issuer}connect?request=${id}`);
  }
  private pending(record: Pending | undefined, csrf: string): Pending {
    if (!record || record.used || record.expires <= this.now() || !TOKEN_RE.test(csrf) || record.csrfHash !== hashToken(csrf)) throw new InvalidGrantError('This connection request expired. Start again in your assistant.');
    return record;
  }
  async describeRequest(id: string, csrf: string) {
    if (!TOKEN_RE.test(id)) throw new InvalidGrantError('Invalid request.');
    const p = this.pending(await this.store.get<Pending>(`oauthRequests/${hashToken(id)}`), csrf);
    return { clientName: p.name, provider: p.provider, callbackHost: new URL(p.redirectUri).hostname, scopes: p.scopes };
  }
  async finishConsent(id: string, csrf: string, uid: string | undefined, approve: boolean, fullRoutes: boolean): Promise<string> {
    if (!TOKEN_RE.test(id)) throw new InvalidGrantError('Invalid request.');
    const path = `oauthRequests/${hashToken(id)}`;
    return this.store.transaction(async (tx) => {
      const p = this.pending(await tx.get<Pending>(path), csrf);
      const redirect = new URL(p.redirectUri);
      if (p.state) redirect.searchParams.set('state', p.state);
      if (!approve) {
        tx.set(path, { ...p, used: true });
        redirect.searchParams.set('error', 'access_denied');
        return redirect.href;
      }
      if (!uid) throw new InvalidGrantError('Sign in first.');
      const user = await tx.get<UserDoc>(`users/${uid}`);
      if (!user || user.deleting) throw new InvalidGrantError('Open KROK on your iPhone and connect Apple Health before authorizing an assistant.');
      const scopes = p.scopes.filter((s) => s !== 'health:routes:full' || fullRoutes);
      const grantId = randomUUID(), code = generateToken();
      const grant: Grant = { uid, clientId: p.clientId, provider: p.provider, scopes, generation: user.generation,
        epoch: user.oauthEpochs?.[p.provider] ?? 0, expires: this.now() + GRANT_MS, revoked: false };
      tx.set(`users/${uid}/oauthGrants/${grantId}`, grant);
      tx.set(`oauthCredentials/${hashToken(code)}`, { kind: 'code', uid, grantId, clientId: p.clientId,
        resource: p.resource, scopes, expires: this.now() + 60_000, challenge: p.challenge, redirectUri: p.redirectUri } satisfies Credential);
      tx.set(path, { ...p, used: true });
      tx.set(`users/${uid}`, { ...user, oauthProfileId: user.oauthProfileId ?? randomUUID(),
        connections: { ...user.connections, [p.provider]: { setUpAt: this.now(), lastUsedAt: this.now() } } });
      redirect.searchParams.set('code', code);
      return redirect.href;
    });
  }
  private credential(record: Credential | undefined, kind: Credential['kind'], clientId?: string): Credential {
    if (!record || record.kind !== kind || record.expires <= this.now() || (clientId && record.clientId !== clientId)) throw new InvalidGrantError('This credential is expired or invalid. Connect KROK again.');
    return record;
  }
  private async activeGrant(tx: Pick<OAuthTransaction, 'get'>, c: Credential): Promise<{ grant: Grant; user: UserDoc }> {
    const user = await tx.get<UserDoc>(`users/${c.uid}`);
    const grant = await tx.get<Grant>(`users/${c.uid}/oauthGrants/${c.grantId}`);
    if (!user || user.deleting || !grant || grant.revoked || grant.expires <= this.now() || grant.generation !== user.generation || grant.epoch !== (user.oauthEpochs?.[grant.provider] ?? 0)) throw new InvalidGrantError('KROK access was disconnected. Connect again to authorize access.');
    return { grant, user };
  }
  async challengeForAuthorizationCode(client: OAuthClientInformationFull, code: string): Promise<string> {
    if (!TOKEN_RE.test(code)) throw new InvalidGrantError('Invalid code.');
    const c = this.credential(await this.store.get<Credential>(`oauthCredentials/${hashToken(code)}`), 'code', client.client_id);
    if (c.used || !c.challenge) throw new InvalidGrantError('Code has already been used.');
    return c.challenge;
  }
  async exchangeAuthorizationCode(client: OAuthClientInformationFull, code: string, _verifier?: string, redirectUri?: string, resource?: URL): Promise<OAuthTokens> {
    this.audience(resource);
    return this.exchange(client, code, 'code', undefined, redirectUri);
  }
  async exchangeRefreshToken(client: OAuthClientInformationFull, token: string, scopes?: string[], resource?: URL): Promise<OAuthTokens> {
    this.audience(resource);
    return this.exchange(client, token, 'refresh', scopes);
  }
  private async exchange(client: OAuthClientInformationFull, token: string, kind: 'code' | 'refresh', requested?: string[], redirectUri?: string): Promise<OAuthTokens> {
    if (!TOKEN_RE.test(token)) throw new InvalidGrantError('Invalid credential.');
    const path = `oauthCredentials/${hashToken(token)}`;
    const result = await this.store.transaction(async (tx) => {
      const c = this.credential(await tx.get<Credential>(path), kind, client.client_id);
      const { grant } = await this.activeGrant(tx, c);
      if (c.used) {
        if (kind === 'refresh') tx.set(`users/${c.uid}/oauthGrants/${c.grantId}`, { ...grant, revoked: true });
        return undefined;
      }
      if (kind === 'code' && redirectUri !== c.redirectUri) throw new InvalidGrantError('Callback does not match the authorization request.');
      const scopes = requested ? this.scopes(requested) : c.scopes;
      if (scopes.some((s) => !c.scopes.includes(s))) throw new InvalidScopeError('Refresh cannot add permissions.');
      const access = generateToken(), refresh = generateToken();
      tx.set(path, { ...c, used: true });
      tx.set(`oauthCredentials/${hashToken(access)}`, { kind: 'access', uid: c.uid, clientId: c.clientId, grantId: c.grantId,
        resource: this.resource, scopes, expires: Math.min(this.now() + ACCESS_MS, grant.expires) } satisfies Credential);
      if (scopes.includes('offline_access')) tx.set(`oauthCredentials/${hashToken(refresh)}`, { kind: 'refresh', uid: c.uid,
        clientId: c.clientId, grantId: c.grantId, resource: this.resource, scopes, expires: grant.expires } satisfies Credential);
      return { access_token: access, token_type: 'Bearer', expires_in: Math.floor(Math.min(ACCESS_MS, grant.expires - this.now()) / 1000),
        scope: scopes.join(' '), ...(scopes.includes('offline_access') ? { refresh_token: refresh } : {}) };
    });
    if (!result) throw new InvalidGrantError('Credential already used; reconnect KROK.');
    return result;
  }
  async verifyAccessToken(token: string): Promise<AuthInfo> {
    try {
      if (!TOKEN_RE.test(token)) throw new InvalidGrantError('Invalid token.');
      const c = this.credential(await this.store.get<Credential>(`oauthCredentials/${hashToken(token)}`), 'access');
      const { grant, user } = await this.activeGrant(this.store, c);
      if (c.resource !== this.resource || c.used) throw new InvalidGrantError('Invalid token audience.');
      return { token, clientId: c.clientId, scopes: c.scopes, resource: new URL(c.resource), expiresAt: c.expires / 1000,
        extra: { uid: c.uid, provider: grant.provider, profileId: user.oauthProfileId } };
    } catch {
      throw new InvalidTokenError('KROK access expired or was disconnected. Reconnect to authorize access.');
    }
  }
  async revokeToken(client: OAuthClientInformationFull, request: OAuthTokenRevocationRequest): Promise<void> {
    if (!TOKEN_RE.test(request.token)) return;
    await this.store.transaction(async (tx) => {
      const c = await tx.get<Credential>(`oauthCredentials/${hashToken(request.token)}`);
      if (!c || c.clientId !== client.client_id || c.kind === 'code') return;
      const path = `users/${c.uid}/oauthGrants/${c.grantId}`;
      const grant = await tx.get<Grant>(path);
      if (grant) tx.set(path, { ...grant, revoked: true });
    });
  }
}

export const pkceChallenge = (verifier: string) => createHash('sha256').update(verifier).digest('base64url');
