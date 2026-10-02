import { statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { columnScale } from '../../src/query/duck.js';
import { getWorkoutRoute, getWorkoutSeries } from '../../src/query/workouts.js';
import { deps, makeEnv, upload } from '../helpers/memory.js';

const WID = '44444444-4444-4444-8444-444444444444';
const T0 = Date.UTC(2024, 5, 20, 7, 0, 0);
const GEN = Date.UTC(2024, 5, 21);

describe('columnScale', () => {
  it('finds the smallest divisor that makes every value exact', () => {
    expect(columnScale([1, 2, 3])).toBe(1);
    expect(columnScale([0.5, 1.25, null, 3])).toBe(100);
    expect(columnScale([50.12345, 50.12346])).toBe(100_000);
    expect(columnScale([0.1, 0.30000000000000004])).toBe(null);
  });

  it('keeps long decimals as doubles and treats an empty column as scale 1', () => {
    expect(columnScale([1 / 3])).toBe(null);
    expect(columnScale([null, undefined])).toBe(1);
    expect(columnScale([])).toBe(1);
  });
});

describe('raw streams stored as scaled integers', () => {
  const n = 600;
  const t = Array.from({ length: n }, (_, i) => T0 + i * 1000);
  const lat = Array.from({ length: n }, (_, i) => Math.round((50 + i * 0.000023) * 1e5) / 1e5);
  const lon = Array.from({ length: n }, (_, i) => Math.round((30 + Math.sin(i / 50) * 0.0004) * 1e5) / 1e5);
  const alt = Array.from({ length: n }, (_, i) => Math.round((100 + Math.sin(i / 90) * 20) * 10) / 10);
  const hr = Array.from({ length: n }, (_, i) => 120 + (i % 30));
  const energy = Array.from({ length: n }, (_, i) => 0.123456789012 * (i + 1)); // long decimals: stays DOUBLE

  async function seed() {
    const env = makeEnv();
    await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, [
      { k: 'w', id: WID, s: T0, e: T0 + n * 1000, act: 37, actName: 'Running', dur: n, en: 100, dist: 1000, hrAvg: 140, hrMax: 150, src: 'Apple Watch', bid: 'com.apple.health', dev: 'Watch7,1' },
    ]);
    await upload(env, { type: '_wstream', mode: 'workoutdata' }, [
      { k: 'ws', wid: WID, st: 'HeartRate', gen: GEN, u: 'count/min', t, v: hr },
      { k: 'ws', wid: WID, st: 'ActiveEnergyBurned', gen: GEN, u: 'kcal', t, v: energy },
      { k: 'ws', wid: WID, st: 'route', gen: GEN, t, lat, lon, alt },
      { k: 'wd', wid: WID, gen: GEN, expected: { HeartRate: n, ActiveEnergyBurned: n, route: n } },
    ]);
    return env;
  }

  it('records the scale per column and keeps non-decimal columns as doubles', async () => {
    const env = await seed();
    const doc = await env.meta.getWorkoutData(env.uid, WID);
    expect(doc?.streams.HeartRate?.files[0]?.scale).toEqual({ v: 1 });
    expect(doc?.streams.route?.files[0]?.scale).toEqual({ lat: 100_000, lon: 100_000, alt: 10 });
    expect(doc?.streams.ActiveEnergyBurned?.files[0]?.scale).toBeUndefined();
  });

  it('reads back exactly the values that were sent', async () => {
    const env = await seed();
    const q = deps(env, 'UTC');
    const series = await getWorkoutSeries(q, { workout_id: WID, stream: 'HeartRate', mode: 'raw', max_points: 1000 });
    expect((series.points as number[][]).map((p) => p[1])).toEqual(hr);
    const energySeries = await getWorkoutSeries(q, { workout_id: WID, stream: 'ActiveEnergyBurned', mode: 'raw', max_points: 1000 });
    expect((energySeries.points as number[][]).map((p) => p[1])).toEqual(energy);
    const route = await getWorkoutRoute(q, { workout_id: WID, mode: 'raw', max_points: 1000, include_full_route: true });
    const pts = route.points as number[][];
    expect(pts.length).toBe(n);
    // [offset_seconds, lat(6dp), lon(6dp), alt(1dp), spd]
    expect(pts.map((p) => p[1])).toEqual(lat);
    expect(pts.map((p) => p[2])).toEqual(lon);
    expect(pts.map((p) => p[3])).toEqual(alt);
  });

  it('stores integer columns in far fewer bytes than doubles would take', async () => {
    const env = await seed();
    const doc = await env.meta.getWorkoutData(env.uid, WID);
    const routeBytes = doc!.streams.route!.files[0]!.bytes;
    expect(routeBytes).toBeLessThan(n * 3 * 8 * 0.5);
    for (const p of env.data.paths) expect(statSync(join(env.data.root, p)).size).toBeGreaterThan(0);
  });
});
