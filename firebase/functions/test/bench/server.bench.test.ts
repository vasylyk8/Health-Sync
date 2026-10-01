/**
 * Server speed bench (not part of `npm test`): `npx vitest run test/bench`.
 * Phone-shaped data from the iPhone speed test; storage and Firestore calls get a fixed latency
 * (BENCH_BLOB_MS, BENCH_META_MS) so local timings approximate the cloud.
 */
import { describe, it } from 'vitest';
import { randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { DirBlobs, MemoryMeta } from '../helpers/memory.js';
import { ingestObject } from '../../src/ingest/ingest.js';
import { getWorkout, getWorkouts, getWorkoutRoute, getWorkoutSeries, workoutHrZones, workoutSplits } from '../../src/query/workouts.js';

const BLOB_MS = Number(process.env.BENCH_BLOB_MS ?? 40);
const META_MS = Number(process.env.BENCH_META_MS ?? 30);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const counts: Record<string, number> = {};
const count = (k: string) => { counts[k] = (counts[k] ?? 0) + 1; };

class SlowBlobs extends DirBlobs {
  override async read(p: string) { count('blob.read'); await sleep(BLOB_MS); return super.read(p); }
  override async write(p: string, d: Buffer) { count('blob.write'); await sleep(BLOB_MS); return super.write(p, d); }
  override async download(p: string, l: string) { count('blob.download'); await sleep(BLOB_MS); return super.download(p, l); }
  override async delete(p: string) { count('blob.delete'); await sleep(BLOB_MS); return super.delete(p); }
}
class SlowMeta extends MemoryMeta {
  override async getUser(u: string) { count('meta.getUser'); await sleep(META_MS); return super.getUser(u); }
  override async getManifest(u: string, t: string) { count('meta.getManifest'); await sleep(META_MS); return super.getManifest(u, t); }
  override async batchState(u: string, b: string) { count('meta.batchState'); await sleep(META_MS); return super.batchState(u, b); }
  override async markBatch(...a: Parameters<MemoryMeta['markBatch']>) { count('meta.markBatch'); await sleep(META_MS); return super.markBatch(...a); }
  override async publish(a: Parameters<MemoryMeta['publish']>[0]) { count('meta.publish'); await sleep(META_MS * 3); return super.publish(a); }
  override async getWorkoutData(u: string, w: string) { count('meta.getWorkoutData'); await sleep(META_MS); return super.getWorkoutData(u, w); }
  override async publishWorkoutData(a: Parameters<MemoryMeta['publishWorkoutData']>[0]) { count('meta.publishWorkoutData'); await sleep(META_MS * 3); return super.publishWorkoutData(a); }
}

const NOW = Date.UTC(2026, 9, 1);
const uid = 'bench';
const env = { incoming: new SlowBlobs(), data: new SlowBlobs(), meta: new SlowMeta() };
env.meta.addUser(uid);
const ingestDeps = { ...env, now: () => NOW };
const q = { uid, meta: env.meta, data: env.data, now: () => NOW, tz: 'UTC' };
let seq = 0;

async function ingest(type: string, mode: string, records: object[], extra: object = {}) {
  const batchId = randomUUID();
  const header = { kind: 'header', schema: type === '_wstream' ? 2 : 1, batchId, type, seq: ++seq, tz: 'UTC', createdAt: NOW, mode, checkedAt: NOW, ...extra };
  const gz = gzipSync([header, ...records].map((r) => JSON.stringify(r)).join('\n'));
  const path = `incoming/${uid}/${batchId}.ndjson.gz`;
  await env.incoming.write(path, gz);
  return { gz: gz.length, result: await ingestObject(path, ingestDeps) };
}

/** A recent Apple Watch run as measured on the phone: ~3,400 samples in 6 types, 1,100 HR points, 2,900 route points. */
function workoutStreams(wid: string, s: number, gen: number) {
  const n = (k: number) => Array.from({ length: k }, (_, i) => Math.round(s + i * 1000 * (1800 / k)));
  const stream = (st: string, u: string, k: number, v: (i: number) => number) => ({ k: 'ws', wid, st, gen, u, t: n(k), v: n(k).map((_, i) => v(i)) });
  const rt = n(2900);
  return [
    stream('HeartRate', 'count/min', 1100, (i) => 120 + (i % 40)),
    stream('ActiveEnergyBurned', 'kcal', 1050, () => 0.123456),
    stream('BasalEnergyBurned', 'kcal', 970, () => 0.0234),
    stream('DistanceWalkingRunning', 'm', 690, (i) => 7.1 + (i % 7) * 0.01),
    stream('StepCount', 'count', 530, (i) => 14 + (i % 3)),
    stream('RunningSpeed', 'm/s', 510, (i) => 3.1 + (i % 9) * 0.013),
    {
      k: 'ws', wid, st: 'route', gen, t: rt,
      lat: rt.map((_, i) => 50.4501234 + i * 0.0000271), lon: rt.map((_, i) => 30.5234123 + i * 0.0000193),
      alt: rt.map((_, i) => 180.2 + Math.sin(i / 50) * 9), spd: rt.map((_, i) => 3.2 + (i % 11) * 0.01),
      crs: rt.map((_, i) => (i * 1.7) % 360), ha: rt.map(() => 3.9), va: rt.map(() => 2.1),
    },
    { k: 'wd', wid, gen, expected: { HeartRate: 1100, ActiveEnergyBurned: 1050, BasalEnergyBurned: 970, DistanceWalkingRunning: 690, StepCount: 530, RunningSpeed: 510, route: 2900 } },
  ];
}

const time = async <T>(label: string, fn: () => Promise<T>) => {
  for (const k of Object.keys(counts)) delete counts[k];
  const t0 = performance.now();
  const r = await fn();
  console.log(`BENCH ${label}: ${(performance.now() - t0).toFixed(0)} ms · ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(', ')}`);
  return r;
};

describe('server speed', () => {
  it('ingest and queries at phone scale', async () => {
    // 3,337 workout summaries over 13 years, uploaded in pages of 200 like the phone.
    const wids: string[] = [];
    const summaries = Array.from({ length: 3337 }, (_, i) => {
      const id = randomUUID().toUpperCase();
      wids.push(id);
      const s = Math.round(NOW - i * 1.42 * 86_400_000);
      return { k: 'w', id, s, e: s + 1_800_000, act: 37, actName: 'Running', dur: 1800, en: 310, dist: 6000, src: 'Apple Watch', bid: 'com.apple.health', dev: 'Watch7,1', stats: { HeartRate: { avg: 140, u: 'count/min' } } };
    });
    await time('summaries: 17 history pages of 200', async () => {
      for (let i = 0; i < summaries.length; i += 200) await ingest('HKWorkoutTypeIdentifier', 'anchored', summaries.slice(i, i + 200), i + 200 >= summaries.length ? { caughtUp: true } : {});
    });

    // One phone upload part: 8 recent workouts.
    const part = wids.slice(0, 8).flatMap((w, i) => workoutStreams(w, Math.round(NOW - i * 1.42 * 86_400_000), NOW));
    const r = await time('ingest one raw-data part (8 workouts)', () => ingest('_wstream', 'workoutdata', part));
    console.log(`BENCH part size ${(r.gz / 1e6).toFixed(2)} MB gzip, result ${r.result}`);
    await time('ingest 3 parts at once (24 workouts)', () => Promise.all([1, 2, 3].map((k) => ingest('_wstream', 'workoutdata', wids.slice(8 * k, 8 * k + 8).flatMap((w, i) => workoutStreams(w, Math.round(NOW - (8 * k + i) * 1.42 * 86_400_000), NOW))))));

    const id = wids[0]!;
    await time('get_workouts last 30 days', () => getWorkouts(q, { start_date: '2026-09-01', end_date: '2026-09-30' }));
    await time('get_workouts one year', () => getWorkouts(q, { start_date: '2025-10-01', end_date: '2026-09-30', limit: 300 }));
    await time('get_workout (one id)', () => getWorkout(q, { workout_id: id }));
    await time('get_workout_series HR', () => getWorkoutSeries(q, { workout_id: id, stream: 'HeartRate' } as never));
    await time('get_workout_route', () => getWorkoutRoute(q, { workout_id: id } as never));
    await time('workout_hr_zones', () => workoutHrZones(q, { workout_id: id, max_hr: 190 }));
    await time('workout_splits', () => workoutSplits(q, { workout_id: id }));
  }, 600_000);
});
