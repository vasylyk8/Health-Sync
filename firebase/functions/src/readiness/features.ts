import type { SplitRow } from '../query/calc.js';
import { formatHms } from '../query/race.js';
import type { WorkoutRow } from '../query/lookup.js';
import type { ReadinessConfig } from './config.js';
import type { MaxHrInfo, RunSummary } from './types.js';

/** Pure helpers over run summaries and splits. No I/O. */

const DAY_MS = 86_400_000;

// ---------------------------------------------------------------------------------------------
// Local calendar dates (YYYY-MM-DD)

export const toMs = (date: string): number => Date.parse(date + 'T00:00:00Z');
export const addDays = (date: string, n: number): string => new Date(toMs(date) + n * DAY_MS).toISOString().slice(0, 10);
/** Whole days from a to b (b - a). */
export const daysBetween = (a: string, b: string): number => Math.round((toMs(b) - toMs(a)) / DAY_MS);
/** Monday of the local week containing the date. */
export const weekStart = (date: string): string => addDays(date, -((new Date(toMs(date)).getUTCDay() + 6) % 7));
/** First day of a window of `weeks` full weeks ending (inclusive) on `end`. */
export const windowStart = (end: string, weeks: number): string => addDays(end, -(weeks * 7 - 1));

export function addMonths(date: string, n: number): string {
  const d = new Date(toMs(date));
  const day = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + n);
  const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  d.setUTCDate(Math.min(day, last));
  return d.toISOString().slice(0, 10);
}

/** h:mm:ss of a (possibly fractional) number of seconds, rounded first so 59.6 s never prints as ":60". */
export const hms = (seconds: number): string => formatHms(Math.round(seconds));

// ---------------------------------------------------------------------------------------------
// Statistics

export const mean = (xs: number[]): number | null => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);

export function median(xs: number[]): number | null {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}

export function sd(xs: number[]): number | null {
  if (xs.length < 2) return null;
  const m = mean(xs)!;
  return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1));
}

/** Coefficient of variation (sd / mean); null for fewer than 2 values. */
export function cv(xs: number[]): number | null {
  const s = sd(xs);
  const m = mean(xs);
  return s === null || !m ? null : s / m;
}

/** Standard normal cumulative distribution (Abramowitz & Stegun 7.1.26, |error| < 1.5e-7). */
export function normalCdf(x: number): number {
  const t = 1 / (1 + 0.3275911 * Math.abs(x) / Math.SQRT2);
  const poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
  const erf = 1 - poly * Math.exp(-(x * x) / 2);
  return 0.5 * (1 + (x >= 0 ? erf : -erf));
}

// ---------------------------------------------------------------------------------------------
// Run summaries

const num = (x: unknown): number | null => (typeof x === 'number' && Number.isFinite(x) ? x : null);
const pos = (x: unknown): number | null => {
  const v = num(x);
  return v !== null && v > 0 ? v : null;
};

/** Apple writes workout weather as "24 degC" / "75 degF". */
export function tempCelsius(md: unknown): number | null {
  const t = md && typeof md === 'object' ? (md as Record<string, unknown>).HKWeatherTemperature : null;
  const m = typeof t === 'string' ? /^\s*(-?[\d.]+)\s*(degC|degF)/.exec(t) : null;
  if (!m) return null;
  const v = Number(m[1]);
  if (!Number.isFinite(v)) return null;
  return m[2] === 'degF' ? (v - 32) / 1.8 : v;
}

export function runSummary(w: WorkoutRow): RunSummary {
  const x = w.extra;
  const md = x.md && typeof x.md === 'object' ? (x.md as Record<string, unknown>) : null;
  return {
    id: w.id,
    startMs: w.s,
    endMs: w.e,
    date: w.startLocal.slice(0, 10),
    distanceM: pos(x.dist),
    movingSec: pos(x.dur),
    avgHr: pos(x.hrAvg),
    maxHr: pos(x.hrMax),
    source: w.src,
    indoor: md?.HKIndoorWorkout === true,
    tempC: tempCelsius(md),
  };
}

export const runKm = (r: RunSummary): number => (r.distanceM ?? 0) / 1000;

/**
 * Groups of workouts that are the same run recorded twice (a watch and a phone app): each overlaps the previous one by
 * more than `fraction` of the shorter workout. Returns groups of two or more ids.
 */
export function findDuplicateGroups(runs: RunSummary[], fraction: number): RunSummary[][] {
  const sorted = [...runs].sort((a, b) => a.startMs - b.startMs);
  const groups: RunSummary[][] = [];
  let cur: RunSummary[] = [];
  let curEnd = -Infinity;
  for (const r of sorted) {
    const overlaps = cur.some((o) => Math.min(o.endMs, r.endMs) - Math.max(o.startMs, r.startMs) > fraction * Math.min(o.endMs - o.startMs, r.endMs - r.startMs));
    if (cur.length && r.startMs < curEnd && overlaps) {
      cur.push(r);
      curEnd = Math.max(curEnd, r.endMs);
    } else {
      if (cur.length > 1) groups.push(cur);
      cur = [r];
      curEnd = r.endMs;
    }
  }
  if (cur.length > 1) groups.push(cur);
  return groups;
}

export const inWindow = (r: RunSummary, start: string, end: string): boolean => r.date >= start && r.date <= end;

/** Mean weekly km over `weeks` full weeks ending on `end`. */
export function avgWeeklyKm(runs: RunSummary[], end: string, weeks: number): number {
  const start = windowStart(end, weeks);
  return runs.filter((r) => inWindow(r, start, end)).reduce((n, r) => n + runKm(r), 0) / weeks;
}

export const countRunsAtLeast = (runs: RunSummary[], km: number, start: string, end: string): number => runs.filter((r) => inWindow(r, start, end) && runKm(r) >= km).length;

/** Distinct local weeks (Monday-based) with at least one run in [start, end]. */
export function weeksWithRuns(runs: RunSummary[], start: string, end: string): number {
  return new Set(runs.filter((r) => inWindow(r, start, end)).map((r) => weekStart(r.date))).size;
}

/** Longest stretch in days between consecutive run dates (and to the window edges) in [start, end]. */
export function longestGapDays(runs: RunSummary[], start: string, end: string): number {
  const days = [...new Set(runs.filter((r) => inWindow(r, start, end)).map((r) => r.date))].sort();
  if (!days.length) return daysBetween(start, end);
  let gap = Math.max(daysBetween(start, days[0]!), daysBetween(days[days.length - 1]!, end));
  for (let i = 1; i < days.length; i++) gap = Math.max(gap, daysBetween(days[i - 1]!, days[i]!));
  return gap;
}

// ---------------------------------------------------------------------------------------------
// Max HR and prior marathon

/**
 * User value, else the highest observed workout maximum in the last 12 months that at least one other workout
 * confirms within a few bpm (one optical-sensor spike is not a maximum), else an age-based default, else a flat default.
 */
export function resolveMaxHr(args: { user?: number; runs: RunSummary[]; asOf: string; ageYears: number | null; cfg: ReadinessConfig }): MaxHrInfo {
  const { cfg } = args;
  if (args.user !== undefined) return { value: args.user, source: 'user' };
  const since = addDays(args.asOf, -364);
  const maxes = args.runs.filter((r) => inWindow(r, since, args.asOf) && r.maxHr !== null && r.maxHr >= cfg.maxHr.plausible[0] && r.maxHr <= cfg.maxHr.plausible[1]).map((r) => r.maxHr!).sort((a, b) => b - a);
  for (let i = 0; i < maxes.length; i++) {
    const confirmed = maxes.filter((m, j) => j !== i && Math.abs(m - maxes[i]!) <= cfg.maxHr.agreeBpm).length + 1;
    if (confirmed >= cfg.maxHr.agreeMinWorkouts) return { value: maxes[i]!, source: 'observed', note: `highest workout maximum confirmed by ${confirmed} workouts within ${cfg.maxHr.agreeBpm} bpm` };
  }
  if (args.ageYears !== null) return { value: Math.round(208 - 0.7 * args.ageYears), source: 'default', note: `208 - 0.7 x age (${args.ageYears}); a population formula, ask the user for the measured maximum` };
  return { value: cfg.maxHr.fallbackBpm, source: 'default', note: `${cfg.maxHr.fallbackBpm} bpm default; ask the user for the measured maximum` };
}

/** Most recent marathon-length run before as_of (and before the race) within the lookback, or the explicitly given one. */
export function detectPriorMarathon(runs: RunSummary[], args: { asOf: string; raceDate: string; lookbackStart: string; override?: string | null; cfg: ReadinessConfig }): RunSummary | null {
  if (args.override === 'none') return null;
  if (args.override) return runs.find((r) => r.id === args.override) ?? null;
  const [lo, hi] = args.cfg.detect.marathonKm;
  const hits = runs.filter((r) => runKm(r) >= lo && runKm(r) <= hi && r.date >= args.lookbackStart && r.date < args.asOf && r.date < args.raceDate);
  return hits.sort((a, b) => b.startMs - a.startMs)[0] ?? null;
}

// ---------------------------------------------------------------------------------------------
// Splits

export interface CleanedSplits {
  splits: SplitRow[];
  dropped: number;
}

/** Drops splits whose pace is more than `factor` x slower or faster than the run's median (GPS dropouts and jumps). */
export function cleanSplits(all: SplitRow[], factor: number): CleanedSplits {
  const full = all.filter((s) => !s.partial && s.pace_seconds_per_unit > 0);
  const med = median(full.map((s) => s.pace_seconds_per_unit));
  if (med === null) return { splits: all, dropped: 0 };
  const keep = all.filter((s) => s.partial || (s.pace_seconds_per_unit <= med * factor && s.pace_seconds_per_unit >= med / factor));
  return { splits: keep, dropped: all.length - keep.length };
}

export const fullSplits = (splits: SplitRow[]): SplitRow[] => splits.filter((s) => !s.partial);
