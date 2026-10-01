import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it } from 'vitest';
import { decodeColumn, decodeTimes, type CompactColumn } from '../../src/ingest/compact.js';
import { BatchError, parseBatch } from '../../src/ingest/batch.js';
import { getWorkoutRoute, getWorkoutSeries } from '../../src/query/workouts.js';
import { deps, makeBatch, makeEnv, upload, type Env } from '../helpers/memory.js';
import { encodeChunk, encodeColumn, type Plan } from '../helpers/compact.js';

interface Fixture {
  name: string;
  input: { t: number[]; cols: Record<string, (number | null)[]> };
  plans: Record<string, Plan>;
  compact: Record<string, unknown> & { t: CompactColumn; n: number };
  decoded: Record<string, (number | null)[]>;
}
const fixtures = (JSON.parse(readFileSync(new URL('../../../../shared/compact-fixtures.json', import.meta.url), 'utf8')) as { cases: Fixture[] }).cases;

describe('compact columns: shared test vectors (the iOS tests use the same file)', () => {
  for (const f of fixtures) {
    it(`decodes: ${f.name}`, () => {
      expect(decodeTimes(f.compact.t, f.compact.n, 4_102_444_800_000)).toEqual(f.decoded.t);
      for (const name of Object.keys(f.input.cols)) {
        expect(decodeColumn(f.compact[name] as CompactColumn, f.compact.n), name).toEqual(f.decoded[name]);
      }
    });
    it(`reference encoder agrees: ${f.name}`, () => {
      expect(encodeChunk({ ...f.input, plans: f.plans })).toEqual(f.compact);
    });
  }

  it('exact columns decode to exactly the numbers that went in', () => {
    // 0.1 + 0.2 and friends: values that are a short decimal come back identical, others are sent as they are.
    const vals = [0, 0.1, 0.2, 0.30000000000000004, 1 / 3, 12345.678, 117, -0.001, 1e-9, 123456789.123456];
    const back = decodeColumn(encodeColumn(vals, 'exact'), vals.length);
    expect(back).toEqual(vals);
    // Every short-decimal value individually.
    for (const v of [0.1, 0.7, 1.15, 2.675, 98.6, 0.001, 123.456, 0.000001]) {
      expect(decodeColumn(encodeColumn([v, v], 'exact'), 2)).toEqual([v, v]);
    }
  });

  it('a random walk survives either difference order', () => {
    let seed = 5;
    const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
    for (const plan of [{ m: 100000 }, { m: 10 }, 'exact'] as Plan[]) {
      let x = 50;
      const vals = Array.from({ length: 5000 }, (_, i) => (i % 97 === 5 ? null : (x += (rnd() - 0.4) * 0.0004)));
      const back = decodeColumn(encodeColumn(vals, plan), vals.length);
      const m = plan === 'exact' ? 0 : (plan as { m: number }).m;
      back.forEach((b, i) => {
        if (vals[i] === null) expect(b).toBeNull();
        else if (m) expect(Math.abs(b! - vals[i]!)).toBeLessThanOrEqual(0.5 / m + 1e-12);
        else expect(b).toBe(vals[i]);
      });
    }
  });
});

describe('compact chunks in uploads', () => {
  let env: Env;
  const WID = '99999999-9999-4999-8999-999999999999';
  const T0 = Date.UTC(2024, 5, 20, 7, 0, 0);
  beforeEach(() => { env = makeEnv(); });

  const summary = { k: 'w', id: WID, s: T0, e: T0 + 600_000, act: 37, dur: 600, src: 'Apple Watch', bid: 'com.apple.health' };

  it('stores a compact route and heart rate exactly like the plain arrays they decode to', async () => {
    await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, [summary]);
    const t = Array.from({ length: 200 }, (_, i) => T0 + i * 1000 + (i % 3));
    const lat = t.map((_, i) => 50 + i * 0.00003);
    const lon = t.map((_, i) => 30 + Math.sin(i / 20) * 0.001);
    const alt = t.map((_, i) => (i % 50 === 7 ? null : 100 + Math.sin(i / 30) * 5));
    const hr = t.map((_, i) => 120 + (i % 25));
    const gen = T0 + 99_000_000;
    const route = { k: 'ws', wid: WID, st: 'route', gen, ...encodeChunk({ t, cols: { lat, lon, alt }, plans: { lat: { m: 100000 }, lon: { m: 100000 }, alt: { m: 10 } } }) };
    const heart = { k: 'ws', wid: WID, st: 'HeartRate', gen, u: 'count/min', ...encodeChunk({ t, cols: { v: hr }, plans: { v: 'exact' } }) };
    const mark = { k: 'wd', wid: WID, gen, expected: { route: 200, HeartRate: 200 } };
    const r = await upload(env, { type: '_wstream', mode: 'workoutdata' }, [route, heart, mark]);
    expect(r.result).toBe('published');
    const doc = env.meta.workoutData.get(`${env.uid}/${WID}`)!;
    expect(doc.rawComplete).toBe(true);
    expect(doc.streams.route!.points).toBe(200);
    expect(doc.firstT).toBe(T0);

    const series = await getWorkoutSeries(deps(env), { workout_id: WID, stream: 'HeartRate', mode: 'raw', max_points: 1000 } as never);
    const values = (series.points as unknown[][]).map((p) => p[1]);
    expect(values).toEqual(hr.slice(0, values.length));
    const rt = await getWorkoutRoute(deps(env), { workout_id: WID, max_points: 1000 } as never);
    expect(rt).toBeTruthy();
  });

  it('a compact batch is far smaller than the same data as plain arrays', () => {
    const n = 5000;
    const t = Array.from({ length: n }, (_, i) => T0 + i * 1000 + (i % 3));
    const walk = (s: number, k: number) => { let x = s; return t.map(() => (x += Math.sin(x * 1000) * k)); };
    const lat = walk(50, 0.00002), lon = walk(30, 0.00003);
    const plain = { k: 'ws', wid: WID, st: 'route', gen: 1, t, lat, lon, alt: t.map((_, i) => 100 + Math.sin(i / 50) * 5) };
    const compact = { k: 'ws', wid: WID, st: 'route', gen: 1, ...encodeChunk({ t, cols: { lat, lon, alt: plain.alt }, plans: { lat: { m: 100000 }, lon: { m: 100000 }, alt: { m: 10 } } }) };
    const a = makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [plain]).gz.length;
    const b = makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [compact]).gz.length;
    expect(b).toBeLessThan(a / 4);
  });

  const bad = (rec: object) => {
    const good = { k: 'ws', wid: WID, st: 'HeartRate', gen: 1, t: [1, 2], v: [100, 101] };
    const { gz } = makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [good, rec]);
    return parseBatch(gz);
  };
  const col = (c: object) => ({ k: 'ws', wid: WID, st: 'route', gen: 1, enc: 1, n: 3, t: { m: 1, o: 1, d: [1000, 1000, 1000] }, lat: c });

  it('skips malformed compact records and keeps the rest of the batch', () => {
    const cases: [string, object][] = [
      ['wrong number of values', col({ m: 10, o: 1, d: [1, 2] })],
      ['null position outside the chunk', col({ m: 10, o: 1, d: [1, 2, 3], x: [5] })],
      ['null positions out of order', col({ m: 10, o: 1, d: [1, 2, 3], x: [2, 1] })],
      ['value overflow', col({ m: 10, o: 1, d: [Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 1] })],
      ['raw column of the wrong length', col({ r: [1, 2] })],
      ['unknown order', col({ m: 10, o: 3, d: [1, 2, 3] })],
      ['zero divisor', col({ m: 0, o: 1, d: [1, 2, 3] })],
      ['fractional integers', col({ m: 10, o: 1, d: [1.5, 2, 3] })],
      ['enc without n', { ...col({ m: 10, o: 1, d: [1, 2, 3] }), n: undefined }],
      ['n without enc', { k: 'ws', wid: WID, st: 'HeartRate', gen: 1, n: 2, t: [1, 2], v: [1, 2] }],
      ['compact column in a plain chunk', { k: 'ws', wid: WID, st: 'HeartRate', gen: 1, t: [1, 2], v: { m: 1, o: 1, d: [1, 1] } }],
      ['plain array in a compact chunk', { ...col({ m: 10, o: 1, d: [1, 2, 3] }), lon: [1, 2, 3] }],
      ['time with a divisor', { ...col({ m: 10, o: 1, d: [1, 2, 3] }), t: { m: 10, o: 1, d: [1000, 1000, 1000] } }],
      ['time with gaps', { ...col({ m: 10, o: 1, d: [1, 2, 3] }), t: { m: 1, o: 1, d: [1000, 1000, 1000], x: [1] } }],
      ['time out of range', { ...col({ m: 10, o: 1, d: [1, 2, 3] }), t: { m: 1, o: 1, d: [9_000_000_000_000, 1, 1] } }],
      ['negative time', { ...col({ m: 10, o: 1, d: [1, 2, 3] }), t: { m: 1, o: 1, d: [5, -10, 1] } }],
    ];
    for (const [name, rec] of cases) {
      const parsed = bad(rec);
      expect(parsed.skipped, name).toBe(1);
      expect(parsed.streams, name).toHaveLength(1);
    }
  });

  it('rejects a batch whose every record is a bad compact record', () => {
    const { gz } = makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [col({ m: 10, o: 1, d: [1] })]);
    expect(() => parseBatch(gz)).toThrow(BatchError);
  });

  it('accepts the largest chunk', () => {
    const n = 20_000;
    const t = Array.from({ length: n }, (_, i) => T0 + i * 1000);
    const { gz } = makeBatch(env, { type: '_wstream', mode: 'workoutdata' }, [{ k: 'ws', wid: WID, st: 'HeartRate', gen: 1, ...encodeChunk({ t, cols: { v: t.map((_, i) => 100 + (i % 50)) }, plans: { v: 'exact' } }) }]);
    const parsed = parseBatch(gz);
    expect(parsed.skipped).toBe(0);
    expect(parsed.streams[0]!.t).toHaveLength(n);
    expect(parsed.streams[0]!.cols.v![n - 1]).toBe(100 + ((n - 1) % 50));
  });
});
