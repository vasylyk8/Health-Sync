import { describe, expect, it } from 'vitest';
import { assessPriorMarathon, computeReadiness } from '../../src/readiness/compute.js';
import { READINESS_CONFIG as cfg } from '../../src/readiness/config.js';
import { addDays } from '../../src/readiness/features.js';
import { readinessSchema } from '../../src/readiness/schema.js';
import type { PriorMarathon, RunRaw, RunSummary } from '../../src/readiness/types.js';
import { effort, inputs, raw, run, splitsOf, trainingBlock } from '../helpers/readiness.js';

const HM = 21_097.5;
const AS_OF = '2024-06-29'; // a Saturday

/** Long-run lengths per week of the 16-week block, oldest first. */
const LONG = [18, 20, 22, 24, 26, 28, 30, 24, 32, 34, 32, 24, 32, 30, 22, 16];

function wellPrepared() {
  const t = trainingBlock({ asOf: AS_OF, weeks: 16, longKm: (w) => LONG[w]!, longPace: 330 });
  // A tagged half marathon three weeks ago: 1:43:30 (6 210 s), average HR 176.
  const hm = run('hm-race1', addDays(AS_OF, -21), 21.2, 6210 / 21.0975, { hr: 176 });
  const hmRaw = raw('hm-race1', 21.2, { split: { pace: 294, hr: 176, gain: 1 }, efforts: [effort(HM, 6210, 176)], gainPerKm: 1 });
  t.runs.push(hm);
  t.raw.set(hm.id, hmRaw);
  return inputs({ runs: t.runs, raw: t.raw, taggedRaceIds: ['hm-race1'] });
}

describe('well-prepared runner, tagged half marathon, race in 14 days', () => {
  const out = computeReadiness(wellPrepared(), cfg, 'full');

  it('produces a valid spec section 7 result', () => {
    expect(readinessSchema.safeParse(out).success).toBe(true);
    expect(out.status).toBe('ok');
    expect(out.mode).toBe('race_window');
    expect(out.race).toMatchObject({ goal_time: '3:45:00', goal_pace_per_km: '5:20', days_until: 14 });
  });
  it('converts the tagged half with the default exponent (6 210 s x 2.19 = 13 600 s = 3:46:40)', () => {
    const e1 = out.estimators!.find((e) => e.name === 'E1_race_conversion')!;
    expect(e1).toMatchObject({ available: true, predicted: '3:46:40', sigma_pct: 3.5 });
    expect(e1.inputs).toMatchObject({ workout_ids: ['hm-race1'], effort_inferred: false, R_source: 'default' });
  });
  it('lists the unavailable prior-marathon estimator and the data gaps', () => {
    expect(out.estimators!.find((e) => e.name === 'E2_prior_marathon')!.available).toBe(false);
    expect(out.data_gaps!.join(' ')).toContain('No prior marathon');
    expect(out.block_comparison!.prior_marathon).toBeNull();
  });
  it('reports a likelihood, a range around the central estimate and a separate confidence', () => {
    const p = out.prediction!;
    expect(p.range_80[0] < p.central && p.central < p.range_80[1]).toBe(true);
    expect(out.likelihood!.score_0_10).toBeGreaterThan(0);
    expect(out.likelihood!.score_0_10).toBeLessThan(10);
    expect(out.confidence!.percent).toBeGreaterThan(40);
    expect(out.confidence!.components).toHaveLength(9);
  });
  it('weights the estimators and adds a per-workout table with detail "full"', () => {
    const w = out.estimators!.filter((e) => e.available).map((e) => e.weight!);
    expect(w.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 2);
    expect(out.workouts!.length).toBeGreaterThan(10);
    expect(computeReadiness(wellPrepared(), cfg, 'summary').workouts).toBeUndefined();
  });
  it('shows the estimate and likelihood without the durability checks next to the final ones', () => {
    const o = computeReadiness(wellPrepared(), cfg);
    const secs = (t: string) => t.split(':').reduce((n, x) => n * 60 + Number(x), 0);
    expect(o.prediction!.durability_adjustment_pct).toBeGreaterThanOrEqual(0);
    expect(secs(o.prediction!.central_before_durability)).toBeLessThanOrEqual(secs(o.prediction!.central));
    expect(o.prediction!.probability_before_durability).toBeGreaterThanOrEqual(o.likelihood!.probability);
    expect(o.block_comparison!.runs_read_in_detail.current_window[1]).toBeGreaterThan(0);
  });
  it('states probability, range, driver and the gaps that matter in plain words, and gives temperature scenarios', () => {
    const o = computeReadiness(wellPrepared(), cfg);
    expect(o.plain_language!.headline).toContain('modelled chance');
    expect(o.plain_language!.headline).toContain(o.prediction!.central);
    expect(o.plain_language!.gaps_that_matter.join(' ')).toContain('Race-day temperature was not given');
    expect(o.plain_language!.validation).toContain('one marathon');
    const sc = o.temperature_scenarios!;
    expect(sc.map((x) => x.temp_c)).toEqual([10, 15, 20, 25]);
    // No heat penalty up to 15 degC; then the chance can only fall as it gets hotter.
    expect(sc[0]!.probability).toBe(sc[1]!.probability);
    expect(sc[3]!.probability).toBeLessThanOrEqual(sc[2]!.probability);
    expect(sc[2]!.probability).toBeLessThan(sc[1]!.probability);
    expect(readinessSchema.safeParse(o).success).toBe(true);
  });
  it('gives no scenarios when the caller supplied the temperature', () => {
    const o = computeReadiness({ ...wellPrepared(), context: { course: null, expectedTempC: 18, newSuperShoes: false } }, cfg);
    expect(o.temperature_scenarios).toBeNull();
    expect(o.plain_language!.gaps_that_matter.join(' ')).not.toContain('temperature was not given');
  });
  it('matches the snapshot', () => {
    expect(computeReadiness(wellPrepared(), cfg)).toMatchSnapshot();
  });
});

describe('under-trained runner with a slow tagged 10K', () => {
  const t = trainingBlock({ asOf: AS_OF, weeks: 16, easyPace: 390, longKm: () => 12, longPace: 395, hr: 150 });
  const tenK = run('tenk-slow', addDays(AS_OF, -14), 10, 348, { hr: 170 });
  t.runs.push(tenK);
  t.raw.set(tenK.id, raw(tenK.id, 10, { split: { pace: 348, hr: 170, gain: 1 }, efforts: [effort(10_000, 3_480, 170)] }));
  const out = computeReadiness(inputs({ runs: t.runs, raw: t.raw, taggedRaceIds: ['tenk-slow'] }), cfg);

  it('says the goal is very unlikely and flags that the long runs are missing', () => {
    expect(out.status).toBe('ok');
    expect(out.likelihood!.label).toBe('very unlikely');
    expect(out.likelihood!.score_0_10).toBeLessThanOrEqual(2);
    expect(out.modifiers!.find((m) => m.check === 'runs_30km_or_more')).toMatchObject({ value: 0, applied_pct: 2, status: 'not_met' });
    // 58:00 10K at 40 km/week: exponent log2(2.19) + 0.02 for low volume -> 3480 x 4.2195^1.1509 = 18 251 s.
    const e1 = out.estimators!.find((e) => e.name === 'E1_race_conversion')!;
    expect(e1.predicted).toBe('4:44:10');
    expect(e1.inputs).toMatchObject({ R_source: 'volume_adjusted' });
  });
  it('matches the snapshot', () => {
    expect(out).toMatchSnapshot();
  });
});

describe('sparse data', () => {
  it('returns insufficient_data without a score when fewer than 6 weeks have runs', () => {
    const t = trainingBlock({ asOf: AS_OF, weeks: 4 });
    const hm = run('hm-race1', addDays(AS_OF, -14), 21.2, 295, { hr: 176 });
    t.runs.push(hm);
    t.raw.set(hm.id, raw(hm.id, 21.2, { efforts: [effort(HM, 6210, 176)] }));
    const out = computeReadiness(inputs({ runs: t.runs, raw: t.raw, taggedRaceIds: ['hm-race1'] }), cfg);
    expect(readinessSchema.safeParse(out).success).toBe(true);
    expect(out).toMatchObject({ status: 'insufficient_data' });
    expect(out.likelihood).toBeUndefined();
    expect(out.prediction).toBeUndefined();
    expect(out.confidence!.percent).toBeGreaterThanOrEqual(0);
    expect(out.data_gaps[0]).toContain('Only 4 of the last 16 weeks');
    expect(out).toMatchSnapshot();
  });
  it('does not score from the training-based estimator alone', () => {
    const t = trainingBlock({ asOf: AS_OF, weeks: 16 });
    const out = computeReadiness(inputs({ runs: t.runs, raw: new Map() }), cfg);
    expect(out.status).toBe('insufficient_data');
    expect(out.data_gaps[0]).toContain('E1b');
    expect(out.estimators).toBeUndefined();
  });
});

describe('edge cases', () => {
  it('flags a race more than 6 weeks away as current fitness and widens the uncertainty', () => {
    const near = computeReadiness(wellPrepared(), cfg);
    const far = computeReadiness({ ...wellPrepared(), race: { ...wellPrepared().race, daysUntil: 91 } }, cfg);
    expect(far.mode).toBe('current_fitness_snapshot');
    expect(far.caveats.join(' ')).toContain('current fitness, not race-day fitness');
    expect(far.prediction!.sigma_pct).toBeGreaterThan(near.prediction!.sigma_pct);
    expect(far.confidence!.components.find((c) => c.name === 'time_to_race')!.points).toBe(0);
  });
  it('without any heart rate only a tagged race can serve as the conversion source, with low confidence', () => {
    const t = trainingBlock({ asOf: AS_OF, weeks: 16, longKm: (w) => LONG[w]! });
    const noHr = new Map([...t.raw].map(([id, r]) => [id, { ...r, hrCoverage: null, splits: r.splits.map((s) => ({ ...s, avg_hr: null })), decouplingPct: null } as RunRaw]));
    const runsNoHr: RunSummary[] = t.runs.map((r) => ({ ...r, avgHr: null }));
    const hm = run('hm-race1', addDays(AS_OF, -21), 21.2, 293, { hr: null });
    runsNoHr.push(hm);
    noHr.set(hm.id, raw(hm.id, 21.2, { hrCoverage: null, efforts: [effort(HM, 6210, null)] }));
    const tagged = computeReadiness(inputs({ runs: runsNoHr, raw: noHr, taggedRaceIds: ['hm-race1'] }), cfg);
    expect(tagged.status).toBe('ok');
    expect(tagged.confidence!.components.find((c) => c.name === 'hr_coverage')!.points).toBe(0);
    expect(tagged.modifiers!.find((m) => m.check === 'long_run_decoupling')!.status).toBe('unknown');
    // The same runner without the tag has no race-quality effort: only a rough estimate from the best training-run effort.
    const untagged = computeReadiness(inputs({ runs: runsNoHr, raw: noHr }), cfg);
    expect(untagged.status).toBe('ok');
    expect(untagged.estimators!.find((e) => e.name === 'E1_race_conversion')!.available).toBe(false);
    expect(untagged.estimators!.find((e) => e.name === 'E1b_training_effort')).toMatchObject({ available: true, sigma_pct: 12 });
    expect(untagged.caveats.join(' ')).toContain('No race-quality effort was found');
    expect(untagged.confidence!.components.find((c) => c.name === 'race_effort')!.points).toBe(5);
  });
  it('notes when a prior marathon already beat the goal and still computes', () => {
    const base = wellPrepared();
    const run42 = run('prior-mar', '2023-10-08', 42.3, 295, { hr: 160 });
    const prior: PriorMarathon = { run: run42, raw: null, seconds: 12_400 };
    const out = computeReadiness({ ...base, runs: [...base.runs, run42], priorMarathon: prior }, cfg);
    expect(out.status).toBe('ok');
    expect(out.caveats.join(' ')).toContain('at or under the goal time');
    expect(out.block_comparison!.prior_marathon).toMatchObject({ workout_id: 'prior-mar', time: '3:26:40' });
  });
  it('lists a tagged race that is too old or missing instead of silently ignoring it', () => {
    const base = wellPrepared();
    const out = computeReadiness({ ...base, taggedRaceIds: ['hm-race1', 'missing-id-1'] }, cfg);
    expect(out.data_gaps.join(' ')).toContain('Tagged race missing-id-1 is not among the running workouts');
  });
  it('flags a default max HR and a switched-off nutrition category as gaps and confidence limits', () => {
    const out = computeReadiness({ ...wellPrepared(), maxHr: { value: 190, source: 'default', note: '190 bpm default; ask the user for the measured maximum' }, nutrition: { enabled: false, carbRunIds: [] } }, cfg);
    expect(out.data_gaps.join(' ')).toContain('Max heart rate is a default');
    expect(out.confidence!.components.find((c) => c.name === 'max_hr_source')!.points).toBe(0);
    expect(out.confidence!.components.find((c) => c.name === 'fueling_logged')).toMatchObject({ status: 'unknown', points: 0 });
  });
  it('never lets the confidence change the likelihood', () => {
    const a = computeReadiness({ ...wellPrepared(), nutrition: { enabled: false, carbRunIds: [] } }, cfg);
    const b = computeReadiness({ ...wellPrepared(), nutrition: { enabled: true, carbRunIds: [] } }, cfg);
    expect(a.likelihood).toEqual(b.likelihood);
    expect(a.prediction).toEqual(b.prediction);
  });
});

// ---------------------------------------------------------------------------------------------
// With a prior marathon: representativeness, personal exponent and the efficiency comparison.

/** Easy runs whose speed rises linearly with HR: v = a + 4 x (HR/maxHr - 0.7); two weeks of 4 runs ending on `end`. */
function efficiencyRuns(prefix: string, end: string, a: number): { runs: RunSummary[]; raw: Map<string, RunRaw> } {
  const runs: RunSummary[] = [];
  const rawMap = new Map<string, RunRaw>();
  for (let i = 0; i < 8; i++) {
    const id = `${prefix}-${i}`;
    const date = addDays(end, -i * 3);
    const frac = (k: number) => 0.66 + 0.14 * (((k + i) % 8) / 7);
    const pace = (k: number) => 1000 / (a + 4 * (frac(k) - 0.7));
    runs.push(run(id, date, 8, 340, { hr: 135 }));
    rawMap.set(id, raw(id, 8, { split: { pace, hr: (k) => frac(k) * 190, gain: 2 }, gainPerKm: 2 }));
  }
  return { runs, raw: rawMap };
}

describe('with a prior marathon', () => {
  const priorDate = '2023-10-08';
  // The generic training blocks run at an HR above the 65-82% aerobic band, so only the dedicated efficiency runs enter the fit.
  const hard = { hr: 160, rawFor: (r: RunSummary) => (r.distanceM ?? 0) >= 20_000 };
  const build = (o: { priorTempC?: number | null; priorHalves?: [number, number]; priorSeconds?: number } = {}) => {
    const now = trainingBlock({ asOf: AS_OF, weeks: 16, longKm: (w) => LONG[w]!, ...hard });
    const nowEff = efficiencyRuns('now', AS_OF, 2.9);
    const hm = run('hm-race1', addDays(AS_OF, -21), 21.2, 295, { hr: 176 });
    const prior = trainingBlock({ asOf: addDays(priorDate, -1), weeks: 16, longKm: () => 28, idPrefix: 'p', ...hard });
    const priorEff = efficiencyRuns('pe', addDays(priorDate, -1), 2.78);
    const priorHm = run('prior-hm', addDays(priorDate, -28), 21.2, 297, { hr: 175 });
    const seconds = o.priorSeconds ?? 13_800;
    const marathon = run('prior-mar', priorDate, 42.3, seconds / 42.195, { hr: 168, tempC: o.priorTempC ?? null });
    const priorRaw = raw('prior-mar', 42.3, { halves: o.priorHalves ?? [seconds * 0.5, seconds * 0.5], efforts: [effort(42_195, seconds, 168)], split: { pace: seconds / 42.195, hr: 168, gain: 2 } });
    const rawMap = new Map([...now.raw, ...nowEff.raw, ...prior.raw, ...priorEff.raw]);
    rawMap.set(hm.id, raw(hm.id, 21.2, { efforts: [effort(HM, 6210, 176)], split: { pace: 295, hr: 176, gain: 1 } }));
    rawMap.set(priorHm.id, raw(priorHm.id, 21.2, { efforts: [effort(HM, 6300, 175)], split: { pace: 297, hr: 175, gain: 1 } }));
    rawMap.set(marathon.id, priorRaw);
    return inputs({
      runs: [...now.runs, ...nowEff.runs, hm, ...prior.runs, ...priorEff.runs, priorHm, marathon], raw: rawMap, taggedRaceIds: ['hm-race1'],
      priorMarathon: { run: marathon, raw: priorRaw, seconds },
    });
  };

  it('derives a personal exponent from the prior marathon and a max-effort half in its block', () => {
    const out = computeReadiness(build(), cfg);
    const e1 = out.estimators!.find((e) => e.name === 'E1_race_conversion')!;
    const personal = Math.log(13_800 / 6_300) / Math.LN2;
    expect(e1.inputs).toMatchObject({ R_source: 'personal', R: Math.round(personal * 1000) / 1000 });
    expect(e1.sigma_pct).toBe(2.5);
  });
  it('compares speed at 75% of max HR between the two blocks (3.10 vs 2.98 m/s = 1.040) and repeats the prior time', () => {
    const out = computeReadiness(build(), cfg);
    const e2 = out.estimators!.find((e) => e.name === 'E2_prior_marathon')!;
    expect(e2.available).toBe(true);
    expect(out.block_comparison!.speed_at_75pct_hrmax_ratio).toBeCloseTo(3.1 / 2.98, 2);
    expect(e2.inputs).toMatchObject({ representative: true });
    expect(e2.sigma_pct).toBe(4.0);
    // 13 800 s x 2.98 / 3.10 = 13 265.8 s = 3:41:06
    expect(e2.predicted).toBe('3:41:06');
  });
  it('treats a hot, positively split prior marathon as not representative: wider sigma, no personal exponent', () => {
    const out = computeReadiness(build({ priorTempC: 26, priorHalves: [6_600, 7_500] }), cfg);
    const e2 = out.estimators!.find((e) => e.name === 'E2_prior_marathon')!;
    expect(e2.sigma_pct).toBe(6.0);
    expect(e2.notes.join(' ')).toContain('understate');
    const e1 = out.estimators!.find((e) => e.name === 'E1_race_conversion')!;
    expect(e1.inputs).toMatchObject({ R_source: 'default' });
    expect(e1.notes.join(' ')).toContain('may not be representative');
    expect(out.block_comparison!.prior_marathon!.representative).toBe(false);
  });
  it('judges representativeness: hot, positive split, walk-heavy, pacing duty', () => {
    const mk = (o: { temp?: number | null; halves?: [number, number]; hr?: number; paces?: (i: number) => number }) => {
      const r = run('prior-mar', priorDate, 42.3, 320, { hr: o.hr ?? 165, tempC: o.temp ?? null });
      return assessPriorMarathon({ run: r, raw: raw('prior-mar', 42.3, { halves: o.halves ?? [6_800, 6_800], splits: splitsOf(42.3, { pace: o.paces ?? 320, hr: 160 }) }), seconds: 13_600 }, 190, cfg);
    };
    expect(mk({}).representative).toBe(true);
    expect(mk({ temp: 19 }).reasons[0]).toContain('hot');
    expect(mk({ temp: 18 }).representative).toBe(true);
    expect(mk({ halves: [6_500, 6_900] }).reasons[0]).toContain('positive split'); // +6.2%
    expect(mk({ halves: [6_600, 6_900] }).representative).toBe(true); // +4.5%
    expect(mk({ paces: (i) => (i % 4 === 0 ? 560 : 320) }).reasons.join(' ')).toContain('walk-heavy');
    expect(mk({ halves: [7_100, 6_500], hr: 130 }).reasons[0]).toContain('pacing duty');
    expect(mk({ halves: [7_100, 6_500], hr: 170 }).representative).toBe(true); // negative split at a high effort is fine
  });
});

// ---------------------------------------------------------------------------------------------
// Context adjustments and training-run efforts

describe('context adjustments', () => {
  const base = () => wellPrepared();
  const sec = (t: string) => t.split(':').reduce((n, x) => n * 60 + Number(x), 0);
  const central = (ctx: Partial<ReturnType<typeof base>['context']>) => sec(computeReadiness({ ...base(), context: { ...base().context, ...ctx } }, cfg).prediction!.central);

  it('moves the central estimate by the stated percentages and lists each adjustment', () => {
    const plain = central({});
    expect(central({ course: 'rolling' }) / plain).toBeCloseTo(1.01, 3);
    expect(central({ course: 'hilly' }) / plain).toBeCloseTo(1.025, 3);
    expect(central({ expectedTempC: 25 }) / plain).toBeCloseTo(1.04, 3);
    expect(central({ expectedTempC: 40 }) / plain).toBeCloseTo(1.08, 3); // capped at 8%
    expect(central({ newSuperShoes: true }) / plain).toBeCloseTo(0.99, 3);
    expect(central({ expectedTempC: 10 })).toBe(plain);
    const out = computeReadiness({ ...base(), context: { course: 'hilly', expectedTempC: 25, newSuperShoes: true } }, cfg);
    expect(out.adjustments!.map((a) => [a.name, a.pct, a.evidence])).toEqual([['course', 2.5, 'weak'], ['expected_race_day_heat', 4, 'weak'], ['super_shoes_what_if', -1, 'weak']]);
    expect(readinessSchema.safeParse(out).success).toBe(true);
  });
  it('widens sigma for each adjustment, the shoes what-if most (its sigma equals its size)', () => {
    const sigma = (ctx: Partial<ReturnType<typeof base>['context']>) => computeReadiness({ ...base(), context: { ...base().context, ...ctx } }, cfg).prediction!.sigma_pct;
    const plain = sigma({});
    expect(sigma({ course: 'hilly' })).toBeGreaterThan(plain);
    expect(sigma({ newSuperShoes: true })).toBeGreaterThan(plain);
    expect(sigma({ course: 'flat' })).toBe(plain);
  });
  it('says what was not modelled when nothing was given', () => {
    const out = computeReadiness(base(), cfg);
    expect(out.adjustments).toEqual([]);
    expect(out.caveats.join(' ')).toMatch(/weather is not modelled.*treated as flat.*fueling, pacing and crowd/s);
  });
  it('shows fueling as context only and never moves the prediction', () => {
    const a = computeReadiness({ ...base(), nutrition: { enabled: true, carbRunIds: ['long-6-0'] } }, cfg);
    expect(a.benchmarks!.find((b) => b.metric === 'long_runs_with_carbs_logged')).toMatchObject({ evidence: 'weak' });
    expect(a.prediction).toEqual(computeReadiness(base(), cfg).prediction);
  });
  it('labels the 52-week base as context that is not used in the estimate', () => {
    expect(computeReadiness(base(), cfg).benchmarks!.find((b) => b.metric === 'avg_weekly_km_base_52wk')!.context).toContain('not used in the estimate');
  });
});

describe('heat in the source efforts', () => {
  it('expresses a tagged half run in 25 degC at a mild temperature (4% faster time) and says so', () => {
    const b = wellPrepared();
    const hotRuns = b.runs.map((r) => (r.id === 'hm-race1' ? { ...r, tempC: 25 } : r));
    const hot = computeReadiness({ ...b, runs: hotRuns }, cfg);
    const cool = computeReadiness(b, cfg);
    const e1 = (o: typeof hot) => o.estimators!.find((e) => e.name === 'E1_race_conversion')!;
    // 13 600 s / 1.04 = 13 077 s = 3:37:57
    expect(e1(cool).predicted).toBe('3:46:40');
    expect(e1(hot).predicted).toBe('3:37:57');
    expect(e1(hot).inputs).toMatchObject({ heat_adjusted_pct: 4 });
    expect(e1(hot).notes.join(' ')).toContain('mild temperature');
  });
  it('leaves a source with unknown temperature alone', () => {
    const e1 = computeReadiness(wellPrepared(), cfg).estimators!.find((e) => e.name === 'E1_race_conversion')!;
    expect(e1.inputs).not.toHaveProperty('heat_adjusted_pct');
  });
});

describe('an earlier race outside the current block', () => {
  function earlier(extra: Partial<Parameters<typeof inputs>[0]> = {}, weeks = 16) {
    const t = trainingBlock({ asOf: AS_OF, weeks, longKm: (w) => LONG[w % LONG.length]!, longPace: 330 });
    const hm = run('hm-old1', addDays(AS_OF, -26 * 7), 21.2, 6036 / 21.0975, { hr: 178 });
    t.runs.push(hm);
    t.raw.set(hm.id, raw(hm.id, 21.2, { split: { pace: 286, hr: 178, gain: 1 }, efforts: [effort(HM, 6036, 178)], gainPerKm: 1 }));
    return inputs({ runs: t.runs, raw: t.raw, ...extra });
  }
  it('is used as a lower-weight estimator with extra uncertainty, and earns partial race-effort confidence', () => {
    const out = computeReadiness(earlier(), cfg);
    expect(out.status).toBe('ok');
    expect(out.estimators!.find((e) => e.name === 'E1_race_conversion')!.available).toBe(false);
    const e1s = out.estimators!.find((e) => e.name === 'E1s_earlier_race')!;
    // 6.5 + 1.0 (26 weeks old) + 2 (no runs between that race and the current block: a break) + 1 (no efficiency comparison)
    expect(e1s).toMatchObject({ available: true, sigma_pct: 10.5 });
    expect(e1s.notes.join(' ')).toContain('gap of');
    expect(e1s.weight).toBeGreaterThan(0);
    expect(out.confidence!.components.find((c) => c.name === 'race_effort')!.points).toBe(12);
    expect(readinessSchema.safeParse(out).success).toBe(true);
  });
  it('has less uncertainty when training continued between that race and now', () => {
    const e1s = computeReadiness(earlier({}, 27), cfg).estimators!.find((e) => e.name === 'E1s_earlier_race')!;
    expect(e1s.sigma_pct).toBeLessThan(10.5);
    expect(e1s.inputs).toMatchObject({ volume_maintained: true });
  });
  it('stays out of the way of a recent race effort', () => {
    const base = wellPrepared();
    const hm = run('hm-old1', addDays(AS_OF, -26 * 7), 21.2, 6036 / 21.0975, { hr: 178 });
    base.runs.push(hm);
    base.raw.set(hm.id, raw(hm.id, 21.2, { split: { pace: 286, hr: 178, gain: 1 }, efforts: [effort(HM, 6036, 178)], gainPerKm: 1 }));
    const out = computeReadiness(base, cfg);
    expect(out.estimators!.find((e) => e.name === 'E1_race_conversion')).toMatchObject({ available: true });
    expect(out.estimators!.find((e) => e.name === 'E1s_earlier_race')!.available).toBe(true);
    expect(out.confidence!.components.find((c) => c.name === 'race_effort')!.points).toBe(25);
  });
});
