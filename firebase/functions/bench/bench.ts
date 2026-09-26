// Local benchmark: a heavy 7-year Apple Watch history through the real ingestion and query code.
// Run: npx tsx bench/bench.ts   (reports Parquet bytes per user, ingest time, query latency)
import { gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { ingestObject } from '../src/ingest/ingest.js';
import { summarize, getSamples } from '../src/query/tools.js';
import { makeEnv, deps } from '../test/helpers/memory.js';

const YEARS = Number(process.env.YEARS ?? 7);
const HR_EVERY_MIN = Number(process.env.HR_EVERY_MIN ?? 5);
const PAGE = 5000;
const env = makeEnv(Date.UTC(2026, 8, 1));
const start = env.now - YEARS * 365 * 86_400_000;
let batches = 0, records = 0, uploadBytes = 0;
const t0 = Date.now();

async function send(type: string, recs: object[], extra: object = {}) {
  const batchId = randomUUID();
  const header = { kind: 'header', schema: 1, batchId, type, seq: ++batches, createdAt: env.now, mode: 'anchored', checkedAt: env.now, ...extra };
  const gz = gzipSync([header, ...recs].map((r) => JSON.stringify(r)).join('\n'));
  uploadBytes += gz.byteLength;
  records += recs.length;
  const path = `incoming/${env.uid}/${batchId}.ndjson.gz`;
  await env.incoming.write(path, gz);
  await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
}

// Heart rate every N minutes (the dominant data volume for Watch users).
let page: object[] = [];
for (let t = start, i = 0; t < env.now; t += HR_EVERY_MIN * 60_000, i++) {
  page.push({ k: 's', id: `${randomUUID()}`, s: t, e: t, v: 55 + (i % 60), u: 'count/min', src: 'Apple Watch', bid: 'com.apple.health.ABC', dev: 'Watch6,2' });
  if (page.length === PAGE) { await send('HKQuantityTypeIdentifierHeartRate', page); page = []; }
}
await send('HKQuantityTypeIdentifierHeartRate', page, { caughtUp: true });
// Steps: hourly samples + hourly merged stats.
page = [];
const stats: object[] = [];
for (let t = start; t < env.now; t += 3_600_000) {
  page.push({ k: 's', id: randomUUID(), s: t, e: t + 3_600_000, v: 400, u: 'count', src: 'iPhone' });
  stats.push({ k: 'h', s: t, e: t + 3_600_000, agg: 'sum', v: 400, u: 'count' });
  if (page.length === PAGE) { await send('HKQuantityTypeIdentifierStepCount', page); page = []; }
}
await send('HKQuantityTypeIdentifierStepCount', page, { caughtUp: true });
for (let i = 0; i < stats.length; i += 50_000) await send('HKQuantityTypeIdentifierStepCount', stats.slice(i, i + 50_000), { mode: 'stats', window: { start, end: env.now } });
const ingestMs = Date.now() - t0;

const parquetBytes = [...(await env.meta.listManifests(env.uid))].flatMap((m) => Object.values(m.files).flat()).reduce((n, f) => n + f.bytes, 0);
const d = deps(env, 'Europe/Berlin');
const time = async (label: string, fn: () => Promise<unknown>) => {
  const s = Date.now();
  try { await fn(); console.log(`${label}: ${Date.now() - s} ms`); } catch (e) { console.log(`${label}: ${(e as Error).message} (${Date.now() - s} ms)`); }
};
console.log(`records ${records.toLocaleString()} in ${batches} batches; upload ${(uploadBytes / 1e6).toFixed(1)} MB gz; ingest ${(ingestMs / 1000).toFixed(1)} s`);
console.log(`stored Parquet: ${(parquetBytes / 1e6).toFixed(1)} MB per user`);
await time('HR monthly avg over all years', () => summarize(d, { type: 'HeartRate', start_date: '2019-09-01', end_date: '2026-08-31', period: 'month', stat: 'avg' }));
await time('HR daily max, 1 year', () => summarize(d, { type: 'HeartRate', start_date: '2025-09-01', end_date: '2026-08-31', period: 'day', stat: 'max' }));
await time('Steps weekly sum all years (merged)', () => summarize(d, { type: 'StepCount', start_date: '2019-09-01', end_date: '2026-08-31', period: 'week' }));
await time('HR samples, 1 day', () => getSamples(d, { type: 'HeartRate', start_date: '2026-08-01', end_date: '2026-08-01' }));
console.log(`peak RSS ${(process.memoryUsage().rss / 1e6).toFixed(0)} MB`);
