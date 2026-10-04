import { describe, expect, it } from 'vitest';
import { applyModifier, combineEstimates, labelOf, likelihood, range80 } from '../../src/readiness/combine.js';
import { confidenceComponents, confidencePercent, type ConfidenceInputs } from '../../src/readiness/confidence.js';
import { READINESS_CONFIG as cfg } from '../../src/readiness/config.js';
import { evaluateModifiers, type ModifierInputs } from '../../src/readiness/modifiers.js';
import type { Estimate, RaceEffort, RunRaw, RunSummary } from '../../src/readiness/types.js';
import { raw, run, splitsOf } from '../helpers/readiness.js';

const est = (name: string, t: number, sigmaPct: number, available = true): Estimate => ({ name, available, predictedSeconds: available ? t : null, sigmaPct: available ? sigmaPct : null, inputs: {}, notes: [] });

describe('combining estimators', () => {
  const two = [est('A', 10_800, 5), est('B', 11_400, 4)];

  it('weights by inverse variance and applies the correlation floor', () => {
    const c = combineEstimates(two, cfg, 2)!;
    expect(c.centralSeconds).toBeCloseTo(11_150.245, 2);
    // Independent sigma would be 348.4 s; the floor is 0.85 x the best single sigma (456 s) = 387.6 s.
    expect(c.sigmaFloorApplied).toBe(true);
    expect(c.sigmaCombinedSeconds).toBeCloseTo(387.6, 6);
    // + race-day 2% of the central estimate, in quadrature.
    expect(c.sigmaTotalSeconds).toBeCloseTo(447.174, 2);
    expect(c.weights.map((w) => w.weight)).toEqual([expect.closeTo(0.41626, 4), expect.closeTo(0.58374, 4)]);
  });
  it('adds a further 1% term when the race is more than 6 weeks away', () => {
    expect(combineEstimates(two, cfg, 6)!.sigmaTotalSeconds).toBeCloseTo(447.174, 2);
    expect(combineEstimates(two, cfg, 6.1)!.sigmaTotalSeconds).toBeCloseTo(460.866, 2);
  });
  it('keeps a single estimator\'s own sigma, and does not floor a combination that is barely tighter than its best member', () => {
    const one = combineEstimates([est('A', 10_800, 5)], cfg, 2)!;
    expect(one.sigmaFloorApplied).toBe(false);
    expect(one.sigmaCombinedSeconds).toBeCloseTo(540, 6);
    // A 10x worse second estimator barely helps: independent sigma 537.3 s is above the floor (459 s).
    const weak = combineEstimates([est('A', 10_800, 5), est('B', 10_800, 50)], cfg, 2)!;
    expect(weak.sigmaFloorApplied).toBe(false);
    expect(weak.sigmaCombinedSeconds).toBeCloseTo(540 / Math.sqrt(1 + 0.01), 3);
    // Two equal estimators would claim 540/sqrt(2) = 381.8 s; the floor holds it at 459 s.
    const twin = combineEstimates([est('A', 10_800, 5), est('B', 10_800, 5)], cfg, 2)!;
    expect(twin.sigmaFloorApplied).toBe(true);
    expect(twin.sigmaCombinedSeconds).toBeCloseTo(0.85 * 540, 6);
  });
  it('ignores unavailable estimators and returns null when none is usable', () => {
    expect(combineEstimates([est('A', 10_800, 5), est('B', 0, 0, false)], cfg, 2)!.weights).toHaveLength(1);
    expect(combineEstimates([est('B', 0, 0, false)], cfg, 2)).toBeNull();
  });
});

describe('likelihood', () => {
  it('is 5.0 at the central estimate and follows the normal distribution', () => {
    expect(likelihood(11_000, 11_000, 400, cfg)).toMatchObject({ score: 5, label: 'toss-up' });
    expect(likelihood(11_400, 11_000, 400, cfg)).toMatchObject({ score: 8.4, label: 'very likely' }); // Phi(1) = 0.8413
    expect(likelihood(10_600, 11_000, 400, cfg)).toMatchObject({ score: 1.6, label: 'very unlikely' });
  });
  it('labels the score bands from the spec', () => {
    expect([0, 2, 2.1, 4, 4.1, 6, 6.1, 8, 8.1, 10].map((s) => labelOf(s, cfg))).toEqual([
      'very unlikely', 'very unlikely', 'unlikely', 'unlikely', 'toss-up', 'toss-up', 'likely', 'likely', 'very likely', 'very likely',
    ]);
  });
  it('gives the 80% range as central +/- 1.2816 sigma and applies modifiers as added time', () => {
    const [lo, hi] = range80(12_000, 400, cfg);
    expect(lo).toBeCloseTo(12_000 - 512.64, 6);
    expect(hi).toBeCloseTo(12_000 + 512.64, 6);
    expect(applyModifier(12_000, 5)).toBeCloseTo(12_600, 6);
    expect(applyModifier(12_000, 0)).toBe(12_000);
  });
});

// ---------------------------------------------------------------------------------------------

const GOAL_PACE = 320; // 3:45:00 marathon pace in s/km (13 500 / 42.195 = 319.9)

function mod(runs: { r: RunSummary; raw?: RunRaw }[], over: Partial<ModifierInputs> = {}): ModifierInputs {
  return {
    cfg, runs: runs.map((x) => x.r), raw: new Map(runs.flatMap((x) => (x.raw ? [[x.r.id, x.raw] as const] : []))),
    windowStart: '2024-04-08', windowEnd: '2024-06-29', goalPaceSecPerKm: GOAL_PACE, maxHr: 190, ...over,
  };
}
const long = (id: string, date: string, km: number, o: Partial<RunRaw> & { pace?: number | ((i: number) => number); hr?: number | ((i: number) => number); tempC?: number } = {}) => ({
  r: run(id, date, km, 330, { tempC: o.tempC ?? null }),
  raw: raw(id, km, { split: { pace: o.pace ?? 330, hr: o.hr ?? 150, gain: 2 }, gainPerKm: 2, ...o }),
});
const find = (res: ReturnType<typeof evaluateModifiers>, check: string) => res.results.find((x) => x.check === check)!;

describe('durability modifiers', () => {
  it('long-run decoupling: median of the last 3 qualifying long runs', () => {
    const runs = [long('a1', '2024-06-22', 30, { decouplingPct: 7 }), long('a2', '2024-06-08', 28, { decouplingPct: 12 }), long('a3', '2024-05-25', 26, { decouplingPct: 4 }), long('a4', '2024-05-11', 26, { decouplingPct: 20 })];
    const m = find(evaluateModifiers(mod(runs)), 'long_run_decoupling');
    expect(m).toMatchObject({ value: 7, appliedPct: 1, status: 'not_met' }); // median of 7, 12, 4 (the 20% run is the 4th newest)
    const lowRuns = [long('b1', '2024-06-22', 30, { decouplingPct: 2 }), long('b2', '2024-06-08', 28, { decouplingPct: 3 })];
    expect(find(evaluateModifiers(mod(lowRuns)), 'long_run_decoupling')).toMatchObject({ value: 2.5, appliedPct: 0, status: 'met' });
    const highRuns = [long('c1', '2024-06-22', 30, { decouplingPct: 11 }), long('c2', '2024-06-08', 28, { decouplingPct: 14 })];
    expect(find(evaluateModifiers(mod(highRuns)), 'long_run_decoupling')).toMatchObject({ value: 12.5, appliedPct: 2 });
  });
  it('excludes hot, hilly, uneven, short and unreliable runs from the decoupling check, and needs two qualifying runs', () => {
    const base = [long('a1', '2024-06-22', 30, { decouplingPct: 2 })];
    const excluded = [
      long('hot0001', '2024-06-15', 30, { decouplingPct: 2, tempC: 23 }),
      long('hill001', '2024-06-08', 30, { decouplingPct: 2, gainPerKm: 12 }),
      long('uneven1', '2024-06-01', 30, { decouplingPct: 2, pace: (i) => (i % 2 ? 280 : 380) }),
      long('short001', '2024-05-25', 24, { decouplingPct: 2 }),
      long('badhr001', '2024-05-18', 30, { decouplingPct: 2, hrUnreliable: true }),
    ];
    const m = find(evaluateModifiers(mod([...base, ...excluded])), 'long_run_decoupling');
    expect(m).toMatchObject({ value: null, appliedPct: 0, status: 'unknown' });
    expect(m.detail).toContain('1 qualifying');
  });
  it('counts runs of 30 km or more: fewer than 2 adds 2%, exactly 2 adds 1%, 3 or more adds nothing', () => {
    const n = (k: number) => Array.from({ length: k }, (_, i) => ({ r: run(`l${i}`, `2024-06-${String(10 + i).padStart(2, '0')}`, 31, 330) }));
    expect(find(evaluateModifiers(mod(n(0))), 'runs_30km_or_more')).toMatchObject({ value: 0, appliedPct: 2 });
    expect(find(evaluateModifiers(mod(n(1))), 'runs_30km_or_more')).toMatchObject({ appliedPct: 2 });
    expect(find(evaluateModifiers(mod(n(2))), 'runs_30km_or_more')).toMatchObject({ appliedPct: 1 });
    expect(find(evaluateModifiers(mod(n(3))), 'runs_30km_or_more')).toMatchObject({ appliedPct: 0, status: 'met' });
  });
  it('goal-pace segment: the longest continuous stretch at or inside 3% of goal pace in a run of 20 km or more', () => {
    // 22 km: km 1-5 slow, km 6-17 at 322 s/km (within 3% of 320: limit 320/0.97 = 329.9), km 18+ slow.
    const pace = (i: number) => (i >= 5 && i <= 16 ? 322 : 360);
    const ok = find(evaluateModifiers(mod([long('seg1', '2024-06-22', 22, { pace })])), 'goal_pace_segment');
    expect(ok).toMatchObject({ value: 12, appliedPct: 0, status: 'met' });
    // Break the streak at km 11: the longest piece is 6 km.
    const broken = (i: number) => (i === 10 ? 360 : pace(i));
    expect(find(evaluateModifiers(mod([long('seg2', '2024-06-22', 22, { pace: broken })])), 'goal_pace_segment')).toMatchObject({ value: 6, appliedPct: 1, status: 'not_met' });
    expect(find(evaluateModifiers(mod([{ r: run('only10k0', '2024-06-22', 10, 330), raw: raw('only10k0', 10) }])), 'goal_pace_segment').status).toBe('unknown');
  });
  it('HR late in long runs at goal pace: above 90% of max adds 1%', () => {
    const goal = (hr: number) => ({ pace: (i: number) => (i >= 25 ? 322 : 340), hr: (i: number) => (i >= 25 ? hr : 140) });
    const hot = find(evaluateModifiers(mod([long('late001', '2024-06-22', 32, goal(175))])), 'hr_at_goal_pace_late_in_long_runs'); // 175/190 = 92.1%
    expect(hot).toMatchObject({ appliedPct: 1, status: 'not_met' });
    expect(hot.value).toBeCloseTo(92.1, 1);
    expect(find(evaluateModifiers(mod([long('late002', '2024-06-22', 32, goal(160))])), 'hr_at_goal_pace_late_in_long_runs')).toMatchObject({ appliedPct: 0, status: 'met' });
    expect(find(evaluateModifiers(mod([long('late003', '2024-06-22', 26, { pace: 340 })])), 'hr_at_goal_pace_late_in_long_runs').status).toBe('unknown');
  });
  it('caps the total at +5% and reports the uncapped total', () => {
    const res = evaluateModifiers(mod([long('l1', '2024-06-22', 30, { decouplingPct: 15, pace: 360, hr: 175 }), long('l2', '2024-06-08', 28, { decouplingPct: 15, pace: 360, hr: 175 })]));
    // decoupling +2, 30 km runs (1 run) +2, goal-pace segment +1, HR check unknown (no goal-pace splits after km 25).
    expect(res.totalPct).toBe(5);
    const more = evaluateModifiers(mod([long('l1', '2024-06-22', 32, { decouplingPct: 15, pace: (i: number) => (i >= 25 ? 322 : 360), hr: (i: number) => (i >= 25 ? 178 : 150) }), long('l2', '2024-06-08', 28, { decouplingPct: 15, pace: 360 })]));
    expect(more.totalPct).toBe(2 + 2 + 1 + 1);
    expect(more.cappedPct).toBe(5);
  });
  it('labels every modifier as weak or moderate evidence, never strong', () => {
    const res = evaluateModifiers(mod([]));
    expect(res.results.every((m) => m.evidence !== 'strong')).toBe(true);
    expect(find(res, 'runs_30km_or_more').evidence).toBe('moderate');
    expect(find(res, 'long_run_decoupling').evidence).toBe('weak');
  });
});

// ---------------------------------------------------------------------------------------------

const eff = (klass: RaceEffort['klass'], ageWeeks: number, tagged = false): RaceEffort => ({ workoutId: 'x', date: '2024-06-01', ageWeeks, distanceM: 21_097.5, seconds: 5_700, hrFraction: 0.9, tagged, effortInferred: !tagged, qualifies: true, klass, tempC: null });
const full: ConfidenceInputs = {
  cfg, effort: eff('half', 3), lowerBoundOnly: false, weeksWithRuns: 14, longestGapDays: 4, longRunsWithSplits: 4, hrCoverage: { fraction: 0.95, rawRuns: 20, summaryRuns: 10 },
  priorMarathon: { present: true, hasStreams: true, representative: true }, maxHrSource: 'user', decouplingRuns: 3, fueling: { enabled: true, qualifyingRuns: 3 }, weeksToRace: 2,
};
const by = (i: ConfidenceInputs) => Object.fromEntries(confidenceComponents(i).map((c) => [c.name, c]));

describe('confidence', () => {
  it('adds up to 100 when every component is at full points', () => {
    const c = confidenceComponents(full);
    expect(c.reduce((n, x) => n + x.max, 0)).toBe(100);
    expect(confidencePercent(c)).toBe(100);
    expect(c.every((x) => x.status === 'full')).toBe(true);
    expect(c.map((x) => x.name)).toEqual(['race_effort', 'training_continuity', 'long_run_evidence', 'hr_coverage', 'prior_marathon', 'max_hr_source', 'decoupling_runs', 'fueling_logged', 'time_to_race']);
  });
  it('scores the recent race effort by distance and age', () => {
    expect(by(full).race_effort!.points).toBe(25);
    expect(by({ ...full, effort: eff('tenK', 5) }).race_effort!.points).toBe(18);
    expect(by({ ...full, effort: eff('half', 12) }).race_effort!.points).toBe(10);
    expect(by({ ...full, effort: eff('fiveK', 2) }).race_effort!.points).toBe(10);
    expect(by({ ...full, effort: null, lowerBoundOnly: true }).race_effort!.points).toBe(5);
    expect(by({ ...full, effort: null }).race_effort!.points).toBe(0);
  });
  it('gives partial credit proportional to the evidence and halves continuity for a long gap', () => {
    expect(by({ ...full, weeksWithRuns: 6 }).training_continuity!.points).toBe(7.5);
    expect(by({ ...full, longestGapDays: 12 }).training_continuity!.points).toBe(7.5);
    expect(by({ ...full, longRunsWithSplits: 1 }).long_run_evidence!.points).toBe(5);
    expect(by({ ...full, hrCoverage: { fraction: 0.4, rawRuns: 1, summaryRuns: 1 } }).hr_coverage!.points).toBe(5);
    expect(by({ ...full, decouplingRuns: 1 }).decoupling_runs!.points).toBe(2.5);
  });
  it('rates the prior marathon, max HR source, fueling and time to race', () => {
    expect(by({ ...full, priorMarathon: { present: true, hasStreams: true, representative: false } }).prior_marathon!.points).toBe(5);
    expect(by({ ...full, priorMarathon: { present: true, hasStreams: false, representative: true } }).prior_marathon!.points).toBe(3);
    expect(by({ ...full, priorMarathon: { present: false, hasStreams: false, representative: false } }).prior_marathon!.points).toBe(0);
    expect([5, 3, 0].map((_, i) => by({ ...full, maxHrSource: (['user', 'observed', 'default'] as const)[i]! }).max_hr_source!.points)).toEqual([5, 3, 0]);
    expect([6, 8, 12, 13].map((w) => by({ ...full, weeksToRace: w }).time_to_race!.points)).toEqual([10, 5, 5, 0]);
  });
  it('reports switched-off nutrition as unknown, not as unfueled', () => {
    const c = by({ ...full, fueling: { enabled: false, qualifyingRuns: 0 } }).fueling_logged!;
    expect(c).toMatchObject({ points: 0, status: 'unknown' });
    expect(c.reason).toContain('says nothing');
    expect(by({ ...full, fueling: { enabled: true, qualifyingRuns: 0 } }).fueling_logged!.reason).toContain('not logged does not mean not eaten');
  });
  it('explains every component', () => {
    expect(confidenceComponents({ ...full, hrCoverage: null }).every((c) => c.reason.length > 5)).toBe(true);
  });
});

describe('splits helper used by the fixtures', () => {
  it('builds hand-checkable splits', () => {
    const s = splitsOf(2.5, { pace: 300, hr: 140 });
    expect(s.map((x) => [x.split, x.distance_m, x.moving_seconds, x.partial])).toEqual([[1, 1000, 300, false], [2, 1000, 300, false], [3, 500, 150, true]]);
  });
});
