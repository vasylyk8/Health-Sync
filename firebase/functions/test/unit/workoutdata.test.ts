import { describe, expect, it } from 'vitest';
import { makeEnv, upload } from '../helpers/memory.js';

const W = 'HKWorkoutTypeIdentifier';
const WID = '11111111-1111-4111-8111-111111111111';
const T0 = Date.UTC(2024, 5, 20, 7, 0, 0);
const GEN = Date.UTC(2024, 5, 21);

const hr = (gen = GEN, n = 3, wid = WID) => ({
  k: 'ws', wid, st: 'HeartRate', gen, u: 'count/min',
  t: Array.from({ length: n }, (_, i) => T0 + i * 1000), v: Array.from({ length: n }, (_, i) => 120 + i),
});
const route = (n = 2) => ({
  k: 'ws', wid: WID, st: 'route', gen: GEN,
  t: Array.from({ length: n }, (_, i) => T0 + i * 1000),
  lat: Array.from({ length: n }, (_, i) => 50 + i * 0.0001), lon: Array.from({ length: n }, () => 30), alt: Array.from({ length: n }, () => 100),
});
const mark = (expected: Record<string, number>, gen = GEN) => ({ k: 'wd', wid: WID, gen, expected });
const stream = (env: ReturnType<typeof makeEnv>, recs: object[], batchId?: string) =>
  upload(env, { type: '_wstream', mode: 'workoutdata', batchId }, recs);

describe('workout raw data ingest', () => {
  it('stores streams per workout and reports rawComplete only when everything arrived', async () => {
    const env = makeEnv();
    const r = await stream(env, [hr(GEN, 3), mark({ HeartRate: 3, route: 2 })]);
    expect(r.result).toBe('published');
    let doc = await env.meta.getWorkoutData(env.uid, WID);
    expect(doc?.streams.HeartRate?.points).toBe(3);
    expect(doc?.rawComplete).toBe(false); // route promised but not yet here
    await stream(env, [route(2)]);
    doc = await env.meta.getWorkoutData(env.uid, WID);
    expect(doc?.rawComplete).toBe(true);
    expect(doc?.streams.route?.cols.sort()).toEqual(['alt', 'lat', 'lon']);
    expect([...env.data.paths].some((p) => p.startsWith(`data/${env.uid}/wstream/${WID}/HeartRate/`))).toBe(true);
  });

  it('replaying the same batch is a no-op', async () => {
    const env = makeEnv();
    const id = '22222222-2222-4222-8222-222222222222';
    await stream(env, [hr(), mark({ HeartRate: 3 })], id);
    const again = await stream(env, [hr(), mark({ HeartRate: 3 })], id);
    expect(again.result).toBe('duplicate');
    expect((await env.meta.getWorkoutData(env.uid, WID))?.streams.HeartRate?.points).toBe(3);
  });

  it('a newer generation replaces older files, a stale one is ignored', async () => {
    const env = makeEnv();
    await stream(env, [hr(GEN, 3), mark({ HeartRate: 3 })]);
    const oldFiles = (await env.meta.getWorkoutData(env.uid, WID))!.streams.HeartRate!.files.map((f) => f.path);
    await stream(env, [hr(GEN + 10, 5), mark({ HeartRate: 5 }, GEN + 10)]);
    let doc = (await env.meta.getWorkoutData(env.uid, WID))!;
    expect(doc.streams.HeartRate?.points).toBe(5);
    expect(doc.streams.HeartRate?.gen).toBe(GEN + 10);
    expect(doc.rawComplete).toBe(true);
    for (const p of oldFiles) expect(env.data.paths.has(p)).toBe(false);
    await stream(env, [hr(GEN + 5, 2)]); // late, older read
    doc = (await env.meta.getWorkoutData(env.uid, WID))!;
    expect(doc.streams.HeartRate?.points).toBe(5);
    expect([...env.data.paths].filter((p) => p.includes(`/${GEN + 5}-`))).toHaveLength(0);
  });

  it('drops streams the phone no longer reports in a newer generation', async () => {
    const env = makeEnv();
    await stream(env, [hr(GEN, 3), route(2), mark({ HeartRate: 3, route: 2 })]);
    await stream(env, [hr(GEN + 1, 3), mark({ HeartRate: 3 }, GEN + 1)]);
    const doc = (await env.meta.getWorkoutData(env.uid, WID))!;
    expect(Object.keys(doc.streams)).toEqual(['HeartRate']);
    expect(doc.rawComplete).toBe(true);
  });

  it('deleting the workout in Health removes its raw data', async () => {
    const env = makeEnv();
    await upload(env, { type: W, caughtUp: true }, [{ k: 'w', id: WID, s: T0, e: T0 + 60_000, act: 37 }]);
    await stream(env, [hr(), mark({ HeartRate: 3 })]);
    expect(await env.meta.getWorkoutData(env.uid, WID)).not.toBeNull();
    await upload(env, { type: W, caughtUp: true }, [{ k: 'd', id: WID }]);
    expect(await env.meta.getWorkoutData(env.uid, WID)).toBeNull();
    expect([...env.data.paths].filter((p) => p.includes('/wstream/'))).toHaveLength(0);
  });

  it('a deletion that started meanwhile discards the upload and its files', async () => {
    const env = makeEnv();
    const b = await import('../helpers/memory.js').then((m) => m.makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [hr(), mark({ HeartRate: 3 })]));
    await env.incoming.write(b.path, b.gz);
    env.meta.users.get(env.uid)!.deleting = true;
    const { ingestObject } = await import('../../src/ingest/ingest.js');
    const r = await ingestObject(b.path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
    expect(r).toBe('discarded');
    expect([...env.data.paths]).toHaveLength(0);
  });

  it('rejects malformed stream batches', async () => {
    const env = makeEnv();
    const bad = (rec: object, opts: Record<string, unknown> = {}) => upload(env, { type: '_wstream', mode: 'workoutdata', ...opts }, [rec]);
    expect((await bad({ ...hr(), v: [1, 2] })).result).toBe('rejected'); // length mismatch
    expect((await bad({ k: 'ws', wid: WID, st: 'HeartRate', gen: GEN, t: [T0] })).result).toBe('rejected'); // no values
    expect((await bad({ ...hr(), st: '../evil' })).result).toBe('rejected');
    expect((await bad(hr(), { schema: 1 })).result).toBe('rejected');
    expect((await upload(env, { type: W }, [hr()])).result).toBe('rejected'); // ws outside workoutdata
    expect((await upload(env, { type: '_wstream', mode: 'anchored' }, [hr()])).result).toBe('rejected');
  });
});

describe('daily context ingest', () => {
  it('stores one row per day; the latest upload of a day wins', async () => {
    const env = makeEnv();
    await upload(env, { type: '_daily', mode: 'stats', window: { start: 0, end: env.now } }, [
      { k: 'day', day: '2024-06-19', m: { restingHr: 52, sleepMin: 430 } },
      { k: 'day', day: '2024-06-20', m: { restingHr: 51 } },
    ]);
    await upload(env, { type: '_daily', mode: 'stats', window: { start: 0, end: env.now } }, [{ k: 'day', day: '2024-06-20', m: { restingHr: 49 } }]);
    const man = await env.meta.getManifest(env.uid, '_daily');
    expect(man?.records).toBe(3);
    expect(man?.coverage.earliest).toBe(Date.UTC(2024, 5, 19));
    expect(man?.coverage.latest).toBe(Date.UTC(2024, 5, 21));
    expect(Object.keys(man!.files)).toEqual(['2024-06']);
  });

  it('rejects impossible dates and day records in other types', async () => {
    const env = makeEnv();
    expect((await upload(env, { type: '_daily', mode: 'stats' }, [{ k: 'day', day: '2024-02-30', m: {} }])).result).toBe('rejected');
    expect((await upload(env, { type: W }, [{ k: 'day', day: '2024-02-20', m: {} }])).result).toBe('rejected');
  });
});
