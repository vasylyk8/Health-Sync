// Weekly real-AI evaluation: Claude and ChatGPT answer fixed questions about the synthetic user
// through the live connector; each answer must contain the known correct number.
// Env: MCP_URL (synthetic user's link), ANTHROPIC_API_KEY, OPENAI_API_KEY.
import { evalCases } from '../synthetic/data.mjs';
import { askClaude } from './claude.mjs';
import { askOpenAI } from './openai.mjs';

const url = process.env.MCP_URL;
if (!url) throw new Error('MCP_URL required');
const analyticsUrl = process.env.ANALYTICS_MCP_URL;

/** True if the answer contains the expected number (commas/spaces ignored, decimals ±0.1). */
export function containsNumber(text, expected) {
  const nums = (text.replace(/(\d)[,\s](?=\d{3}\b)/g, '$1').match(/-?\d+(?:\.\d+)?/g) ?? []).map(Number);
  return nums.some((n) => Math.abs(n - expected) <= (Number.isInteger(expected) ? 0 : 0.1) + 1e-9);
}

const providers = [
  ['claude', askClaude, !!process.env.ANTHROPIC_API_KEY],
  ['chatgpt', askOpenAI, !!process.env.OPENAI_API_KEY],
];
let failures = 0;
const rows = [];
for (const [name, ask, enabled] of providers) {
  if (!enabled) {
    console.log(`skip ${name}: no API key`);
    continue;
  }
  for (const c of evalCases()) {
    let ok = false, detail = '';
    try {
      const r = await ask(c.q, url);
      ok = c.expect.every((e) => containsNumber(r.text, e));
      detail = `${(r.toolCalls ?? []).join(',')} → ${r.text.replace(/\s+/g, ' ').slice(0, 160)}`;
    } catch (err) {
      detail = `error: ${err.message}`;
    }
    if (!ok) failures++;
    rows.push(`${ok ? 'PASS' : 'FAIL'} [${name}] ${c.q} (expected ${c.expect.join(', ')})\n      ${detail}`);
  }
}
if (analyticsUrl) {
  const end = new Date().toISOString().slice(0, 10);
  const start = new Date(Date.now() - 6 * 86_400_000).toISOString().slice(0, 10);
  const analyticsCases = [
    { q: 'Define KROK activation precisely and state its main observability limitation.', tool: 'metric_definition' },
    { q: `Summarize KROK product usage from ${start} through ${end} UTC. State the period, denominator caveat and data freshness.`, tool: 'usage_overview' },
  ];
  for (const [name, ask, enabled] of providers) {
    if (!enabled) continue;
    for (const c of analyticsCases) {
      let ok = false, detail = '';
      try {
        const r = await ask(c.q, analyticsUrl, { name: 'krok-analytics', system: 'Use only the aggregate KROK Analytics tools. State periods, UTC timezone, denominators, freshness and small-sample limitations. Never claim access to a user or Health data.' });
        ok = (r.toolCalls ?? []).includes(c.tool) && r.text.length > 20;
        detail = `${(r.toolCalls ?? []).join(',')} → ${r.text.replace(/\s+/g, ' ').slice(0, 160)}`;
      } catch (err) { detail = `error: ${err.message}`; }
      if (!ok) failures++;
      rows.push(`${ok ? 'PASS' : 'FAIL'} [${name} analytics] ${c.q} (expected tool ${c.tool})\n      ${detail}`);
    }
  }
}
console.log(rows.join('\n'));
const summary = `${rows.length - failures}/${rows.length} passed`;
console.log(summary);
if (process.env.GITHUB_STEP_SUMMARY) {
  const { appendFileSync } = await import('node:fs');
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, `## Real-AI evals: ${summary}\n\n\`\`\`\n${rows.join('\n')}\n\`\`\`\n`);
}
process.exit(failures ? 1 : 0);
