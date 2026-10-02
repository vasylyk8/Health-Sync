// Runs KROK MCP tool calls against the synthetic dataset on this machine, through the real ingest code and the
// real MCP endpoint (HTTP + the MCP client an AI uses). No cloud, no phone: seconds per run.
//   npx tsx scripts/local-probe.ts '[{"tool":"get_daily_context","args":{"start_date":"2024-03-01","end_date":"2024-03-03"}}]'
//   npx tsx scripts/local-probe.ts tools            (tool catalogue)
// MAX_CHARS limits the printed size per result (default 6000).
import { startSynthetic } from '../test/helpers/synthetic.js';

if (process.argv[1]?.endsWith('local-probe.ts')) {
  const arg = process.argv[2] ?? 'tools';
  const max = Number(process.env.MAX_CHARS ?? 6000);
  const t0 = Date.now();
  const s = await startSynthetic();
  console.log(`(synthetic dataset loaded in ${Date.now() - t0} ms)`);
  if (arg === 'tools') {
    for (const t of (await s.client.listTools()).tools) console.log(`${t.name}: ${(t.description ?? '').replace(/\s+/g, ' ').slice(0, 140)}`);
  } else {
    for (const c of JSON.parse(arg) as { tool: string; args?: Record<string, unknown> }[]) {
      const t = Date.now();
      const r = await s.call(c.tool, c.args ?? {});
      console.log(`\n=== ${c.tool} ${JSON.stringify(c.args ?? {})}\n(${r.text.length} chars, ${Date.now() - t} ms${r.isError ? ', isError' : ''})`);
      console.log(r.text.length > max ? `${r.text.slice(0, max)}\n… [${r.text.length - max} more chars; raise MAX_CHARS]` : r.text);
    }
  }
  await s.close();
}
