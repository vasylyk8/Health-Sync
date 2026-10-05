import type { DuckDBConnection } from '@duckdb/node-api';
import { CATEGORIES, COVERAGE, DAILY_KEY_CATEGORY, DEFAULT_CATEGORIES, EVENT_TYPES, HOURLY_METRICS } from '../config.js';
import { DAILY_TYPE, WORKOUT_TYPE } from '../ingest/batch.js';
import type { TypeManifest } from '../store/types.js';
import { round } from './calc.js';
import { envelope, range, rows, type ToolResult } from './common.js';
import { isComplete, loadType, localRangeToUtc, localTs, ToolError, validTz, type QueryDeps } from './context.js';
import { lit, withDuck } from './duck.js';
import { findWorkout, parseExtra } from './lookup.js';
import { readinessHint } from './race.js';

const DAY_MS = 86_400_000;

// ---------------------------------------------------------------------------------------------
// Shared helpers

/** Health metrics carry float noise (26388.047698444407 steps); keep them readable and cheap in tokens. */
export function tidyMetric(v: unknown): unknown {
  if (typeof v !== 'number' || !Number.isFinite(v)) return v;
  const a = Math.abs(v);
  return round(v, a >= 1000 ? 0 : a >= 10 ? 1 : 2);
}
export const tidyMetrics = (m: Record<string, unknown>): Record<string, unknown> => Object.fromEntries(Object.entries(m).map(([k, v]) => [k, tidyMetric(v)]));

/** The consent categories the user has switched on. */
export async function enabledCategories(deps: QueryDeps): Promise<Set<string>> {
  const user = await deps.meta.getUser(deps.uid);
  return new Set(user?.categories ?? DEFAULT_CATEGORIES);
}

export function requireCategory(cats: Set<string>, category: string, what: string): void {
  if (cats.has(category)) return;
  const label = CATEGORIES.find((c) => c.id === category)?.label ?? category;
  throw new ToolError('category_disabled', `${what} is switched off. Ask the user to turn on "${label}" in the KROK app (Settings > Health data) and let it sync.`);
}

const dayBefore = (day: string) => new Date(Date.parse(day + 'T00:00:00Z') - DAY_MS).toISOString().slice(0, 10);
const mean = (xs: number[]) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const sd = (xs: number[]) => {
  if (xs.length < 2) return null;
  const m = mean(xs)!;
  return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / (xs.length - 1));
};

/** Local wall-clock `YYYY-MM-DD HH:MM` of an epoch ms in `tz`. */
const fmtLocal = (c: string) => `strftime(${c}, '%Y-%m-%d %H:%M')`;

// ---------------------------------------------------------------------------------------------
// Daily context

/** Daily metric groups for the `groups` filter. */
const GROUPS: Record<string, (k: string) => boolean> = {
  sleep: (k) => k.startsWith('sleep'),
  heart: (k) => /^(restingHr|hr[A-Z]|hrv|walkingHrAvg|vo2max|spo2|respiratory|perfusion)/.test(k),
  activity: (k) => /^(steps|flights|activeKcal|basalKcal|exerciseMin|standMin|moveMin|daylightMin|physicalEffort|ring|nikeFuel|swimStrokes|pushCount|uvExposure|mindful)/.test(k) || /DistanceM$/.test(k),
  mobility: (k) => /^(walking|stair|sixMinute|timesFallen)/.test(k) && k !== 'walkingHrAvg',
  body: (k) => /^(bodyMass|bodyFat|leanMass|bmi|height|waist|bodyTemp)/.test(k),
  nutrition: (k) => DAILY_KEY_CATEGORY.get(k) === 'nutrition',
  cycle: (k) => DAILY_KEY_CATEGORY.get(k) === 'cycle',
  audio: (k) => /^(envAudio|headphoneAudio|soundReduction)/.test(k),
};
export const DAILY_GROUPS = Object.keys(GROUPS);

/** Daily types the user has switched on: the core one plus one per enabled category. */
const dailyTypes = (cats: Set<string>) => COVERAGE.types.filter((t) => t.kind === 'daily' && cats.has(t.category ?? 'core')).map((t) => t.id);

/** Loads every enabled daily type for [startMs, endMs) and merges the metrics of each day. */
export async function dailyMaps(c: DuckDBConnection, dir: string, deps: QueryDeps, cats: Set<string>, startMs: number, endMs: number, from: string, to: string) {
  const byDay = new Map<string, Record<string, unknown>>();
  const mans: [string, TypeManifest | null][] = [];
  let i = 0;
  for (const type of dailyTypes(cats)) {
    const alias = `d${i++}`;
    // Every upload of a day is kept and merged metric by metric (the later upload wins per metric), so a later partial
    // upload of the same day (a pass where some HealthKit queries failed) cannot erase metrics an earlier one had.
    const man = await loadType(c, dir, deps, type, [startMs, endMs], alias, { what: 'raw', budget: { bytes: 0 }, keepVersions: true });
    mans.push([type, man]);
    for (const r of await rows(c, `SELECT id, extra FROM ${alias} WHERE k = 'day' AND id >= ${lit(from)} AND id <= ${lit(to)} ORDER BY seq ASC, batch ASC`)) {
      const day = String(r.id);
      byDay.set(day, { ...(byDay.get(day) ?? {}), ...((parseExtra(r.extra).m as Record<string, unknown>) ?? {}) });
    }
  }
  return { byDay, mans };
}

export interface DailyArgs { start_date: string; end_date: string; metrics?: string[]; groups?: string[]; rollup?: 'week' | 'month' }

export async function getDailyContext(deps: QueryDeps, args: DailyArgs): Promise<ToolResult> {
  const r = range(deps, { ...args, timezone: 'UTC' });
  const days = (Date.parse(r.end + 'T00:00:00Z') - Date.parse(r.start + 'T00:00:00Z')) / DAY_MS + 1;
  const maxDays = args.rollup ? 3_700 : 400;
  if (days > maxDays) throw new ToolError('too_large', args.rollup ? 'At most 3,700 days per call.' : 'At most 400 days per call (use rollup "week" or "month" for longer ranges).');
  const wanted = new Set(args.metrics ?? []);
  const groups = (args.groups ?? []).map((g) => {
    const f = GROUPS[g];
    if (!f) throw new ToolError('bad_request', `Unknown group "${g}". Groups: ${DAILY_GROUPS.join(', ')}.`);
    return f;
  });
  const keep = (k: string) => (!wanted.size && !groups.length) || wanted.has(k) || groups.some((f) => f(k));
  const cats = await enabledCategories(deps);
  return withDuck(async (c, dir) => {
    const s = Date.parse(r.start + 'T00:00:00Z');
    const e = Date.parse(r.end + 'T00:00:00Z') + DAY_MS;
    const { byDay, mans } = await dailyMaps(c, dir, deps, cats, s, e, r.start, r.end);
    const core = mans.find(([t]) => t === DAILY_TYPE)?.[1] ?? null;
    const sorted = [...byDay.entries()].sort(([a], [b]) => (a < b ? -1 : 1));
    const notes = [
      'Each day is a local calendar day on the user\'s phone. Sleep is dated by the morning it ends. A missing metric means it was not recorded that day, not zero.',
      `Metric groups you can ask for: ${DAILY_GROUPS.join(', ')}. Categories the user has not switched on are not available.`,
    ];
    const complete = isComplete(core, s, e, deps.now(), true);
    if (!args.rollup) {
      return {
        ...envelope(deps, mans, complete, notes),
        count: sorted.length,
        days: sorted.map(([date, m]) => ({ date, ...tidyMetrics(Object.fromEntries(Object.entries(m).filter(([k]) => keep(k)))) })),
      };
    }
    // Weekly (Monday-start) or monthly averages of every numeric metric.
    const bucket = (date: string) => {
      if (args.rollup === 'month') return date.slice(0, 7);
      const d = new Date(date + 'T00:00:00Z');
      return new Date(d.getTime() - ((d.getUTCDay() + 6) % 7) * DAY_MS).toISOString().slice(0, 10);
    };
    const periods = new Map<string, { days: number; sums: Map<string, { sum: number; n: number }> }>();
    for (const [date, m] of sorted) {
      const key = bucket(date);
      const p = periods.get(key) ?? { days: 0, sums: new Map() };
      p.days++;
      for (const [k, v] of Object.entries(m)) {
        if (typeof v !== 'number' || !keep(k)) continue;
        const cur = p.sums.get(k) ?? { sum: 0, n: 0 };
        cur.sum += v;
        cur.n++;
        p.sums.set(k, cur);
      }
      periods.set(key, p);
    }
    notes.push(`Each ${args.rollup} shows the average of the days that have the metric (text metrics such as bedtime are left out).`);
    return {
      ...envelope(deps, mans, complete, notes),
      rollup: args.rollup,
      count: periods.size,
      periods: [...periods.entries()].map(([period, p]) => ({
        period, days_with_data: p.days, ...Object.fromEntries([...p.sums.entries()].map(([k, x]) => [k, tidyMetric(x.sum / x.n)])),
      })),
    };
  });
}

// ---------------------------------------------------------------------------------------------
// Hourly series

export interface HourlyArgs { series: string; start_date: string; end_date: string; timezone?: string; resolution?: 'hour' | 'day' }

export async function getHourlySeries(deps: QueryDeps, args: HourlyArgs): Promise<ToolResult> {
  const def = [...HOURLY_METRICS.values()].find((h) => h.name.toLowerCase() === args.series.toLowerCase().replace(/[\s_-]+/g, ''));
  if (!def) throw new ToolError('bad_request', `Unknown series "${args.series}". Available: ${[...HOURLY_METRICS.keys()].join(', ')}.`);
  const r = range(deps, args);
  const days = (Date.parse(r.end + 'T00:00:00Z') - Date.parse(r.start + 'T00:00:00Z')) / DAY_MS + 1;
  const res = args.resolution ?? (days <= 14 ? 'hour' : 'day');
  if (res === 'hour' && days > 62) throw new ToolError('too_large', 'Hourly values: at most 62 days per call. Use resolution "day" for longer ranges.');
  if (res === 'day' && days > 400) throw new ToolError('too_large', 'Daily values: at most 400 days per call.');
  return withDuck(async (c, dir) => {
    const [a, b] = await localRangeToUtc(c, r.tz, r.start, r.end);
    const man = await loadType(c, dir, deps, '_hourly', [a, b], 'h', { what: 'raw', budget: { bytes: 0 } });
    const hasRange = def.cols.length > 1;
    const where = `agg = ${lit(def.name)} AND s >= ${a} AND s < ${b}`;
    const local = localTs('s', r.tz);
    const base = {
      ...envelope(deps, [['_hourly', man]], isComplete(man, a, b, deps.now(), true), [
        'One value per local hour that had readings (hours without readings are missing). Heart rate outside workouts is recorded roughly every 5 minutes, so an hour averages several readings.',
      ]),
      series: def.name, unit: def.unit, timezone: r.tz, resolution: res,
    };
    if (res === 'hour') {
      const out = await rows(c, `SELECT ${fmtLocal(local)} AS t, v, v2, v3 FROM h WHERE ${where} ORDER BY s`);
      return { ...base, columns: hasRange ? ['local_hour', 'avg', 'min', 'max'] : def.cols[0] === 'sum' ? ['local_hour', 'sum'] : ['local_hour', 'avg'], count: out.length, hours: out.map((x) => (hasRange ? [x.t, tidyMetric(x.v), tidyMetric(x.v2), tidyMetric(x.v3)] : [x.t, tidyMetric(x.v)])) };
    }
    const sum = def.cols[0] === 'sum';
    const out = await rows(c, `SELECT strftime(${local}, '%Y-%m-%d') AS d, ${sum ? 'sum(v)' : 'avg(v)'} AS v, min(v2) AS lo, max(v3) AS hi, count(*) AS n FROM h WHERE ${where} GROUP BY 1 ORDER BY 1`);
    return {
      ...base, columns: hasRange ? ['date', 'avg_of_hourly_avgs', 'min', 'max', 'hours_with_data'] : ['date', sum ? 'total' : 'avg', 'hours_with_data'], count: out.length,
      days: out.map((x) => (hasRange ? [x.d, tidyMetric(x.v), tidyMetric(x.lo), tidyMetric(x.hi), x.n] : [x.d, tidyMetric(x.v), x.n])),
    };
  });
}

// ---------------------------------------------------------------------------------------------
// Nutrition log

export interface NutritionArgs { start_date?: string; end_date?: string; workout_id?: string; hours_before?: number; nutrients?: string[]; timezone?: string }

const DEFAULT_NUTRIENTS = ['DietaryEnergyConsumed', 'DietaryProtein', 'DietaryCarbohydrates', 'DietaryFatTotal', 'DietaryCaffeine', 'DietaryWater', 'NumberOfAlcoholicBeverages'];

export async function getNutritionLog(deps: QueryDeps, args: NutritionArgs): Promise<ToolResult> {
  const cats = await enabledCategories(deps);
  requireCategory(cats, 'nutrition', 'Nutrition data');
  const nutrients = (args.nutrients?.length ? args.nutrients : DEFAULT_NUTRIENTS).map((n) => {
    const hit = [...EVENT_TYPES.values()].find((e) => e.category === 'nutrition' && e.name.toLowerCase().replace(/^dietary/, '') === n.toLowerCase().replace(/^dietary/, '').replace(/[\s_-]+/g, ''));
    if (!hit) throw new ToolError('bad_request', `Unknown nutrient "${n}".`);
    return hit.name;
  });
  return withDuck(async (c, dir) => {
    let a: number;
    let b: number;
    let tz = validTz(args.timezone ?? deps.tz);
    let anchor: number | null = null;
    if (args.workout_id) {
      const { row } = await findWorkout(c, dir, deps, args.workout_id, tz);
      anchor = row.s;
      a = row.s - Math.min(Math.max(args.hours_before ?? 6, 0.5), 48) * 3_600_000;
      b = row.s;
    } else {
      if (!args.start_date || !args.end_date) throw new ToolError('bad_request', 'Pass workout_id, or start_date and end_date.');
      const r = range(deps, { start_date: args.start_date, end_date: args.end_date, timezone: args.timezone });
      tz = r.tz;
      [a, b] = await localRangeToUtc(c, r.tz, r.start, r.end);
    }
    const man = await loadType(c, dir, deps, '_events_nutrition', [a, b], 'ev', { what: 'raw', budget: { bytes: 0 } });
    const out = await rows(c, `SELECT s, ${fmtLocal(localTs('s', tz))} AS t, agg, v, u, src FROM ev WHERE agg IN (${nutrients.map(lit).join(',')}) AND s >= ${a} AND s < ${b} ORDER BY s`);
    // Entries logged at the same minute by the same app form one meal/entry.
    const entries = new Map<string, Record<string, unknown>>();
    for (const x of out) {
      const key = `${Math.floor(Number(x.s) / 60_000)}|${x.src ?? ''}`;
      const e = entries.get(key) ?? { time: x.t, source: x.src ?? null, ...(anchor !== null ? { minutes_before_workout: round((anchor - Number(x.s)) / 60_000, 0) } : {}) };
      e[`${String(x.agg).replace(/^Dietary/, '')}${x.u ? ` (${x.u})` : ''}`] = tidyMetric(x.v);
      entries.set(key, e);
    }
    const list = [...entries.values()].slice(0, 300);
    return {
      ...envelope(deps, [['_events_nutrition', man]], !!man, [
        'Entries are what the user logged in a nutrition app; many people log only some meals, so totals can be incomplete. Daily totals are in get_daily_context (group nutrition).',
      ]),
      timezone: tz, count: list.length, entries: list,
    };
  });
}

// ---------------------------------------------------------------------------------------------
// Profile

/** Opt-in profile (throws category_disabled when switched off): date of birth, sex, and age / rough max HR derived from it. */
export async function loadProfile(deps: QueryDeps, asOfMs: number = deps.now()) {
  const cats = await enabledCategories(deps);
  requireCategory(cats, 'profile', 'Profile data');
  return withDuck(async (c, dir) => {
    const man = await loadType(c, dir, deps, '_events_profile', 'all', 'ev', { what: 'raw', budget: { bytes: 0 } });
    const out = await rows(c, `SELECT extra, s FROM ev WHERE agg = 'Profile' ORDER BY s DESC LIMIT 1`);
    const p = out.length ? parseExtra(out[0]!.extra) : {};
    let age: number | null = null;
    if (typeof p.dob === 'string') {
      const d = new Date(p.dob + 'T00:00:00Z');
      const now = new Date(asOfMs);
      age = now.getUTCFullYear() - d.getUTCFullYear() - (now.getUTCMonth() < d.getUTCMonth() || (now.getUTCMonth() === d.getUTCMonth() && now.getUTCDate() < d.getUTCDate()) ? 1 : 0);
    }
    return { man, profile: { ...p, ...(age !== null ? { age_years: age, estimated_max_hr: round(208 - 0.7 * age, 0) } : {}) } as Record<string, unknown> & { age_years?: number; estimated_max_hr?: number } };
  });
}

export async function getProfile(deps: QueryDeps): Promise<ToolResult> {
  const { man, profile } = await loadProfile(deps);
  return {
    ...envelope(deps, [['_events_profile', man]], !!man, ['Estimated max heart rate is only a rough starting point; ask the user for their measured maximum or zone boundaries when they have them.']),
    profile,
  };
}

// ---------------------------------------------------------------------------------------------
// Recovery baseline

const RECOVERY_METRICS = ['hrv', 'hrvRmssd', 'restingHr', 'respiratoryRate', 'sleepAsleepMin', 'sleepDeepMin', 'sleepRemMin', 'spo2Avg', 'sleepingWristTempC', 'walkingHrAvg'];

interface Night { date: string; sleepHrAvg: number | null; sleepHrMin: number | null; hrvOvernight: number | null }

export interface RecoveryArgs { date?: string; window_days?: number; timezone?: string }

export async function getRecovery(deps: QueryDeps, args: RecoveryArgs): Promise<ToolResult> {
  const tz = validTz(args.timezone ?? deps.tz);
  const windowDays = Math.min(Math.max(args.window_days ?? 60, 14), 180);
  const cats = await enabledCategories(deps);
  return withDuck(async (c, dir) => {
    const lastDay = args.date ?? new Date(deps.now()).toISOString().slice(0, 10);
    const from = new Date(Date.parse(lastDay + 'T00:00:00Z') - windowDays * DAY_MS).toISOString().slice(0, 10);
    const s = Date.parse(from + 'T00:00:00Z');
    const e = Date.parse(lastDay + 'T00:00:00Z') + DAY_MS;
    const { byDay, mans } = await dailyMaps(c, dir, deps, cats, s, e, from, lastDay);
    // The target is the given date, or the latest day that has data.
    const target = args.date ?? [...byDay.keys()].sort().at(-1) ?? lastDay;
    const row = byDay.get(target);
    if (!row) throw new ToolError('no_data', `No daily data for ${target}. The phone may not have synced yet.`);
    // Overnight heart rate and HRV from the hourly series, between bedtime and wake time of each night.
    const nights: Night[] = [];
    const hourlyMan = await loadType(c, dir, deps, '_hourly', [s - DAY_MS, e], 'hr', { what: 'raw', budget: { bytes: 0 } });
    const nightRows = [...byDay.entries()].filter(([, m]) => typeof m.sleepBedtime === 'string' && typeof m.sleepWakeTime === 'string');
    if (hourlyMan && nightRows.length) {
      const values = nightRows.map(([d, m]) => {
        const bed = String(m.sleepBedtime);
        const startDate = Number(bed.slice(0, 2)) >= 12 ? dayBefore(d) : d;
        return `(${lit(d)}, ${lit(`${startDate} ${bed}:00`)}, ${lit(`${d} ${String(m.sleepWakeTime)}:00`)})`;
      });
      const res = await rows(c, `WITH n(d, bed, wake) AS (VALUES ${values.join(',')}),
        w AS (SELECT d, epoch_ms(timezone(${lit(tz)}, bed::TIMESTAMP)) - 3540000 AS a, epoch_ms(timezone(${lit(tz)}, wake::TIMESTAMP)) AS b FROM n)
        SELECT w.d AS d,
          avg(h.v) FILTER (WHERE h.agg = 'HeartRate') AS hr_avg, min(h.v2) FILTER (WHERE h.agg = 'HeartRate') AS hr_min,
          avg(h.v) FILTER (WHERE h.agg IN ('HeartRateVariabilitySDNN')) AS hrv
        FROM w JOIN hr h ON h.s >= w.a AND h.s < w.b GROUP BY w.d`);
      for (const x of res) nights.push({ date: String(x.d), sleepHrAvg: x.hr_avg === null ? null : Number(x.hr_avg), sleepHrMin: x.hr_min === null ? null : Number(x.hr_min), hrvOvernight: x.hrv === null ? null : Number(x.hrv) });
    }
    const nightMap = new Map(nights.map((n) => [n.date, n]));
    const metricOf = (day: string, k: string): number | null => {
      if (k === 'sleepHrAvg') return nightMap.get(day)?.sleepHrAvg ?? null;
      if (k === 'sleepHrMin') return nightMap.get(day)?.sleepHrMin ?? null;
      if (k === 'hrvOvernight') return nightMap.get(day)?.hrvOvernight ?? null;
      const v = byDay.get(day)?.[k];
      return typeof v === 'number' ? v : null;
    };
    const baselineDays = [...byDay.keys()].filter((d) => d < target).sort();
    const keys = [...RECOVERY_METRICS, 'sleepHrAvg', 'sleepHrMin', 'hrvOvernight'];
    const metrics: Record<string, unknown> = {};
    for (const k of keys) {
      const v = metricOf(target, k);
      const base = baselineDays.map((d) => metricOf(d, k)).filter((x): x is number => x !== null);
      if (v === null && !base.length) continue;
      const m = mean(base);
      const sdv = sd(base);
      const z = v !== null && m !== null && sdv ? (v - m) / sdv : null;
      metrics[k] = {
        value: tidyMetric(v), baseline_mean: tidyMetric(m), baseline_sd: tidyMetric(sdv), baseline_days: base.length,
        change_pct: v !== null && m ? round(((v - m) / m) * 100, 1) : null, z_score: round(z, 2),
        status: z === null || base.length < 14 ? 'not enough baseline' : z <= -1 ? 'below baseline' : z >= 1 ? 'above baseline' : 'within baseline range',
      };
    }
    return {
      ...envelope(deps, [...mans, ['_hourly', hourlyMan]], true, [
        `Each value is compared with this user's own average and spread over the previous ${windowDays} days (needs about 14+ days). The labels and z-scores describe statistical differences from a personal baseline, not clinical reference ranges, a recovery score or readiness to exercise. Differences alone do not establish their cause.`,
        'sleepHrAvg, sleepHrMin and hrvOvernight are derived from hourly values between bedtime and wake time (accurate to about an hour).',
      ]),
      date: target, window_days: windowDays, metrics,
    };
  });
}

// ---------------------------------------------------------------------------------------------
// Training load

export interface LoadArgs { end_date?: string; days?: number; max_hr?: number; resting_hr?: number; sex?: 'male' | 'female'; timezone?: string }

export async function getTrainingLoad(deps: QueryDeps, args: LoadArgs): Promise<ToolResult> {
  const tz = validTz(args.timezone ?? deps.tz);
  const n = Math.min(Math.max(args.days ?? 42, 7), 180);
  const cats = await enabledCategories(deps);
  const WARMUP = 120;
  return withDuck(async (c, dir) => {
    const end = args.end_date ?? new Date(deps.now()).toISOString().slice(0, 10);
    const first = new Date(Date.parse(end + 'T00:00:00Z') - (n + WARMUP) * DAY_MS).toISOString().slice(0, 10);
    const [a, b] = await localRangeToUtc(c, tz, first, end);
    const man = await loadType(c, dir, deps, WORKOUT_TYPE, [a - DAY_MS * 2, b], 'w', { what: 'raw', budget: { bytes: 0 } });
    const ws = await rows(c, `SELECT strftime(${localTs('s', tz)}, '%Y-%m-%d') AS d, extra FROM w WHERE k = 'w' AND s >= ${a} AND s < ${b} ORDER BY s`);
    const { byDay } = await dailyMaps(c, dir, deps, cats, a - DAY_MS, b, first, end);
    const observedRest = mean([...byDay.values()].map((m) => m.restingHr).filter((x): x is number => typeof x === 'number'));
    const rest = args.resting_hr ?? observedRest ?? 60;
    const observedMax = Math.max(0, ...ws.map((x) => Number(parseExtra(x.extra).hrMax) || 0));
    const maxHr = args.max_hr ?? (observedMax >= 120 ? observedMax : 190);
    const k = args.sex === 'female' ? 1.67 : 1.92;
    const loads = new Map<string, number>();
    const basis = { trimp: 0, effort: 0, none: 0 };
    for (const x of ws) {
      const ex = parseExtra(x.extra);
      const durMin = (Number(ex.dur) || 0) / 60;
      const hrAvg = Number(ex.hrAvg) || 0;
      const stats = (ex.stats ?? {}) as Record<string, { avg?: number }>;
      const effort = stats.WorkoutEffortScore?.avg ?? stats.EstimatedWorkoutEffortScore?.avg;
      let load = 0;
      if (durMin > 0 && hrAvg > rest && maxHr > rest) {
        const f = Math.min(1, (hrAvg - rest) / (maxHr - rest));
        load = durMin * f * 0.64 * Math.exp(k * f);
        basis.trimp++;
      } else if (durMin > 0 && typeof effort === 'number') {
        load = effort * durMin * 0.3;
        basis.effort++;
      } else basis.none++;
      loads.set(String(x.d), (loads.get(String(x.d)) ?? 0) + load);
    }
    let atl = 0;
    let ctl = 0;
    const series: { date: string; load: number; ctl: number; atl: number; tsb: number }[] = [];
    for (let t = Date.parse(first + 'T00:00:00Z'); t <= Date.parse(end + 'T00:00:00Z'); t += DAY_MS) {
      const d = new Date(t).toISOString().slice(0, 10);
      const load = loads.get(d) ?? 0;
      atl += (load - atl) / 7;
      ctl += (load - ctl) / 42;
      series.push({ date: d, load: round(load, 0), ctl: round(ctl, 1), atl: round(atl, 1), tsb: round(ctl - atl, 1) });
    }
    const shown = series.slice(-n);
    const last = shown.at(-1)!;
    const weekAgo = series.at(-8);
    const hint = await readinessHint(deps);
    return {
      ...envelope(deps, [[WORKOUT_TYPE, man]], isComplete(man, a, b, deps.now()), [
        'Load per workout is a heart-rate based training impulse (TRIMP) using resting and maximum heart rate; workouts without heart rate fall back to Apple\'s effort score x duration. CTL and ATL are 42-day and 7-day smoothed load estimates; TSB = CTL - ATL. They are not measurements of actual fitness, fatigue, injury risk or readiness to exercise. No training or treatment recommendation is supplied.',
        'Apple\'s own Training Load number is not readable by apps, so this is an independent estimate.',
        'Days without recorded workouts and workouts without usable heart rate or effort are assigned zero load in this model; this does not prove inactivity. Observed workout maximum heart rate is not necessarily physiological maximum heart rate. Without supplied or observed parameters, defaults are 190 bpm maximum and 60 bpm resting heart rate. The default TRIMP coefficient is 1.92; the explicit female formula uses 1.67. Sex is not inferred.',
        ...(hint ? [hint] : []),
      ]),
      inputs: { resting_hr: round(rest, 0), resting_hr_source: args.resting_hr !== undefined ? 'given' : observedRest !== null ? 'mean recorded resting heart rate' : 'default 60 (ask the user)', trimp_coefficient: k, trimp_coefficient_source: args.sex ? 'sex-specific formula selected by user' : 'default formula coefficient (sex not inferred)', max_hr: round(maxHr, 0), max_hr_source: args.max_hr ? 'given' : observedMax >= 120 ? 'highest workout max heart rate seen' : 'default 190 (ask the user)', workouts_by_basis: basis },
      current: { ...last, ramp_rate_ctl_per_week: weekAgo ? round(last.ctl - weekAgo.ctl, 1) : null },
      weekly_load: weeklyTotals(series.slice(-56)),
      series_columns: ['date', 'load', 'ctl', 'atl', 'tsb'],
      series: shown.filter((x) => n <= 60 || x.date.slice(-2) === '01' || shown.indexOf(x) % 3 === 0).map((x) => [x.date, x.load, x.ctl, x.atl, x.tsb]),
    };
  });
}

function weeklyTotals(series: { date: string; load: number }[]) {
  const weeks = new Map<string, number>();
  for (const x of series) {
    const d = new Date(x.date + 'T00:00:00Z');
    const monday = new Date(d.getTime() - ((d.getUTCDay() + 6) % 7) * DAY_MS).toISOString().slice(0, 10);
    weeks.set(monday, (weeks.get(monday) ?? 0) + x.load);
  }
  return [...weeks.entries()].map(([week_start, load]) => ({ week_start, load: round(load, 0) }));
}
