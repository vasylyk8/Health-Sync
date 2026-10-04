import { describe, expect, it } from 'vitest';
import { evaluate, summarise, type BacktestRow } from '../../scripts/backtest-readiness.js';
import { withConfig } from '../../src/readiness/config.js';
import { deps as memDeps, makeEnv } from '../helpers/memory.js';
import { at, runnerSeeds, seedRuns } from '../helpers/readiness-data.js';

describe('summarise', () => {
  const row = (error_pct: number, inside_80: boolean, pit: number): BacktestRow => ({ uid: 'u', race_date: '2024-01-01', as_of: '2023-12-18', actual: '3:30:00', status: 'ok', error_pct, inside_80, pit, predicted: '3:31:00' });
  it('reports bias, absolute error, 80% coverage and the sorted PIT values', () => {
    const s = summarise([row(2, true, 0.7), row(-4, true, 0.2), row(6, false, 0.95), { ...row(0, true, 0.5), status: 'insufficient_data', error_pct: undefined }]);
    expect(s).toMatchObject({ races: 4, scored: 3, insufficient: 1, inside_80_share: 2 / 3 });
    expect(s.mean_error_pct).toBeCloseTo(4 / 3, 10);
    expect(s.mean_abs_error_pct).toBeCloseTo(4, 10);
    expect(s.pit).toEqual([0.2, 0.7, 0.95]);
  });
  it('is empty-safe', () => {
    expect(summarise([])).toMatchObject({ races: 0, scored: 0, mean_error_pct: null, inside_80_share: null, pit: [] });
  });
});

describe('backtest on a seeded runner', () => {
  it('evaluates each past marathon as of 14 days before it, without using the race itself', async () => {
    const env = makeEnv();
    const hm = 'hm-race-1';
    await seedRuns(env, [
      ...runnerSeeds('2024-06-29', hm),
      // The marathon two weeks later: 42.2 km at 5:25/km.
      { id: 'marathon-0001', start: at('2024-07-13', '08:00'), km: 42.2, pace: 325, hr: (k) => 160 + (k % 5), gain: 1 },
    ]);
    const d = { ...memDeps(env), now: () => Date.UTC(2024, 7, 1, 12) };
    const rows = await evaluate(d, env.uid, { daysBefore: 14, maxHr: 190 });
    expect(rows).toHaveLength(1);
    const r = rows[0]!;
    expect(r).toMatchObject({ race_date: '2024-07-13', as_of: '2024-06-29', status: 'ok' });
    // 42.2 km in 13 715 s scaled to 42.195 km = 13 713 s = 3:48:33.
    expect(r.actual).toBe('3:48:33');
    expect(r.predicted).toBeDefined();
    const sec = (t: string) => t.split(':').reduce((n, x) => n * 60 + Number(x), 0);
    expect(r.error_pct).toBeCloseTo(((sec(r.predicted!) - 13_713) / 13_713) * 100, 1); // signed percent of the actual time
    expect(Math.abs(r.error_pct!)).toBeLessThan(3);
    expect(r.pit).toBeGreaterThan(0);
    expect(r.pit).toBeLessThan(1);
    expect(typeof r.inside_80).toBe('boolean');

    // The result must not depend on the race itself: deleting the marathon workout from the data changes nothing about the prediction.
    const env2 = makeEnv();
    await seedRuns(env2, runnerSeeds('2024-06-29', hm));
    const pred = await import('../../src/readiness/assess.js').then((m) => m.assessRaceReadiness({ ...memDeps(env2), now: () => Date.UTC(2024, 7, 1, 12) }, { as_of_date: '2024-06-29', goal_time: '3:48:33', max_hr: 190 }, { race: { id: 'x-marathon', name: 'x', date: '2024-07-13' } }));
    expect((pred.prediction as { central: string }).central).toBe(r.predicted);
  });

  it('accepts tuned configuration', async () => {
    const env = makeEnv();
    await seedRuns(env, [...runnerSeeds('2024-06-29', 'hm-race-1'), { id: 'marathon-0001', start: at('2024-07-13', '08:00'), km: 42.2, pace: 325, hr: 160, gain: 1 }]);
    const d = { ...memDeps(env), now: () => Date.UTC(2024, 7, 1, 12) };
    const base = await evaluate(d, env.uid, { maxHr: 190 });
    const tuned = await evaluate(d, env.uid, { maxHr: 190, cfg: withConfig({ e1: { rDefault: 1.2 } }) });
    expect(tuned[0]!.error_pct!).toBeGreaterThan(base[0]!.error_pct!); // a higher exponent predicts a slower marathon
  });

  it('reports no rows for a runner without marathons', async () => {
    const env = makeEnv();
    await seedRuns(env, runnerSeeds('2024-06-29', 'hm-race-1'));
    expect(await evaluate({ ...memDeps(env), now: () => Date.UTC(2024, 7, 1, 12) }, env.uid)).toEqual([]);
  });
});
