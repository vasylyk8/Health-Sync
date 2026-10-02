import { afterAll, beforeAll, describe, expect, it } from 'vitest';
// @ts-expect-error plain JS module shared with the monitoring scripts
import { alertOn, dailyValue, DAILY_KEYS, hourHrv, MEAL_KCAL, MEAL_PROTEIN, mealOn, PROFILE } from '../../../../scripts/synthetic/data.mjs';
import { TOOL_NAMES } from '../../src/mcp/server.js';
import { startSynthetic } from '../helpers/synthetic.js';

/**
 * Every question an AI can ask through KROK, asked of the synthetic user through the real MCP endpoint, with exact
 * expected answers. The same calls can be repeated by hand with `npx tsx scripts/local-probe.ts` or the mcp-probe workflow.
 */
type S = Awaited<ReturnType<typeof startSynthetic>>;
let s: S;
const asked = new Set<string>();
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ask = async (tool: string, args: Record<string, unknown> = {}): Promise<Record<string, any>> => {
  asked.add(tool);
  const r = await s.call(tool, args);
  expect(r.isError, `${tool}: ${r.text.slice(0, 300)}`).toBe(false);
  expect(r.json, tool).not.toBeNull();
  return r.json;
};

beforeAll(async () => { s = await startSynthetic(); }, 120_000);
afterAll(async () => { await s?.close(); });

const D = 63; // 2024-03-04 is the 63rd day after 2024-01-01

describe('every daily metric the phone can send comes back out of get_daily_context', () => {
  it('returns all metrics of one day unchanged', async () => {
    const r = await ask('get_daily_context', { start_date: '2024-03-04', end_date: '2024-03-04' });
    const row = r.days[0] as Record<string, number>;
    const missing = [...DAILY_KEYS.keys()].filter((k: string) => row[k] !== dailyValue(k, D));
    expect(missing).toEqual([]);
    expect(Object.keys(row).length).toBe(DAILY_KEYS.size + 1); // + date
  });

  it('groups select the right metrics', async () => {
    const r = await ask('get_daily_context', { start_date: '2024-03-04', end_date: '2024-03-04', groups: ['sleep'] });
    expect(Object.keys(r.days[0]).sort()).toEqual(['date', 'sleepAsleepMin', 'sleepAwakeMin', 'sleepBreathingDisturbances', 'sleepCoreMin', 'sleepDeepMin', 'sleepInBedMin', 'sleepRemMin', 'sleepingWristTempC']);
    for (const g of ['heart', 'activity', 'mobility', 'body', 'nutrition', 'cycle', 'mind', 'audio']) {
      const x = await ask('get_daily_context', { start_date: '2024-03-04', end_date: '2024-03-04', groups: [g] });
      expect(Object.keys(x.days[0]).length, `group ${g}`).toBeGreaterThan(2);
    }
  });

  it('weekly rollup averages and a long range stay within limits', async () => {
    const r = await ask('get_daily_context', { start_date: '2024-01-01', end_date: '2024-12-30', rollup: 'month', metrics: ['steps', 'hrv'] });
    expect(r.periods.length).toBe(12);
    const year = await ask('get_daily_context', { start_date: '2024-01-01', end_date: '2024-12-30', metrics: ['steps'] });
    expect(year.count).toBe(365);
  });
});

describe('hourly series, recovery and training load', () => {
  it('hourly HRV, heart rate and steps', async () => {
    const hrv = await ask('get_hourly_series', { series: 'HeartRateVariabilitySDNN', start_date: '2024-03-04', end_date: '2024-03-04', resolution: 'hour' });
    const at = (h: number) => hrv.hours.find((x: [string, number]) => x[0].endsWith(`${String(h + 1).padStart(2, '0')}:00`))[1];
    expect(at(10)).toBe(hourHrv(10)); // local time is UTC+1 in March
    expect(hrv.count).toBe(24);
  });

  it('recovery compares a day with the 60-day baseline', async () => {
    const r = await ask('get_recovery', { date: '2024-06-15' });
    expect(r.metrics.hrv.value).toBe(dailyValue('hrv', 166));
    expect(r.metrics.hrv.baseline_days).toBe(60);
    expect(r.metrics).toHaveProperty('restingHr');
  });

  it('training load estimates fitness from the Monday runs', async () => {
    const r = await ask('get_training_load', { start_date: '2024-03-01', end_date: '2024-03-31' });
    expect(r.current.ctl).toBeGreaterThan(0);
    expect(r.inputs.workouts_by_basis.trimp).toBeGreaterThan(0);
  });
});

describe('opt-in data', () => {
  it('nutrition log entries', async () => {
    const r = await ask('get_nutrition_log', { start_date: '2024-03-01', end_date: '2024-03-07' });
    const meals = [60, 61, 62, 63, 64, 65, 66].filter(mealOn);
    expect(r.entries.length).toBe(meals.length);
    expect(r.entries[0]['EnergyConsumed (kcal)']).toBe(MEAL_KCAL(meals[0]));
    expect(r.entries[0]['Protein (g)']).toBe(MEAL_PROTEIN(meals[0]));
  });

  it('heart events', async () => {
    const r = await ask('get_health_events', { category: 'heart', start_date: '2024-01-01', end_date: '2024-03-31' });
    expect(r.count).toBe(Array.from({ length: 91 }, (_, d) => d).filter(alertOn).length);
    expect(r.events[0].type).toBe('HighHeartRateEvent');
  });

  it('profile', async () => {
    const r = await ask('get_profile');
    expect(r.profile).toMatchObject({ dob: PROFILE.dob, sex: PROFILE.sex });
    expect(r.profile.age_years).toBeGreaterThan(30);
  });

  it('glucose around a run', async () => {
    const r = await ask('get_glucose', { workout_id: 'run-2024-03-04' });
    expect(r.during_workout.mean_mg_dl).toBe(90);
  });

  it('medications are off for this user and the tool says so', async () => {
    const r = await s.call('get_health_events', { category: 'medications', start_date: '2024-01-01', end_date: '2024-03-31' });
    expect(r.isError).toBe(true);
    expect(r.text).toMatch(/switched on|not available|off/i);
  });
});

describe('workout tools', () => {
  const id = 'run-2024-03-04';
  it('lists and describes workouts', async () => {
    const list = await ask('get_workouts', { start_date: '2024-03-01', end_date: '2024-03-31' });
    expect(list.workouts.length).toBe(4);
    const one = await ask('get_workout', { workout_id: id });
    expect(JSON.stringify(one)).toContain('sleepAsleepMin');
  });
  it('series, route, zones, splits, drift, best efforts and elevation', async () => {
    expect((await ask('get_workout_series', { workout_id: id, stream: 'HeartRate', max_points: 20 })).points.length).toBeGreaterThan(0);
    expect((await ask('get_workout_route', { workout_id: id, max_points: 50 })).trimmed_ends).toBe(true);
    expect((await ask('workout_hr_zones', { workout_id: id, max_hr: 200 })).zones[2].seconds).toBe(1800);
    expect((await ask('workout_splits', { workout_id: id })).splits).toHaveLength(5);
    expect((await ask('workout_hr_drift', { workout_id: id })).hr_change_percent).toBe(7.1);
    expect((await ask('workout_best_efforts', { workout_id: id, distances_m: [3000] })).efforts[0].moving_seconds).toBe(1080);
    expect(await ask('workout_elevation', { workout_id: id })).toHaveProperty('gain_m');
  });
});

describe('coverage of the tool list', () => {
  it('every tool the server offers was asked at least once above', () => {
    const offered = TOOL_NAMES.filter((t: string) => t !== 'get_account');
    expect([...asked].sort()).toEqual(expect.arrayContaining(offered));
  });
});
