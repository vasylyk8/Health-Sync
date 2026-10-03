import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Firestore } from 'firebase-admin/firestore';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { z } from 'zod';
import { TOKEN_RE, hashToken, type RateLimiter } from '../auth/tokens.js';
import { ANALYTICS_INSTRUCTIONS, METRIC_DEFINITIONS } from './contract.js';
import { activationFunnel, AnalyticsQueryError, metricDefinition, reliability, retention, usageOverview } from './query.js';
import { log } from '../log.js';

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).describe('UTC date, YYYY-MM-DD');
const output = z.object({}).passthrough();

function result(value: unknown) {
  return { structuredContent: value as Record<string, unknown>, content: [{ type: 'text' as const, text: JSON.stringify(value) }] };
}

function buildServer(db: Firestore): McpServer {
  const server = new McpServer({ name: 'krok-analytics', version: '1.0.0' }, { instructions: ANALYTICS_INSTRUCTIONS });
  const register = (name: string, title: string, description: string, inputSchema: z.ZodRawShape, run: (a: Record<string, unknown>) => Promise<unknown> | unknown) => {
    server.registerTool(name, { title, description, inputSchema, outputSchema: output,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }, _meta: { securitySchemes: [{ type: 'noauth' }] } },
    (async (args: Record<string, unknown>) => {
      try { return result(await run(args ?? {})); }
      catch (err) {
        const known = err instanceof AnalyticsQueryError;
        if (!known) log.error('analytics tool failed', { tool: name, code: (err as { code?: string }).code ?? 'internal' });
        const body = { error: known ? err.code : 'internal', message: known ? err.message : 'Analytics could not be read. Try a shorter period.' };
        return { isError: true, content: [{ type: 'text' as const, text: JSON.stringify(body) }] };
      }
    }) as never);
  };
  register('usage_overview', 'Usage overview', 'Activated users, active user-days, successful and failed tool calls, success rate, and provider mix for up to 90 days.',
    { start_date: date, end_date: date }, (a) => usageOverview(db, String(a.start_date), String(a.end_date)));
  register('activation_funnel', 'Activation funnel', 'First-open cohort progress through Health connection, Apple linking, first usable sync, assistant connection, and activation. Optional app-version cohort filter.',
    { start_date: date, end_date: date, app_version: z.string().max(32).optional() },
    (a) => activationFunnel(db, String(a.start_date), String(a.end_date), a.app_version as string | undefined));
  register('retention', 'W1 and W4 retention', 'Query retention for activation cohorts. Immature cohorts are excluded from denominators.',
    { start_date: date, end_date: date }, (a) => retention(db, String(a.start_date), String(a.end_date)));
  register('reliability', 'Sync and MCP reliability', 'Sync and MCP success rates and mean wall-clock duration. Contains no Health values or tool arguments.',
    { start_date: date, end_date: date, app_version: z.string().max(32).optional() }, (a) => reliability(db, String(a.start_date), String(a.end_date), a.app_version as string | undefined));
  register('metric_definition', 'Define a metric', 'Exact numerator, denominator, and interpretation for one KROK product metric.',
    { name: z.enum(Object.keys(METRIC_DEFINITIONS) as [keyof typeof METRIC_DEFINITIONS, ...(keyof typeof METRIC_DEFINITIONS)[]]) },
    (a) => metricDefinition(a.name as keyof typeof METRIC_DEFINITIONS));
  return server;
}

function send(res: ServerResponse, status: number, body: object) {
  res.statusCode = status; res.setHeader('Content-Type', 'application/json'); res.setHeader('Cache-Control', 'no-store'); res.end(JSON.stringify(body));
}

const invalidHits = new Map<string, { window: number; count: number }>();
function invalidAllowed(ip: string, now = Date.now()): boolean {
  const window = Math.floor(now / 60_000), current = invalidHits.get(ip);
  if (!current || current.window !== window) {
    if (invalidHits.size > 10_000) invalidHits.clear();
    invalidHits.set(ip, { window, count: 1 }); return true;
  }
  current.count++; return current.count <= 30;
}

export async function handleAnalyticsMcp(req: IncomingMessage & { body?: unknown }, res: ServerResponse, deps: { db: Firestore; limiter: RateLimiter }): Promise<void> {
  res.setHeader('Cache-Control', 'no-store');
  const match = /^\/analytics-mcp\/([^/?#]+)\/?(?:[?#].*)?$/.exec(req.url ?? '');
  const token = match?.[1] ?? '';
  const ip = (String(req.headers['x-forwarded-for'] ?? '').split(',')[0] || req.socket.remoteAddress || '?').trim();
  if (!TOKEN_RE.test(token)) {
    if (!invalidAllowed(ip)) return send(res, 429, { error: 'too_many_requests' });
    return send(res, 404, { error: 'not_found', message: 'This KROK Analytics link is not valid.' });
  }
  const hash = hashToken(token);
  const snap = await deps.db.collection('analyticsTokens').doc(hash).get();
  if (!snap.exists || snap.get('revokedAt')) {
    if (!invalidAllowed(ip)) return send(res, 429, { error: 'too_many_requests' });
    return send(res, 404, { error: 'not_found', message: 'This KROK Analytics link is not valid.' });
  }
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return send(res, 405, { error: 'method_not_allowed' }); }
  if (!await deps.limiter.hit(`analytics_mcp_${hash.slice(0, 32)}`, 60, 60_000)) {
    res.setHeader('Retry-After', '60'); return send(res, 429, { error: 'too_many_requests' });
  }
  const server = buildServer(deps.db);
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  res.on('close', () => { void transport.close(); void server.close(); });
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
}
