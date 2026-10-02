// Loads the synthetic dataset (scripts/synthetic) through the real ingest code into in-memory stores and serves it
// over the real MCP endpoint, so tests and the local probe ask questions the way an AI client does.
process.env.HS_LOG ??= 'off';
import { gzipSync } from 'node:zlib';
import { createServer } from 'node:http';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { generateToken, hashToken } from '../../src/auth/tokens.js';
import { handleMcp, type McpDeps } from '../../src/mcp/server.js';
import { ingestObject } from '../../src/ingest/ingest.js';
import { makeEnv, type Env } from './memory.js';
// @ts-expect-error plain JS module shared with the monitoring scripts
import { batches, FULL_CATEGORIES, TZ } from '../../../../scripts/synthetic/data.mjs';

export async function startSynthetic() {
  const env = makeEnv(Date.now());
  const user = env.meta.users.get(env.uid)!;
  user.categories = FULL_CATEGORIES;
  user.tz = TZ;
  for (const lines of batches(true) as { batchId?: string; type?: string }[][]) {
    const path = `incoming/${env.uid}/${lines[0]!.batchId}.ndjson.gz`;
    await env.incoming.write(path, gzipSync(lines.map((l) => JSON.stringify(l)).join('\n')));
    const r = await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
    if (r !== 'published') throw new Error(`batch ${lines[0]!.type} was ${r}`);
  }
  return serve(env);
}

/** Serves an environment's data over the real MCP endpoint and returns a client that asks questions the way an AI does. */
export async function serve(env: Env) {
  const token = generateToken();
  const auth = {
    tokens: new Map([[hashToken(token), { uid: env.uid, provider: 'claude' as const, createdAt: 0 }]]),
    async resolve(h: string) { return this.tokens.get(h) ?? null; }, async hit() { return true; }, async record() {}, async touch() {},
  };
  const deps = { tokens: auth, limiter: auth, accessLog: auth, connections: auth, meta: env.meta, data: env.data } as unknown as McpDeps;
  const server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    await handleMcp(Object.assign(req, { body: chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined }), res, deps);
  });
  await new Promise<void>((r) => server.listen(0, r));
  const url = `http://127.0.0.1:${(server.address() as { port: number }).port}/mcp/${token}`;
  const client = new Client({ name: 'krok-local-probe', version: '1' });
  await client.connect(new StreamableHTTPClientTransport(new URL(url)));
  const call = async (tool: string, args: Record<string, unknown> = {}) => {
    const r = await client.callTool({ name: tool, arguments: args });
    const text = (r.content as { text?: string }[]).map((b) => b.text ?? '').join('\n');
    return { isError: !!r.isError, text, json: (() => { try { return JSON.parse(text); } catch { return null; } })() };
  };
  return { env, client, call, close: async () => { await client.close(); server.close(); } };
}

