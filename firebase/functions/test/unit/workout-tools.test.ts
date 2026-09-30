import { beforeEach, describe, expect, it } from 'vitest';
import { deps, makeEnv, upload, type Env } from '../helpers/memory.js';
import { M_PER_DEG, RUN, seedRun } from '../helpers/workouts.js';
import {
  getDailyContext, getWorkout, getWorkoutRoute, getWorkoutSeries, getWorkouts, workoutBestEfforts, workoutElevation, workoutHrDrift, workoutHrZones, workoutSplits,
} from '../../src/query/workouts.js';
import { ToolError } from '../../src/query/context.js';

let env: Env;
const q = () => deps(env, 'UTC');
const day = { start_date: '2024-06-20', end_date: '2024-06-20' };

beforeEach(async () => {
  env = makeEnv();
  await seedRun(env);
});

const fails = async (p: Promise<unknown>, code: string) => {
  const err = await p.then(() => null, (e: unknown) => e);
  expect(err).toBeInstanceOf(ToolError);
  expect((err as ToolError).code).toBe(code);
  return (err as ToolError).message;
};

describe('get_workouts / get_workout', () => {
  it('lists the workout with Apple summary values and raw-data status', async () => {
    const r = await getWorkouts(q(), day);
    const [w] = r.workouts as Record<string, unknown>[];
    expect(r.count).toBe(1);
    expect(w).toMatchObject({ id: RUN, activity: 'Running', duration_min: 30, active_kcal: 310.5, distance_km: 6, avg_hr: 145, max_hr: 162, raw_data: 'complete', source: 'Apple Watch', start: '2024-06-20 07:00' });
    expect(r.complete).toBe(true);
  });

  it('filters by activity and range', async () => {
    expect((await getWorkouts(q(), { ...day, activity: 'cycling' })).count).toBe(0);
    expect((await getWorkouts(q(), { start_date: '2024-06-21', end_date: '2024-06-22' })).count).toBe(0);
  });

  it('truncates to the requested limit instead of failing, and treats % in the activity filter literally', async () => {
    for (const wid of ['55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666']) await seedRun(env, { wid, withRaw: false });
    const r = await getWorkouts(q(), { ...day, limit: 2 });
    expect(r.count).toBe(2);
    expect(r.truncated).toBe(true);
    expect((r.notes as string[]).join(' ')).toContain('More workouts match');
    expect((await getWorkouts(q(), { ...day, limit: 3 })).truncated).toBe(false);
    expect((await getWorkouts(q(), { ...day, activity: '%' })).count).toBe(0);
  });

  it('returns the full detail: events, streams and daily context', async () => {
    const r = await getWorkout(q(), { workout_id: RUN });
    const w = r.workout as Record<string, unknown>;
    expect(w.paused_seconds).toBe(60);
    expect((r.events as { counts: Record<string, number> }).counts).toEqual({ pause: 1, resume: 1 });
    expect((r.apple_summary as { statistics: Record<string, unknown> }).statistics).toHaveProperty('HeartRate');
    const raw = r.raw_data as { status: string; streams: { name: string; points: number; expected_points: number }[] };
    expect(raw.status).toBe('complete');
    expect(raw.streams.map((s) => s.name).sort()).toEqual(['DistanceWalkingRunning', 'HeartRate', 'route']);
    expect(raw.streams.every((s) => s.points === s.expected_points)).toBe(true);
    const daily = r.daily_context as { same_day: Record<string, number>; previous_day: Record<string, number> };
    expect(daily.previous_day.sleepMinutes).toBe(455);
    expect(daily.same_day.restingHr).toBe(51);
  });

  it('reports summary-only workouts honestly', async () => {
    const other = '44444444-4444-4444-8444-444444444444';
    await seedRun(env, { wid: other, withRaw: false });
    const list = (await getWorkouts(q(), day)).workouts as { id: string; raw_data: string }[];
    expect(list.find((w) => w.id === other)?.raw_data).toBe('none');
    const r = await getWorkout(q(), { workout_id: other });
    expect((r.raw_data as { status: string }).status).toBe('none');
    expect((r.notes as string[]).join(' ')).toContain('not synced yet');
    await fails(getWorkoutSeries(q(), { workout_id: other, stream: 'HeartRate' }), 'no_data');
  });

  it('errors clearly for unknown or malformed ids', async () => {
    await fails(getWorkout(q(), { workout_id: '55555555-5555-4555-8555-555555555555' }), 'not_found');
    await fails(getWorkout(q(), { workout_id: "x'; drop" }), 'bad_request');
  });
});

describe('get_workout_series', () => {
  it('returns everything when it fits, offsets relative to the workout start', async () => {
    const r = await getWorkoutSeries(q(), { workout_id: RUN, stream: 'heart rate'.replace(' ', ''), max_points: 1000 });
    expect(r.downsampled).toBe(false);
    const pts = r.points as number[][];
    expect(pts).toHaveLength(361);
    expect(pts[0]).toEqual([0, 140]);
    expect(pts[pts.length - 1]![0]).toBe(1860);
  });

  it('downsamples into time buckets with mean/min/max', async () => {
    const r = await getWorkoutSeries(q(), { workout_id: RUN, stream: 'HeartRate', max_points: 4 });
    expect(r.downsampled).toBe(true);
    expect(r.columns).toEqual(['offset_seconds_bucket_start', 'mean', 'min', 'max']);
    const pts = r.points as number[][];
    expect(pts.length).toBeLessThanOrEqual(4);
    expect(pts[0]![1]).toBe(140);
    expect(pts[pts.length - 1]![1]).toBe(150);
    expect(r.points_in_range).toBe(361);
  });

  it('pages through every raw reading exactly once', async () => {
    let cursor: number | null = 0;
    const seen: number[] = [];
    while (cursor !== null) {
      const r = await getWorkoutSeries(q(), { workout_id: RUN, stream: 'HeartRate', mode: 'raw', max_points: 100, cursor });
      seen.push(...(r.points as number[][]).map((p) => p[0]!));
      cursor = r.next_cursor as number | null;
    }
    expect(seen).toHaveLength(361);
    expect(new Set(seen).size).toBe(361);
    expect(seen).toEqual([...seen].sort((a, b) => a - b));
  });

  it('filters by offset range', async () => {
    const r = await getWorkoutSeries(q(), { workout_id: RUN, stream: 'HeartRate', start_offset_seconds: 0, end_offset_seconds: 50, max_points: 1000 });
    expect(r.points_in_range).toBe(11);
  });

  it('rejects unknown streams (listing the available ones), the route stream, and bad limits', async () => {
    expect(await fails(getWorkoutSeries(q(), { workout_id: RUN, stream: 'Power' }), 'not_found')).toContain('HeartRate');
    await fails(getWorkoutSeries(q(), { workout_id: RUN, stream: 'route' }), 'bad_request');
    await fails(getWorkoutSeries(q(), { workout_id: RUN, stream: 'HeartRate', max_points: 5000 }), 'bad_request');
  });
});

describe('get_workout_route', () => {
  it('hides the first and last 300 m by default', async () => {
    const r = await getWorkoutRoute(q(), { workout_id: RUN, max_points: 1000 });
    expect(r.trimmed_ends).toBe(true);
    const pts = r.points as number[][];
    const box = r.bounding_box as { min_lat: number; max_lat: number };
    expect(box.min_lat).toBeGreaterThanOrEqual(50 + 300 / M_PER_DEG - 1e-6);
    expect(box.max_lat).toBeLessThanOrEqual(50 + 5700 / M_PER_DEG + 1e-6);
    expect(pts[0]![0]).toBeGreaterThan(80); // first shown point is ~90 s in
    expect((r.notes as string[]).join(' ')).toContain('Privacy');
    expect(r.total_distance_m).toBeCloseTo(6000, -1);
  });

  it('returns the full route only when explicitly asked', async () => {
    const r = await getWorkoutRoute(q(), { workout_id: RUN, include_full_route: true, max_points: 1000 });
    expect(r.trimmed_ends).toBe(false);
    expect((r.points as number[][])[0]).toEqual([0, 50, 30, 0, 3.33]);
    expect((r.bounding_box as { min_lat: number }).min_lat).toBe(50);
  });

  it('thins long routes and pages in raw mode', async () => {
    const thin = await getWorkoutRoute(q(), { workout_id: RUN, include_full_route: true, max_points: 50 });
    expect(thin.returned).toBe(50);
    expect(thin.downsampled).toBe(true);
    const page = await getWorkoutRoute(q(), { workout_id: RUN, include_full_route: true, mode: 'raw', max_points: 100, cursor: 300 });
    expect(page.returned).toBe(61);
    expect(page.next_cursor).toBeNull();
  });

  it('refuses to show a route too short to trim without revealing its ends', async () => {
    const short = '66666666-6666-4666-8666-666666666666';
    await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, [{ k: 'w', id: short, s: env.now - 1e6, e: env.now - 9e5, act: 37, actName: 'Walking' }]);
    const t0 = env.now - 1e6;
    await upload(env, { type: '_wstream', mode: 'workoutdata' }, [
      { k: 'ws', wid: short, st: 'route', gen: 1, t: [t0, t0 + 1000, t0 + 2000], lat: [50, 50.0005, 50.001], lon: [30, 30, 30] },
      { k: 'wd', wid: short, gen: 1, expected: { route: 3 } },
    ]);
    const msg = await fails(getWorkoutRoute(q(), { workout_id: short }), 'bad_request');
    expect(msg).toContain('include_full_route');
    expect((await getWorkoutRoute(q(), { workout_id: short, include_full_route: true })).returned).toBe(3);
  });
});

describe('calculation tools', () => {
  it('hr zones: exact seconds, requires max_hr or zones', async () => {
    const r = await workoutHrZones(q(), { workout_id: RUN, max_hr: 200 });
    expect((r.zones as { zone: number; seconds: number }[]).map((z) => z.seconds)).toEqual([0, 0, 1800, 0, 0]);
    expect(r.unmeasured_seconds).toBe(0);
    expect(r.moving_seconds).toBe(1800);
    const custom = await workoutHrZones(q(), { workout_id: RUN, zones_bpm: [100, 145, 170, 185] });
    expect((custom.zones as { seconds: number }[]).map((z) => z.seconds)).toEqual([0, 900, 900, 0, 0]);
    expect(await fails(workoutHrZones(q(), { workout_id: RUN }), 'bad_request')).toContain('do not guess');
  });

  it('splits: 300 s kilometres, per-split HR and climb, paused time removed', async () => {
    const r = await workoutSplits(q(), { workout_id: RUN });
    const s = r.splits as { moving_seconds: number; pace: string; avg_hr: number; elevation_gain_m: number; partial: boolean }[];
    expect(s).toHaveLength(6);
    expect(s.map((x) => x.moving_seconds)).toEqual([300, 300, 300, 300, 300, 300]);
    expect(s.every((x) => x.pace === '5:00' && !x.partial)).toBe(true);
    expect(s.map((x) => x.avg_hr)).toEqual([140, 140, 140, 150, 150, 150]);
    expect(s[0]!.elevation_gain_m).toBeGreaterThan(7);
    expect(s[0]!.elevation_gain_m).toBeLessThanOrEqual(10.5);
    expect(s[4]!.elevation_gain_m).toBe(0);
    expect(r.distance_source).toBe('DistanceWalkingRunning');
    const mi = await workoutSplits(q(), { workout_id: RUN, unit: 'mi' });
    expect((mi.splits as unknown[]).length).toBe(4); // 6000 m = 3 full miles + 0.73 mi
    expect((mi.splits as { pace: string }[])[0]!.pace).toBe('8:03');
  });

  it('splits can use the GPS route instead of the distance stream', async () => {
    const r = await workoutSplits(q(), { workout_id: RUN, distance_source: 'route' });
    expect(r.distance_source).toBe('route (GPS)');
    const s = r.splits as { moving_seconds: number }[];
    expect(s).toHaveLength(6);
    for (const x of s) expect(x.moving_seconds).toBeCloseTo(300, 0);
  });

  it('best efforts', async () => {
    const r = await workoutBestEfforts(q(), { workout_id: RUN });
    const e = r.efforts as { distance_m: number; moving_seconds: number; time: string; pace_per_km: string }[];
    expect(e.map((x) => x.distance_m)).toEqual([400, 1000, 1609.344, 3000, 5000]);
    expect(e.find((x) => x.distance_m === 1000)).toMatchObject({ moving_seconds: 300, time: '5:00', pace_per_km: '5:00' });
    expect(e.find((x) => x.distance_m === 5000)?.moving_seconds).toBe(1500);
    await fails(workoutBestEfforts(q(), { workout_id: RUN, distances_m: [-5] }), 'bad_request');
  });

  it('hr drift and decoupling', async () => {
    const r = await workoutHrDrift(q(), { workout_id: RUN });
    expect(r.hr_change_percent).toBe(7.1);
    expect(r.decoupling_percent).toBe(6.7);
    expect((r.first_half as { avg_hr: number }).avg_hr).toBe(140);
    expect((r.second_half as { avg_hr: number; pace_seconds_per_km: number }).pace_seconds_per_km).toBe(300);
  });

  it('elevation profile', async () => {
    const r = await workoutElevation(q(), { workout_id: RUN });
    expect(r.gain_m as number).toBeGreaterThan(26);
    expect(r.gain_m as number).toBeLessThanOrEqual(30.5);
    expect(r.loss_m as number).toBeGreaterThan(26);
    expect(r.max_m as number).toBeCloseTo(30, 0);
    expect((r.profile as unknown[]).length).toBe(20);
  });

  it('says so when raw data is still incomplete', async () => {
    const half = '77777777-7777-4777-8777-777777777777';
    await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, [{ k: 'w', id: half, s: env.now - 1e6, e: env.now - 9e5, act: 37, actName: 'Running' }]);
    await upload(env, { type: '_wstream', mode: 'workoutdata' }, [
      { k: 'ws', wid: half, st: 'HeartRate', gen: 1, u: 'count/min', t: [env.now - 1e6, env.now - 999_000], v: [120, 121] },
      { k: 'wd', wid: half, gen: 1, expected: { HeartRate: 2, route: 100 } },
    ]);
    const r = await workoutHrZones(q(), { workout_id: half, max_hr: 190 });
    expect(r.complete).toBe(false);
    expect((r.notes as string[]).join(' ')).toContain('still uploading');
  });
});

describe('get_daily_context', () => {
  it('returns local days with their metrics', async () => {
    const r = await getDailyContext(q(), { start_date: '2024-06-19', end_date: '2024-06-21' });
    expect(r.count).toBe(2);
    expect((r.days as { date: string; sleepMinutes: number }[])[0]).toMatchObject({ date: '2024-06-19', sleepMinutes: 455 });
    await fails(getDailyContext(q(), { start_date: '2020-01-01', end_date: '2024-06-21' }), 'too_large');
  });
});
