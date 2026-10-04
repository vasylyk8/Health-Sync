import { describe, expect, it } from 'vitest';
import { READINESS_CONFIG as cfg, withConfig } from '../../src/readiness/config.js';
import {
  classOf, convertTime, efficiencyPoints, effortsOfRun, estimateE1, estimateE1b, estimateE2, estimateE3, fitSpeedAtHr, lowerBoundEffort, personalExponent, selectE1Source, toMarathon, volumeAdjustedR,
  type EfficiencyPoint,
} from '../../src/readiness/estimators.js';
import { adjustmentSigmaSeconds, applyAdjustments, buildAdjustments, heatPenaltyPct } from '../../src/readiness/adjust.js';
import { hms } from '../../src/readiness/features.js';
import type { RaceEffort } from '../../src/readiness/types.js';
import { effort, raw, run } from '../helpers/readiness.js';

const HM = 21_097.5;
const MAR = 42_195;
const R = cfg.e1.rDefault;

describe('toMarathon', () => {
  it('leaves half-marathon and longer sources on the default exponent', () => {
    expect(hms(toMarathon(cfg, 4930, HM, R))).toBe('2:59:57');
  });
  it('converts 10K and 5K sources through the half marathon with the milder sub-half exponent', () => {
    expect(hms(toMarathon(cfg, 3_253, 10_000, R))).toBe('4:21:59');
    expect(hms(toMarathon(cfg, 1_739, 5_000, R))).toBe('4:51:59');
  });
});

describe('race conversion', () => {
  it('converts a 1:22:10 half marathon with the default exponent (log2 of 2.19)', () => {
    expect(R).toBeCloseTo(1.13093, 5);
    expect(convertTime(4930, HM, R, MAR)).toBeCloseTo(4930 * 2.19, 6); // 10 796.7 s
    expect(hms(convertTime(4930, HM, R, MAR))).toBe('2:59:57');
    // A literal 1.13 would give 2:59:50: the spec's "about 2:59:56" matches log2(2.19), not 1.13.
    expect(hms(convertTime(4930, HM, 1.13, MAR))).toBe('2:59:50');
  });
  it('is the identity at the target distance', () => {
    expect(convertTime(12_600, MAR, 1.2, MAR)).toBe(12_600);
  });
  it('adjusts the exponent for volume only when both volume conditions hold', () => {
    expect(volumeAdjustedR(cfg, 95, 3).adjustment).toBe(-0.02);
    expect(volumeAdjustedR(cfg, 95, 2).adjustment).toBe(0);
    expect(volumeAdjustedR(cfg, 70, 5).adjustment).toBe(0);
    expect(volumeAdjustedR(cfg, 49.9, 0).adjustment).toBe(0.02);
    expect(volumeAdjustedR(cfg, 45, 0).r).toBeCloseTo(R + 0.02, 10);
  });
  it('derives a personal exponent and clamps it to 1.04-1.22', () => {
    expect(personalExponent(cfg, 12_600, 5_700, HM)).toBeCloseTo(Math.log(12_600 / 5_700) / Math.LN2, 10); // 1.1444
    expect(personalExponent(cfg, 12_600, 5_700, HM)).toBeCloseTo(1.1444, 3);
    expect(personalExponent(cfg, 14_400, 5_400, HM)).toBe(1.22);
    expect(personalExponent(cfg, 10_200, 5_400, HM)).toBe(1.04);
    expect(personalExponent(cfg, 12_600, 5_700, MAR)).toBeNull();
    expect(personalExponent(cfg, 0, 5_700, HM)).toBeNull();
  });
  it('classifies source distances', () => {
    expect([classOf(5_000), classOf(10_000), classOf(15_000), classOf(21_097.5), classOf(23_000)]).toEqual(['fiveK', 'tenK', 'tenK', 'half', 'half']);
  });
});

describe('race efforts', () => {
  const r = run('hmrace1', '2024-06-08', 21.3, 270);
  const mk = (avgHr: number | null, extra: Partial<Parameters<typeof raw>[2]> = {}) => raw('hmrace1', 21.3, { efforts: [effort(HM, 5_700, avgHr)], ...extra });
  const ef2 = (r2: ReturnType<typeof run>, rawRun: ReturnType<typeof raw>) => effortsOfRun({ cfg, run: r2, raw: rawRun, tagged: false, maxHr: 190, ageWeeks: 3 });
  const ef = (rawRun: ReturnType<typeof raw> | null, tagged: boolean, maxHr = 190) => effortsOfRun({ cfg, run: r, raw: rawRun, tagged, maxHr, ageWeeks: 3 });

  it('accepts a half-marathon effort at 88% of max HR and rejects 87%', () => {
    expect(ef(mk(0.88 * 190 + 0.01), false)[0]).toMatchObject({ klass: 'half', qualifies: true, effortInferred: true });
    expect(ef(mk(0.87 * 190), false)[0]).toMatchObject({ qualifies: false, effortInferred: true });
  });
  it('needs 90% for a 10K or 5K effort', () => {
    const tenRun = run('tenk0001', '2024-06-08', 10.2, 250);
    const fiveRun = run('fivek001', '2024-06-08', 5.1, 240);
    const tenK = ef2(tenRun, raw('tenk0001', 10.2, { efforts: [effort(10_000, 2_500, 0.89 * 190)] }));
    const fiveK = ef2(fiveRun, raw('fivek001', 5.1, { efforts: [effort(5_000, 1_200, 0.91 * 190)] }));
    expect(tenK.find((e) => e.klass === 'tenK')?.qualifies).toBe(false);
    expect(fiveK.find((e) => e.klass === 'fiveK')?.qualifies).toBe(true);
  });
  it('never treats an effort inside a longer run as a race, even at 95% of max HR', () => {
    const inside = raw('hmrace1', 21.3, { efforts: [effort(10_000, 2_400, 0.95 * 190), effort(5_000, 1_150, 0.95 * 190)] });
    const out = ef(inside, false);
    expect(out.filter((e) => e.klass !== 'half').every((e) => !e.qualifies)).toBe(true);
  });
  it('treats a tagged race as a qualifying, non-inferred source even without heart rate', () => {
    expect(ef(mk(null), true)[0]).toMatchObject({ qualifies: true, effortInferred: false, tagged: true, distanceM: HM, seconds: 5_700 });
  });
  it('uses the whole workout for a tagged race that is not near a standard distance', () => {
    const odd = run('race15k1', '2024-06-08', 15, 280);
    const out = effortsOfRun({ cfg, run: odd, raw: null, tagged: true, maxHr: 190, ageWeeks: 3 });
    expect(out[0]).toMatchObject({ klass: 'tenK', distanceM: 15_000, seconds: 15 * 280, qualifies: true });
    expect(effortsOfRun({ cfg, run: run('ultra000', '2024-06-08', 50, 400), raw: null, tagged: true, maxHr: 190, ageWeeks: 3 })).toEqual([]);
  });
  it('does not trust efforts from a run with unreliable heart rate', () => {
    expect(ef(mk(0.95 * 190, { hrUnreliable: true }), false)[0]?.qualifies).toBe(false);
  });
  it('returns nothing for an untagged run that was not analysed', () => {
    expect(ef(null, false)).toEqual([]);
  });
});

describe('E1 source selection and estimate', () => {
  const e = (klass: RaceEffort['klass'], ageWeeks: number, qualifies = true, seconds = 5_000): RaceEffort => ({ workoutId: `${klass}${ageWeeks}`, date: '2024-06-01', ageWeeks, distanceM: klass === 'half' ? HM : klass === 'tenK' ? 10_000 : 5_000, seconds, hrFraction: 0.9, tagged: false, effortInferred: true, qualifies, klass, tempC: null });

  it('prefers the most recent half marathon, then 10K, then 5K, within 16 weeks', () => {
    expect(selectE1Source([e('tenK', 1), e('half', 10), e('half', 4), e('fiveK', 0)], cfg)?.workoutId).toBe('half4');
    expect(selectE1Source([e('tenK', 3), e('tenK', 1), e('fiveK', 0)], cfg)?.workoutId).toBe('tenK1');
    expect(selectE1Source([e('fiveK', 2), e('half', 17)], cfg)?.workoutId).toBe('fiveK2');
    expect(selectE1Source([e('half', 2, false)], cfg)).toBeNull();
  });
  it('keeps the fastest below-threshold effort as a lower bound only', () => {
    const lb = lowerBoundEffort([e('half', 2, false, 5_800), e('tenK', 2, false, 2_300)], cfg, R);
    expect(lb).not.toBeNull();
    const est = estimateE1({ cfg, source: null, personalR: null, avgWeeklyKm: 70, runs30k: 3, lowerBound: lb });
    expect(est.available).toBe(false);
    expect(JSON.stringify(est.inputs)).toContain('lower_bound_only');
    expect(JSON.stringify(est.inputs)).toContain('"effort_inferred":false');
  });
  it('predicts with a default exponent and the spec sigmas', () => {
    const half = estimateE1({ cfg, source: e('half', 3, true, 4_930), personalR: null, avgWeeklyKm: 70, runs30k: 3 });
    expect(half.predictedSeconds).toBeCloseTo(4_930 * 2.19, 4);
    expect(half.sigmaPct).toBe(3.5);
    expect(half.inputs).toMatchObject({ R_source: 'default', source_time: '1:22:10' });
    expect(estimateE1({ cfg, source: e('half', 10), personalR: null, avgWeeklyKm: 70, runs30k: 3 }).sigmaPct).toBe(5.0);
    expect(estimateE1({ cfg, source: e('tenK', 1), personalR: null, avgWeeklyKm: 70, runs30k: 3 }).sigmaPct).toBe(5.0);
    expect(estimateE1({ cfg, source: e('fiveK', 1), personalR: null, avgWeeklyKm: 70, runs30k: 3 }).sigmaPct).toBe(7.0);
  });
  it('applies a volume adjustment to the default exponent, but never to a personal one', () => {
    const high = estimateE1({ cfg, source: e('half', 3, true, 4_930), personalR: null, avgWeeklyKm: 95, runs30k: 3 });
    expect(high.inputs).toMatchObject({ R_source: 'volume_adjusted' });
    expect(high.predictedSeconds).toBeCloseTo(convertTime(4_930, HM, R - 0.02, MAR), 6);
    const personal = estimateE1({ cfg, source: e('half', 3, true, 4_930), personalR: 1.15, avgWeeklyKm: 95, runs30k: 3 });
    expect(personal.inputs).toMatchObject({ R_source: 'personal', R: 1.15 });
    expect(personal.predictedSeconds).toBeCloseTo(convertTime(4_930, HM, 1.15, MAR), 6);
    expect(personal.sigmaPct).toBe(2.5); // 3.5 - 1.0
  });
});

describe('E2b efficiency fit', () => {
  const line = (n: number, f: (hr: number) => number): EfficiencyPoint[] => Array.from({ length: n }, (_, i) => { const hr = 0.66 + (0.14 * i) / (n - 1); return { hrFraction: hr, speed: f(hr) }; });

  it('recovers the speed at 75% of max HR from a straight line', () => {
    const fit = fitSpeedAtHr(line(20, (hr) => 2.5 + 3 * (hr - 0.7)), cfg);
    expect(fit.ok).toBe(true);
    if (fit.ok) {
      expect(fit.speedAt).toBeCloseTo(2.65, 10);
      expect(fit.slope).toBeCloseTo(3, 10);
      expect(fit.n).toBe(20);
    }
  });
  it('refuses a fit with too few splits, too little HR spread, or a non-positive slope', () => {
    expect(fitSpeedAtHr(line(14, () => 2.6), cfg)).toMatchObject({ ok: false, reason: expect.stringContaining('14 qualifying splits') });
    expect(fitSpeedAtHr(Array.from({ length: 20 }, (_, i) => ({ hrFraction: 0.74 + 0.0005 * i, speed: 2.6 })), cfg)).toMatchObject({ ok: false, reason: expect.stringContaining('varies too little') });
    expect(fitSpeedAtHr(line(20, (hr) => 3 - 2 * (hr - 0.7)), cfg)).toMatchObject({ ok: false, reason: expect.stringContaining('does not rise') });
  });
  it('keeps only steady, flat, aerobic splits and skips the first kilometre', () => {
    const good = raw('good', 10, { split: { pace: (i) => 330 + (i % 2) * 4, hr: (i) => 135 + i, gain: 3 } });
    const hilly = raw('hilly', 10, { split: { pace: 330, hr: 140, gain: 3 }, gainPerKm: 14 });
    const intervals = raw('intervals', 10, { split: { pace: (i) => (i % 2 ? 240 : 400), hr: 150, gain: 3 } });
    const noHr = raw('nohr', 10, { split: { pace: 330, hr: null, gain: 3 }, hrCoverage: null });
    const unreliable = raw('bad', 10, { split: { pace: 330, hr: 140, gain: 3 }, hrUnreliable: true });
    const noAlt = raw('noalt', 10, { split: { pace: 330, hr: 140, gain: null }, gainPerKm: null });
    const pts = efficiencyPoints([good, hilly, intervals, noHr, unreliable, noAlt], 190, cfg);
    // good: splits 2..10 (9 splits) with HR 136..144 = 71.6%..75.8% of 190, all inside 65-82%.
    expect(pts).toHaveLength(9);
    expect(pts[0]).toEqual({ hrFraction: 136 / 190, speed: 1000 / 334 });
    // A split above the HR band is dropped.
    const high = raw('high', 6, { split: { pace: 300, hr: (i) => (i === 3 ? 170 : 140), gain: 3 } });
    expect(efficiencyPoints([high], 190, cfg)).toHaveLength(4); // splits 2,3,5,6
  });
  it('predicts the repeat time from the speed ratio between blocks and widens sigma when the prior result is not representative', () => {
    const now = { ok: true as const, n: 20, slope: 3, intercept: 0.5, speedAt: 2.75, hrSd: 0.04 };
    const prior = { ...now, speedAt: 2.5 };
    const rep = estimateE2({ cfg, priorSeconds: 12_600, priorDate: '2023-10-08', representative: true, reasons: [], now, prior });
    expect(rep.rEff).toBeCloseTo(1.1, 10);
    expect(rep.estimate).toMatchObject({ available: true, sigmaPct: 4.0 });
    expect(rep.estimate.predictedSeconds).toBeCloseTo(12_600 / 1.1, 6);
    const notRep = estimateE2({ cfg, priorSeconds: 12_600, representative: false, reasons: ['hot'], now, prior });
    expect(notRep.estimate.sigmaPct).toBe(6.0);
    expect(notRep.estimate.notes.join(' ')).toContain('understate');
  });
  it('is unavailable without a prior marathon or without enough splits in either block', () => {
    const ok = { ok: true as const, n: 20, slope: 3, intercept: 0.5, speedAt: 2.75, hrSd: 0.04 };
    const bad = { ok: false as const, n: 4, reason: '4 qualifying splits (need 15)' };
    expect(estimateE2({ cfg, priorSeconds: null, representative: true, reasons: [], now: ok, prior: ok }).estimate.available).toBe(false);
    const x = estimateE2({ cfg, priorSeconds: 12_600, representative: true, reasons: [], now: ok, prior: bad });
    expect(x.estimate.available).toBe(false);
    expect(x.estimate.notes[0]).toContain('prior block');
  });
});

describe('E3 Tanda & Knechtle', () => {
  it('matches the published equation (hand-computed: 201.92 min for 60 km/week, 5:00/km, 15% body fat)', () => {
    const e = estimateE3({ cfg, weeklyKm: 60, paceSecPerKm: 300, weeksWithRuns: 8, bodyFatPct: 15, sex: 'male' });
    expect(e.predictedSeconds! / 60).toBeCloseTo(201.9198, 3);
    expect(e.sigmaPct).toBe(7.0);
    expect(e.notes.join(' ')).not.toContain('outside');
  });
  it('flags default body fat, unknown or female sex and results outside the fitted range', () => {
    const noBf = estimateE3({ cfg, weeklyKm: 60, paceSecPerKm: 300, weeksWithRuns: 8, bodyFatPct: null, sex: null });
    expect(noBf.inputs).toMatchObject({ body_fat_pct: 15, body_fat_source: 'default' });
    expect(noBf.notes.join(' ')).toContain('Sex not available');
    expect(estimateE3({ cfg, weeklyKm: 60, paceSecPerKm: 300, weeksWithRuns: 8, bodyFatPct: 15, sex: 'female' }).sigmaPct).toBe(9.0);
    expect(estimateE3({ cfg, weeklyKm: 20, paceSecPerKm: 450, weeksWithRuns: 8, bodyFatPct: 15, sex: 'male' }).notes.join(' ')).toContain('outside the 165-266');
  });
  it('is unavailable with fewer than 6 weeks of runs', () => {
    expect(estimateE3({ cfg, weeklyKm: 60, paceSecPerKm: 300, weeksWithRuns: 5, bodyFatPct: 15, sex: 'male' }).available).toBe(false);
  });
});

describe('config', () => {
  it('can be overridden for tuning without mutating the defaults', () => {
    const tuned = withConfig({ e1: { rDefault: 1.1 }, combine: { raceDaySigmaPct: 3 } });
    expect(tuned.e1.rDefault).toBe(1.1);
    expect(tuned.e1.rClamp).toEqual([1.04, 1.22]);
    expect(tuned.combine.raceDaySigmaPct).toBe(3);
    expect(cfg.e1.rDefault).toBeCloseTo(1.13093, 5);
  });
});

describe('E1b: best effort inside a training run', () => {
  const eff = (o: Partial<RaceEffort> = {}): RaceEffort => ({ workoutId: 'long-run-1', date: '2024-06-01', ageWeeks: 4, distanceM: HM, seconds: 7_065, hrFraction: 0.84, tagged: false, effortInferred: true, qualifies: false, klass: 'half', tempC: null, ...o });

  it('converts the effort like E1 but with a wide sigma and an honest note', () => {
    const e = estimateE1b({ cfg, effort: eff(), personalR: null, avgWeeklyKm: 70, runs30k: 3 });
    expect(e.name).toBe('E1b_training_effort');
    expect(e.available).toBe(true);
    expect(e.sigmaPct).toBe(12);
    expect(e.predictedSeconds).toBeCloseTo(7_065 * 2.19, 4); // 1:57:45 half -> 15 472 s
    expect(hms(e.predictedSeconds!)).toBe('4:17:52');
    expect(e.inputs).toMatchObject({ below_max_effort_threshold: true, hr_fraction: 0.84, R_source: 'default', source_time: '1:57:45' });
    expect(e.notes[0]).toMatch(/did not reach the heart-rate level of a max effort.*conservative/);
  });
  it('is unavailable without an effort and handles a missing heart rate', () => {
    expect(estimateE1b({ cfg, effort: null, personalR: null, avgWeeklyKm: 70, runs30k: 3 }).available).toBe(false);
    const noHr = estimateE1b({ cfg, effort: eff({ hrFraction: null }), personalR: null, avgWeeklyKm: 70, runs30k: 3 });
    expect(noHr.available).toBe(true);
    expect(noHr.notes[0]).toContain('no usable heart rate');
  });
  it('uses the personal or volume-adjusted exponent like E1', () => {
    expect(estimateE1b({ cfg, effort: eff(), personalR: 1.15, avgWeeklyKm: 70, runs30k: 3 }).inputs).toMatchObject({ R_source: 'personal', R: 1.15 });
    expect(estimateE1b({ cfg, effort: eff(), personalR: null, avgWeeklyKm: 40, runs30k: 0 }).inputs).toMatchObject({ R_source: 'volume_adjusted' });
  });
  it('expresses a hot effort at a mild temperature, in E1 and E1b alike', () => {
    const hot = eff({ tempC: 25 });
    expect(estimateE1b({ cfg, effort: hot, personalR: null, avgWeeklyKm: 70, runs30k: 3 }).predictedSeconds).toBeCloseTo((7_065 / 1.04) * 2.19, 4);
    expect(estimateE1({ cfg, source: { ...hot, qualifies: true }, personalR: null, avgWeeklyKm: 70, runs30k: 3 }).predictedSeconds).toBeCloseTo((7_065 / 1.04) * 2.19, 4);
  });
  it('carries the run temperature into the efforts it builds', () => {
    const r = run('hmrace1', '2024-06-08', 21.3, 270);
    const out = effortsOfRun({ cfg, run: { ...r, tempC: 21 }, raw: raw('hmrace1', 21.3, { efforts: [effort(HM, 5_700, 170)] }), tagged: false, maxHr: 190, ageWeeks: 3 });
    expect(out[0]!.tempC).toBe(21);
  });
});

describe('heat in the efficiency fit', () => {
  it('leaves runs recorded at 22 degC or hotter out of the fit', () => {
    const mk = (tempC: number | null) => raw('x', 10, { split: { pace: (i) => 330 + (i % 2) * 4, hr: (i) => 135 + i, gain: 3 }, tempC });
    expect(efficiencyPoints([mk(null)], 190, cfg)).toHaveLength(9);
    expect(efficiencyPoints([mk(21.9)], 190, cfg)).toHaveLength(9);
    expect(efficiencyPoints([mk(22)], 190, cfg)).toHaveLength(0);
  });
});

describe('adjustments', () => {
  it('heat costs 0.4% per degree above 15, capped at 8%', () => {
    expect([10, 15, 20, 25, 30, 35, 45].map((t) => heatPenaltyPct(t, cfg))).toEqual([0, 0, 2, 4, 6, 8, 8]);
  });
  it('builds only the adjustments that were asked for', () => {
    const none = { course: null, expectedTempC: null, newSuperShoes: false };
    expect(buildAdjustments(none, cfg)).toEqual([]);
    const all = buildAdjustments({ course: 'rolling', expectedTempC: 20, newSuperShoes: true }, cfg);
    expect(all.map((a) => [a.name, a.pct, a.sigmaPct])).toEqual([['course', 1, 0.5], ['expected_race_day_heat', 2, 1], ['super_shoes_what_if', -1, 1]]);
    expect(buildAdjustments({ ...none, course: 'flat' }, cfg)[0]).toMatchObject({ pct: 0 });
  });
  it('multiplies the percentages and adds their uncertainty in quadrature', () => {
    const adjs = buildAdjustments({ course: 'hilly', expectedTempC: 25, newSuperShoes: true }, cfg);
    expect(applyAdjustments(12_000, adjs)).toBeCloseTo(12_000 * 1.025 * 1.04 * 0.99, 6);
    // sigma: 1.25%, 2%, 1% of 12 000 s = 150, 240, 120 -> sqrt(150^2 + 240^2 + 120^2) = 309.8 s
    expect(adjustmentSigmaSeconds(12_000, adjs)).toBeCloseTo(Math.sqrt(150 ** 2 + 240 ** 2 + 120 ** 2), 6);
    expect(applyAdjustments(12_000, [])).toBe(12_000);
    expect(adjustmentSigmaSeconds(12_000, [])).toBe(0);
  });
});
