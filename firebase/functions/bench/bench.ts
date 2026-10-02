// Cost and speed of the workouts-only design with realistic raw data.
//   npx tsx bench/bench.ts [workouts]   (default 500)
// Each workout is 90 minutes: heart rate every 5 s, GPS route at 1 Hz (8 columns), running power at 1 Hz,
// speed every 5 s, distance every 10 s, steps every 10 s, energy every 30 s (about 14,000 points).
import { gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { ingestObject } from '../src/ingest/ingest.js';
import { getWorkouts, getWorkoutSeries, getWorkoutRoute, workoutBestEfforts, workoutHrZones, workoutSplits } from '../src/query/workouts.js';
import { deps, makeEnv } from '../test/helpers/memory.js';

const N = Number(process.argv[2] ?? 500);
// NOISE=1: sensor-like randomness (real data compresses far worse than smooth formulas).
const noise = process.env.NOISE === '1';
const r = (amp: number) => (noise ? (Math.random() - 0.5) * amp : 0);
// ROUND=1: round values like the app now does before encoding (GPS 1e-5 deg, altitude/speed 0.1, other values 4 decimals).
const roundValues = process.env.ROUND === '1';
const SCALE_BY_COL: Record<string, number> = { lat: 1e5, lon: 1e5, alt: 10, spd: 10, crs: 1, ha: 1, va: 1, v: 1e4 };
const rv = (col: string, v: number) => (roundValues ? Math.round(v * SCALE_BY_COL[col]!) / SCALE_BY_COL[col]! : v);
const env = makeEnv(Date.UTC(2026, 8, 1, 12));
const gen = env.now;
const DUR = 5400;
const stream = (wid: string, st: string, step: number, s: number, cols: Record<string, (i: number) => number>, unit?: string) => {
  const n = Math.floor(DUR / step);
  return { k: 'ws', wid, st, gen, ...(unit ? { u: unit } : {}), t: Array.from({ length: n }, (_, i) => s + i * step * 1000), ...Object.fromEntries(Object.entries(cols).map(([c, f]) => [c, Array.from({ length: n }, (_, i) => rv(c, f(i)))])) };
};
const header = (type: string, mode: string, extra: object = {}) => ({ kind: 'header', schema: 2, batchId: randomUUID(), type, seq: 1, createdAt: env.now, mode, checkedAt: env.now, ...extra });
async function send(lines: object[]) {
  const h = lines[0] as { batchId: string };
  const gz = gzipSync(lines.map((l) => JSON.stringify(l)).join('\n'));
  const path = `incoming/${env.uid}/${h.batchId}.ndjson.gz`;
  await env.incoming.write(path, gz);
  const r = await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
  if (r !== 'published') throw new Error(`batch ${r}`);
  return gz.byteLength;
}

let uploadBytes = 0;
let points = 0;
const ids: string[] = [];
const t0 = Date.now();
const summaries: object[] = [];
const streamBatches: object[][] = [];
for (let i = 0; i < N; i++) {
  const wid = `bench-${String(i).padStart(5, '0')}-${randomUUID().slice(0, 8)}`;
  ids.push(wid);
  const s = Date.UTC(2020, 0, 1, 7) + i * 3.3 * 86_400_000;
  summaries.push({ k: 'w', id: wid, s, e: s + DUR * 1000, act: 37, actName: 'Running', dur: DUR, en: 900, dist: 15000, hrAvg: 150, hrMax: 172, stats: { HeartRate: { avg: 150, min: 100, max: 172, u: 'count/min' } } });
  const hr = stream(wid, 'HeartRate', 5, s, { v: (i2) => Math.round(130 + (i2 % 40) + r(8)) }, 'count/min');
  const route = stream(wid, 'route', 1, s, {
    lat: (i2) => 50 + (i2 * 2.8) / 111_194.93 + r(3e-5), lon: () => 30 + r(3e-5), alt: (i2) => 100 + Math.sin(i2 / 300) * 20 + r(2), spd: () => 2.8 + r(0.6), crs: () => 180 + r(60), ha: () => 5 + r(4), va: () => 3 + r(2),
  });
  const power = stream(wid, 'RunningPower', 1, s, { v: (i2) => Math.round(200 + (i2 % 60) + r(30)) }, 'W');
  const speed = stream(wid, 'RunningSpeed', 5, s, { v: () => 2.8 + r(0.5) }, 'm/s');
  const dist = stream(wid, 'DistanceWalkingRunning', 10, s, { v: () => 28 + r(6) }, 'm');
  const steps = stream(wid, 'StepCount', 10, s, { v: () => 27 }, 'count');
  const energy = stream(wid, 'ActiveEnergyBurned', 30, s, { v: () => 5 }, 'kcal');
  const streams = [hr, route, power, speed, dist, steps, energy] as { t: number[] }[];
  points += streams.reduce((n, x) => n + x.t.length, 0);
  streamBatches.push([header('_wstream', 'workoutdata'), ...streams, { k: 'wd', wid, gen, expected: Object.fromEntries((streams as unknown as { st: string; t: number[] }[]).map((x) => [x.st, x.t.length])) }]);
}
// Summaries in pages of 200, like the app.
for (let i = 0; i < summaries.length; i += 200) uploadBytes += await send([header('HKWorkoutTypeIdentifier', 'anchored', { caughtUp: i + 200 >= summaries.length }), ...summaries.slice(i, i + 200)]);
const tSummaries = Date.now() - t0;
for (const b of streamBatches) uploadBytes += await send(b);
const tIngest = Date.now() - t0;

let stored = 0;
for (const p of env.data.paths) stored += statSync(join(env.data.root, p)).size;
const mb = (b: number) => (b / 1024 / 1024).toFixed(1);
const byStream: Record<string, number> = {};
for (const p of env.data.paths) {
  const m = /\/wstream\/[^/]+\/([^/]+)\//.exec(p);
  const key = m ? m[1]! : p.includes('/HKWorkoutTypeIdentifier/') ? 'summaries' : 'other';
  byStream[key] = (byStream[key] ?? 0) + statSync(join(env.data.root, p)).size;
}
console.log(`${N} workouts, ${points.toLocaleString()} raw points`);
console.log(`upload (gzipped NDJSON): ${mb(uploadBytes)} MB total, ${(uploadBytes / N / 1024).toFixed(0)} KB per workout`);
console.log(`stored (Parquet):        ${mb(stored)} MB total, ${(stored / N / 1024).toFixed(0)} KB per workout`);
console.log('stored KB per workout by stream: ' + Object.entries(byStream).map(([k, b]) => `${k} ${(b / N / 1024).toFixed(1)}`).join(', '));
console.log(`ingest time: summaries ${tSummaries} ms, streams ${tIngest - tSummaries} ms (${((tIngest - tSummaries) / N).toFixed(0)} ms per workout, local, excluding network/Firestore latency)`);

const q = deps(env, 'UTC');
const mid = ids[Math.floor(N / 2)]!;
async function time(label: string, fn: () => Promise<unknown>) {
  const s = Date.now();
  const r = (await fn()) as { returned?: number };
  console.log(`${label.padEnd(44)} ${String(Date.now() - s).padStart(6)} ms${r.returned ? `  (${r.returned} points)` : ''}`);
}
console.log(`peak memory: ${(process.memoryUsage().rss / 1024 / 1024).toFixed(0)} MB (whole process, incl. test data)`);
await time('list all workouts of a year', () => getWorkouts(q, { start_date: '2020-01-01', end_date: '2020-12-31' }));
await time('list 500 workouts (all history)', () => getWorkouts(q, { start_date: '2020-01-01', end_date: '2026-12-31', limit: 300 }).catch(() => ({})));
await time('one workout: HR series, 300 points', () => getWorkoutSeries(q, { workout_id: mid, stream: 'HeartRate' }));
await time('one workout: power series (5400 pts), 300', () => getWorkoutSeries(q, { workout_id: mid, stream: 'RunningPower' }));
await time('one workout: route, 300 points', () => getWorkoutRoute(q, { workout_id: mid }));
await time('one workout: HR zones', () => workoutHrZones(q, { workout_id: mid, max_hr: 190 }));
await time('one workout: splits per km', () => workoutSplits(q, { workout_id: mid }));
await time('one workout: best efforts', () => workoutBestEfforts(q, { workout_id: mid }));
