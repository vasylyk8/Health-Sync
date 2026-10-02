// Calls KROK MCP tools exactly as an AI client would (JSON-RPC over HTTP) against the synthetic
// user's connector link and prints the decoded results. Lets a developer (or Claude Code) repeat
// any question an AI can ask about real data, on deterministic synthetic data, without the phone.
// Env: MCP_URL (secret link, never printed), CALLS (JSON array of {tool, args}; "tools/list" prints
// the tool catalogue), MAX_CHARS (per result, default 20000).
import { writeFileSync } from 'node:fs';

const url = process.env.MCP_URL;
if (!url) throw new Error('MCP_URL required');
const max = Number(process.env.MAX_CHARS || 20000);
const calls = JSON.parse(process.env.CALLS || '[]');
const log = [];
const out = (s) => { console.log(s); log.push(s); };

async function rpc(id, method, params) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
  });
  const text = await res.text();
  const body = text.trimStart().startsWith('event:') || text.trimStart().startsWith('data:')
    ? text.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).pop()
    : text;
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(body);
}

await rpc(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'krok-probe', version: '1' } });
let n = 2;
let failed = 0;
for (const c of calls) {
  if (c === 'tools/list' || c.tool === 'tools/list') {
    const r = await rpc(n++, 'tools/list');
    for (const t of r.result.tools) out(`${t.name}: ${(t.description || '').replace(/\s+/g, ' ').slice(0, 160)}`);
    continue;
  }
  const started = Date.now();
  out(`\n=== ${c.tool} ${JSON.stringify(c.args ?? {})}`);
  try {
    const r = await rpc(n++, 'tools/call', { name: c.tool, arguments: c.args ?? {} });
    if (r.error) { failed++; out(`ERROR ${JSON.stringify(r.error)}`); continue; }
    const text = (r.result?.content ?? []).map((b) => b.text ?? '').join('\n');
    if (r.result?.isError) failed++;
    out(`(${text.length} chars, ${Date.now() - started} ms${r.result?.isError ? ', isError' : ''})`);
    out(text.length > max ? `${text.slice(0, max)}\n… [${text.length - max} more chars; raise MAX_CHARS]` : text);
  } catch (e) {
    failed++;
    out(`ERROR ${e.message}`);
  }
}
writeFileSync('probe.log', log.join('\n'));
if (failed) { console.log(`\n${failed} call(s) failed`); process.exit(1); }
