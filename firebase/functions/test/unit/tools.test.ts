import { describe, expect, it } from 'vitest';
import { deps, makeEnv, upload, type Env } from '../helpers/memory.js';
import { getOverview, getProfile, getSamples, getSleep, getWorkouts, listAvailableData, summarize } from '../../src/query/tools.js';
import { ToolError } from '../../src/query/context.js';

const STEPS = 'HKQuantityTypeIdentifierStepCount';
const HR = 'HKQuantityTypeIdentifierHeartRate';
const SLEEP = 'HKCategoryTypeIdentifierSleepAnalysis';
const H = 3_600_000;
const day = (d: number, h = 0) => Date.UTC(2024, 5, d, h);

async function seedSteps(env: Env) {
  // Watch and iPhone both record the same walk: raw sums double count, merged stats do not.
  await upload(env, { type: STEPS, mode: 'recent', window: { start: day(1), end: env.now } }, [
    { k: 's', id: 'w1', s: day(1, 9), e: day(1, 10), v: 1000, u: 'count', src: 'Apple Watch' },
    { k: 's', id: 'p1', s: day(1, 9), e: day(1, 10), v: 1000, u: 'count', src: 'iPhone' },
    { k: 's', id: 'w2', s: day(2, 9), e: day(2, 10), v: 500, u: 'count', src: 'Apple Watch' },
  ]);
  await upload(env, { type: STEPS, mode: 'stats', window: { start: day(1), end: env.now } }, [
    { k: 'h', s: day(1, 9), e: day(1, 10), agg: 'sum', v: 1000, u: 'count' },
    { k: 'h', s: day(2, 9), e: day(2, 10), agg: 'sum', v: 500, u: 'count' },
  ]);
}

describe('summarize', () => {
  it('uses merged statistics for totals (no double counting)', async () => {
    const env = makeEnv();
    await seedSteps(env);
    const r = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-01', end_date: '2024-06-02', period: 'day' });
    expect(r.method).toBe('merged');
    expect(r.rows).toEqual([{ period: '2024-06-01', value: 1000, unit: 'count' }, { period: '2024-06-02', value: 500, unit: 'count' }]);
    expect(r.complete).toBe(true);
  });

  it('flags raw sums that may double count, and filters by source', async () => {
    const env = makeEnv();
    await seedSteps(env);
    const raw = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day', stat: 'count' });
    expect(raw.method).toBe('raw');
    const watch = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-01', end_date: '2024-06-02', period: 'none', source: 'watch' });
    expect(watch.rows).toEqual([{ period: '2024-06-01..2024-06-02', value: 1500, samples: 2, sources: 1 }]);
  });

  it('falls back to raw data with a note when statistics do not cover the range', async () => {
    const env = makeEnv();
    await upload(env, { type: STEPS, mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 's', id: 'w1', s: day(1, 9), e: day(1, 10), v: 1000, u: 'count', src: 'Watch' },
      { k: 's', id: 'p1', s: day(1, 9), e: day(1, 10), v: 800, u: 'count', src: 'iPhone' },
    ]);
    const r = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day' });
    expect(r.method).toBe('raw_may_double_count');
    expect(r.notes.join(' ')).toMatch(/Merged hourly statistics do not cover/);
  });

  it('buckets by local day across timezones', async () => {
    const env = makeEnv();
    // 23:30 UTC on Jun 1 is 02:30 on Jun 2 in Kyiv (UTC+3).
    await upload(env, { type: HR, mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 's', id: 'a', s: day(1, 23) + 30 * 60_000, e: day(1, 23) + 30 * 60_000, v: 50, u: 'count/min' },
      { k: 's', id: 'b', s: day(1, 12), e: day(1, 12), v: 70, u: 'count/min' },
    ]);
    const utc = await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-02', period: 'day' });
    expect(utc.rows).toEqual([{ period: '2024-06-01', value: 60, samples: 2, sources: 1 }]);
    const kyiv = await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-02', period: 'day', timezone: 'Europe/Kyiv' });
    expect(kyiv.rows).toEqual([{ period: '2024-06-01', value: 70, samples: 1, sources: 1 }, { period: '2024-06-02', value: 50, samples: 1, sources: 1 }]);
  });

  it('applies deletions and de-duplicates re-sent samples', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 's', id: 'a', s: day(1, 8), e: day(1, 8), v: 50, u: 'count/min' },
      { k: 's', id: 'b', s: day(1, 9), e: day(1, 9), v: 90, u: 'count/min' },
    ]);
    // Anchored pass re-sends 'a' and reports that 'b' was deleted.
    await upload(env, { type: HR, caughtUp: true }, [{ k: 's', id: 'a', s: day(1, 8), e: day(1, 8), v: 50, u: 'count/min' }, { k: 'd', id: 'b' }]);
    const r = await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', period: 'none', stat: 'count' });
    expect((r.rows as { value: number }[])[0]!.value).toBe(1);
  });

  it('reports partial coverage honestly', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, mode: 'recent', window: { start: day(20), end: env.now } }, [{ k: 's', id: 'a', s: day(21, 8), e: day(21, 8), v: 50, u: 'count/min' }]);
    const r = await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-25', period: 'none' });
    expect(r.complete).toBe(false);
    expect(r.notes.join(' ')).toMatch(/not fully synced/);
  });

  it('marks stale data', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, mode: 'recent', window: { start: day(1), end: day(2) }, checkedAt: day(2) }, [{ k: 's', id: 'a', s: day(1, 8), e: day(1, 8), v: 50, u: 'count/min' }]);
    const r = await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', period: 'none' });
    expect(r.coverage[0]!.stale).toBe(true);
    expect(r.notes.join(' ')).toMatch(/opens the KROK app/);
  });

  it('rejects bad input clearly', async () => {
    const env = makeEnv();
    await expect(summarize(deps(env), { type: 'Nope', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day' })).rejects.toThrow(ToolError);
    await expect(summarize(deps(env), { type: 'HeartRate', start_date: '2024-6-1', end_date: '2024-06-01', period: 'day' })).rejects.toThrow(/date like/);
    await expect(summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day', timezone: 'Mars/Base' })).rejects.toThrow(/timezone/);
    await expect(summarize(deps(env), { type: 'SleepAnalysis', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day', stat: 'avg' })).rejects.toThrow(/no numeric/);
  });

  it('refuses too many periods instead of truncating', async () => {
    const env = makeEnv();
    const rec = [];
    for (let i = 0; i < 2100; i++) rec.push({ k: 's', id: `x${i}`, s: day(1) + i * H, e: day(1) + i * H, v: 60, u: 'count/min' });
    await upload(env, { type: HR, mode: 'recent', window: { start: day(1), end: env.now } }, rec);
    await expect(summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-09-30', period: 'hour' })).rejects.toThrow(/coarser period/);
  });
});

describe('getSamples', () => {
  it('returns readings with local times and refuses over-limit requests', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 's', id: 'a', s: day(1, 8), e: day(1, 8), v: 50, u: 'count/min', src: 'Watch', md: { context: 'rest' } },
      { k: 's', id: 'b', s: day(1, 9), e: day(1, 9), v: 60, u: 'count/min', src: 'Watch' },
    ]);
    const r = await getSamples(deps(env, 'Europe/Kyiv'), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01' });
    expect(r.samples).toMatchObject([{ start: '2024-06-01 11:00:00', value: 50, source: 'Watch', details: { md: { context: 'rest' } } }, { value: 60 }]);
    await expect(getSamples(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', limit: 1 })).rejects.toThrow(/There are 2 readings/);
  });
});

describe('getSleep', () => {
  it('picks one source per night and splits stages', async () => {
    const env = makeEnv();
    const sl = (id: string, s: number, e: number, c: number, src: string) => ({ k: 's', id, s, e, c, src });
    await upload(env, { type: SLEEP, mode: 'recent', window: { start: day(1), end: env.now } }, [
      sl('1', day(1, 22), day(2, 1), 3, 'Watch'),
      sl('2', day(2, 1), day(2, 3), 4, 'Watch'),
      sl('3', day(2, 3), day(2, 6), 5, 'Watch'),
      sl('4', day(2, 3), day(2, 3) + 10 * 60_000, 2, 'Watch'),
      sl('5', day(1, 22), day(2, 6), 1, 'SleepApp'),
    ]);
    const r = await getSleep(deps(env), { start_date: '2024-06-02', end_date: '2024-06-02' });
    expect(r.nights).toEqual([{
      night: '2024-06-02', asleep_min: 480, in_bed_min: 0, core_min: 180, deep_min: 120, rem_min: 180, awake_min: 10,
      unspecified_asleep_min: 0, went_to_bed: '22:00', woke_up: '06:00', source: 'Watch',
    }]);
  });
});

describe('getWorkouts / profile / list', () => {
  it('lists workouts with pauses excluded', async () => {
    const env = makeEnv();
    await upload(env, { type: 'HKWorkoutTypeIdentifier', mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 'w', id: 'w1', s: day(3, 7), e: day(3, 8), act: 37, actName: 'Running', dur: 3000, en: 500.24, dist: 10123, src: 'Watch' },
    ]);
    const r = await getWorkouts(deps(env), { start_date: '2024-06-01', end_date: '2024-06-30', activity: 'run' });
    expect(r.workouts).toMatchObject([{ start: '2024-06-03 07:00', activity: 'Running', duration_min: 50, active_kcal: 500.2, distance_km: 10.123 }]);
  });

  it('shows workout segments as local times and merges repeats', async () => {
    const env = makeEnv();
    const seg = (s: number, e: number, actName: string) => ({ s, e, act: 1, actName });
    const at = (d: number, h: number, m: number) => day(d, h) + m * 60_000;
    await upload(env, { type: 'HKWorkoutTypeIdentifier', mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 'w', id: 'w1', s: day(3, 7), e: day(3, 8), act: 82, actName: 'Multisport', dur: 3600, acts: [seg(day(3, 7), at(3, 7, 20), 'Running'), seg(at(3, 7, 20), at(3, 7, 40), 'Running'), seg(at(3, 7, 40), day(3, 8), 'Cycling')], src: 'Watch' },
      { k: 'w', id: 'w2', s: day(4, 7), e: day(4, 8), act: 37, actName: 'Running', dur: 3600, acts: [seg(day(4, 7), at(4, 7, 30), 'Running'), seg(at(4, 7, 30), day(4, 8), 'Running')], src: 'Watch' },
    ]);
    const r = await getWorkouts(deps(env), { start_date: '2024-06-01', end_date: '2024-06-30' });
    const [multi, single] = r.workouts as { segments: unknown }[];
    expect(multi!.segments).toEqual([{ activity: 'Running', start: '07:00', minutes: 40 }, { activity: 'Cycling', start: '07:40', minutes: 20 }]);
    expect(single!.segments).toBeNull();
  });

  it('understands everyday names and suggests close matches', async () => {
    const env = makeEnv();
    await upload(env, { type: STEPS, mode: 'stats', window: { start: day(1), end: env.now } }, [{ k: 'h', s: day(1, 9), e: day(1, 10), agg: 'sum', v: 1000, u: 'count' }]);
    const r = await summarize(deps(env), { type: 'Steps', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day' });
    expect(r.type).toBe('StepCount');
    await expect(summarize(deps(env), { type: 'Heartrat', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day' })).rejects.toThrow(/Did you mean HeartRate/);
  });

  it('computes age from the profile', async () => {
    const env = makeEnv();
    await upload(env, { type: '_profile', mode: 'profile' }, [{ k: 'p', dob: '1990-07-15', sex: 'female', blood: 'A+' }]);
    const r = await getProfile(deps(env));
    expect(r.profile).toMatchObject({ dob: '1990-07-15', sex: 'female', age: 33 });
  });

  it('lists synced types', async () => {
    const env = makeEnv();
    await seedSteps(env);
    const r = await listAvailableData(deps(env));
    expect(r.types).toMatchObject([{ name: 'StepCount', group: 'activity', unit: 'count', aggregation: 'cumulative' }]);
  });
});

describe('series samples', () => {
  it('deleting a series sample removes all of its expanded readings', async () => {
    const env = makeEnv();
    await upload(env, { type: HR, mode: 'recent', window: { start: day(1), end: env.now } }, [
      { k: 's', id: 'S1#0', s: day(1, 8), e: day(1, 8), v: 100, u: 'count/min' },
      { k: 's', id: 'S1#1', s: day(1, 8) + 5000, e: day(1, 8) + 5000, v: 110, u: 'count/min' },
      { k: 's', id: 'S2', s: day(1, 9), e: day(1, 9), v: 60, u: 'count/min' },
    ]);
    await upload(env, { type: HR }, [{ k: 'd', id: 'S1' }]);
    const r = await summarize(deps(env), { type: 'HeartRate', start_date: '2024-06-01', end_date: '2024-06-01', period: 'none', stat: 'count' });
    expect((r.rows as { value: number }[])[0]!.value).toBe(1);
  });
});

describe('merged totals', () => {
  it('are rounded to whole counts', async () => {
    const env = makeEnv();
    await upload(env, { type: STEPS, mode: 'stats', window: { start: day(1), end: env.now } }, [
      { k: 'h', s: day(1, 9), e: day(1, 10), agg: 'sum', v: 1000.4, u: 'count' },
      { k: 'h', s: day(1, 10), e: day(1, 11), agg: 'sum', v: 500.4, u: 'count' },
    ]);
    const r = await summarize(deps(env), { type: 'StepCount', start_date: '2024-06-01', end_date: '2024-06-01', period: 'day' });
    expect(r.rows).toEqual([{ period: '2024-06-01', value: 1501, unit: 'count' }]);
  });
});

describe('getOverview daily average', () => {
  it('is not diluted by days before the first data', async () => {
    const env = makeEnv();
    await upload(env, { type: STEPS, mode: 'stats', window: { start: Date.UTC(2023, 0, 1), end: env.now } }, [
      { k: 'h', s: day(1, 9), e: day(1, 10), agg: 'sum', v: 1000, u: 'count' },
      { k: 'h', s: day(2, 9), e: day(2, 10), agg: 'sum', v: 500, u: 'count' },
    ]);
    const r = await getOverview(deps(env), { days: 365 });
    expect((r.metrics as { steps: unknown }).steps).toEqual({ dailyAverage: 50, total: 1500, daysCovered: 30 });
  });
});

describe('getOverview', () => {
  it('returns every metric in a fixed order with per-metric results', async () => {
    const env = makeEnv();
    await seedSteps(env);
    const r = await getOverview(deps(env), { days: 30 });
    expect(Object.keys(r.metrics as object)).toEqual([
      'steps', 'activeEnergyKcal', 'exerciseMinutes', 'restingHeartRateBpm', 'hrvSdnnMs', 'bodyMassKg', 'vo2Max', 'sleep', 'workouts',
    ]);
    expect((r.metrics as { steps: unknown }).steps).toEqual({ dailyAverage: 50, total: 1500, daysCovered: 30 });
    expect((r.metrics as { sleep: unknown }).sleep).toBe('no data');
    expect(r.period).toBe('2024-06-01..2024-06-30');
    expect(r.dataAsOf).not.toBeNull();
  });
});
