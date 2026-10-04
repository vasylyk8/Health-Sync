import { adjustmentSigmaSeconds, applyAdjustments, buildAdjustments } from './adjust.js';
import { combineEstimates, applyModifier, likelihood, range80 } from './combine.js';
import { confidenceComponents, confidencePercent } from './confidence.js';
import { READINESS_CONFIG, type ReadinessConfig } from './config.js';
import { effortsOfRun, efficiencyPoints, estimateE1, estimateE1b, estimateE2, estimateE3, estimateEarlierRace, fitSpeedAtHr, lowerBoundEffort, personalExponent, selectE1Source, volumeAdjustedR, volumeBasedRepeat } from './estimators.js';
import { addDays, avgWeeklyKm, countRunsAtLeast, daysBetween, fullSplits, hms, inWindow, longestGapDays, mean, median, runKm, weeksWithRuns, windowStart } from './features.js';
import { decouplingQualifying, evaluateModifiers, relativeModifiers } from './modifiers.js';
import type { ReadinessResult } from './schema.js';
import type { Estimate, PriorMarathon, RaceEffort, ReadinessInputs, RunRaw, RunSummary } from './types.js';

/** The pure computation behind assess_race_readiness: inputs in, the spec section 7 result out. No I/O. */

const round = (x: number, d = 1) => Math.round(x * 10 ** d) / 10 ** d;
const paceStr = (secPerKm: number) => `${Math.floor(Math.round(secPerKm) / 60)}:${String(Math.round(secPerKm) % 60).padStart(2, '0')}`;

export const CAVEATS = [
  'Estimates come from population formulas and heuristics, not measured physiology; individual error is real.',
  'The likelihood is a modelled probability of finishing at or under the goal time given the recorded data. It is not a guarantee, a medical assessment or a training prescription.',
  'Confidence describes how complete and trustworthy the data is. It is reported separately and does not change the likelihood.',
  'Modifier sizes, sigmas and confidence weights are heuristics until calibrated by backtest.',
];

export interface Representativeness {
  representative: boolean;
  reasons: string[];
  splitRatio: number | null;
}

/** Whether a prior marathon reflects the runner's fitness: not hot, not positively split, not walk-heavy, not a pacing job. */
export function assessPriorMarathon(prior: PriorMarathon, maxHr: number, cfg: ReadinessConfig): Representativeness {
  const r = cfg.e2.representative;
  const reasons: string[] = [];
  const t = prior.run.tempC;
  if (t !== null && t > r.hotC) reasons.push(`hot (${round(t)} degC recorded)`);
  let splitRatio: number | null = null;
  const raw = prior.raw;
  if (raw?.halves && raw.halves[0] > 0) {
    splitRatio = raw.halves[1] / raw.halves[0] - 1;
    if (splitRatio > r.positiveSplit) reasons.push(`positive split (second half ${round(splitRatio * 100)}% slower)`);
    else if (splitRatio < -r.paceDutySplit && prior.run.avgHr !== null && prior.run.avgHr / maxHr < r.paceDutyHrFraction) reasons.push('large negative split at low heart rate (pacing duty?)');
  }
  if (raw) {
    const paces = fullSplits(raw.splits).map((s) => s.pace_seconds_per_unit);
    const med = median(paces);
    if (med !== null && paces.length >= 10 && paces.filter((p) => p > med * r.walkSlowFactor).length / paces.length >= r.walkShare) reasons.push('many very slow kilometres (walk-heavy)');
  }
  return { representative: reasons.length === 0, reasons, splitRatio };
}

const analysedRaw = (inputs: ReadinessInputs, runs: RunSummary[]): RunRaw[] => runs.flatMap((r) => (inputs.raw.has(r.id) ? [inputs.raw.get(r.id)!] : []));

export function computeReadiness(inputs: ReadinessInputs, cfg: ReadinessConfig = READINESS_CONFIG, detail: 'summary' | 'full' = 'summary'): ReadinessResult {
  const w = cfg.windows;
  const asOf = inputs.asOf;
  const weeksToRace = inputs.race.daysUntil / 7;
  const mode = weeksToRace > w.raceWindowWeeks ? 'current_fitness_snapshot' : 'race_window';
  const blockStart = windowStart(asOf, w.blockWeeks);
  const durStart = windowStart(asOf, w.durabilityWeeks);
  const goalPace = inputs.goalSeconds / (cfg.marathonM / 1000);
  const gaps = [...inputs.gaps];
  const caveats = [...CAVEATS];
  if (mode === 'current_fitness_snapshot') caveats.push(`The race is ${round(weeksToRace)} weeks away: the result describes current fitness, not race-day fitness, and race-day uncertainty is widened.`);

  const blockRuns = inputs.runs.filter((r) => inWindow(r, blockStart, asOf));
  const weeksRun = weeksWithRuns(inputs.runs, blockStart, asOf);
  const maxHr = inputs.maxHr.value;

  // ---- Prior marathon, its representativeness and its block -------------------------------------------------------
  const prior = inputs.priorMarathon;
  const rep = prior ? assessPriorMarathon(prior, maxHr, cfg) : null;
  const priorDate = prior?.run.date ?? null;
  const priorBlockStart = priorDate ? windowStart(addDays(priorDate, -1), w.blockWeeks) : null;
  const priorBlockEnd = priorDate ? addDays(priorDate, -1) : null;

  // ---- E1: race conversion ---------------------------------------------------------------------------------------
  const efforts: RaceEffort[] = [];
  const tagged = new Set(inputs.taggedRaceIds);
  for (const id of tagged) {
    const run = inputs.runs.find((r) => r.id === id);
    if (!run) gaps.push(`Tagged race ${id} is not among the running workouts up to ${asOf}.`);
    else if (run.date < windowStart(asOf, cfg.earlier.maxAgeWeeks)) gaps.push(`Tagged race ${id} (${run.date}) is older than ${cfg.earlier.maxAgeWeeks} weeks and was not used.`);
    else if (effortsOfRun({ cfg, run, raw: inputs.raw.get(id) ?? null, tagged: true, maxHr, ageWeeks: 0 }).length === 0) gaps.push(`Tagged race ${id} could not be used (its distance is outside ${cfg.detect.taggedRangeM[0] / 1000}-${cfg.detect.taggedRangeM[1] / 1000} km or it has no duration).`);
  }
  for (const run of blockRuns) {
    efforts.push(...effortsOfRun({ cfg, run, raw: inputs.raw.get(run.id) ?? null, tagged: tagged.has(run.id), maxHr, ageWeeks: daysBetween(run.date, asOf) / 7 }));
  }
  const source = selectE1Source(efforts, cfg);
  const avgKm12 = avgWeeklyKm(inputs.runs, asOf, w.durabilityWeeks);
  const runs30k = countRunsAtLeast(inputs.runs, cfg.modifiers.longRuns30k.minKm, durStart, asOf);

  // ---- E2a: personal exponent (needs a representative prior marathon and a max-effort shorter race in its block) ----
  let personalR: number | null = null;
  let personalNote: string | null = null;
  if (prior && rep) {
    const priorEfforts: RaceEffort[] = [];
    for (const run of inputs.runs.filter((r) => inWindow(r, priorBlockStart!, priorBlockEnd!))) {
      priorEfforts.push(...effortsOfRun({ cfg, run, raw: inputs.raw.get(run.id) ?? null, tagged: false, maxHr, ageWeeks: daysBetween(run.date, priorDate!) / 7 }));
    }
    const pSrc = selectE1Source(priorEfforts.filter((e) => e.klass !== 'fiveK'), cfg);
    if (pSrc && rep.representative) personalR = personalExponent(cfg, prior.seconds, pSrc.seconds, pSrc.distanceM);
    else if (pSrc && !rep.representative) personalNote = 'Personal exponent not used: the prior marathon may not be representative.';
    else personalNote = 'No max-effort half marathon or 10K found in the prior marathon block, so no personal exponent.';
  }
  const lowerBound = source ? null : lowerBoundEffort(efforts, cfg, personalR ?? volumeAdjustedR(cfg, avgKm12, runs30k).r);
  const e1 = estimateE1({ cfg, source, personalR, avgWeeklyKm: avgKm12, runs30k, lowerBound });
  if (personalNote) e1.notes.push(personalNote);
  if (personalR !== null) e1.notes.push('Exponent derived from the prior marathon and a max-effort race in the same block.');
  const sourceRaw = source ? inputs.raw.get(source.workoutId) : undefined;
  if (e1.available && sourceRaw && sourceRaw.gainPerKm !== null && sourceRaw.gainPerKm >= cfg.e2.efficiency.maxGainPerKm) {
    e1.notes.push(`The source effort was on hilly terrain (${round(sourceRaw.gainPerKm)} m of climbing per km), so it likely understates flat-course fitness; no terrain correction is applied to sources.`);
  }
  // No race-quality effort: the best effort inside a training run is a conservative, wide estimate rather than a floor.
  const e1b = source ? null : estimateE1b({ cfg, effort: lowerBound, personalR, avgWeeklyKm: avgKm12, runs30k });

  // ---- E2: efficiency-adjusted repeat of the prior marathon -------------------------------------------------------
  const nowEff = fitSpeedAtHr(efficiencyPoints(analysedRaw(inputs, inputs.runs.filter((r) => inWindow(r, windowStart(asOf, w.efficiencyWeeks), asOf))), maxHr, cfg), cfg);
  const priorEff = prior ? fitSpeedAtHr(efficiencyPoints(analysedRaw(inputs, inputs.runs.filter((r) => inWindow(r, windowStart(priorBlockEnd!, w.efficiencyWeeks), priorBlockEnd!))), maxHr, cfg), cfg) : ({ ok: false, n: 0, reason: 'no prior marathon' } as const);
  const e2res = estimateE2({ cfg, priorSeconds: prior?.seconds ?? null, priorDate: priorDate ?? undefined, representative: rep?.representative ?? true, reasons: rep?.reasons ?? [], now: nowEff, prior: priorEff });
  const e2 = e2res.estimate;
  if (inputs.priorDisabled) e2.notes = ['Prior marathon comparison disabled by the caller.'];

  // ---- E3: training-based (Tanda) ---------------------------------------------------------------------------------
  const e3Start = windowStart(asOf, w.e3Weeks);
  const e3Runs = inputs.runs.filter((r) => inWindow(r, e3Start, asOf) && r.distanceM && r.movingSec);
  const e3Km = e3Runs.reduce((n, r) => n + runKm(r), 0);
  // Treadmill pace depends on calibration: the pace term uses outdoor runs when there are any (their distance still counts towards volume).
  const outdoor = e3Runs.filter((r) => !r.indoor);
  const paceRuns = outdoor.length ? outdoor : e3Runs;
  const paceKm = paceRuns.reduce((n, r) => n + runKm(r), 0);
  const paceSec = paceRuns.reduce((n, r) => n + r.movingSec!, 0);
  const e3 = estimateE3({ cfg, weeklyKm: e3Km / w.e3Weeks, paceSecPerKm: paceKm > 0 ? paceSec / paceKm : 0, weeksWithRuns: weeksWithRuns(inputs.runs, e3Start, asOf), bodyFatPct: inputs.bodyFatPct, sex: inputs.sex });
  if (e3.available && outdoor.length && outdoor.length < e3Runs.length) e3.notes.push(`${e3Runs.length - outdoor.length} treadmill run(s) were left out of the training pace (their distance counts towards weekly km).`);

  const indices = (start: string, end: string) => {
    const rs = inputs.runs.filter((r) => inWindow(r, start, end) && r.distanceM && r.movingSec);
    const outdoorRs = rs.filter((r) => !r.indoor);
    const pr = outdoorRs.length ? outdoorRs : rs;
    const k = pr.reduce((n, r) => n + runKm(r), 0);
    return { weeklyKm: rs.reduce((n, r) => n + runKm(r), 0) / w.e3Weeks, pace: k > 0 ? pr.reduce((n, r) => n + r.movingSec!, 0) / k : 0 };
  };
  const massAround = (date: string) => {
    const from = addDays(date, -cfg.earlier.massWindowDays);
    const xs = inputs.bodyMassKg.filter((m) => m.date >= from && m.date <= date).map((m) => m.kg);
    return xs.length ? mean(xs) : null;
  };

  // ---- E1s: an earlier race (older than the current block) as personal data -------------------------------------------
  const earlierStart = windowStart(asOf, cfg.earlier.maxAgeWeeks);
  const earlierEfforts: RaceEffort[] = [];
  for (const run of inputs.runs.filter((r) => r.date >= earlierStart && r.date < blockStart)) {
    earlierEfforts.push(...effortsOfRun({ cfg, run, raw: inputs.raw.get(run.id) ?? null, tagged: tagged.has(run.id), maxHr, ageWeeks: daysBetween(run.date, asOf) / 7 }));
  }
  const earlierCfg = { ...cfg, e1: { ...cfg.e1, maxSourceAgeWeeks: cfg.earlier.maxAgeWeeks } };
  const earlierSource = selectE1Source(earlierEfforts, earlierCfg);
  let earlierR: number | null = null;
  if (earlierSource && personalR === null && prior && rep?.representative && priorBlockEnd) {
    // Personal exponent from the best race in the lead-up to the prior marathon, shrunk towards the default (one pair is noisy and confounded by fitness change).
    const lead: RaceEffort[] = [];
    for (const run of inputs.runs.filter((r) => inWindow(r, windowStart(priorBlockEnd, cfg.earlier.maxAgeWeeks), priorBlockEnd))) {
      lead.push(...effortsOfRun({ cfg, run, raw: inputs.raw.get(run.id) ?? null, tagged: false, maxHr, ageWeeks: daysBetween(run.date, priorDate!) / 7 }));
    }
    const leadSrc = selectE1Source(lead.filter((x) => x.klass !== 'fiveK'), earlierCfg);
    const pr = leadSrc ? personalExponent(cfg, prior.seconds, leadSrc.seconds, leadSrc.distanceM) : null;
    if (pr !== null) {
      const baseR = volumeAdjustedR(cfg, avgKm12, runs30k).r;
      earlierR = baseR + cfg.earlier.personalRShrink * (pr - baseR);
    }
  }
  let e1s: Estimate | null = null;
  if (earlierSource) {
    const end = addDays(earlierSource.date, -1);
    const thenEff = fitSpeedAtHr(efficiencyPoints(analysedRaw(inputs, inputs.runs.filter((r) => inWindow(r, windowStart(end, w.efficiencyWeeks), end))), maxHr, cfg), cfg);
    const kmThen = avgWeeklyKm(inputs.runs, end, w.durabilityWeeks);
    const gapDays = longestGapDays(inputs.runs, addDays(earlierSource.date, 1), asOf);
    const maintained = avgKm12 >= cfg.earlier.maintainedVolumeFraction * kmThen && gapDays <= cfg.earlier.maxGapDays;
    const idxNow = indices(e3Start, asOf);
    const idxThen = indices(windowStart(end, w.e3Weeks), end);
    const volumeTimeRatio = volumeBasedRepeat({ cfg, priorSeconds: 1, nowKm: idxNow.weeklyKm, nowPace: idxNow.pace, priorKm: idxThen.weeklyKm, priorPace: idxThen.pace });
    e1s = estimateEarlierRace({
      cfg, source: earlierSource, personalR: personalR ?? earlierR, avgWeeklyKm: avgKm12, runs30k, now: nowEff, then: thenEff, weeklyKmThen: kmThen, maintained, gapDays,
      volumeTimeRatio, massNow: massAround(asOf), massThen: massAround(earlierSource.date),
    });
    if (earlierR !== null && personalR === null) e1s.notes.push('Exponent: the runner\'s own marathon-vs-race relationship, moved halfway from the default (a single pair is noisy).');
  }

  // E1b says the runner can run at least that fast: a bound, not an estimate. It only enters the average when nothing better exists;
  // otherwise it can only cap the time (it must not drag better evidence slower).
  const e1bAsEstimate = !!e1b?.available && !e1.available && !e2.available && !e1s?.available;
  if (e1b?.available && !e1bAsEstimate) e1b.notes.push('Used only as an upper bound on the finish time (the effort did not reach a max-effort heart rate), because better evidence exists.');
  const estimates: Estimate[] = [e1, ...(e1b ? [e1b] : []), ...(e1s ? [e1s] : []), e2, e3];

  // ---- Confidence (computed even when there is no score, so the user sees what is missing) -----------------------------
  const durRaw = inputs.runs.filter((r) => inWindow(r, durStart, asOf));
  const modInputs = { cfg, runs: durRaw, raw: inputs.raw, windowStart: durStart, windowEnd: asOf, goalPaceSecPerKm: goalPace, maxHr };
  const hrFrac = (() => {
    if (!blockRuns.length) return null;
    let covered = 0;
    let total = 0;
    let rawRuns = 0;
    let summaryRuns = 0;
    for (const r of blockRuns) {
      const raw = inputs.raw.get(r.id);
      const sec = raw?.movingSec ?? r.movingSec ?? 0;
      if (sec <= 0) continue;
      total += sec;
      if (raw) {
        covered += sec * (raw.hrUnreliable ? 0 : raw.hrCoverage ?? 0);
        rawRuns++;
      } else {
        covered += r.avgHr !== null ? sec : 0;
        summaryRuns++;
      }
    }
    return total > 0 ? { fraction: covered / total, rawRuns, summaryRuns } : null;
  })();
  const minRunSec = cfg.confidence.fueling.minRunMinutes * 60;
  const carbRuns = blockRuns.filter((r) => inputs.nutrition.carbRunIds.includes(r.id) && (r.movingSec ?? 0) >= minRunSec).length;
  const components = confidenceComponents({
    cfg, effort: source, lowerBoundOnly: !source && !e1s && !!lowerBound, earlierRace: !source && e1s && earlierSource ? { ageWeeks: earlierSource.ageWeeks, tagged: earlierSource.tagged } : null, weeksWithRuns: weeksRun, longestGapDays: longestGapDays(inputs.runs, blockStart, asOf),
    longRunsWithSplits: durRaw.filter((r) => runKm(r) >= cfg.confidence.longRuns.minKm && (inputs.raw.get(r.id)?.splits.length ?? 0) > 0).length,
    hrCoverage: hrFrac, priorMarathon: { present: !!prior, hasStreams: !!prior?.raw, representative: rep?.representative ?? false },
    maxHrSource: inputs.maxHr.source, decouplingRuns: decouplingQualifying(modInputs).length, fueling: { enabled: inputs.nutrition.enabled, qualifyingRuns: carbRuns }, weeksToRace,
  });
  const confidence = { percent: confidencePercent(components), components };

  // ---- Shared output parts ------------------------------------------------------------------------------------------
  if (inputs.maxHr.source === 'default') gaps.push(`Max heart rate is a default (${maxHr} bpm: ${inputs.maxHr.note ?? 'default'}); heart-rate checks are less reliable.`);
  const skippedBy = new Map<string, number>();
  for (const s of inputs.rawSkipped) skippedBy.set(s.reason, (skippedBy.get(s.reason) ?? 0) + 1);
  for (const [reason, n] of skippedBy) gaps.push(`${n} shortlisted run(s) were not analysed from raw data: ${reason}.`);
  if (inputs.bodyFatPct === null) gaps.push(`Body fat is not recorded in the last ${w.durabilityWeeks} weeks; the training-based estimator uses a default.`);
  const noAlt = [...inputs.raw.values()].filter((r) => r.gainPerKm === null).length;
  if (noAlt) gaps.push(`${noAlt} analysed run(s) have no altitude data, so they cannot be shown to be flat and are left out of the decoupling and efficiency checks.`);
  if (!inputs.nutrition.enabled) gaps.push('Nutrition data is switched off or not granted to this connection, so fueling is unknown (this says nothing about the runner\'s fueling).');
  gaps.push('Heart-rate artefact check by cadence is not available; only implausible or flat heart-rate traces are flagged.');
  for (const e of estimates) if (!e.available) gaps.push(`${e.name}: ${e.notes.join(' ')}`);

  const race = {
    id: inputs.race.id, name: inputs.race.name, date: inputs.race.date, days_until: inputs.race.daysUntil,
    goal_time: hms(inputs.goalSeconds), goal_pace_per_km: paceStr(goalPace),
  };
  const assumptions = {
    max_hr: maxHr, max_hr_source: inputs.maxHr.source, max_hr_note: inputs.maxHr.note ?? null,
    body_fat_source: inputs.bodyFatPct === null ? ('default' as const) : ('health' as const),
    sex_source: inputs.sex === null ? ('unknown' as const) : ('profile' as const),
    goal_time_source: 'race_goal' as const,
    course: inputs.context.course,
    expected_temp_c: inputs.context.expectedTempC,
  };

  const combined = e1.available || e1b?.available || e1s?.available || e2.available ? combineEstimates(estimates.filter((e) => e.name !== 'E1b_training_effort' || e1bAsEstimate), cfg, weeksToRace) : null;
  if (weeksRun < w.minDataWeeks || !combined) {
    if (weeksRun < w.minDataWeeks) gaps.unshift(`Only ${weeksRun} of the last ${w.blockWeeks} weeks have runs; at least ${w.minDataWeeks} are needed.`);
    else gaps.unshift('No race-quality effort (E1), training-run effort (E1b) or prior-marathon comparison (E2) is available, and the training-based estimator alone is not used.');
    return { status: 'insufficient_data', as_of: asOf, mode, race, confidence, data_gaps: dedupe(gaps), assumptions, caveats };
  }

  // ---- Modifiers, likelihood ---------------------------------------------------------------------------------------
  let mods = evaluateModifiers(modInputs);
  const e2Weight = combined.weights.find((x) => x.name === 'E2_prior_marathon')?.weight ?? 0;
  if (prior && priorBlockEnd && e2Weight > 0) {
    const pStart = windowStart(priorBlockEnd, w.durabilityWeeks);
    const priorMods = evaluateModifiers({ ...modInputs, runs: inputs.runs.filter((r) => inWindow(r, pStart, priorBlockEnd)), windowStart: pStart, windowEnd: priorBlockEnd });
    mods = relativeModifiers(mods, priorMods, e2Weight, cfg.modifiers.capPct);
    caveats.push('Durability checks were compared with the prior marathon block, because the prior marathon carries most of the weight: only a shortfall against that block adds time to that part of the estimate.');
  }
  for (const m of mods.results) if (m.status === 'unknown') gaps.push(`Durability check "${m.check}" is unknown: ${m.detail ?? 'no qualifying data'}.`);
  const e1bCap = e1b?.available && !e1bAsEstimate ? e1b.predictedSeconds! : null;
  const centralBase = e1bCap !== null ? Math.min(combined.centralSeconds, e1bCap) : combined.centralSeconds;
  if (e1bCap !== null && e1bCap < combined.centralSeconds) caveats.push('The best training-run effort capped the central estimate: the runner can run at least that fast.');
  const centralMod = applyModifier(centralBase, mods.cappedPct);
  // Context adjustments (course, expected heat, shoes what-if) move the central estimate and widen sigma, because they are uncertain too.
  const adjs = buildAdjustments(inputs.context, cfg);
  const centralFinal = applyAdjustments(centralMod, adjs);
  const sigma = Math.sqrt(combined.sigmaTotalSeconds ** 2 + adjustmentSigmaSeconds(centralMod, adjs) ** 2);
  if (e1b?.available) caveats.push('No race-quality effort was found: the estimate rests on the best effort inside a training run and on training volume. Treat it as rough; a recent race or a hard half-marathon or 10K effort would sharpen it a lot.');
  if (inputs.context.expectedTempC === null) caveats.push('Race-day weather is not modelled (pass expected_temp_c to include heat).');
  if (inputs.context.course === null) caveats.push('No course profile was given, so the course is treated as flat (pass course for a rolling or hilly course).');
  caveats.push('Race-day fueling, pacing and crowd congestion are not modelled; the race-day uncertainty term covers typical effects.');
  const lk = likelihood(inputs.goalSeconds, centralFinal, sigma, cfg);
  const [lo, hi] = range80(centralFinal, sigma, cfg);
  if (mods.totalPct > mods.cappedPct) caveats.push(`Durability modifiers total ${mods.totalPct}%; capped at ${mods.cappedPct}%.`);
  if (prior && prior.seconds <= inputs.goalSeconds) caveats.push(`A prior marathon (${prior.run.date}, ${hms(prior.seconds)}) is at or under the goal time.`);
  if (combined.disagreementSeconds >= 300) caveats.push(`The estimators disagree by about ${Math.round(combined.disagreementSeconds / 60)} minutes, so the uncertainty was widened.`);
  if (combined.sigmaFloorApplied) caveats.push('The estimators share one runner, so the combined uncertainty was held at 85% of the best single estimator.');

  const est = estimates.map((e) => ({
    name: e.name, available: e.available, predicted: e.predictedSeconds !== null ? hms(e.predictedSeconds) : null,
    sigma_pct: e.sigmaPct !== null ? round(e.sigmaPct) : null, weight: combined.weights.find((x) => x.name === e.name)?.weight ?? null, inputs: e.inputs, notes: e.notes,
  })).map((e) => ({ ...e, weight: e.weight !== null ? round(e.weight, 3) : null }));

  // ---- Benchmarks and block comparison -----------------------------------------------------------------------------
  const priorEnd = priorBlockEnd;
  const massNow = massAround(asOf);
  const massPrior = priorDate ? massAround(priorDate) : null;
  if (e2.available && massNow !== null && massPrior !== null && Math.abs(massNow / massPrior - 1) >= 0.02) {
    caveats.push(`Body mass is ${round(massNow)} kg vs ${round(massPrior)} kg at the prior marathon (${massNow < massPrior ? 'lighter' : 'heavier'}). The prior-marathon estimate compares speed at a fixed heart rate, which already includes the effect of weight, so no separate weight adjustment is added to it.`);
  }
  const volumeRepeatSec = prior && priorEnd ? (() => {
    const now = indices(e3Start, asOf);
    const then = indices(windowStart(priorEnd, w.e3Weeks), priorEnd);
    return volumeBasedRepeat({ cfg, priorSeconds: prior.seconds, nowKm: now.weeklyKm, nowPace: now.pace, priorKm: then.weeklyKm, priorPace: then.pace });
  })() : null;
  if (volumeRepeatSec !== null && e2.available && Math.abs(volumeRepeatSec / e2.predictedSeconds! - 1) > 0.03) {
    const dir = volumeRepeatSec < e2.predictedSeconds! ? 'faster' : 'slower';
    caveats.push(`Cross-check: scaling the prior marathon by the change in training volume and pace alone gives ${hms(volumeRepeatSec)}, ${dir} than the efficiency-based repeat (${hms(e2.predictedSeconds!)}) by more than 3%. The two measure different things (volume vs aerobic efficiency); the volume figure is not averaged in.`);
  }
  const priorDurStart = priorEnd ? windowStart(priorEnd, w.durabilityWeeks) : null;
  const priorKm12 = priorEnd ? avgWeeklyKm(inputs.runs, priorEnd, w.durabilityWeeks) : null;
  const priorRuns30 = priorEnd ? countRunsAtLeast(inputs.runs, cfg.modifiers.longRuns30k.minKm, priorDurStart!, priorEnd) : null;
  const longest = Math.max(0, ...durRaw.map(runKm));
  const baseEnd = addDays(blockStart, -1);
  const baseStart = windowStart(baseEnd, w.baseWeeks);
  const baseRuns = inputs.runs.filter((r) => inWindow(r, baseStart, baseEnd));
  const earliest = inputs.runs.reduce<string | null>((m, r) => (m === null || r.date < m ? r.date : m), null);
  const historyWeeks = earliest === null ? 0 : Math.max(0, Math.floor(daysBetween(earliest, blockStart) / 7));
  if (historyWeeks < w.baseWeeks) gaps.push(`Running history before the ${w.blockWeeks}-week block covers ${historyWeeks} of the ${w.baseWeeks} weeks wanted for the long-term base; the base figure uses the weeks available.`);
  const baseWeeksUsed = Math.max(1, Math.min(w.baseWeeks, historyWeeks));
  const benchmarks = [
    { metric: 'avg_weekly_km_12wk', value: round(avgKm12), context: priorKm12 !== null ? `prior marathon block: ${round(priorKm12)}` : 'no prior marathon block', evidence: 'moderate' as const },
    { metric: 'longest_run_km_12wk', value: round(longest), context: 'a longest run of 25 km or more is associated with faster marathon finishes (PMC7496388)', evidence: 'moderate' as const },
    { metric: 'runs_30km_or_more_12wk', value: runs30k, context: priorRuns30 !== null ? `prior marathon block: ${priorRuns30}` : 'no prior marathon block', evidence: 'moderate' as const },
    { metric: 'avg_weekly_km_base_52wk', value: baseRuns.length ? round(avgWeeklyKm(inputs.runs, baseEnd, baseWeeksUsed)) : null, context: baseRuns.length ? `context only, not used in the estimate: mean over the ${baseWeeksUsed} week(s) of history before the ${w.blockWeeks}-week block (up to ${w.baseWeeks})` : 'context only, not used in the estimate: no runs recorded before the block', evidence: 'moderate' as const },
    { metric: 'long_runs_with_carbs_logged', value: inputs.nutrition.enabled ? carbRuns : null, context: inputs.nutrition.enabled ? `of ${blockRuns.filter((r) => (r.movingSec ?? 0) >= minRunSec).length} runs of ${cfg.confidence.fueling.minRunMinutes} minutes or more in the block; not logged does not mean not eaten (context only)` : 'nutrition data is off or not granted (context only)', evidence: 'weak' as const },
    { metric: 'weeks_with_runs_16wk', value: weeksRun, context: `of ${w.blockWeeks}`, evidence: 'weak' as const },
  ];
  const block_comparison = {
    prior_marathon: prior && rep ? { workout_id: prior.run.id, date: prior.run.date, time: hms(prior.seconds), representative: rep.representative } : null,
    weekly_km_now_vs_prior: [round(avgKm12), priorKm12 !== null ? round(priorKm12) : null] as [number, number | null],
    runs_30k_now_vs_prior: [runs30k, priorRuns30] as [number, number | null],
    speed_at_75pct_hrmax_ratio: e2res.rEff !== null ? round(e2res.rEff, 3) : null,
    volume_based_repeat: volumeRepeatSec !== null ? hms(volumeRepeatSec) : null,
    body_mass_kg_now_vs_prior: [massNow !== null ? round(massNow) : null, massPrior !== null ? round(massPrior) : null] as [number | null, number | null],
  };

  const result: ReadinessResult = {
    status: 'ok', as_of: asOf, mode, race,
    likelihood: { score_0_10: lk.score, probability: round(lk.probability, 3), label: lk.label },
    prediction: { central: hms(centralFinal), range_80: [hms(lo), hms(hi)], sigma_pct: round((sigma / centralFinal) * 100, 2) },
    confidence, estimators: est,
    modifiers: mods.results.map((m) => ({ check: m.check, value: m.value, benchmark: m.benchmark, applied_pct: m.appliedPct, status: m.status, evidence: m.evidence, ...(m.detail ? { detail: m.detail } : {}) })),
    adjustments: adjs.map((a) => ({ name: a.name, pct: round(a.pct, 2), evidence: 'weak' as const, detail: a.detail })),
    benchmarks, block_comparison, data_gaps: dedupe(gaps), assumptions, caveats,
  };
  if (detail === 'full') result.workouts = workoutTable(inputs);
  return result;
}

const dedupe = (xs: string[]) => [...new Set(xs)];

/** Per-run table for detail "full": the runs that were analysed from raw data, newest first. */
function workoutTable(inputs: ReadinessInputs): Record<string, unknown>[] {
  return inputs.runs
    .filter((r) => inputs.raw.has(r.id))
    .sort((a, b) => b.startMs - a.startMs)
    .slice(0, 80)
    .map((r) => {
      const raw = inputs.raw.get(r.id)!;
      return {
        id: r.id, date: r.date, distance_km: round(raw.distanceM / 1000, 2), moving_time: hms(raw.movingSec), avg_hr: r.avgHr, indoor: r.indoor, temp_c: r.tempC,
        decoupling_pct: raw.decouplingPct, gain_per_km: raw.gainPerKm !== null ? round(raw.gainPerKm) : null, hr_coverage: raw.hrCoverage !== null ? round(raw.hrCoverage, 2) : null, hr_unreliable: raw.hrUnreliable,
        distance_source: raw.distanceSource, efforts: raw.efforts.map((e) => ({ distance_m: e.distanceM, time: hms(e.movingSec), avg_hr: e.avgHr !== null ? round(e.avgHr) : null })),
      };
    });
}
