import { describe, expect, it } from 'vitest';
import {
  getDailyContext, getGlucose, getHealthEvents, getHourlySeries, getNutritionLog, getProfile, getRecovery, getTrainingLoad,
} from '../../src/query/health.js';
import { derivedWeather } from '../../src/query/workouts.js';
import { deps, makeEnv, upload, type Env } from '../helpers/memory.js';

const DAY = 86_400_000;
const HOUR = 3_600_000;
const W = 'HKWorkoutTypeIdentifier';
const iso = (ms: number) => new Date(ms).toISOString().slice(0, 10);
const enable = (env: Env, ...categories: string[]) => (env.meta.users.get(env.uid)!.categories = ['core', ...categories]);
const stats = (env: Env) => ({ type: '_daily', schema: 2 as const, mode: 'stats' as const, window: { start: 0, end: env.now } });

async function seedWorkout(env: Env, id: string, s: number, durMin: number, extra: Record<string, unknown> = {}) {
  await upload(env, { type: W, caughtUp: true }, [{ k: 'w', id, s, e: s + durMin * 60_000, act: 37, actName: 'Running', dur: durMin * 60, en: 400, dist: 8000, src: 'Apple Watch', bid: 'com.apple.health', ...extra }]);
}

describe('daily context with categories, groups and rollups', () => {
  const base = Date.UTC(2024, 5, 3); // a Monday
  const days = Array.from({ length: 14 }, (_, i) => iso(base + i * DAY));

  it('merges enabled category rows, filters by group and hides switched-off categories', async () => {
    const env = makeEnv();
    enable(env, 'nutrition');
    await upload(env, stats(env), days.map((d, i) => ({ k: 'day', day: d, m: { steps: 8000 + i * 100, restingHr: 52, sleepAsleepMin: 420 } })));
    await upload(env, { ...stats(env), type: '_daily_nutrition' }, days.map((d) => ({ k: 'day', day: d, m: { proteinG: 120, waterL: 2.4 } })));
    const q = deps(env);
    const nutrition = await getDailyContext(q, { start_date: days[0]!, end_date: days[2]!, groups: ['nutrition'] });
    expect(nutrition.days).toEqual([
      { date: days[0], proteinG: 120, waterL: 2.4 }, { date: days[1], proteinG: 120, waterL: 2.4 }, { date: days[2], proteinG: 120, waterL: 2.4 },
    ]);
    const heart = await getDailyContext(q, { start_date: days[0]!, end_date: days[0]!, groups: ['heart'] });
    expect(heart.days).toEqual([{ date: days[0], restingHr: 52 }]);
    // Switching the category off hides what was stored (the server also deletes it when the app tells it to).
    enable(env);
    const off = await getDailyContext(q, { start_date: days[0]!, end_date: days[13]! });
    expect((off.days as Record<string, unknown>[])[0]).not.toHaveProperty('proteinG');
    expect((off.days as Record<string, unknown>[])[0]).toHaveProperty('steps');
  });

  it('averages by week and month', async () => {
    const env = makeEnv();
    await upload(env, stats(env), days.map((d, i) => ({ k: 'day', day: d, m: { steps: 1000 * (i + 1), sleepBedtime: '23:00' } })));
    const weeks = await getDailyContext(deps(env), { start_date: days[0]!, end_date: days[13]!, rollup: 'week', metrics: ['steps', 'sleepBedtime'] });
    expect(weeks.periods).toEqual([
      { period: days[0], days_with_data: 7, steps: 4000 },
      { period: days[7], days_with_data: 7, steps: 11000 },
    ]);
    const month = await getDailyContext(deps(env), { start_date: days[0]!, end_date: days[13]!, rollup: 'month' });
    expect((month.periods as unknown[]).length).toBe(1);
  });
});

describe('hourly series', () => {
  it('returns hourly rows and daily rollups in the user timezone', async () => {
    const env = makeEnv();
    const t0 = Date.UTC(2024, 5, 20, 0);
    const t = Array.from({ length: 48 }, (_, i) => t0 + i * HOUR);
    await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [
      { k: 'hs', st: 'HeartRate', u: 'count/min', t, v: t.map((_, i) => 60 + (i % 24)), lo: t.map((_, i) => 50 + (i % 24)), hi: t.map((_, i) => 70 + (i % 24)) },
      { k: 'hs', st: 'StepCount', u: 'count', t, v: t.map(() => 100) },
    ]);
    const hourly = await getHourlySeries(deps(env), { series: 'HeartRate', start_date: '2024-06-20', end_date: '2024-06-20', resolution: 'hour' });
    expect(hourly.count).toBe(24);
    expect((hourly.hours as unknown[][])[1]).toEqual(['2024-06-20 01:00', 61, 51, 71]);
    const steps = await getHourlySeries(deps(env), { series: 'StepCount', start_date: '2024-06-20', end_date: '2024-06-21', resolution: 'day' });
    expect(steps.days).toEqual([['2024-06-20', 2400, 24], ['2024-06-21', 2400, 24]]);
    const hr = await getHourlySeries(deps(env), { series: 'HeartRate', start_date: '2024-06-20', end_date: '2024-06-21', resolution: 'day' });
    expect((hr.days as unknown[][])[0]).toEqual(['2024-06-20', 71.5, 50, 93, 24]);
  });
});

describe('recovery vs baseline', () => {
  it('flags a low HRV / high resting HR night and derives overnight heart rate from hourly data', async () => {
    const env = makeEnv(Date.UTC(2024, 5, 29, 12));
    const end = Date.UTC(2024, 5, 28);
    const dates = Array.from({ length: 70 }, (_, i) => iso(end - (69 - i) * DAY));
    await upload(env, stats(env), dates.map((d, i) => {
      const last = i === 69;
      return { k: 'day', day: d, m: { hrv: last ? 40 : 60 + (i % 3), restingHr: last ? 58 : 52 + (i % 2), sleepAsleepMin: 420 + (i % 5), sleepBedtime: '23:00', sleepWakeTime: '07:00' } };
    }));
    // Hourly data for the last night: 23:00 (27 June) to 06:00 (28 June).
    const nightStart = Date.UTC(2024, 5, 27, 23);
    const t = Array.from({ length: 8 }, (_, i) => nightStart + i * HOUR);
    await upload(env, { type: '_hourly', schema: 2, mode: 'stats' }, [
      { k: 'hs', st: 'HeartRate', t, v: t.map(() => 50), lo: t.map((_, i) => 46 + i), hi: t.map(() => 60) },
      { k: 'hs', st: 'HeartRateVariabilitySDNN', t: [t[2]!, t[4]!], v: [66, 74] },
    ]);
    const r = await getRecovery(deps(env), { window_days: 60 });
    const m = r.metrics as Record<string, { value: number; baseline_mean: number; status: string; change_pct: number }>;
    expect(r.date).toBe('2024-06-28');
    expect(m.hrv!.status).toBe('below baseline');
    expect(m.hrv!.change_pct).toBeLessThan(-25);
    expect(m.restingHr!.status).toBe('above baseline');
    expect(m.sleepHrAvg!.value).toBe(50);
    expect(m.sleepHrMin!.value).toBe(46);
    expect(m.hrvOvernight!.value).toBe(70);
  });
});

describe('training load', () => {
  it('builds load, fitness and fatigue from heart rate and effort scores', async () => {
    const env = makeEnv(Date.UTC(2024, 5, 30, 12));
    for (let i = 0; i < 20; i++) await seedWorkout(env, `run-${String(i).padStart(2, '0')}-aaaaaaaa`, Date.UTC(2024, 5, 10 + i, 7), 60, { hrAvg: 150, hrMax: 180 });
    await seedWorkout(env, 'strength-aaaaaaaa', Date.UTC(2024, 5, 29, 18), 45, { act: 50, actName: 'Strength', stats: { WorkoutEffortScore: { avg: 6, u: 'appleEffortScore' } } });
    const r = await getTrainingLoad(deps(env), { end_date: '2024-06-30', days: 28, resting_hr: 55 });
    const inputs = r.inputs as { workouts_by_basis: { trimp: number; effort: number }; max_hr: number };
    expect(inputs.workouts_by_basis.trimp).toBe(20);
    expect(inputs.workouts_by_basis.effort).toBe(1);
    expect(inputs.max_hr).toBe(180);
    const cur = r.current as { ctl: number; atl: number; tsb: number; date: string };
    expect(cur.date).toBe('2024-06-30');
    expect(cur.ctl).toBeGreaterThan(20);
    expect(cur.atl).toBeGreaterThan(0);
    expect(cur.tsb).toBeCloseTo(cur.ctl - cur.atl, 0);
    expect((r.weekly_load as unknown[]).length).toBeGreaterThan(3);
  });
});

describe('glucose, events, nutrition and profile (opt-in categories)', () => {
  const run = 'run-glucose-aaaaaaaa';
  const t0 = Date.UTC(2024, 5, 20, 7, 0);

  async function seed(env: Env) {
    enable(env, 'devices', 'mind', 'nutrition', 'profile');
    await seedWorkout(env, run, t0, 30, { hrAvg: 150, hrMax: 170 });
    const times = Array.from({ length: 12 * 9 }, (_, i) => Date.UTC(2024, 5, 20, 5, 0) + i * 300_000); // 05:00-13:55
    const value = times.map((t) => (t < t0 ? 105 : t < t0 + 30 * 60_000 ? 85 : 165));
    await upload(env, { type: '_events_devices', schema: 2 }, [
      { k: 'ev', ty: 'BloodGlucose', u: 'mg/dL', src: 'Dexcom', s: times, v: value },
      { k: 'ev', ty: 'InsulinDelivery', u: 'IU', src: 'Pump', s: [t0 - 3_600_000], v: [2], meta: [{ HKInsulinDeliveryReason: 2 }] },
    ]);
  }

  it('reports glucose before, during and after a workout, and range statistics', async () => {
    const env = makeEnv();
    await seed(env);
    const g = await getGlucose(deps(env), { workout_id: run });
    expect((g.before_workout as { mean_mg_dl: number }).mean_mg_dl).toBe(105);
    expect((g.during_workout as { mean_mg_dl: number; min_mg_dl: number }).mean_mg_dl).toBe(85);
    expect((g.after_workout as { max_mg_dl: number; time_above_high_pct: number }).max_mg_dl).toBe(165);
    expect(g.at_start_mg_dl).toEqual({ value: 85, minutes_before_start: 0 });
    expect((g.insulin as { units: number }[])[0]!.units).toBe(2);
    const range = await getGlucose(deps(env), { start_date: '2024-06-20', end_date: '2024-06-20' });
    const o = range.overall as { readings: number; time_in_range_pct: number; time_below_low_pct: number; gmi_percent: number };
    expect(o.readings).toBe(108);
    expect(o.time_in_range_pct).toBe(100);
    expect(o.time_below_low_pct).toBe(0);
    expect(o.gmi_percent).toBeGreaterThan(5);
  });

  it('refuses while a category is switched off, with a message the AI can pass on', async () => {
    const env = makeEnv();
    await expect(getGlucose(deps(env), { start_date: '2024-06-20', end_date: '2024-06-20' })).rejects.toMatchObject({ code: 'category_disabled' });
    await expect(getHealthEvents(deps(env), { category: 'mind', start_date: '2024-06-20', end_date: '2024-06-20' })).rejects.toThrow(/switched off/);
  });

  it('lists symptoms with severity, blood pressure pairs and medications', async () => {
    const env = makeEnv();
    enable(env, 'devices', 'mind', 'medications');
    await upload(env, { type: '_events_mind', schema: 2 }, [{ k: 'ev', ty: 'Fatigue', src: 'Health', s: [t0], c: [3], ids: ['sym-1'] }]);
    await upload(env, { type: '_events_devices', schema: 2 }, [
      { k: 'ev', ty: 'BloodPressureSystolic', u: 'mmHg', s: [t0], v: [118], ids: ['bp-1'] },
      { k: 'ev', ty: 'BloodPressureDiastolic', u: 'mmHg', s: [t0], v: [76], ids: ['bp-2'] },
    ]);
    await upload(env, { type: '_events_medications', schema: 2 }, [{ k: 'ev', ty: 'Medication', s: [t0], ids: ['med-1'], meta: [{ name: 'Metoprolol', form: 'tablet' }] }]);
    const sym = await getHealthEvents(deps(env), { category: 'mind', start_date: '2024-06-20', end_date: '2024-06-20' });
    expect(sym.events).toEqual([{ time: '2024-06-20 07:00', type: 'Fatigue', severity: 'moderate', source: 'Health' }]);
    const bp = await getHealthEvents(deps(env), { types: ['BloodPressureSystolic', 'BloodPressureDiastolic'], start_date: '2024-06-20', end_date: '2024-06-20' });
    expect((bp.events as { value: number }[]).map((e) => e.value)).toEqual([118, 76]);
    const meds = await getHealthEvents(deps(env), { category: 'medications', start_date: '2024-06-20', end_date: '2024-06-20' });
    expect((meds.events as { details: { name: string } }[])[0]!.details.name).toBe('Metoprolol');
  });

  it('shows what was eaten before a workout and the profile', async () => {
    const env = makeEnv();
    await seed(env);
    const at = Date.UTC(2024, 5, 20, 4, 30);
    await upload(env, { type: '_events_nutrition', schema: 2 }, [
      { k: 'ev', ty: 'DietaryCarbohydrates', u: 'g', src: 'Cronometer', s: [at], v: [60] },
      { k: 'ev', ty: 'DietaryEnergyConsumed', u: 'kcal', src: 'Cronometer', s: [at], v: [400] },
      { k: 'ev', ty: 'DietaryCaffeine', u: 'mg', src: 'Cronometer', s: [at - 3 * HOUR], v: [95] },
    ]);
    const log = await getNutritionLog(deps(env), { workout_id: run, hours_before: 6 });
    expect(log.entries).toEqual([
      { time: '2024-06-20 01:30', source: 'Cronometer', minutes_before_workout: 330, 'Caffeine (mg)': 95 },
      { time: '2024-06-20 04:30', source: 'Cronometer', minutes_before_workout: 150, 'Carbohydrates (g)': 60, 'EnergyConsumed (kcal)': 400 },
    ]);
    await upload(env, { type: '_events_profile', schema: 2 }, [{ k: 'ev', ty: 'Profile', s: [env.now], ids: ['profile'], meta: [{ dob: '1990-05-01', sex: 'male', wheelchair: false }] }]);
    const p = await getProfile(deps(env));
    expect((p.profile as { age_years: number; estimated_max_hr: number; sex: string })).toMatchObject({ age_years: 34, estimated_max_hr: 184, sex: 'male' });
  });
});

describe('derived weather', () => {
  it('computes dew point everywhere and heat index when it is hot and humid', () => {
    expect(derivedWeather({ HKWeatherTemperature: '20 degC', HKWeatherHumidity: '60 %' })).toEqual({ derived_dew_point_c: 12 });
    const hot = derivedWeather({ HKWeatherTemperature: '95 degF', HKWeatherHumidity: '70 %' });
    expect(hot.derived_heat_index_c).toBeGreaterThan(41);
    expect(hot.derived_dew_point_c).toBeGreaterThan(25);
    expect(derivedWeather({ HKWeatherTemperature: 'warm' })).toEqual({});
  });
});
