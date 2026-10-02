import express, { type Request } from 'express';
import { mcpAuthRouter, createOAuthMetadata } from '@modelcontextprotocol/sdk/server/auth/router.js';
import { OAuthError } from '@modelcontextprotocol/sdk/server/auth/errors.js';
import { KrokOAuth, OAUTH_SCOPES, CONSENT_COOKIE } from './oauth.js';
import type { RateLimiter } from './tokens.js';

export interface LoginIdentity { uid: string; apple: boolean; reviewer: boolean }
const cookie = (req: Request): string => {
  const found = String(req.headers.cookie ?? '').split(';').map((s) => s.trim()).find((s) => s.startsWith(`${CONSENT_COOKIE}=`));
  return found?.slice(CONSENT_COOKIE.length + 1) ?? '';
};

export function createOAuthRouter(provider: KrokOAuth, verifyLogin: (token: string) => Promise<LoginIdentity>, limiter: RateLimiter) {
  const app = express();
  app.disable('x-powered-by');
  app.use((_req, res, next) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    next();
  });
  app.use(async (req, res, next) => {
    const ip = req.socket.remoteAddress ?? 'unknown';
    if (!await limiter.hit(`oauth_${ip.replace(/[^a-zA-Z0-9]/g, '_')}`, 100, 60_000)) {
      res.setHeader('Retry-After', '60');
      res.status(429).json({ error: 'temporarily_unavailable', error_description: 'Too many requests. Try again in a minute.' });
      return;
    }
    next();
  });
  // Firebase Functions already parses the body. These also support standalone test servers.
  app.use(express.json({ limit: '8kb' }));
  app.use(express.urlencoded({ extended: false, limit: '8kb' }));
  app.get('/oauth/request/:id', async (req, res) => {
    try { res.json(await provider.describeRequest(String(req.params.id), cookie(req))); }
    catch (error) { res.status(400).json({ error: 'invalid_request', message: error instanceof OAuthError ? error.message : 'Start again in your assistant.' }); }
  });
  app.post('/oauth/consent', async (req, res) => {
    if (req.headers.origin !== new URL(provider.issuer).origin) {
      res.status(403).json({ error: 'access_denied', message: 'Open this page from your assistant to connect.' });
      return;
    }
    try {
      const body = req.body as Record<string, unknown>;
      if (typeof body.request !== 'string' || typeof body.approve !== 'boolean' || (body.fullRoutes !== undefined && typeof body.fullRoutes !== 'boolean')) {
        res.status(400).json({ error: 'invalid_request', message: 'Invalid consent request.' }); return;
      }
      let uid: string | undefined;
      if (body.approve) {
        const bearer = /^Bearer (.+)$/.exec(String(req.headers.authorization ?? ''))?.[1];
        if (!bearer) { res.status(401).json({ error: 'access_denied', message: 'Sign in with Apple first.' }); return; }
        const identity = await verifyLogin(bearer);
        if (!identity.apple && !identity.reviewer) { res.status(403).json({ error: 'access_denied', message: 'Use Sign in with Apple to connect your KROK account.' }); return; }
        uid = identity.uid;
      }
      const redirect = await provider.finishConsent(body.request, cookie(req), uid, body.approve, body.fullRoutes === true);
      res.clearCookie(CONSENT_COOKIE, { httpOnly: true, secure: true, sameSite: 'lax', path: '/' });
      res.json({ redirect });
    } catch (error) {
      res.status(400).json({ error: 'invalid_request', message: error instanceof OAuthError ? error.message : 'Your login expired. Sign in again and retry.' });
    }
  });
  // The SDK advertises confidential-client auth methods too. KROK registers only public PKCE clients.
  const metadata = { ...createOAuthMetadata({ provider, issuerUrl: new URL(provider.issuer), scopesSupported: OAUTH_SCOPES }),
    token_endpoint_auth_methods_supported: ['none'], revocation_endpoint_auth_methods_supported: ['none'] };
  app.get('/.well-known/oauth-authorization-server', (_req, res) => res.json(metadata));
  app.get('/.well-known/oauth-protected-resource', (_req, res) => res.json({ resource: provider.resource,
    authorization_servers: [provider.issuer], scopes_supported: OAUTH_SCOPES,
    resource_documentation: `${provider.issuer}mcp-docs`, resource_policy_uri: `${provider.issuer}privacy` }));
  app.use(mcpAuthRouter({ provider, issuerUrl: new URL(provider.issuer), resourceServerUrl: new URL(provider.resource),
    serviceDocumentationUrl: new URL(`${provider.issuer}mcp-docs`), scopesSupported: OAUTH_SCOPES,
    resourceName: 'KROK Apple Health', clientRegistrationOptions: { clientSecretExpirySeconds: 0 } }));
  app.use((_req, res) => res.status(404).json({ error: 'not_found' }));
  return app;
}
