import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { assessRaceReadiness, parseGoalTime } from '../../src/readiness/assess.js';
import { addDays } from '../../src/readiness/features.js';
import { readinessSchema } from '../../src/readiness/schema.js';
import { TOOL_NAMES, toolScopes, SERVER_INSTRUCTIONS } from '../../src/mcp/server.js';
import { deps, makeEnv, type Env } from '../helpers/memory.js';
import { at, runnerSeeds, seedRuns } from '../helpers/readiness-data.js';
import { serve } from '../helpers/synthetic.js';

/**
 * The whole tool through the real ingest code, DuckDB and parquet: a runner with 12 weeks of training, a half-marathon race and
 * the questions an assistant can ask. All times are hand-checkable (constant paces).
 */
const AS_OF = '2024-06-29'; // Saturday; makeEnv() "now" is 2024-06-30 12:00 UTC
const HM_ID = 'hm-race-1';
const secs = (hms: string) => hms.split(':').reduce((n, x) => n * 60 + Number(x), 0);

let env: Env;
const D = () => deps(env);
const ask = (args: Parameters<typeof assessRaceReadiness>[1] = {}, o: Parameters<typeof assessRaceReadiness>[2] = {}) => assessRaceReadiness(D(), { max_hr: 190, as_of_date: AS_OF, ...args }, o);

beforeAll(async () => {
  env = makeEnv();
  env.meta.users.get(env.uid)!.raceGoals = { 'chicago-marathon-2024': { raceName: 'Chicago Marathon', raceDate: '2024-07-13', goalSeconds: 13_500, updatedAt: 1 } };
  await seedRuns(env, runnerSeeds(AS_OF, HM_ID));
}, 120_000);

describe('assess_race_readiness end to end', () => {
  it('converts the tagged half marathon, reports a valid result and discloses what it could not use', async () => {
    const r = await ask({ race_workout_ids: [HM_ID] });
    expect(readinessSchema.safeParse(r).success).toBe(true);
    expect(r).toMatchObject({ status: 'ok', mode: 'race_window', as_of: AS_OF, race: { id: 'chicago-marathon-2024', goal_time: '3:45:00', goal_pace_per_km: '5:20', days_until: 14 } });
    const e1 = (r.estimators as { name: string; predicted: string; sigma_pct: number; inputs: Record<string, unknown> }[]).find((e) => e.name === 'E1_race_conversion')!;
    // 21.0975 km at 295 s/km = 6 223.8 s; x 2.19 = 13 630 s (3:47:10).
    expect(Math.abs(secs(e1.predicted) - 13_630)).toBeLessThanOrEqual(3);
    expect(e1.sigma_pct).toBe(3.5);
    expect(e1.inputs).toMatchObject({ workout_ids: [HM_ID], effort_inferred: false, R_source: 'default' });
    expect(r.assumptions).toMatchObject({ max_hr: 190, max_hr_source: 'user', goal_time_source: 'race_goal' });
    expect(r.data_gaps as string[]).toEqual(expect.arrayContaining([expect.stringContaining('No prior marathon')]));
    expect((r.coverage as { type: string }[]).some((c) => c.type === 'Workouts')).toBe(true);
    // 3 runs of 30 km or more in the last 12 weeks (30, 32, 32): the check is met.
    expect((r.modifiers as { check: string; value: number; status: string }[]).find((m) => m.check === 'runs_30km_or_more')).toMatchObject({ value: 3, status: 'met' });
    // The shortlisted runs without raw data are reported, not hidden.
    expect(JSON.stringify(r.data_gaps)).toMatch(/not analysed from raw data/);
  });

  it('infers the same effort from heart rate when the race is not tagged', async () => {
    const r = await ask();
    const e1 = (r.estimators as { name: string; predicted: string; inputs: Record<string, unknown> }[]).find((e) => e.name === 'E1_race_conversion')!;
    expect(e1.inputs).toMatchObject({ effort_inferred: true, workout_ids: [HM_ID] });
    expect(Math.abs(secs(e1.predicted) - 13_630)).toBeLessThanOrEqual(3);
  });

  it('accepts a what-if goal time and shows its source', async () => {
    const base = await ask({ race_workout_ids: [HM_ID] });
    const fast = await ask({ race_workout_ids: [HM_ID], goal_time: '3:30:00' });
    expect((fast.likelihood as { score_0_10: number }).score_0_10).toBeLessThan((base.likelihood as { score_0_10: number }).score_0_10);
    expect(fast.assumptions).toMatchObject({ goal_time_source: 'parameter' });
    expect(fast.race).toMatchObject({ goal_time: '3:30:00' });
  });

  it('never reads data after as_of_date (a faster half marathon the next day changes nothing)', async () => {
    const before = await ask({ race_workout_ids: [HM_ID] });
    await seedRuns(env, [
      { id: 'future-hm-001', start: at('2024-06-30', '07:00'), km: 21.1, pace: 250, hr: 185, gain: 0 },
      { id: 'future-long-1', start: at('2024-07-05', '07:00'), km: 35, pace: 300, hr: 150, gain: 0 },
    ]);
    const after = await ask({ race_workout_ids: [HM_ID, 'future-hm-001'] });
    const pick = (x: Record<string, unknown>) => ({ l: x.likelihood, p: x.prediction, e: x.estimators, m: x.modifiers, b: x.benchmarks, c: x.confidence });
    expect(pick(after)).toEqual(pick(before));
    expect(JSON.stringify(after.data_gaps)).toContain('Tagged race future-hm-001 is not among the running workouts up to 2024-06-29');
    // The same question asked later does see it.
    const later = await assessRaceReadiness(D(), { max_hr: 190, as_of_date: '2024-06-30', race_workout_ids: ['future-hm-001'] });
    expect(JSON.stringify((later.estimators as { predicted: string }[])[0])).not.toEqual(JSON.stringify((before.estimators as { predicted: string }[])[0]));
  });

  it('with an earlier as_of_date the later race does not exist yet', async () => {
    const r = await ask({ as_of_date: '2024-05-25', race_workout_ids: [HM_ID] });
    expect(r.status).toBe('insufficient_data');
    expect(JSON.stringify(r.data_gaps)).toContain(`Tagged race ${HM_ID} is not among the running workouts up to 2024-05-25`);
    expect(r.likelihood).toBeUndefined();
  });

  it('removes a duplicate recording of the same run and says so', async () => {
    await seedRuns(env, [{ id: 'long-6-dup0', start: at(addDays(AS_OF, -7 * 5), '07:00:20'), km: 29.9, pace: 340, hr: null, raw: false }]);
    const r = await ask({ race_workout_ids: [HM_ID] });
    expect(JSON.stringify(r.notes)).toMatch(/1 overlapping duplicate workout\(s\)/);
  });

  it('notes treadmill runs and does not require a route for them', async () => {
    await seedRuns(env, [{ id: 'treadmill-01', start: at('2024-06-26', '18:00'), km: 8, pace: 340, hr: 150, indoor: true }]);
    const r = await ask({ race_workout_ids: [HM_ID], detail: 'full' });
    expect(JSON.stringify(r.notes)).toMatch(/Treadmill runs/);
    expect((r.workouts as { id: string; indoor: boolean }[]).find((w) => w.id === 'treadmill-01')?.indoor).toBe(true);
  });

  it('keeps going when the time budget runs out, using the tagged race from its summary and listing the skipped runs', async () => {
    let calls = 0;
    const clock = () => (calls++ === 0 ? 0 : 1e9);
    const r = await ask({ race_workout_ids: [HM_ID] }, { clock });
    expect(r.status).toBe('ok');
    expect(JSON.stringify(r.data_gaps)).toContain('time budget reached');
    const e1 = (r.estimators as { name: string; inputs: Record<string, unknown> }[]).find((e) => e.name === 'E1_race_conversion')!;
    expect(e1.inputs).toMatchObject({ workout_ids: [HM_ID], effort_inferred: false });
  });

  it('respects connection scopes: without profile or events access, age, sex and fueling are reported as unknown', async () => {
    const r = await ask({ race_workout_ids: [HM_ID] }, { scopes: ['health:workouts:read', 'health:daily:read'] });
    expect(JSON.stringify(r.data_gaps)).toContain('not granted profile access');
    expect(JSON.stringify(r.data_gaps)).toContain('not granted');
    expect((r.confidence as { components: { name: string; status: string }[] }).components.find((c) => c.name === 'fueling_logged')?.status).toBe('unknown');
  });

  it('uses a default max HR when none is confirmed by two workouts and says so', async () => {
    const e2 = makeEnv();
    e2.meta.users.get(e2.uid)!.raceGoals = { 'chicago-marathon-2024': { raceName: 'Chicago Marathon', raceDate: '2024-07-13', goalSeconds: 13_500, updatedAt: 1 } };
    await seedRuns(e2, [
      { id: 'one-run-0001', start: at('2024-06-20'), km: 10, pace: 330, hr: 150, hrMax: 172, raw: false },
      { id: 'one-run-0002', start: at('2024-06-22'), km: 10, pace: 330, hr: 150, hrMax: 181, raw: false },
    ]);
    const r = await assessRaceReadiness(deps(e2), { as_of_date: AS_OF });
    expect(r.assumptions).toMatchObject({ max_hr: 190, max_hr_source: 'default' });
    expect(JSON.stringify(r.data_gaps)).toContain('Max heart rate is a default');
  });
  it('takes the max HR confirmed by two workouts as observed', async () => {
    const r = await assessRaceReadiness(D(), { as_of_date: AS_OF, race_workout_ids: [HM_ID] });
    expect(r.assumptions).toMatchObject({ max_hr_source: 'observed' });
  });
});

describe('statuses and validation', () => {
  it('no_race_goal without a goal, for an unknown race id, and when the race is already past', async () => {
    const e2 = makeEnv();
    const none = await assessRaceReadiness(deps(e2), { as_of_date: AS_OF });
    expect(none).toMatchObject({ status: 'no_race_goal' });
    expect(readinessSchema.safeParse(none).success).toBe(true);
    expect(await ask({ race_id: 'nope' })).toMatchObject({ status: 'no_race_goal' });
    // The race (13 July) is already past on 20 July: asked "today" (a later clock) or by name.
    const later = { ...D(), now: () => Date.UTC(2024, 6, 25, 12) };
    expect(await assessRaceReadiness(later, { as_of_date: '2024-07-20' })).toMatchObject({ status: 'no_race_goal' });
    const byName = await assessRaceReadiness(later, { as_of_date: '2024-07-20', race_id: 'chicago-marathon-2024' });
    expect(byName).toMatchObject({ status: 'no_race_goal' });
    expect(JSON.stringify(byName.notes)).toContain('before as_of_date');
  });
  it('unsupported_distance for a race that is not a marathon', async () => {
    const e2 = makeEnv();
    e2.meta.users.get(e2.uid)!.raceGoals = { 'turkey-trot-5k': { raceName: 'Turkey Trot', raceDate: '2024-07-14', goalSeconds: 1_500, updatedAt: 1 } };
    const r = await assessRaceReadiness(deps(e2), { as_of_date: AS_OF });
    expect(r).toMatchObject({ status: 'unsupported_distance', race: { id: 'turkey-trot-5k', goal_pace_per_km: null } });
    expect(readinessSchema.safeParse(r).success).toBe(true);
  });
  it('prefers the next upcoming marathon over a nearer shorter race', async () => {
    const e2 = makeEnv();
    e2.meta.users.get(e2.uid)!.raceGoals = {
      'turkey-trot-5k': { raceName: 'Turkey Trot', raceDate: '2024-07-02', goalSeconds: 1_500, updatedAt: 1 },
      'chicago-marathon-2024': { raceName: 'Chicago Marathon', raceDate: '2024-07-13', goalSeconds: 13_500, updatedAt: 1 },
    };
    const r = await assessRaceReadiness(deps(e2), { as_of_date: AS_OF });
    expect(r.race).toMatchObject({ id: 'chicago-marathon-2024' });
  });
  it('rejects bad arguments with a clear error', async () => {
    await expect(ask({ goal_time: '3:75:00' })).rejects.toThrow(/goal_time/);
    await expect(ask({ goal_time: '0:05:00' })).rejects.toThrow(/goal_time/);
    await expect(ask({ as_of_date: '2024-02-30' })).rejects.toThrow(/as_of_date/);
    await expect(ask({ as_of_date: '2024-07-02' })).rejects.toThrow(/future/);
    await expect(ask({ race_workout_ids: ['x'] })).rejects.toThrow(/race_workout_ids/);
    await expect(ask({ race_workout_ids: Array.from({ length: 11 }, (_, i) => `workout-${i}-aa`) })).rejects.toThrow(/up to 10/);
    await expect(ask({ prior_marathon_workout_id: 'a/b' })).rejects.toThrow(/prior_marathon/);
    await expect(ask({ timezone: 'Mars/Base' })).rejects.toThrow(/timezone/);
  });
  it('parses goal times', () => {
    expect(parseGoalTime('3:45:00')).toBe(13_500);
    expect(parseGoalTime('2:59:59')).toBe(10_799);
    expect(() => parseGoalTime('3:45')).toThrow();
    expect(() => parseGoalTime('25:00:00')).toThrow();
  });
});

describe('MCP registration', () => {
  let s: Awaited<ReturnType<typeof serve>>;
  beforeAll(async () => { s = await serve(env); }, 60_000);
  afterAll(async () => { await s?.close(); });

  it('is offered read-only, declared with workout and daily scopes, and described in the server instructions', async () => {
    expect(TOOL_NAMES).toContain('assess_race_readiness');
    expect(toolScopes('assess_race_readiness')).toEqual(['health:workouts:read', 'health:daily:read']);
    expect(SERVER_INSTRUCTIONS).toMatch(/assess_race_readiness/);
    expect(SERVER_INSTRUCTIONS).toMatch(/do not prescribe training/);
    const tool = (await s.client.listTools()).tools.find((t) => t.name === 'assess_race_readiness')!;
    expect(tool.annotations).toMatchObject({ readOnlyHint: true, destructiveHint: false });
    expect(tool.description).toMatch(/not a guarantee, medical assessment, or training prescription/);
    expect(tool.description).toMatch(/more than 6 weeks away/);
    expect(Object.keys(tool.inputSchema.properties ?? {}).sort()).toEqual(['as_of_date', 'detail', 'distance_source', 'goal_time', 'max_hr', 'prior_marathon_workout_id', 'race_id', 'race_workout_ids', 'timezone']);
  });
  it('answers through the real endpoint with output that validates against the declared schema', async () => {
    const r = await s.call('assess_race_readiness', { as_of_date: AS_OF, max_hr: 190, race_workout_ids: [HM_ID] });
    expect(r.isError, r.text.slice(0, 400)).toBe(false);
    expect(r.json).toMatchObject({ status: 'ok', likelihood: { label: expect.any(String) }, confidence: { percent: expect.any(Number) } });
    expect(JSON.stringify(r.json).length).toBeLessThan(60 * 1024);
  });
  it('reports a clear tool error for bad input', async () => {
    const r = await s.call('assess_race_readiness', { as_of_date: '2024-02-30' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('as_of_date');
  });
});
