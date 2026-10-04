import type { ReadinessConfig } from './config.js';
import { heatPenaltyPct } from './adjust.js';
import { cv, fullSplits, hms, mean, sd } from './features.js';
import type { Estimate, RaceEffort, RunRaw, StdDistanceKey } from './types.js';

/** Pure estimators of marathon finishing time (spec section 5.2). No I/O. */

const KEY_BY_NOMINAL: [StdDistanceKey, keyof ReadinessConfig['stdDistancesM']][] = [['fiveK', 'fiveK'], ['tenK', 'tenK'], ['half', 'half']];

/** Standard distance class of a source distance, for sigma lookup: >= 18 km half-marathon class, >= 8 km 10K, else 5K. */
export function classOf(distanceM: number): StdDistanceKey {
  return distanceM >= 18_000 ? 'half' : distanceM >= 8_000 ? 'tenK' : 'fiveK';
}

export const nominalM = (cfg: ReadinessConfig, key: StdDistanceKey): number => cfg.stdDistancesM[KEY_BY_NOMINAL.find(([k]) => k === key)![1]];

/** T_target = T_src x (D_target / D_src)^R. */
export const convertTime = (tSrc: number, dSrc: number, r: number, targetM: number): number => tSrc * (targetM / dSrc) ** r;

/**
 * A source time expressed as a marathon time. From the half marathon on, R covers the whole jump (the half x 2.19 finding); from a
 * shorter source the Riegel exponent first carries the time up to the half, where it is well calibrated, and R carries it from there.
 * (One exponent over a 5K or 10K to marathon jump overstates the fade by a large margin.)
 */
export function toMarathon(cfg: ReadinessConfig, tSrc: number, dSrc: number, r: number): number {
  const half = cfg.stdDistancesM.half;
  if (dSrc >= half) return convertTime(tSrc, dSrc, r, cfg.marathonM);
  return convertTime(convertTime(tSrc, dSrc, cfg.e1.belowHalfExponent, half), half, r, cfg.marathonM);
}

/** Default exponent adjusted for training volume: high volume with several 30 km runs is lower, low volume higher. */
export function volumeAdjustedR(cfg: ReadinessConfig, avgWeeklyKm: number, runs30k: number): { r: number; adjustment: number } {
  const v = cfg.e1.volume;
  const adjustment = avgWeeklyKm >= v.highKmPerWeek && runs30k >= v.highLongRuns ? v.highDelta : avgWeeklyKm < v.lowKmPerWeek ? v.lowDelta : 0;
  return { r: cfg.e1.rDefault + adjustment, adjustment };
}

/** The runner's own exponent from a marathon and a max-effort shorter race in the same block. */
export function personalExponent(cfg: ReadinessConfig, marathonSec: number, srcSec: number, srcM: number): number | null {
  if (!(marathonSec > 0 && srcSec > 0 && srcM > 0 && srcM < cfg.marathonM)) return null;
  // Same two-step shape as toMarathon: a shorter source is first expressed as a half-marathon time.
  const half = cfg.stdDistancesM.half;
  const halfSec = srcM < half ? convertTime(srcSec, srcM, cfg.e1.belowHalfExponent, half) : srcSec;
  const halfM = Math.max(srcM, half);
  const r = Math.log(marathonSec / halfSec) / Math.log(cfg.marathonM / halfM);
  if (!Number.isFinite(r)) return null;
  return Math.min(cfg.e1.rClamp[1], Math.max(cfg.e1.rClamp[0], r));
}

// ---------------------------------------------------------------------------------------------
// Race efforts

const hrThreshold = (cfg: ReadinessConfig, key: StdDistanceKey): number => (key === 'half' ? cfg.e1.effortHrFraction.half : key === 'tenK' ? cfg.e1.effortHrFraction.tenK : cfg.e1.effortHrFraction.fiveK);

/**
 * Race-quality efforts of one analysed run. A tagged race is accepted as it is; otherwise an effort counts as a max effort only
 * when its average heart rate reaches the threshold for its distance (a best effort inside an easy run does not).
 */
export function effortsOfRun(args: { cfg: ReadinessConfig; run: { id: string; date: string; distanceM: number | null; movingSec: number | null; tempC?: number | null }; raw: RunRaw | null; tagged: boolean; maxHr: number; ageWeeks: number }): RaceEffort[] {
  const { cfg, run, raw, tagged, maxHr, ageWeeks } = args;
  const mk = (klass: StdDistanceKey, distanceM: number, seconds: number, avgHr: number | null, inferred: boolean): RaceEffort => {
    const hrFraction = avgHr !== null && maxHr > 0 ? avgHr / maxHr : null;
    return { workoutId: run.id, date: run.date, ageWeeks, distanceM, seconds, hrFraction, tagged, effortInferred: inferred, qualifies: tagged || (hrFraction !== null && hrFraction >= hrThreshold(cfg, klass)), klass, tempC: run.tempC ?? null };
  };
  if (tagged) {
    const d = run.distanceM;
    if (d === null || d < cfg.detect.taggedRangeM[0] || d > cfg.detect.taggedRangeM[1]) return [];
    const nearest = KEY_BY_NOMINAL.map(([k]) => ({ k, nom: nominalM(cfg, k) })).sort((a, b) => Math.abs(a.nom - d) - Math.abs(b.nom - d))[0]!;
    if (Math.abs(nearest.nom - d) / nearest.nom <= cfg.detect.taggedNearestTolerance) {
      const eff = raw?.efforts.find((e) => e.distanceM === nearest.nom);
      if (eff) return [mk(nearest.k, nearest.nom, eff.movingSec, eff.avgHr, false)];
    }
    if (run.movingSec === null) return [];
    return [mk(classOf(d), d, run.movingSec, null, false)];
  }
  if (!raw) return [];
  const out: RaceEffort[] = [];
  for (const [k] of KEY_BY_NOMINAL) {
    const nom = nominalM(cfg, k);
    const eff = raw.efforts.find((e) => e.distanceM === nom);
    if (!eff) continue;
    const e = mk(k, eff.distanceM, eff.movingSec, raw.hrUnreliable ? null : eff.avgHr, true);
    // Only a workout that is about the effort's distance can be a max effort; a stretch inside a longer run is training
    // (a runner whose marathon-pace heart rate is already ~89% of max passes any heart-rate test inside a long run).
    const raceLike = run.distanceM !== null && run.distanceM <= nom * (1 + cfg.detect.taggedNearestTolerance);
    out.push(raceLike ? e : { ...e, qualifies: false });
  }
  return out;
}

/** Spec: most recent qualifying half-marathon, else most recent 10K, else most recent 5K. */
export function selectE1Source(efforts: RaceEffort[], cfg: ReadinessConfig): RaceEffort | null {
  const ok = efforts.filter((e) => e.qualifies && e.ageWeeks <= cfg.e1.maxSourceAgeWeeks);
  for (const klass of ['half', 'tenK', 'fiveK'] as const) {
    const hit = ok.filter((e) => e.klass === klass).sort((a, b) => a.ageWeeks - b.ageWeeks)[0];
    if (hit) return hit;
  }
  return null;
}

/** The fastest implied marathon among efforts that failed the HR test (a floor on fitness, not an estimate). */
export function lowerBoundEffort(efforts: RaceEffort[], cfg: ReadinessConfig, r: number): RaceEffort | null {
  const ok = efforts.filter((e) => !e.qualifies && e.ageWeeks <= cfg.e1.maxSourceAgeWeeks);
  return ok.sort((a, b) => toMarathon(cfg, a.seconds, a.distanceM, r) - toMarathon(cfg, b.seconds, b.distanceM, r))[0] ?? null;
}

// ---------------------------------------------------------------------------------------------
// E1: race conversion

export function estimateE1(args: { cfg: ReadinessConfig; source: RaceEffort | null; personalR: number | null; avgWeeklyKm: number; runs30k: number; lowerBound?: RaceEffort | null }): Estimate {
  const { cfg, source, personalR } = args;
  if (!source) {
    const lb = args.lowerBound ? toMarathon(cfg, args.lowerBound.seconds, args.lowerBound.distanceM, personalR ?? cfg.e1.rDefault) : null;
    return {
      name: 'E1_race_conversion', available: false, predictedSeconds: null, sigmaPct: null,
      inputs: lb !== null ? { lower_bound_only: { workout_id: args.lowerBound!.workoutId, effort_inferred: false, implied_marathon: hms(lb), note: 'A best effort from a training run that did not reach the heart-rate threshold of a max effort: the runner can run at least this fast, not necessarily that this is their limit.' } } : {},
      notes: [lb !== null ? 'No race-quality effort in the last 16 weeks; only a below-threshold effort exists (lower bound).' : 'No race-quality half marathon, 10K or 5K effort found in the last 16 weeks.'],
    };
  }
  const vol = volumeAdjustedR(cfg, args.avgWeeklyKm, args.runs30k);
  const r = personalR ?? vol.r;
  const rSource = personalR !== null ? 'personal' : vol.adjustment !== 0 ? 'volume_adjusted' : 'default';
  // An effort run in the heat understates fitness: express it as it would have been at a mild temperature.
  const heatPct = source.tempC !== null ? heatPenaltyPct(source.tempC, cfg) : 0;
  const seconds = source.seconds / (1 + heatPct / 100);
  const predicted = toMarathon(cfg, seconds, source.distanceM, r);
  const s = cfg.e1.sigmaPct;
  let sigma = source.klass === 'half' ? (source.ageWeeks <= cfg.e1.halfFreshWeeks ? s.halfUnder8w : s.half8to16w) : source.klass === 'tenK' ? s.tenK : s.fiveK;
  if (personalR !== null) sigma += cfg.e1.personalRSigmaDelta;
  const notes: string[] = [];
  if (source.tagged) notes.push('Source is a race the runner tagged.');
  else notes.push(`Source is an inferred max effort (average HR ${source.hrFraction !== null ? Math.round(source.hrFraction * 100) + '% of max' : 'unknown'}).`);
  if (heatPct > 0) notes.push(`The source effort was run at ${round1(source.tempC!)} degC; its time was reduced by ${heatPct.toFixed(1)}% to express fitness at a mild temperature (heuristic).`);
  if (rSource === 'volume_adjusted') notes.push(`Exponent adjusted ${vol.adjustment > 0 ? '+' : ''}${vol.adjustment} for volume (${Math.round(args.avgWeeklyKm)} km/week, ${args.runs30k} runs of 30 km or more).`);
  return {
    name: 'E1_race_conversion', available: true, predictedSeconds: predicted, sigmaPct: sigma,
    inputs: {
      workout_ids: [source.workoutId], source_distance_m: source.distanceM, source_time: hms(source.seconds), source_age_weeks: Math.round(source.ageWeeks * 10) / 10,
      effort_inferred: source.effortInferred, R: Math.round(r * 1000) / 1000, R_source: rSource, ...(heatPct > 0 ? { heat_adjusted_pct: Math.round(heatPct * 10) / 10 } : {}),
    },
    notes,
  };
}

const round1 = (x: number) => Math.round(x * 10) / 10;

/**
 * E1b: when no race-quality effort exists, the best effort inside a training run (below the heart-rate level of a max effort)
 * still says something: the runner can run at least this fast. It is used as a conservative, wide-sigma estimate, never as a floor.
 */
export function estimateE1b(args: { cfg: ReadinessConfig; effort: RaceEffort | null; personalR: number | null; avgWeeklyKm: number; runs30k: number }): Estimate {
  const { cfg, effort } = args;
  const base = { name: 'E1b_training_effort', predictedSeconds: null, sigmaPct: null };
  if (!effort) return { ...base, available: false, inputs: {}, notes: ['No usable effort inside a training run in the last 16 weeks.'] };
  const vol = volumeAdjustedR(cfg, args.avgWeeklyKm, args.runs30k);
  const r = args.personalR ?? vol.r;
  const heatPct = effort.tempC !== null ? heatPenaltyPct(effort.tempC, cfg) : 0;
  const seconds = effort.seconds / (1 + heatPct / 100);
  const notes = [
    `Best effort found inside a training run${effort.hrFraction !== null ? `, at ${Math.round(effort.hrFraction * 100)}% of max HR` : ' (no usable heart rate)'}; it did not reach the heart-rate level of a max effort, so it likely understates what a race would give. Treated as a conservative, uncertain estimate.`,
  ];
  if (heatPct > 0) notes.push(`Run at ${round1(effort.tempC!)} degC; time reduced by ${heatPct.toFixed(1)}% to express fitness at a mild temperature (heuristic).`);
  return {
    ...base, available: true, predictedSeconds: toMarathon(cfg, seconds, effort.distanceM, r), sigmaPct: cfg.e1.sigmaPct.trainingRun,
    inputs: {
      workout_ids: [effort.workoutId], source_distance_m: effort.distanceM, source_time: hms(effort.seconds), source_age_weeks: round1(effort.ageWeeks),
      below_max_effort_threshold: true, hr_fraction: effort.hrFraction !== null ? Math.round(effort.hrFraction * 100) / 100 : null, R: Math.round(r * 1000) / 1000, R_source: args.personalR !== null ? 'personal' : vol.adjustment !== 0 ? 'volume_adjusted' : 'default',
      ...(heatPct > 0 ? { heat_adjusted_pct: round1(heatPct) } : {}),
    },
    notes,
  };
}

// ---------------------------------------------------------------------------------------------
// E2: prior marathon

export interface EfficiencyPoint {
  hrFraction: number;
  speed: number;
}

/** Splits of qualifying steady, flat, aerobic-HR runs: (HR as fraction of max, speed m/s). */
export function efficiencyPoints(runs: RunRaw[], maxHr: number, cfg: ReadinessConfig): EfficiencyPoint[] {
  const e = cfg.e2.efficiency;
  const out: EfficiencyPoint[] = [];
  for (const run of runs) {
    if (run.hrUnreliable || run.hrCoverage === null) continue;
    if (run.tempC !== null && run.tempC >= e.maxTempC) continue;
    if (run.gainPerKm === null || run.gainPerKm >= e.maxGainPerKm) continue;
    const full = fullSplits(run.splits).slice(e.skipFirstKm ? 1 : 0);
    const paceCv = cv(full.map((s) => s.pace_seconds_per_unit));
    if (paceCv === null || paceCv > e.maxPaceCv) continue;
    for (const sp of full) {
      if (sp.avg_hr === null || sp.elevation_gain_m === null || sp.elevation_gain_m >= e.maxGainPerKm || sp.pace_seconds_per_unit <= 0) continue;
      const f = sp.avg_hr / maxHr;
      if (f >= e.hrBand[0] && f <= e.hrBand[1]) out.push({ hrFraction: f, speed: 1000 / sp.pace_seconds_per_unit });
    }
  }
  return out;
}

export type EfficiencyFit = { ok: true; n: number; slope: number; intercept: number; speedAt: number; hrSd: number } | { ok: false; n: number; reason: string };

/** Least-squares speed = a + b x HR, evaluated at `cfg.e2.efficiency.predictAt` of max HR. */
export function fitSpeedAtHr(points: EfficiencyPoint[], cfg: ReadinessConfig): EfficiencyFit {
  const e = cfg.e2.efficiency;
  const n = points.length;
  if (n < e.minSplitsPerBlock) return { ok: false, n, reason: `${n} qualifying splits (need ${e.minSplitsPerBlock})` };
  const xs = points.map((p) => p.hrFraction);
  const ys = points.map((p) => p.speed);
  const mx = mean(xs)!;
  const my = mean(ys)!;
  const hrSd = sd(xs)!;
  if (hrSd < e.minHrSd) return { ok: false, n, reason: `heart rate varies too little across splits (sd ${(hrSd * 100).toFixed(1)}% of max) to fit speed against it` };
  const sxx = xs.reduce((a, x) => a + (x - mx) ** 2, 0);
  const sxy = xs.reduce((a, x, i) => a + (x - mx) * (ys[i]! - my), 0);
  const slope = sxy / sxx;
  if (!(slope > 0)) return { ok: false, n, reason: 'speed does not rise with heart rate in these splits, so the fit is not usable' };
  const intercept = my - slope * mx;
  return { ok: true, n, slope, intercept, speedAt: intercept + slope * e.predictAt, hrSd };
}

/** Marathon repeat adjusted for the change in speed at a fixed aerobic heart rate between the two blocks. */
export function estimateE2(args: { cfg: ReadinessConfig; priorSeconds: number | null; priorDate?: string; representative: boolean; reasons: string[]; now: EfficiencyFit; prior: EfficiencyFit }): { estimate: Estimate; rEff: number | null } {
  const { cfg, now, prior } = args;
  const base = { name: 'E2_prior_marathon', predictedSeconds: null, sigmaPct: null };
  if (args.priorSeconds === null) return { estimate: { ...base, available: false, inputs: {}, notes: ['No prior marathon found in the last 36 months.'] }, rEff: null };
  if (!now.ok || !prior.ok) {
    const why = [!now.ok ? `current block: ${now.reason}` : null, !prior.ok ? `prior block: ${prior.reason}` : null].filter(Boolean).join('; ');
    return { estimate: { ...base, available: false, inputs: { prior_marathon: hms(args.priorSeconds) }, notes: [`Efficiency comparison unavailable: ${why}.`] }, rEff: null };
  }
  const rEff = now.speedAt / prior.speedAt;
  const sigma = cfg.e2.sigmaPct + (args.representative ? 0 : cfg.e2.nonRepresentativeSigmaAdd);
  const notes = args.representative ? [] : [`Prior result may understate fitness (${args.reasons.join('; ')}).`];
  return {
    estimate: {
      ...base, available: true, predictedSeconds: args.priorSeconds / rEff, sigmaPct: sigma,
      inputs: { prior_marathon: hms(args.priorSeconds), prior_date: args.priorDate ?? null, speed_ratio_at_75pct_hrmax: Math.round(rEff * 1000) / 1000, splits_now: now.n, splits_prior: prior.n, representative: args.representative },
      notes,
    },
    rEff,
  };
}

// ---------------------------------------------------------------------------------------------
// E3: Tanda & Knechtle (2013)

export function estimateE3(args: { cfg: ReadinessConfig; weeklyKm: number; paceSecPerKm: number; weeksWithRuns: number; bodyFatPct: number | null; sex: 'male' | 'female' | null }): Estimate {
  const { cfg } = args;
  const base = { name: 'E3_training_based', predictedSeconds: null, sigmaPct: null };
  if (args.weeksWithRuns < cfg.e3.minWeeksWithRuns) return { ...base, available: false, inputs: {}, notes: [`Only ${args.weeksWithRuns} of the last ${cfg.windows.e3Weeks} weeks have runs (need ${cfg.e3.minWeeksWithRuns}).`] };
  const t = cfg.e3.tanda;
  const bf = args.bodyFatPct ?? cfg.e3.defaultBodyFatPct;
  const minutes = t.a + t.b * Math.exp(t.c * args.weeklyKm) + t.d * args.paceSecPerKm + t.e * Math.exp(t.f * bf);
  const notes: string[] = ['Population formula derived from recreational men (Tanda & Knechtle 2013); low weight.'];
  if (args.bodyFatPct === null) notes.push(`Body fat not recorded; default ${cfg.e3.defaultBodyFatPct}% used.`);
  if (minutes < cfg.e3.validRangeMin[0] || minutes > cfg.e3.validRangeMin[1]) notes.push(`Result is outside the ${cfg.e3.validRangeMin[0]}-${cfg.e3.validRangeMin[1]} minute range the formula was fitted on.`);
  let sigma = cfg.e3.sigmaPct.male;
  if (args.sex === 'female') {
    sigma = cfg.e3.sigmaPct.female;
    notes.push('Formula was derived from men; limited applicability.');
  } else if (args.sex === null) notes.push('Sex not available (profile data off); the male-derived formula and sigma are used.');
  return {
    ...base, available: true, predictedSeconds: minutes * 60, sigmaPct: sigma,
    inputs: { mean_weekly_km_8wk: Math.round(args.weeklyKm * 10) / 10, mean_training_pace_s_per_km: Math.round(args.paceSecPerKm), body_fat_pct: bf, body_fat_source: args.bodyFatPct === null ? 'default' : 'health' },
    notes,
  };
}

/**
 * Cross-check only (never averaged in, which would count the same fitness twice): the prior marathon scaled by how the
 * Tanda training-index prediction changed between the prior block and now. Population-level, so it ignores personal response.
 */
export function volumeBasedRepeat(args: { cfg: ReadinessConfig; priorSeconds: number; nowKm: number; nowPace: number; priorKm: number; priorPace: number }): number | null {
  const t = args.cfg.e3.tanda;
  const f = (km: number, pace: number) => t.a + t.b * Math.exp(t.c * km) + t.d * pace;
  if (!(args.nowKm > 0 && args.nowPace > 0 && args.priorKm > 0 && args.priorPace > 0)) return null;
  const bf = t.e * Math.exp(t.f * args.cfg.e3.defaultBodyFatPct);
  return args.priorSeconds * ((f(args.nowKm, args.nowPace) + bf) / (f(args.priorKm, args.priorPace) + bf));
}
