import { describe, expect, it } from 'vitest';
import { AccountError, parseRaceGoal } from '../../src/account.js';
import { formatHms, getRaceGoal } from '../../src/query/race.js';
import { SERVER_INSTRUCTIONS, TOOL_NAMES, toolScopes } from '../../src/mcp/server.js';
import { makeEnv } from '../helpers/memory.js';

const ok = { raceId: 'chicago-marathon-2026', raceName: 'Chicago Marathon', raceDate: '2026-10-11', goalSeconds: 12_600 };

describe('parseRaceGoal', () => {
  it('accepts a valid goal and a clear', () => {
    expect(parseRaceGoal(ok)).toEqual(ok);
    expect(parseRaceGoal({ ...ok, goalSeconds: null }).goalSeconds).toBeNull();
    expect(parseRaceGoal({ ...ok, goalSeconds: 600 }).goalSeconds).toBe(600);
    expect(parseRaceGoal({ ...ok, goalSeconds: 86_400 }).goalSeconds).toBe(86_400);
  });
  it.each([
    [{ ...ok, raceId: 'Chicago' }], [{ ...ok, raceId: '' }], [{ ...ok, raceId: 'a'.repeat(41) }], [{ ...ok, raceId: 'a/b' }],
    [{ ...ok, raceName: '' }], [{ ...ok, raceName: 'x'.repeat(61) }], [{ ...ok, raceName: 'a\nb' }], [{ ...ok, raceName: 5 }],
    [{ ...ok, raceDate: '2026-02-30' }], [{ ...ok, raceDate: '10/11/2026' }], [{ ...ok, raceDate: undefined }],
    [{ ...ok, goalSeconds: 599 }], [{ ...ok, goalSeconds: 86_401 }], [{ ...ok, goalSeconds: 12_600.5 }], [{ ...ok, goalSeconds: '12600' }], [{ ...ok, goalSeconds: undefined }],
    [null], [[]], ['x'],
  ])('rejects %j', (payload) => {
    expect(() => parseRaceGoal(payload)).toThrow(AccountError);
  });
});

describe('get_race_goal', () => {
  it('is declared read-only with an existing broad scope (no new OAuth scope)', () => {
    expect(TOOL_NAMES).toContain('get_race_goal');
    expect(toolScopes('get_race_goal')).toEqual(['health:daily:read']);
    expect(SERVER_INSTRUCTIONS).toMatch(/get_race_goal/);
    expect(SERVER_INSTRUCTIONS).toMatch(/not a measured/);
  });

  it('returns goal time, marathon pace and days to race in the user timezone', async () => {
    const env = makeEnv(Date.UTC(2026, 9, 3, 23, 30)); // 3 Oct 23:30 UTC = 4 Oct in Berlin
    env.meta.addUser(env.uid, { tz: 'Europe/Berlin', raceGoals: {
      'chicago-marathon-2026': { raceName: 'Chicago Marathon', raceDate: '2026-10-11', goalSeconds: 12_600, updatedAt: 1_700_000_000_000 },
      'turkey-trot-5k': { raceName: 'Turkey Trot', raceDate: '2026-11-26', goalSeconds: 1_500, updatedAt: 1_700_000_000_000 },
    } });
    const r = await getRaceGoal({ uid: env.uid, meta: env.meta, data: env.data, now: () => env.now, tz: 'UTC' });
    expect(r).toMatchObject({ complete: true, notes: expect.any(Array), coverage: [] });
    const [marathon, trot] = r.races as Record<string, unknown>[];
    expect(marathon).toMatchObject({ raceId: 'chicago-marathon-2026', goalTime: '3:30:00', goalSeconds: 12_600, daysUntilRace: 7, goalPacePerKm: '4:59', goalPacePerMile: '8:01' });
    expect(trot).toMatchObject({ goalTime: '0:25:00', daysUntilRace: 53 });
    expect(trot).not.toHaveProperty('goalPacePerKm');
    expect(JSON.stringify(r.notes)).toMatch(/not a measured/);
    // Points readiness questions at assess_race_readiness while a race is still ahead.
    expect(JSON.stringify(r.notes)).toMatch(/call assess_race_readiness/);
  });

  it('does not point at the readiness tool when there is no race ahead', async () => {
    const env = makeEnv(Date.UTC(2026, 9, 20));
    env.meta.addUser(env.uid, { tz: 'UTC', raceGoals: { 'old-marathon': { raceName: 'Old', raceDate: '2026-10-11', goalSeconds: 12_600, updatedAt: 1 } } });
    const q = { uid: env.uid, meta: env.meta, data: env.data, now: () => env.now, tz: 'UTC' };
    expect(JSON.stringify((await getRaceGoal(q)).notes)).not.toMatch(/assess_race_readiness/);
    expect(JSON.stringify((await getRaceGoal({ ...q, uid: 'nobody' })).notes)).not.toMatch(/assess_race_readiness/);
  });

  it('falls back to UTC for a missing or invalid timezone and handles no goal', async () => {
    const env = makeEnv(Date.UTC(2026, 9, 3, 23, 30));
    const q = { uid: env.uid, meta: env.meta, data: env.data, now: () => env.now, tz: 'UTC' };
    expect((await getRaceGoal(q)).races).toEqual([]);
    env.meta.addUser(env.uid, { tz: 'Not/AZone', raceGoals: { 'x-marathon': { raceName: 'X', raceDate: '2026-10-04', goalSeconds: 10_000, updatedAt: 1 } } });
    expect(((await getRaceGoal(q)).races as { daysUntilRace: number }[])[0]!.daysUntilRace).toBe(1);
  });

  it('formats h:mm:ss', () => {
    expect(formatHms(3661)).toBe('1:01:01');
    expect(formatHms(86_400)).toBe('24:00:00');
  });
});

describe('readiness pointer in the tools a model reaches for first', () => {
  const setup = async (raceDate: string | null) => {
    const { seedRun } = await import('../helpers/workouts.js');
    const env = makeEnv(Date.UTC(2024, 5, 30, 12));
    if (raceDate) env.meta.users.get(env.uid)!.raceGoals = { 'chicago-marathon-2024': { raceName: 'Chicago Marathon', raceDate, goalSeconds: 13_500, updatedAt: 1 } };
    await seedRun(env);
    return { uid: env.uid, meta: env.meta, data: env.data, incoming: env.incoming, now: () => env.now, tz: 'UTC' };
  };
  it('get_workouts and get_training_load point at assess_race_readiness while a marathon is ahead', async () => {
    const { getWorkouts } = await import('../../src/query/workouts.js');
    const { getTrainingLoad } = await import('../../src/query/health.js');
    const q = await setup('2024-07-13');
    const w = await getWorkouts(q, { start_date: '2024-06-01', end_date: '2024-06-30' });
    const l = await getTrainingLoad(q, { end_date: '2024-06-30' });
    expect(JSON.stringify(w.notes)).toMatch(/call assess_race_readiness/);
    expect(JSON.stringify(l.notes)).toMatch(/call assess_race_readiness/);
  });
  it('stays silent without a marathon ahead, and never fails the tool', async () => {
    const { getWorkouts } = await import('../../src/query/workouts.js');
    for (const date of [null, '2024-06-01']) {
      const q = await setup(date);
      const w = await getWorkouts(q, { start_date: '2024-06-01', end_date: '2024-06-30' });
      expect(JSON.stringify(w.notes)).not.toMatch(/assess_race_readiness/);
      expect(w.count).toBeGreaterThan(0);
    }
  });
});
