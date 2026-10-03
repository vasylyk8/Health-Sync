import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { generateToken, hashToken } from '../../src/auth/tokens.js';
import { handleAnalyticsMcp } from '../../src/analytics/mcp.js';
import type { DailyRollup } from '../../src/analytics/rollup.js';

const token = generateToken();
const today = '2026-09-01';
const row: DailyRollup = {
  date: today, generatedAt: Date.UTC(2026, 8, 1, 13),
  cohort: { steps: { first_opened: 10, health_connect_started: 8, health_connected: 7, apple_linked: 6, first_sync_ready: 6, assistant_connected: 5, activated: 4 }, byProvider: {}, byAppVersion: {} },
  usage: { activeUsers: 4, calls: 12, successfulCalls: 11, failedCalls: 1, byProvider: { claude: { activeUsers: 4, calls: 12 } } },
  reliability: { syncAttempts: 9, syncSuccesses: 8, syncFailures: 1, syncDurationCount: 9, syncDurationSumMs: 9000, syncDurationBuckets: [0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0], mcpDurationCount: 12, mcpDurationSumMs: 1200, mcpDurationBuckets: [12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], syncByAppVersion: { '1.0.0': { attempts: 5, successes: 4, durationCount: 5, durationSumMs: 5000, durationBuckets: [0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0] } } },
  retention: { activated: 4, w1Eligible: 2, w1Retained: 1, w4Eligible: 0, w4Retained: 0 },
};

class FakeDb {
  collection(name: string) {
    if (name === 'analyticsTokens') return { doc: (id: string) => ({ get: async () => ({ exists: id === hashToken(token), get: () => undefined }) }) };
    if (name === 'analyticsRollups') {
      const chain = { where: () => chain, orderBy: () => chain, get: async () => ({ empty: false, docs: [{ data: () => row }] }) };
      return chain;
    }
    throw new Error(`unexpected collection ${name}`);
  }
}

class Limiter { limit = true; async hit() { return this.limit; } }

let server: Server, base: string, limiter: Limiter;

beforeAll(async () => {
  limiter = new Limiter();
  server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
    await handleAnalyticsMcp(Object.assign(req, { body }), res, { db: new FakeDb() as never, limiter });
  });
  await new Promise<void>((resolve) => server.listen(0, resolve));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
afterAll(() => server.close());

async function connect() {
  const client = new Client({ name: 'test', version: '1' });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/analytics-mcp/${token}`)));
  return client;
}

describe('KROK Analytics MCP', () => {
  it('is a separate aggregate-only read-only connector', async () => {
    const client = await connect();
    const tools = await client.listTools();
    expect(tools.tools.map((t) => t.name).sort()).toEqual(['activation_funnel', 'metric_definition', 'reliability', 'retention', 'usage_overview']);
    expect(tools.tools.every((t) => t.annotations?.readOnlyHint === true)).toBe(true);
    expect(client.getInstructions()).toMatch(/aggregate product-usage/);
    expect(client.getInstructions()).toMatch(/never contains Apple Health values/);
    await client.close();
  });

  it('answers a usage question without identifiers or raw rows', async () => {
    const client = await connect();
    const res = await client.callTool({ name: 'usage_overview', arguments: { start_date: today, end_date: today } });
    expect(res.isError).not.toBe(true);
    const text = (res.content as { text: string }[])[0]!.text;
    const body = JSON.parse(text);
    expect(body).toMatchObject({ activated_users: 4, active_user_days: 4, successful_tool_calls: 11, failed_tool_calls: 1 });
    expect(text).not.toMatch(/uid|email|route|workout|u1/);
    await client.close();
  });

  it('filters sync reliability by app version and returns bounded p95 latency', async () => {
    const client = await connect();
    const res = await client.callTool({ name: 'reliability', arguments: { start_date: today, end_date: today, app_version: '1.0.0' } });
    const body = JSON.parse((res.content as { text: string }[])[0]!.text);
    expect(body.sync).toMatchObject({ attempts: 5, successes: 4, failures: 1, p95_duration_upper_bound_ms: 1000 });
    expect(body.notes.join(' ')).toMatch(/filter applies to sync only/);
    await client.close();
  });

  it('rejects customer, malformed, revoked, and rate-limited links with no-store', async () => {
    const post = (path: string) => fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    expect((await post('/analytics-mcp/short')).status).toBe(404);
    expect((await post(`/analytics-mcp/${generateToken()}`)).status).toBe(404);
    const get = await fetch(`${base}/analytics-mcp/${token}`);
    expect(get.status).toBe(405);
    expect(get.headers.get('cache-control')).toBe('no-store');
    limiter.limit = false;
    expect((await post(`/analytics-mcp/${token}`)).status).toBe(429);
    limiter.limit = true;
  });
});
