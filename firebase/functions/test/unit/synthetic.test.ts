import { gzipSync } from 'node:zlib';
import { beforeAll, describe, expect, it } from 'vitest';
// @ts-expect-error plain JS module shared with the monitoring scripts
import { batches, CATEGORIES, evalCases, runId, TZ } from '../../../../scripts/synthetic/data.mjs';
import { ingestObject } from '../../src/ingest/ingest.js';
import { getGlucose, getHealthEvents, getHourlySeries } from '../../src/query/health.js';
import { getDailyContext, getWorkout, getWorkoutRoute, getWorkoutSeries, getWorkouts, workoutBestEfforts, workoutHrDrift, workoutHrZones, workoutSplits } from '../../src/query/workouts.js';
import { deps, makeEnv, type Env } from '../helpers/memory.js';

/** The synthetic monitoring user (scripts/synthetic) must produce exactly the answers the evals expect. */
let env: Env;
const q = () => deps(env, TZ);
const cases: { q: string; expect: number[] }[] = evalCases();
const expected = (n: number) => cases[n]!.expect[0]!;

beforeAll(async () => {
  env = makeEnv(Date.now());
  env.meta.users.get(env.uid)!.categories = CATEGORIES;
  for (const lines of batches() as { batchId?: string; type?: string }[][]) {
    const batchId = lines[0]!.batchId!;
    const path = `incoming/${env.uid}/${batchId}.ndjson.gz`;
    await env.incoming.write(path, gzipSync(lines.map((l) => JSON.stringify(l)).join('\n')));
    const r = await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
    expect(r, `${lines[0]!.type}`).toBe('published');
  }
}, 120_000);

const id = (day: string) => `run-${day}`;

describe('synthetic user answers match the eval expectations', () => {
  it('eval 1-2: workout count and distance in Q1', async () => {
    const r = await getWorkouts(q(), { start_date: '2024-01-01', end_date: '2024-03-31' });
    const list = r.workouts as { distance_km: number; raw_data: string }[];
    expect(list.length).toBe(expected(0));
    expect(Math.round(list.reduce((n, w) => n + w.distance_km, 0))).toBe(expected(1));
    expect(list.every((w) => w.raw_data === 'complete')).toBe(true);
  });

  it('eval 3: minutes in zone 3', async () => {
    const r = await workoutHrZones(q(), { workout_id: id('2024-03-04'), max_hr: 200 });
    expect((r.zones as { seconds: number }[])[2]!.seconds / 60).toBe(expected(2));
  });

  it('eval 4: fastest 3 km', async () => {
    const r = await workoutBestEfforts(q(), { workout_id: id('2024-01-15'), distances_m: [3000] });
    expect((r.efforts as { moving_seconds: number }[])[0]!.moving_seconds / 60).toBe(expected(3));
  });

  it('eval 5: heart rate rise between halves', async () => {
    const r = await workoutHrDrift(q(), { workout_id: id('2024-03-04') });
    expect(r.hr_change_percent).toBe(expected(4));
  });

  it('eval 6: heart rate 10 minutes in', async () => {
    const r = await getWorkoutSeries(q(), { workout_id: id('2024-01-15'), stream: 'HeartRate', start_offset_seconds: 600, end_offset_seconds: 600, max_points: 10 });
    expect((r.points as number[][])[0]![1]).toBe(expected(5));
  });

  it('eval 7-9: daily context', async () => {
    const march = await getDailyContext(q(), { start_date: '2024-03-01', end_date: '2024-03-31' });
    expect((march.days as { steps: number }[]).reduce((n, d) => n + d.steps, 0)).toBe(expected(6));
    const june = await getDailyContext(q(), { start_date: '2024-06-01', end_date: '2024-06-30' });
    const rhr = (june.days as { restingHr: number }[]).map((d) => d.restingHr);
    expect(Math.round((rhr.reduce((a, b) => a + b, 0) / rhr.length) * 10) / 10).toBe(expected(7));
    const night = await getDailyContext(q(), { start_date: '2024-04-10', end_date: '2024-04-10' });
    expect((night.days as { sleepAsleepMin: number }[])[0]!.sleepAsleepMin).toBe(expected(8));
  });

  it('eval 10-13: hourly series, glucose around a run and symptom log', async () => {
    const hr = await getHourlySeries(q(), { series: 'HeartRate', start_date: '2024-03-04', end_date: '2024-03-04', resolution: 'hour' });
    const hours = hr.hours as [string, number][];
    expect(hours.find((h) => h[0].includes('14:00'))![1]).toBe(expected(9));
    const steps = await getHourlySeries(q(), { series: 'StepCount', start_date: '2024-03-04', end_date: '2024-03-04', resolution: 'hour' });
    const sh = steps.hours as [string, number][];
    expect(sh.filter((h) => h[0].includes('09:00') || h[0].includes('10:00')).reduce((n, h) => n + h[1], 0)).toBe(expected(10));
    const g = await getGlucose(q(), { workout_id: id('2024-03-04') });
    expect((g.during_workout as { mean_mg_dl: number }).mean_mg_dl).toBe(expected(11));
    const e = await getHealthEvents(q(), { types: ['Headache'], start_date: '2024-03-01', end_date: '2024-03-31', limit: 500 });
    expect(e.count).toBe(expected(12));
  });

  it('smoke test answers (scripts/tasks/smoke.sh)', async () => {
    const w = await getWorkouts(q(), { start_date: '2024-03-04', end_date: '2024-03-04' });
    expect((w.workouts as { distance_km: number; raw_data: string }[])[0]).toMatchObject({ distance_km: 5, raw_data: 'complete' });
    const s = await workoutSplits(q(), { workout_id: runId(60 + 3) });
    expect((s.splits as { moving_seconds: number }[]).map((x) => x.moving_seconds)).toEqual([360, 360, 360, 360, 360]);
    const route = await getWorkoutRoute(q(), { workout_id: id('2024-03-04'), max_points: 50 });
    expect(route.trimmed_ends).toBe(true);
    expect(route.returned as number).toBeGreaterThan(10);
    const d = await getDailyContext(q(), { start_date: '2024-03-01', end_date: '2024-03-01' });
    expect((d.days as { steps: number }[])[0]!.steps).toBe(10000);
    expect(JSON.stringify(await getWorkout(q(), { workout_id: id('2024-03-04') }))).toContain('sleepAsleepMin');
  });
});
