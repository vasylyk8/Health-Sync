import { describe, expect, it } from 'vitest';
import { parseCategories, purgeCategoryData, purgeRetiredType } from '../../src/account.js';
import { loadType } from '../../src/query/context.js';
import { withDuck } from '../../src/query/duck.js';
import { deps, makeEnv, upload, type Env } from '../helpers/memory.js';
import { encodeChunk } from '../helpers/compact.js';

const H0 = Date.UTC(2024, 5, 20, 0, 0, 0);
const HOUR = 3_600_000;
const withCategories = (env: Env, categories: string[]) => (env.meta.users.get(env.uid)!.categories = categories);

async function read(env: Env, type: string, sql: string) {
  return withDuck(async (c, dir) => {
    await loadType(c, dir, deps(env), type, 'all', 'r', { what: 'raw', budget: { bytes: 0 } });
    return (await c.runAndReadAll(sql)).getRows();
  });
}

describe('hourly series', () => {
  const t = Array.from({ length: 30 }, (_, i) => H0 + i * HOUR);
  const avg = t.map((_, i) => 60 + (i % 20));
  const lo = avg.map((v) => v - 5);
  const hi = avg.map((v) => v + 40);

  it('stores plain hourly chunks as one row per hour, across months', async () => {
    const env = makeEnv();
    const t2 = [...t, Date.UTC(2024, 6, 1, 3)];
    const r = await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [{ k: 'hs', st: 'HeartRate', u: 'count/min', t: t2, v: [...avg, 70], lo: [...lo, 60], hi: [...hi, 120] }]);
    expect(r.result).toBe('published');
    const man = await env.meta.getManifest(env.uid, '_hourly');
    expect(Object.keys(man!.files).sort()).toEqual(['2024-06', '2024-07']);
    const rows = await read(env, '_hourly', `SELECT agg, count(*), min(v2), max(v3) FROM r GROUP BY agg`);
    expect(rows).toEqual([['HeartRate', 31n, 55, 120]]);
  });

  it('decodes compact hourly chunks to the same rows', async () => {
    const env = makeEnv();
    const chunk = encodeChunk({ t, cols: { v: avg, lo, hi }, plans: { v: 'exact', lo: 'exact', hi: 'exact' } });
    const r = await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [{ k: 'hs', st: 'HeartRate', u: 'count/min', ...chunk }]);
    expect(r.result).toBe('published');
    const rows = await read(env, '_hourly', `SELECT s, v, v2, v3 FROM r ORDER BY s`);
    expect(rows.map((x) => [Number(x[0]), x[1], x[2], x[3]])).toEqual(t.map((s, i) => [s, avg[i], lo[i], hi[i]]));
  });

  it('rejects an unknown series and replaces a re-sent hour instead of doubling it', async () => {
    const env = makeEnv();
    const bad = await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [{ k: 'hs', st: 'Bogus', t, v: avg }]);
    expect(bad.result).toBe('rejected');
    await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [{ k: 'hs', st: 'StepCount', t: t.slice(0, 3), v: [10, 20, 30] }]);
    await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [{ k: 'hs', st: 'StepCount', t: t.slice(0, 3), v: [11, 21, 31] }]);
    const rows = await read(env, '_hourly', `SELECT count(*), sum(v) FROM r WHERE agg = 'StepCount'`);
    expect(rows).toEqual([[3n, 63]]);
  });
});

describe('event logs', () => {
  const s = Array.from({ length: 12 }, (_, i) => H0 + i * 300_000);
  const water = [101, 104, 110, 118, 126, 131, 128, 120, 112, 106, 102, 99];

  it('is dropped while the category is switched off and stored once it is on', async () => {
    const env = makeEnv();
    withCategories(env, ['core']);
    const off = await upload(env, { type: '_events_nutrition', schema: 2, mode: 'anchored' }, [{ k: 'ev', ty: 'DietaryWater', u: 'mL', src: 'Health', s, v: water }]);
    expect(off.result).toBe('discarded');
    expect(await env.meta.getManifest(env.uid, '_events_nutrition')).toBeNull();
    withCategories(env, ['core', 'nutrition']);
    const on = await upload(env, { type: '_events_nutrition', schema: 2, mode: 'anchored' }, [{ k: 'ev', ty: 'DietaryWater', u: 'mL', src: 'Health', s, v: water }]);
    expect(on.result).toBe('published');
    const rows = await read(env, '_events_nutrition', `SELECT agg, src, count(*), min(v), max(v) FROM r GROUP BY agg, src`);
    expect(rows).toEqual([['DietaryWater', 'Health', 12n, 99, 131]]);
  });

  it('keeps one row per reading when the same readings arrive twice (no ids needed)', async () => {
    const env = makeEnv();
    withCategories(env, ['core', 'nutrition']);
    const rec = { k: 'ev', ty: 'DietaryWater', u: 'mL', src: 'Health', s, v: water };
    await upload(env, { type: '_events_nutrition', schema: 2 }, [rec]);
    await upload(env, { type: '_events_nutrition', schema: 2 }, [{ ...rec, v: water.map((g) => g + 1) }]);
    const rows = await read(env, '_events_nutrition', `SELECT count(*), min(v) FROM r`);
    expect(rows).toEqual([[12n, 100]]);
  });

  it('applies deletions by id and accepts compact columns, end times and metadata', async () => {
    const env = makeEnv();
    withCategories(env, ['core', 'nutrition']);
    const start = [H0, H0 + 86_400_000, H0 + 2 * 86_400_000];
    const chunk = encodeChunk({ t: start, cols: { v: [95, 80, 120] }, plans: { v: 'exact' } });
    const rec = {
      k: 'ev', ty: 'DietaryCaffeine', u: 'mg', src: 'Health', enc: 1, n: 3, s: chunk.t, v: chunk.v,
      e: encodeChunk({ t: start.map((x) => x + HOUR), cols: {}, plans: {} }).t,
      ids: ['aaa-1', 'bbb-2', 'ccc-3'], meta: [null, { HKWasUserEntered: true }, null],
    };
    const r = await upload(env, { type: '_events_nutrition', schema: 2 }, [rec]);
    expect(r.result).toBe('published');
    await upload(env, { type: '_events_nutrition', schema: 2 }, [{ k: 'd', id: 'bbb-2' }]);
    const rows = await read(env, '_events_nutrition', `SELECT id, v, e - s, extra FROM r ORDER BY s`);
    expect(rows.map((x) => [x[0], x[1], Number(x[2]), x[3]])).toEqual([['aaa-1', 95, HOUR, null], ['ccc-3', 120, HOUR, null]]);
  });

  it('rejects an event type that does not belong in the batch type, and unknown types', async () => {
    const env = makeEnv();
    withCategories(env, ['core', 'nutrition', 'profile']);
    const wrong = await upload(env, { type: '_events_profile', schema: 2 }, [{ k: 'ev', ty: 'DietaryWater', s, v: water }]);
    expect(wrong.result).toBe('rejected');
    const unknown = await upload(env, { type: '_events_nutrition', schema: 2 }, [{ k: 'ev', ty: 'Nope', s, v: water }]);
    expect(unknown.result).toBe('rejected');
  });

  it('removes every file and manifest of a category when it is switched off', async () => {
    const env = makeEnv();
    withCategories(env, ['core', 'nutrition']);
    await upload(env, { type: '_events_nutrition', schema: 2 }, [{ k: 'ev', ty: 'DietaryCaffeine', u: 'mg', s: s.slice(0, 2), v: [1.5, 0.5], meta: [{ HKWasUserEntered: true }, null] }]);
    expect(await env.meta.getManifest(env.uid, '_events_nutrition')).not.toBeNull();
    expect((await env.data.list(`data/${env.uid}/_events_nutrition/`)).length).toBeGreaterThan(0);
    await purgeCategoryData({ meta: env.meta, data: env.data }, env.uid, 'nutrition');
    expect(await env.meta.getManifest(env.uid, '_events_nutrition')).toBeNull();
    expect(await env.data.list(`data/${env.uid}/_events_nutrition/`)).toEqual([]);
  });
});

describe('retired types (glucose, medications, heart alerts, symptoms, mood)', () => {
  const s = [H0, H0 + 300_000];

  it('acknowledges and drops batches from old app builds, whatever the saved categories', async () => {
    const env = makeEnv();
    withCategories(env, ['core', 'devices', 'mind', 'heart', 'medications']);
    for (const [type, ty] of [['_events_devices', 'BloodGlucose'], ['_events_mind', 'Fatigue'], ['_events_heart', 'HighHeartRateEvent'], ['_events_medications', 'Medication']] as const) {
      const r = await upload(env, { type, schema: 2, mode: 'anchored' }, [{ k: 'ev', ty, s, v: [100, 101] }]);
      expect(r.result).toBe('discarded');
      expect(await env.meta.getManifest(env.uid, type)).toBeNull();
    }
    const daily = await upload(env, { type: '_daily_mind', schema: 2, mode: 'stats' }, [{ k: 'day', d: '2024-06-20', m: { mindfulMin: 5 } }]);
    expect(daily.result).toBe('discarded');
  });

  it('deletes stored files and manifests of a retired type', async () => {
    const env = makeEnv();
    const path = `data/${env.uid}/_events_devices/2024-06/old.parquet`;
    await env.data.write(path, Buffer.from('x'));
    await env.meta.publish({ uid: env.uid, type: '_events_devices', batchId: 'old', generation: 1, mutate: (m) => m });
    expect(await env.meta.getManifest(env.uid, '_events_devices')).not.toBeNull();
    await purgeRetiredType({ meta: env.meta, data: env.data }, env.uid, '_events_devices');
    expect(await env.meta.getManifest(env.uid, '_events_devices')).toBeNull();
    expect(await env.data.list(`data/${env.uid}/_events_devices/`)).toEqual([]);
  });

  it('ignores retired category ids in a saved choice and in a category change', () => {
    expect(parseCategories(['mind', 'cycle', 'devices'])).toEqual(['core', 'cycle']);
    expect(() => parseCategories(['bogus'])).toThrow();
  });
});
