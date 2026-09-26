import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createServer, type Server } from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { generateToken, hashToken, type TokenRecord } from '../../src/auth/tokens.js';
import { handleMcp, TOOL_NAMES, type McpDeps } from '../../src/mcp/server.js';
import { makeEnv, upload, type Env } from '../helpers/memory.js';

class MemAuth {
  tokens = new Map<string, TokenRecord>();
  hits = new Map<string, number>();
  log: { tool: string; ok: boolean; provider: string }[] = [];
  touched: string[] = [];
  limit = Infinity;
  async resolve(h: string) { return this.tokens.get(h) ?? null; }
  async hit(key: string) { const n = (this.hits.get(key) ?? 0) + 1; this.hits.set(key, n); return n <= this.limit; }
  async record(e: { tool: string; ok: boolean; provider: string }) { this.log.push(e); }
  async touch(uid: string, provider: string) { this.touched.push(`${uid}:${provider}`); }
}

let env: Env;
let auth: MemAuth;
let server: Server;
let base: string;
let token: string;

beforeAll(async () => {
  env = makeEnv(Date.now());
  auth = new MemAuth();
  token = generateToken();
  auth.tokens.set(hashToken(token), { uid: env.uid, provider: 'claude', createdAt: 0 });
  const today = Date.now();
  await upload(env, { type: 'HKQuantityTypeIdentifierHeartRate', mode: 'recent', window: { start: today - 5 * 86_400_000, end: today } }, [
    { k: 's', id: 'a', s: today - 3_600_000, e: today - 3_600_000, v: 61, u: 'count/min', src: 'Watch' },
  ]);
  const deps: McpDeps = { tokens: auth, limiter: auth, accessLog: auth, connections: auth, meta: env.meta, data: env.data };
  server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
    await handleMcp(Object.assign(req, { body }), res, deps);
  });
  await new Promise<void>((r) => server.listen(0, r));
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
afterAll(() => server.close());

async function connect(url: string) {
  const client = new Client({ name: 'test', version: '1' });
  await client.connect(new StreamableHTTPClientTransport(new URL(url)));
  return client;
}

describe('MCP endpoint', () => {
  it('lists tools and serves instructions', async () => {
    const client = await connect(`${base}/mcp/${token}`);
    const tools = await client.listTools();
    expect(tools.tools.map((t) => t.name).sort()).toEqual([...TOOL_NAMES].sort());
    expect(tools.tools.every((t) => t.annotations?.readOnlyHint)).toBe(true);
    expect(client.getInstructions()).toMatch(/read-only access/);
    await client.close();
  });

  it('runs a tool end to end and logs access without values', async () => {
    const client = await connect(`${base}/mcp/${token}`);
    const res = await client.callTool({ name: 'list_available_data', arguments: {} });
    const body = JSON.parse((res.content as { text: string }[])[0]!.text);
    expect(body.types[0]).toMatchObject({ name: 'HeartRate' });
    expect(auth.log.at(-1)).toEqual({ uid: env.uid, provider: 'claude', tool: 'list_available_data', ok: true });
    expect(auth.touched).toContain(`${env.uid}:claude`);
    await client.close();
  });

  it('returns tool errors as isError with a helpful message', async () => {
    const client = await connect(`${base}/mcp/${token}`);
    const res = await client.callTool({ name: 'summarize', arguments: { type: 'Nope', start_date: '2024-01-01', end_date: '2024-01-02', period: 'day' } });
    expect(res.isError).toBe(true);
    expect((res.content as { text: string }[])[0]!.text).toMatch(/list_available_data/);
    await client.close();
  });

  it('rejects unknown, malformed and revoked links', async () => {
    const post = (path: string) => fetch(`${base}${path}`, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: '{}' });
    expect((await post('/mcp/short')).status).toBe(404);
    expect((await post(`/mcp/${generateToken()}`)).status).toBe(404);
    expect((await post('/mcp/')).status).toBe(404);
    const r = await fetch(`${base}/mcp/${token}`);
    expect(r.status).toBe(405);
    expect(r.headers.get('cache-control')).toBe('no-store');
  });

  it('rate limits per link', async () => {
    auth.limit = 0;
    const r = await fetch(`${base}/mcp/${token}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    expect(r.status).toBe(429);
    auth.limit = Infinity;
  });

  it('stops working for users being deleted', async () => {
    env.meta.users.get(env.uid)!.deleting = true;
    const r = await fetch(`${base}/mcp/${token}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    expect(r.status).toBe(404);
    env.meta.users.get(env.uid)!.deleting = false;
  });
});
