import type { DuckDBConnection } from '@duckdb/node-api';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { DAILY_TYPE, WORKOUT_TYPE } from '../ingest/batch.js';
import { bestEfforts, heartRateDrift, movingMs, splits, timeAtDistance, weightReadings, type DistSeries } from '../query/calc.js';
import { rows } from '../query/common.js';
import { isComplete, loadType, ToolError, type QueryDeps } from '../query/context.js';
import { withDuck } from '../query/duck.js';
import { dailyMaps, enabledCategories, loadProfile } from '../query/health.js';
import type { WorkoutRow } from '../query/lookup.js';
import { calcContextFromRow, distanceOf, loadRoute, loadStream, loadWorkoutSummaries, rawStatus, type DistanceSource, type LoadedStream } from '../query/workouts.js';
import type { TypeManifest, WorkoutDataDoc } from '../store/types.js';
import type { ReadinessConfig } from './config.js';
import { addDays, addMonths, cleanSplits, daysBetween, detectPriorMarathon, findDuplicateGroups, inWindow, mean, resolveMaxHr, runKm, runSummary, sd, windowStart } from './features.js';
import type { EffortHr, PriorMarathon, ReadinessInputs, RunRaw, RunSummary } from './types.js';

/** Data extraction for assess_race_readiness: reads run summaries cheaply, then raw streams only for a shortlist. */

const DAY_MS = 86_400_000;

// ---------------------------------------------------------------------------------------------
// Shortlist (pure)

export interface ShortlistArgs {
  runs: RunSummary[];
  asOf: string;
  maxHr: number;
  taggedIds: string[];
  prior: RunSummary | null;
  cfg: ReadinessConfig;
}

/**
 * Which runs are worth reading raw streams for, most valuable first (the time budget drops the tail):
 * the prior marathon, tagged races, long runs, likely max efforts, steady aerobic runs of both blocks.
 */
export function selectForRawAnalysis(a: ShortlistArgs): { id: string; why: string }[] {
  const { cfg, runs } = a;
  const b = cfg.budget;
  const out: { id: string; why: string }[] = [];
  const seen = new Set<string>();
  const add = (list: RunSummary[], why: string, max = Infinity) => {
    let n = 0;
    for (const r of list) {
      if (n >= max) break;
      if (seen.has(r.id)) continue;
      seen.add(r.id);
      out.push({ id: r.id, why });
      n++;
    }
  };
  const speed = (r: RunSummary) => (r.distanceM && r.movingSec ? r.distanceM / r.movingSec : 0);
  const newestFirst = (xs: RunSummary[]) => [...xs].sort((x, y) => y.startMs - x.startMs);
  const fastestFirst = (xs: RunSummary[]) => [...xs].sort((x, y) => speed(y) - speed(x));
  const steady = (r: RunSummary) => {
    const km = runKm(r);
    return km >= b.steadyRunKm[0] && km <= b.steadyRunKm[1] && r.avgHr !== null && r.avgHr / a.maxHr >= b.steadyHrFraction[0] && r.avgHr / a.maxHr <= b.steadyHrFraction[1];
  };

  const blockStart = windowStart(a.asOf, cfg.windows.blockWeeks);
  const durStart = windowStart(a.asOf, cfg.windows.durabilityWeeks);
  const effStart = windowStart(a.asOf, cfg.windows.efficiencyWeeks);
  const block = runs.filter((r) => inWindow(r, blockStart, a.asOf));

  if (a.prior) add([a.prior], 'prior marathon');
  add(runs.filter((r) => a.taggedIds.includes(r.id)), 'tagged race');
  add(newestFirst(runs.filter((r) => inWindow(r, durStart, a.asOf) && runKm(r) >= b.longRunMinKm)), 'long run', 2 * b.candidatesPerBlock);
  add(fastestFirst(block.filter((r) => runKm(r) >= b.effortCandidateMinKm)), 'possible max effort', b.candidatesPerBlock);
  add(newestFirst(runs.filter((r) => inWindow(r, effStart, a.asOf) && steady(r))), 'steady run (current block)', b.steadyRunsPerBlock);
  if (a.prior) {
    const end = addDays(a.prior.date, -1);
    const priorBlock = runs.filter((r) => inWindow(r, windowStart(end, cfg.windows.blockWeeks), end));
    add(newestFirst(priorBlock.filter((r) => inWindow(r, windowStart(end, cfg.windows.durabilityWeeks), end) && runKm(r) >= b.longRunMinKm)), 'long run (prior block)', b.candidatesPerBlock);
    add(newestFirst(priorBlock.filter((r) => inWindow(r, windowStart(end, cfg.windows.efficiencyWeeks), end) && steady(r))), 'steady run (prior block)', b.steadyRunsPerBlock);
    add(fastestFirst(priorBlock.filter((r) => runKm(r) >= b.effortCandidateMinKm)), 'possible max effort (prior block)', b.candidatesPerBlock);
  }
  // Earlier races (older than the current block): the likeliest race-like runs, and the steady runs of the block before the first one
  // so the fitness change since then can be measured. Also races in the lead-up to the prior marathon (personal exponent).
  const raceLike = (r: RunSummary) => {
    const km = runKm(r);
    return km >= 4.8 && km <= 22.5 && r.avgHr !== null && r.avgHr / a.maxHr >= cfg.earlier.candidateHrFraction;
  };
  const prefer = (xs: RunSummary[]) => [...xs].sort((x, y) => Number(runKm(y) >= 19.5) - Number(runKm(x) >= 19.5) || y.startMs - x.startMs);
  const earlier = prefer(runs.filter((r) => r.date >= windowStart(a.asOf, cfg.earlier.maxAgeWeeks) && r.date < blockStart && raceLike(r)));
  add(earlier, 'earlier race candidate', cfg.earlier.candidates);
  if (earlier[0]) {
    const end = addDays(earlier[0].date, -1);
    add(newestFirst(runs.filter((r) => inWindow(r, windowStart(end, cfg.windows.efficiencyWeeks), end) && steady(r))), 'steady run (earlier race block)', b.steadyRunsPerBlock);
  }
  if (a.prior) {
    const end = addDays(a.prior.date, -1);
    add(prefer(runs.filter((r) => inWindow(r, windowStart(end, cfg.earlier.maxAgeWeeks), end) && raceLike(r))), 'race before prior marathon', cfg.earlier.candidates);
  }
  return out.slice(0, b.maxRawRuns);
}

// ---------------------------------------------------------------------------------------------
// Raw analysis of one run

export type RunAnalysis = { ok: true; raw: RunRaw } | { ok: false; reason: string };

/** Heart-rate samples outside the plausible range are sensor errors; a trace that is mostly errors or perfectly flat is unreliable. */
export function cleanHeartRate(hr: LoadedStream, maxHr: number, cfg: ReadinessConfig): { v: (number | null)[]; unreliable: boolean } {
  const [lo, hi] = cfg.maxHr.sampleRange;
  let total = 0;
  let dropped = 0;
  let spikes = 0;
  const v = (hr.cols.v ?? []).map((x) => {
    if (x == null) return null;
    total++;
    if (x < lo || x > hi) {
      dropped++;
      return null;
    }
    if (x > maxHr + cfg.maxHr.spikeMarginBpm) spikes++;
    return x;
  });
  const good = v.filter((x): x is number => x !== null);
  const flat = good.length >= 300 && (sd(good) ?? 0) < 1;
  return { v, unreliable: total === 0 || dropped / total > 0.05 || spikes / total > 0.02 || flat };
}

export async function analyseRun(deps: QueryDeps, c: DuckDBConnection, dir: string, row: WorkoutRow, doc: WorkoutDataDoc, man: TypeManifest | null, budget: { bytes: number }, o: { cfg: ReadinessConfig; maxHr: number; distanceSource: DistanceSource; targetsM: number[]; indoor: boolean; tempC: number | null }): Promise<RunAnalysis> {
  if (Object.keys(doc.streams).length === 0) return { ok: false, reason: 'no raw data synced yet' };
  // DuckDB caches parquet metadata by path: every run's stream files need a path of their own (the one-workout tools never meet this).
  const wdir = join(dir, `run-${row.id}`);
  await mkdir(wdir, { recursive: true });
  const ctx = calcContextFromRow(c, wdir, row, doc, man, budget);
  let dist: DistSeries;
  let used: string;
  try {
    ({ dist, used } = await distanceOf(deps, ctx, o.distanceSource));
  } catch (err) {
    if (err instanceof ToolError) return { ok: false, reason: 'no distance stream or GPS route' };
    throw err;
  }
  const total = dist.d[dist.d.length - 1] ?? 0;
  if (total < 1000) return { ok: false, reason: 'shorter than 1 km' };
  const movingSec = movingMs(ctx.pauses, row.s, row.e) / 1000;

  const hrStream = doc.streams.HeartRate ? await loadStream(c, wdir, deps, doc, 'HeartRate', budget) : null;
  const cleaned = hrStream ? cleanHeartRate(hrStream, o.maxHr, o.cfg) : null;
  const route = doc.streams.route ? await loadRoute(c, wdir, deps, doc) : null;

  const rawSplits = splits({
    dist, unitM: 1000, startMs: row.s, pauses: ctx.pauses,
    hr: hrStream && cleaned ? { t: hrStream.t, v: cleaned.v } : undefined,
    alt: route?.alt ? { t: route.t, v: route.alt } : undefined,
  }).map((s) => (o.indoor && s.elevation_gain_m === null ? { ...s, elevation_gain_m: 0 } : s));
  const { splits: kept } = cleanSplits(rawSplits, o.cfg.e2.gpsDropoutFactor);

  const full = kept.filter((s) => !s.partial);
  const gainKnown = full.length > 0 && full.every((s) => s.elevation_gain_m !== null);
  const gainPerKm = gainKnown ? full.reduce((n, s) => n + (s.elevation_gain_m ?? 0), 0) / full.length : null;

  const readings = hrStream && cleaned ? weightReadings(hrStream.t, cleaned.v, row.e, ctx.pauses) : null;
  const hrCoverage = readings && movingSec > 0 ? Math.min(1, readings.reduce((n, r) => n + r.w, 0) / movingSec) : null;
  const decoupling = readings ? heartRateDrift({ readings, startMs: row.s, endMs: row.e, pauses: ctx.pauses, dist }).decoupling_percent : null;

  const efforts: EffortHr[] = bestEfforts(dist, o.targetsM, row.s, ctx.pauses).map((e) => ({
    distanceM: e.distance_m,
    movingSec: e.moving_seconds,
    avgHr: hrStream && cleaned ? meanOrNull(hrStream.t, cleaned.v, row.s + e.start_offset_seconds * 1000, row.s + e.end_offset_seconds * 1000) : null,
  }));

  const tHalf = timeAtDistance(dist, total / 2);
  const firstHalf = tHalf === null ? null : movingMs(ctx.pauses, row.s, tHalf) / 1000;
  return {
    ok: true,
    raw: {
      id: row.id, distanceSource: used, splits: kept, hrCoverage, hrUnreliable: cleaned?.unreliable ?? false, decouplingPct: cleaned?.unreliable ? null : decoupling,
      efforts, movingSec, distanceM: total, gainPerKm, halves: firstHalf === null ? null : [firstHalf, movingSec - firstHalf], rawComplete: rawStatus(doc) === 'complete', tempC: o.tempC,
    },
  };
}

function meanOrNull(t: number[], v: (number | null)[], a: number, b: number): number | null {
  const xs: number[] = [];
  for (let i = 0; i < t.length; i++) {
    if (t[i]! < a) continue;
    if (t[i]! > b) break;
    if (v[i] != null) xs.push(v[i]!);
  }
  return mean(xs);
}

// ---------------------------------------------------------------------------------------------
// Gathering

export interface GatherArgs {
  tz: string;
  asOf: string;
  race: ReadinessInputs['race'];
  goalSeconds: number;
  maxHr?: number;
  raceWorkoutIds: string[];
  priorMarathonId?: string | null;
  distanceSource: DistanceSource;
  cfg: ReadinessConfig;
  context: ReadinessInputs['context'];
  /** The connection may read profile / nutrition events (OAuth scopes); false skips them with a disclosed gap. */
  allowProfile: boolean;
  allowNutrition: boolean;
  /** Monotonic millisecond clock (injected by tests). */
  clock?: () => number;
}

const richness = (doc: WorkoutDataDoc | null): number => {
  if (!doc) return 0;
  const useful = ['HeartRate', 'route', 'DistanceWalkingRunning'].filter((s) => doc.streams[s]).length;
  return useful * 1e9 + Object.values(doc.streams).reduce((n, s) => n + s.points, 0);
};

/**
 * Running workouts of a local date range as summaries, with the same run recorded twice (a watch and a phone app) reduced to one:
 * the one with the richest raw streams is kept. Shared by the tool and the backtest.
 */
export async function loadRunSummaries(deps: QueryDeps, c: DuckDBConnection, dir: string, tz: string, start: string, end: string, cfg: ReadinessConfig, budget: { bytes: number } = { bytes: 0 }) {
  const loaded = await loadWorkoutSummaries(c, dir, deps, tz, start, end, { activity: 'running', budget });
  const notes: string[] = [];
  const rowsById = new Map(loaded.workouts.map((w) => [w.id, w]));
  let runs = loaded.workouts.map(runSummary);
  const dup = findDuplicateGroups(runs, cfg.detect.duplicateOverlapFraction);
  if (dup.length) {
    const drop = new Set<string>();
    for (const group of dup) {
      const docs = await Promise.all(group.map((r) => deps.meta.getWorkoutData(deps.uid, r.id)));
      const scored = group.map((r, i) => ({ r, s: richness(docs[i] ?? null), km: runKm(r) }));
      scored.sort((x, y) => y.s - x.s || y.km - x.km);
      for (const x of scored.slice(1)) drop.add(x.r.id);
    }
    runs = runs.filter((r) => !drop.has(r.id));
    notes.push(`${drop.size} overlapping duplicate workout(s) (the same run from two sources) were removed, keeping the one with the richest raw data.`);
  }
  runs = runs.filter((r) => r.distanceM !== null || r.movingSec !== null);
  if (runs.some((r) => r.indoor)) notes.push('Treadmill runs are included only where a distance stream exists and are treated as flat; their pace depends on the treadmill or watch calibration.');
  return { man: loaded.man, startUtc: loaded.startUtc, endUtc: loaded.endUtc, rowsById, runs, notes };
}

export async function gatherInputs(deps: QueryDeps, a: GatherArgs): Promise<{ inputs: ReadinessInputs; coverage: [string, TypeManifest | null][]; complete: boolean }> {
  const { cfg } = a;
  const clock = a.clock ?? (() => performance.now());
  const t0 = clock();
  return withDuck(async (c, dir) => {
    const budget = { bytes: 0 };
    const gaps: string[] = [];
    const notes: string[] = [];
    const coverage: [string, TypeManifest | null][] = [];

    // ---- Run summaries (no raw data) ----------------------------------------------------------------------------
    const lookbackStart = addDays(addMonths(a.asOf, -cfg.windows.priorMarathonLookbackMonths), -cfg.windows.blockWeeks * 7);
    const loaded = await loadRunSummaries(deps, c, dir, a.tz, lookbackStart, a.asOf, cfg, budget);
    coverage.push([WORKOUT_TYPE, loaded.man]);
    const complete = isComplete(loaded.man, loaded.startUtc, loaded.endUtc, deps.now());
    const rowsById = loaded.rowsById;
    const runs = loaded.runs;
    notes.push(...loaded.notes);

    // ---- Profile (opt-in), max HR, body fat -----------------------------------------------------------------------
    const cats = await enabledCategories(deps);
    let sex: 'male' | 'female' | null = null;
    let age: number | null = null;
    if (cats.has('profile') && a.allowProfile) {
      try {
        const { man, profile } = await loadProfile(deps);
        coverage.push(['_events_profile', man]);
        if (profile.sex === 'male' || profile.sex === 'female') sex = profile.sex;
        age = typeof profile.age_years === 'number' ? profile.age_years : null;
      } catch (err) {
        if (!(err instanceof ToolError)) throw err;
      }
    } else gaps.push(cats.has('profile') ? 'This connection was not granted profile access: age and sex are unknown.' : 'Profile data is switched off: age and sex are unknown.');
    const maxHr = resolveMaxHr({ user: a.maxHr, runs, asOf: a.asOf, ageYears: age, cfg });

    let bodyFatPct: number | null = null;
    let bodyMassKg: { date: string; kg: number }[];
    {
      const from = windowStart(a.asOf, cfg.windows.durabilityWeeks);
      // Body mass is compared across the prior-marathon lookback, so the daily rows are read for that whole span.
      const massFrom = addMonths(a.asOf, -(cfg.windows.priorMarathonLookbackMonths + 1));
      const startMs = Date.parse(massFrom + 'T00:00:00Z');
      const { byDay, mans } = await dailyMaps(c, dir, deps, cats, startMs - DAY_MS, Date.parse(a.asOf + 'T00:00:00Z') + 2 * DAY_MS, massFrom, a.asOf);
      coverage.push(...mans.filter(([t]) => t === DAILY_TYPE));
      const days = [...byDay.entries()].filter(([d, m]) => d >= from && typeof m.bodyFatPct === 'number').sort((x, y) => y[0].localeCompare(x[0]));
      if (days.length) bodyFatPct = days[0]![1].bodyFatPct as number;
      bodyMassKg = [...byDay.entries()].filter(([, m]) => typeof m.bodyMassKg === 'number' && (m.bodyMassKg as number) > 20).map(([date, m]) => ({ date, kg: m.bodyMassKg as number })).sort((x, y) => x.date.localeCompare(y.date));
    }

    // ---- Prior marathon and shortlist -------------------------------------------------------------------------------
    const priorDisabled = a.priorMarathonId === 'none';
    const priorRun = detectPriorMarathon(runs, { asOf: a.asOf, raceDate: a.race.date, lookbackStart: addMonths(a.asOf, -cfg.windows.priorMarathonLookbackMonths), override: a.priorMarathonId, cfg });
    if (a.priorMarathonId && !priorDisabled && !priorRun) gaps.push(`prior_marathon_workout_id ${a.priorMarathonId} is not among the running workouts in the last ${cfg.windows.priorMarathonLookbackMonths} months.`);
    const shortlist = selectForRawAnalysis({ runs, asOf: a.asOf, maxHr: maxHr.value, taggedIds: a.raceWorkoutIds, prior: priorRun, cfg });
    const docs = new Map((await Promise.all(shortlist.map(async (s) => [s.id, await deps.meta.getWorkoutData(deps.uid, s.id)] as const))));

    // ---- Raw analysis within the time budget -------------------------------------------------------------------------
    const raw = new Map<string, RunRaw>();
    const skipped: { id: string; reason: string }[] = [];
    for (const s of shortlist) {
      const row = rowsById.get(s.id)!;
      const doc = docs.get(s.id) ?? null;
      if (!doc) {
        skipped.push({ id: s.id, reason: 'no raw data synced yet' });
        continue;
      }
      if (clock() - t0 > cfg.budget.softTimeMs) {
        skipped.push({ id: s.id, reason: 'time budget reached' });
        continue;
      }
      const isPrior = priorRun?.id === s.id;
      const targets = [cfg.stdDistancesM.fiveK, cfg.stdDistancesM.tenK, cfg.stdDistancesM.half, ...(isPrior ? [cfg.marathonM] : [])];
      const res = await analyseRun(deps, c, dir, row, doc, loaded.man, budget, { cfg, maxHr: maxHr.value, distanceSource: a.distanceSource, targetsM: targets, indoor: runs.find((r) => r.id === s.id)?.indoor ?? false, tempC: runs.find((r) => r.id === s.id)?.tempC ?? null });
      if (res.ok) raw.set(s.id, res.raw);
      else skipped.push({ id: s.id, reason: res.reason });
    }

    let prior: PriorMarathon | null = null;
    if (priorRun) {
      const r = raw.get(priorRun.id) ?? null;
      const full = r?.efforts.find((e) => e.distanceM === cfg.marathonM);
      const dist = r?.distanceM ?? priorRun.distanceM ?? cfg.marathonM;
      const sec = full?.movingSec ?? (r?.movingSec ?? priorRun.movingSec ?? 0) * (Math.abs(dist - cfg.marathonM) / cfg.marathonM <= 0.03 ? cfg.marathonM / dist : 1);
      if (sec > 0) prior = { run: priorRun, raw: r, seconds: sec };
      else gaps.push('The prior marathon has no usable duration.');
    }

    // ---- Nutrition (carbohydrates logged during long runs) -------------------------------------------------------------
    const nutrition = { enabled: cats.has('nutrition') && a.allowNutrition, carbRunIds: [] as string[] };
    if (nutrition.enabled) {
      const blockStart = windowStart(a.asOf, cfg.windows.blockWeeks);
      const longRuns = runs.filter((r) => inWindow(r, blockStart, a.asOf) && (r.movingSec ?? 0) >= cfg.confidence.fueling.minRunMinutes * 60);
      if (longRuns.length) {
        const from = Math.min(...longRuns.map((r) => r.startMs));
        const to = Math.max(...longRuns.map((r) => r.endMs));
        const man = await loadType(c, dir, deps, '_events_nutrition', [from - DAY_MS, to + DAY_MS], 'ev', { what: 'raw', budget });
        coverage.push(['_events_nutrition', man]);
        const ev = (await rows(c, `SELECT s FROM ev WHERE agg = 'DietaryCarbohydrates' AND s >= ${from} AND s <= ${to}`)).map((x) => Number(x.s));
        nutrition.carbRunIds = longRuns.filter((r) => ev.some((s) => s >= r.startMs && s <= r.endMs)).map((r) => r.id);
      }
    }

    if (daysBetween(a.asOf, a.race.date) < 0) gaps.push('The race date is before as_of_date.');
    const inputs: ReadinessInputs = {
      asOf: a.asOf, tz: a.tz, race: a.race, goalSeconds: a.goalSeconds, maxHr, sex, bodyFatPct, bodyMassKg, runs, raw, rawSkipped: skipped,
      taggedRaceIds: a.raceWorkoutIds, priorMarathon: prior, priorDisabled, nutrition, context: a.context, gaps, notes,
    };
    return { inputs, coverage, complete };
  });
}
