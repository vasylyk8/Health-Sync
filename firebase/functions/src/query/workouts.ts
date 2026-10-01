import type { DuckDBConnection } from '@duckdb/node-api';
import { join } from 'node:path';
import { LIMITS } from '../config.js';
import { DAILY_TYPE, WORKOUT_TYPE } from '../ingest/batch.js';
import type { StreamInfo, TypeManifest, WorkoutDataDoc } from '../store/types.js';
import {
  bestEfforts, distanceFromIncrements, elevationProfile, EVENT_NAMES, heartRateDrift, heartRateZones, movingMs, pausesFromEvents,
  round, routeDistance, splits, thin, trimRouteIndexes, weightReadings, zoneBounds, type DistSeries, type Pause, type RoutePoints, type WorkoutEvent,
} from './calc.js';
import { envelope, range, rows, type ToolResult } from './common.js';
import { isComplete, loadType, localRangeToUtc, localTs, roughUtcRange, ToolError, validTz, type QueryDeps } from './context.js';
import { lit, withDuck } from './duck.js';

const MAX_LIST = 300;
const DEFAULT_POINTS = 300;
const MAX_POINTS = 1000;
/** Metres hidden at each end of a route unless the user explicitly asks for it. */
export const ROUTE_TRIM_M = 300;

const ID_RE = /^[0-9A-Za-z-]{8,64}$/;

/** Apple's cumulative distance types, in the order we prefer them as the distance source. */
const DISTANCE_STREAMS = [
  'DistanceWalkingRunning', 'DistanceCycling', 'DistanceSwimming', 'DistanceRowing', 'DistancePaddleSports',
  'DistanceSkatingSports', 'DistanceCrossCountrySkiing', 'DistanceDownhillSnowSports', 'DistanceWheelchair',
];

const STREAM_ALIASES: Record<string, string> = { hr: 'HeartRate', heartrate: 'HeartRate', pulse: 'HeartRate', gps: 'route', route: 'route', location: 'route', energy: 'ActiveEnergyBurned', calories: 'ActiveEnergyBurned' };

// ---------------------------------------------------------------------------------------------
// Loading

interface WorkoutRow {
  id: string;
  s: number;
  e: number;
  startLocal: string;
  endLocal: string;
  src: string | null;
  bid: string | null;
  dev: string | null;
  extra: Record<string, unknown>;
}

const parseExtra = (raw: unknown): Record<string, unknown> => {
  if (typeof raw !== 'string') return {};
  try {
    const v = JSON.parse(raw) as unknown;
    return v && typeof v === 'object' ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
};

const toWorkoutRow = (r: Record<string, unknown>): WorkoutRow => ({
  id: String(r.id), s: Number(r.s), e: Number(r.e), startLocal: String(r.start_local), endLocal: String(r.end_local),
  src: (r.src as string) ?? null, bid: (r.bid as string) ?? null, dev: (r.dev as string) ?? null, extra: parseExtra(r.extra),
});

const SELECT_W = (tz: string) => `SELECT id, s, e, src, bid, dev, extra,
  strftime(${localTs('s', tz)}, '%Y-%m-%d %H:%M') AS start_local, strftime(${localTs('e', tz)}, '%Y-%m-%d %H:%M') AS end_local FROM w`;

/** Earliest raw-data time of a workout: stored on its index, or read from its smallest stream file (older uploads). */
async function firstRawTime(c: DuckDBConnection, dir: string, deps: QueryDeps, doc: WorkoutDataDoc | null): Promise<number | null> {
  if (!doc) return null;
  if (typeof doc.firstT === 'number') return doc.firstT;
  const files = Object.values(doc.streams).flatMap((s) => s.files).sort((a, b) => a.bytes - b.bytes);
  const f = files[0];
  if (!f) return null;
  const p = join(dir, 'first_t.parquet');
  await deps.data.download(f.path, p);
  const r = await rows(c, `SELECT min(t) AS t FROM read_parquet(${lit(p)})`);
  return r[0]?.t == null ? null : Number(r[0].t);
}

/**
 * Loads the workout's summary row (table `w`) and its raw-data index. Summaries are stored by month: with
 * the raw data's first timestamp only the 1-2 months around it are read; otherwise (no raw data, or not
 * found there) every month, as before.
 */
async function findWorkout(c: DuckDBConnection, dir: string, deps: QueryDeps, id: string, tz: string) {
  if (!ID_RE.test(id)) throw new ToolError('bad_request', 'workout_id must be an id returned by get_workouts.');
  const doc = await deps.meta.getWorkoutData(deps.uid, id);
  const first = await firstRawTime(c, dir, deps, doc).catch(() => null);
  const query = `${SELECT_W(tz)} WHERE id = ${lit(id)} AND k = 'w' LIMIT 1`;
  let man: TypeManifest | null = null;
  let found: Record<string, unknown>[] = [];
  if (first !== null) {
    // A workout starts before its first sample; two days covers a start just before a month boundary.
    man = await loadType(c, dir, deps, WORKOUT_TYPE, [first - 2 * 86_400_000, first + 86_400_000], 'w', { what: 'raw', budget: { bytes: 0 } });
    found = await rows(c, query);
  }
  if (!found.length) {
    man = await loadType(c, dir, deps, WORKOUT_TYPE, 'all', 'w', { what: 'raw', budget: { bytes: 0 } });
    found = await rows(c, query);
  }
  if (!found.length) throw new ToolError('not_found', 'No workout with that id. Call get_workouts to list workout ids.');
  return { man, row: toWorkoutRow(found[0]!), doc };
}

export interface LoadedStream {
  name: string;
  unit: string | null;
  t: number[];
  cols: Record<string, (number | null)[]>;
  info: StreamInfo;
}

function resolveStreamName(doc: WorkoutDataDoc, name: string): string {
  const q = name.trim();
  const lower = q.toLowerCase().replace(/[\s_-]+/g, '');
  const names = Object.keys(doc.streams);
  const hit = names.find((n) => n === q) ?? names.find((n) => n.toLowerCase() === lower) ?? (STREAM_ALIASES[lower] && names.find((n) => n === STREAM_ALIASES[lower]));
  if (!hit) {
    throw new ToolError('not_found', `This workout has no raw "${name}" data. Available streams: ${names.length ? names.join(', ') : 'none yet'}.`);
  }
  return hit;
}

async function loadStream(c: DuckDBConnection, dir: string, deps: QueryDeps, doc: WorkoutDataDoc, name: string, budget: { bytes: number }): Promise<LoadedStream> {
  const info = doc.streams[name]!;
  budget.bytes += info.files.reduce((n, f) => n + f.bytes, 0);
  if (budget.bytes > LIMITS.maxScanBytes) throw new ToolError('too_large', 'That workout stream is too large to read at once.');
  const local = await Promise.all(info.files.map(async (f, i) => {
    const p = join(dir, `${name}_${i}.parquet`);
    await deps.data.download(f.path, p);
    return p;
  }));
  const list = local.map(lit).join(',');
  // Chunks of a re-sent read can overlap: one point per timestamp.
  const res = await rows(c, `SELECT * FROM read_parquet([${list}]) QUALIFY row_number() OVER (PARTITION BY t ORDER BY t) = 1 ORDER BY t`);
  const t = res.map((r) => Number(r.t));
  const cols: Record<string, (number | null)[]> = {};
  for (const col of info.cols) cols[col] = res.map((r) => (r[col] == null ? null : Number(r[col])));
  return { name, unit: info.unit, t, cols, info };
}

function rawDoc(doc: WorkoutDataDoc | null): WorkoutDataDoc {
  if (!doc || Object.keys(doc.streams).length === 0) {
    throw new ToolError('no_data', 'No raw data has been synced for this workout yet. It may still be uploading (the summary arrives first). Ask the user to open KROK and pull down to sync, then try again.');
  }
  return doc;
}

function rawStatus(doc: WorkoutDataDoc | null): 'complete' | 'partial' | 'none' {
  if (!doc || Object.keys(doc.streams).length === 0) return 'none';
  return doc.rawComplete ? 'complete' : 'partial';
}

/** Health metrics carry float noise (26388.047698444407 steps); keep them readable and cheap in tokens. */
function tidyMetric(v: unknown): unknown {
  if (typeof v !== 'number' || !Number.isFinite(v)) return v;
  const a = Math.abs(v);
  return round(v, a >= 1000 ? 0 : a >= 10 ? 1 : 2);
}
const tidyMetrics = (m: Record<string, unknown>): Record<string, unknown> => Object.fromEntries(Object.entries(m).map(([k, v]) => [k, tidyMetric(v)]));

/** Apple stores weather humidity as a fraction x 10000 with a "%" unit ("8100 %" means 81%). */
function tidyMetadata(md: unknown): unknown {
  if (!md || typeof md !== 'object') return md ?? null;
  const out: Record<string, unknown> = { ...(md as Record<string, unknown>) };
  const h = out.HKWeatherHumidity;
  const m = typeof h === 'string' ? /^\s*([\d.]+)\s*%\s*$/.exec(h) : null;
  if (m && Number(m[1]) > 100) out.HKWeatherHumidity = `${round(Number(m[1]) / 100, 0)} %`;
  // HKSwimmingLocationType is an enum (1 pool, 2 open water); older uploads stored 0/1 as booleans.
  const loc = out.HKSwimmingLocationType;
  if (loc === true || loc === 1) out.HKSwimmingLocationType = 'pool';
  else if (loc === 2) out.HKSwimmingLocationType = 'open water';
  else if (loc === false || loc === 0) out.HKSwimmingLocationType = 'unknown';
  return out;
}

const num = (x: unknown): number | null => (typeof x === 'number' && Number.isFinite(x) ? x : null);

function eventsOf(extra: Record<string, unknown>): WorkoutEvent[] {
  const ev = extra.ev;
  if (!Array.isArray(ev)) return [];
  return ev.filter((e): e is WorkoutEvent => !!e && typeof e === 'object' && typeof (e as WorkoutEvent).t === 'number' && typeof (e as WorkoutEvent).type === 'number');
}

/** Compact Apple-computed summary shared by list and detail views. */
function summaryOf(w: WorkoutRow) {
  const x = w.extra;
  const dur = num(x.dur);
  const dist = num(x.dist);
  return {
    id: w.id,
    start: w.startLocal,
    end: w.endLocal,
    activity: typeof x.actName === 'string' ? x.actName : 'Unknown',
    duration_min: round(dur !== null ? dur / 60 : (w.e - w.s) / 60_000, 1),
    active_kcal: round(num(x.en), 1),
    distance_km: dist !== null ? round(dist / 1000, 3) : null,
    avg_hr: round(num(x.hrAvg), 1),
    max_hr: round(num(x.hrMax), 1),
    source: w.src,
  };
}

// ---------------------------------------------------------------------------------------------
// get_workouts / get_workout

export async function getWorkouts(deps: QueryDeps, args: { start_date: string; end_date: string; timezone?: string; activity?: string; limit?: number }): Promise<ToolResult> {
  const r = range(deps, args);
  const cap = Math.min(args.limit ?? MAX_LIST, MAX_LIST);
  return withDuck(async (c, dir) => {
    const [startUtc, endUtc] = await localRangeToUtc(c, r.tz, r.start, r.end);
    const man = await loadType(c, dir, deps, WORKOUT_TYPE, roughUtcRange(r.start, r.end), 'w', { what: 'raw', budget: { bytes: 0 } });
    const filters = [`s >= ${startUtc} AND s < ${endUtc}`, `k = 'w'`];
    if (args.activity) filters.push(`json_extract_string(extra, '$.actName') ILIKE ${lit('%' + args.activity.replace(/[\\%_]/g, '\\$&') + '%')} ESCAPE '\\'`);
    const out = await rows(c, `${SELECT_W(r.tz)} WHERE ${filters.join(' AND ')} ORDER BY s LIMIT ${cap + 1}`);
    const truncated = out.length > cap;
    if (truncated) out.length = cap;
    const docs = new Map((await deps.meta.listWorkoutData(deps.uid)).map((d) => [d.wid, d]));
    const list = out.map((row) => {
      const w = toWorkoutRow(row);
      return { ...summaryOf(w), raw_data: rawStatus(docs.get(w.id) ?? null) };
    });
    const notes = ['duration_min excludes pauses. distance_km and avg_hr are null when the workout recorded none.', 'raw_data: complete = all raw streams synced; partial = still uploading; none = summary only.'];
    if (truncated) {
      notes.push(`More workouts match than the ${cap} shown (oldest first). To see the rest, call again starting after ${list[list.length - 1]!.start.slice(0, 10)}, or narrow the range or activity filter.`);
    }
    return {
      ...envelope(deps, [[WORKOUT_TYPE, man]], isComplete(man, startUtc, endUtc, deps.now()), notes),
      timezone: r.tz, count: list.length, truncated, workouts: list,
    };
  });
}

export async function getWorkout(deps: QueryDeps, args: { workout_id: string; timezone?: string }): Promise<ToolResult> {
  const tz = validTz(args.timezone ?? deps.tz);
  return withDuck(async (c, dir) => {
    const { man, row, doc } = await findWorkout(c, dir, deps, args.workout_id, tz);
    const x = row.extra;
    const events = eventsOf(x);
    const pauses = pausesFromEvents(events, row.e);
    // Auto-detected segments (one per ~km, often overlapping) add noise; their count stays in events.counts.
    const listed = events.filter((e) => EVENT_NAMES[e.type] !== 'segment');
    const day = row.startLocal.slice(0, 10);
    const dailyMan = await loadType(c, dir, deps, DAILY_TYPE, [row.s - 3 * 86_400_000, row.s + 86_400_000], 'd', { what: 'raw', budget: { bytes: 0 } });
    const dailyRows = await rows(c, `SELECT id, extra FROM d WHERE k = 'day' AND id IN (${lit(day)}, ${lit(dayBefore(day))})`);
    const daily = Object.fromEntries(dailyRows.map((d) => [String(d.id), tidyMetrics((parseExtra(d.extra).m as Record<string, unknown>) ?? {})]));
    const streams = doc
      ? Object.entries(doc.streams).map(([name, s]) => ({
          name, points: s.points, unit: s.unit, columns: s.cols,
          expected_points: doc.expected?.[name] ?? null,
        }))
      : [];
    const eventCounts: Record<string, number> = {};
    for (const e of events) eventCounts[EVENT_NAMES[e.type] ?? `type_${e.type}`] = (eventCounts[EVENT_NAMES[e.type] ?? `type_${e.type}`] ?? 0) + 1;
    const complete = isComplete(man, row.s, row.e, deps.now());
    const notes = [
      'apple_summary comes from Apple Health as recorded by the source app or watch. Raw data is available through get_workout_series and get_workout_route; calculations through the workout_* tools.',
      'daily_context: "same_day" is the workout date; "previous_day" is the day before (e.g. last night\'s sleep is dated the morning it ends).',
    ];
    if (rawStatus(doc) !== 'complete') notes.push(`Raw data for this workout is ${rawStatus(doc) === 'none' ? 'not synced yet' : 'still uploading'}. Summary values are available; raw analysis may be incomplete.`);
    return {
      ...envelope(deps, [[WORKOUT_TYPE, man], [DAILY_TYPE, dailyMan]], complete, notes),
      timezone: tz,
      workout: {
        ...summaryOf(row),
        source_bundle_id: row.bid,
        device: row.dev,
        paused_seconds: round(pauses.reduce((n, p) => n + (p.e - p.s), 0) / 1000, 1),
        sub_activities: Array.isArray(x.acts) ? x.acts : null,
      },
      apple_summary: {
        statistics: x.stats ?? null,
        metadata: tidyMetadata(x.md),
        extra: Object.fromEntries(Object.entries(x).filter(([k]) => !['actName', 'dur', 'en', 'dist', 'hrAvg', 'hrMax', 'ev', 'acts', 'md', 'stats', 'act'].includes(k))),
      },
      events: {
        counts: eventCounts,
        list: listed.slice(0, 100).map((e) => ({ offset_seconds: round((e.t - row.s) / 1000, 1), type: EVENT_NAMES[e.type] ?? `type_${e.type}`, duration_seconds: round(e.dur ?? 0, 1) })),
        truncated: listed.length > 100,
        segments_omitted_from_list: events.length - listed.length,
      },
      raw_data: { status: rawStatus(doc), streams },
      daily_context: { same_day: daily[day] ?? null, previous_day: daily[dayBefore(day)] ?? null },
    };
  });
}

function dayBefore(day: string): string {
  return new Date(Date.parse(day + 'T00:00:00Z') - 86_400_000).toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------------------------------
// get_workout_series / get_workout_route

export interface SeriesArgs {
  workout_id: string;
  stream: string;
  start_offset_seconds?: number;
  end_offset_seconds?: number;
  max_points?: number;
  mode?: 'downsample' | 'raw';
  cursor?: number;
  timezone?: string;
}

function pointLimit(n: number | undefined): number {
  const v = n ?? DEFAULT_POINTS;
  if (!Number.isInteger(v) || v < 2 || v > MAX_POINTS) throw new ToolError('bad_request', `max_points must be a whole number from 2 to ${MAX_POINTS}.`);
  return v;
}

export async function getWorkoutSeries(deps: QueryDeps, args: SeriesArgs): Promise<ToolResult> {
  const limit = pointLimit(args.max_points);
  if ((args.start_offset_seconds ?? -Infinity) > (args.end_offset_seconds ?? Infinity)) {
    throw new ToolError('bad_request', 'start_offset_seconds is after end_offset_seconds.');
  }
  return withDuck(async (c, dir) => {
    const found = await findWorkout(c, dir, deps, args.workout_id, validTz(args.timezone ?? deps.tz));
    const { man, row } = found;
    const doc = rawDoc(found.doc);
    const name = resolveStreamName(doc, args.stream);
    if (name === 'route') throw new ToolError('bad_request', 'Use get_workout_route for GPS data.');
    const s = await loadStream(c, dir, deps, doc, name, { bytes: 0 });
    const from = row.s + (args.start_offset_seconds ?? -Infinity) * 1000;
    const to = row.s + (args.end_offset_seconds ?? Infinity) * 1000;
    const idx: number[] = [];
    s.t.forEach((t, i) => {
      if (t >= from && t <= to && s.cols.v?.[i] != null) idx.push(i);
    });
    const v = s.cols.v ?? [];
    const off = (i: number) => round((s.t[i]! - row.s) / 1000, 1);
    const base = {
      ...envelope(deps, [[WORKOUT_TYPE, man]], doc.rawComplete, doc.rawComplete ? [] : ['Raw data for this workout is still uploading; the series may be incomplete.']),
      workout_id: row.id, stream: name, unit: s.unit, points_in_range: idx.length, points_in_stream: s.t.length,
      columns: ['offset_seconds', 'value'],
    };
    if (args.mode === 'raw') {
      const start = args.cursor ?? 0;
      if (!Number.isInteger(start) || start < 0) throw new ToolError('bad_request', 'cursor must be 0 or the next_cursor of a previous call.');
      const page = idx.slice(start, start + limit);
      const next = start + limit < idx.length ? start + limit : null;
      return { ...base, mode: 'raw', returned: page.length, next_cursor: next, points: page.map((i) => [off(i), v[i]]) };
    }
    if (idx.length <= limit) return { ...base, mode: 'downsample', downsampled: false, returned: idx.length, points: idx.map((i) => [off(i), v[i]]) };
    // Equal-time buckets: mean, min and max of each.
    const t0 = s.t[idx[0]!]!;
    const t1 = s.t[idx[idx.length - 1]!]!;
    const width = (t1 - t0) / limit || 1;
    const buckets = new Map<number, { sum: number; n: number; min: number; max: number }>();
    for (const i of idx) {
      const b = Math.min(limit - 1, Math.floor((s.t[i]! - t0) / width));
      const val = v[i]!;
      const cur = buckets.get(b);
      if (cur) {
        cur.sum += val; cur.n++; cur.min = Math.min(cur.min, val); cur.max = Math.max(cur.max, val);
      } else buckets.set(b, { sum: val, n: 1, min: val, max: val });
    }
    return {
      ...base, mode: 'downsample', downsampled: true, bucket_seconds: round(width / 1000, 1),
      columns: ['offset_seconds_bucket_start', 'mean', 'min', 'max'],
      returned: buckets.size,
      points: [...buckets.entries()].sort((a, b) => a[0] - b[0]).map(([b, x]) => [round((t0 + b * width - row.s) / 1000, 1), round(x.sum / x.n, 2), x.min, x.max]),
      notes: [...(base.notes as string[]), 'Values are averaged per time bucket (mean/min/max shown). Use mode "raw" with next_cursor to page through every reading.'],
    };
  });
}

export interface RouteArgs {
  workout_id: string;
  max_points?: number;
  include_full_route?: boolean;
  mode?: 'downsample' | 'raw';
  cursor?: number;
  timezone?: string;
}

async function loadRoute(c: DuckDBConnection, dir: string, deps: QueryDeps, doc: WorkoutDataDoc): Promise<RoutePoints> {
  if (!doc.streams.route) throw new ToolError('not_found', `This workout has no GPS route. Available streams: ${Object.keys(doc.streams).join(', ')}.`);
  const s = await loadStream(c, dir, deps, doc, 'route', { bytes: 0 });
  return { t: s.t, lat: s.cols.lat ?? [], lon: s.cols.lon ?? [], alt: s.cols.alt, spd: s.cols.spd };
}

export async function getWorkoutRoute(deps: QueryDeps, args: RouteArgs): Promise<ToolResult> {
  const limit = pointLimit(args.max_points);
  return withDuck(async (c, dir) => {
    const found = await findWorkout(c, dir, deps, args.workout_id, validTz(args.timezone ?? deps.tz));
    const { man, row } = found;
    const doc = rawDoc(found.doc);
    const route = await loadRoute(c, dir, deps, doc);
    const all = routeDistance(route);
    const total = all.d[all.d.length - 1] ?? 0;
    const notes: string[] = [];
    if (!doc.rawComplete) notes.push('Raw data for this workout is still uploading; the route may be incomplete.');
    let keep = all.idx;
    if (!args.include_full_route) {
      const trimmed = trimRouteIndexes(route, ROUTE_TRIM_M);
      if (!trimmed) {
        throw new ToolError('bad_request', `This route is shorter than ${ROUTE_TRIM_M * 2} m, so it cannot be shown without revealing where it starts and ends. Pass include_full_route=true only if the user explicitly asks for exact locations.`);
      }
      keep = trimmed.keep;
      notes.push(`Privacy: the first and last ${ROUTE_TRIM_M} m of the route are hidden so home and work locations are not exposed. Pass include_full_route=true only if the user explicitly asks for exact start and end points.`);
    }
    const lat = route.lat;
    const lon = route.lon;
    const point = (i: number) => [round((route.t[i]! - row.s) / 1000, 1), round(lat[i]!, 6), round(lon[i]!, 6), route.alt?.[i] != null ? round(route.alt[i]!, 1) : null, route.spd?.[i] != null ? round(route.spd[i]!, 2) : null];
    const lats = keep.map((i) => lat[i]!);
    const lons = keep.map((i) => lon[i]!);
    const base = {
      ...envelope(deps, [[WORKOUT_TYPE, man]], doc.rawComplete, notes),
      workout_id: row.id,
      columns: ['offset_seconds', 'lat', 'lon', 'altitude_m', 'speed_mps'],
      route_points_total: route.t.length, route_points_shown_range: keep.length,
      total_distance_m: round(total, 1),
      bounding_box: keep.length ? { min_lat: Math.min(...lats), max_lat: Math.max(...lats), min_lon: Math.min(...lons), max_lon: Math.max(...lons) } : null,
      trimmed_ends: !args.include_full_route,
    };
    if (args.mode === 'raw') {
      const start = args.cursor ?? 0;
      if (!Number.isInteger(start) || start < 0) throw new ToolError('bad_request', 'cursor must be 0 or the next_cursor of a previous call.');
      const page = keep.slice(start, start + limit);
      return { ...base, mode: 'raw', returned: page.length, next_cursor: start + limit < keep.length ? start + limit : null, points: page.map(point) };
    }
    const shown = thin(keep, limit);
    return { ...base, mode: 'downsample', downsampled: shown.length < keep.length, returned: shown.length, points: shown.map(point) };
  });
}

// ---------------------------------------------------------------------------------------------
// Calculation tools

interface CalcContext {
  c: DuckDBConnection;
  dir: string;
  row: WorkoutRow;
  doc: WorkoutDataDoc;
  man: Awaited<ReturnType<typeof findWorkout>>['man'];
  pauses: Pause[];
  budget: { bytes: number };
}

async function calcContext(c: DuckDBConnection, dir: string, deps: QueryDeps, workoutId: string, timezone?: string): Promise<CalcContext> {
  const found = await findWorkout(c, dir, deps, workoutId, validTz(timezone ?? deps.tz));
  const { man, row } = found;
  const doc = rawDoc(found.doc);
  return { c, dir, row, doc, man, pauses: pausesFromEvents(eventsOf(row.extra), row.e), budget: { bytes: 0 } };
}

const calcEnvelope = (deps: QueryDeps, ctx: CalcContext, notes: string[] = []) =>
  envelope(deps, [[WORKOUT_TYPE, ctx.man]], ctx.doc.rawComplete, ctx.doc.rawComplete ? notes : [...notes, 'Raw data for this workout is still uploading; results may change.']);

async function hrOf(deps: QueryDeps, ctx: CalcContext): Promise<LoadedStream> {
  if (!ctx.doc.streams.HeartRate) throw new ToolError('no_data', `This workout has no heart rate data. Available streams: ${Object.keys(ctx.doc.streams).join(', ')}.`);
  return loadStream(ctx.c, ctx.dir, deps, ctx.doc, 'HeartRate', ctx.budget);
}

type DistanceSource = 'auto' | 'route' | 'distance';

async function distanceOf(deps: QueryDeps, ctx: CalcContext, source: DistanceSource = 'auto'): Promise<{ dist: DistSeries; used: string }> {
  const stream = DISTANCE_STREAMS.find((n) => ctx.doc.streams[n]);
  if (source !== 'route' && stream) {
    const s = await loadStream(ctx.c, ctx.dir, deps, ctx.doc, stream, ctx.budget);
    return { dist: distanceFromIncrements(s.t, s.cols.v ?? [], ctx.row.s), used: stream };
  }
  if (source === 'distance') throw new ToolError('no_data', 'This workout has no distance stream. Try distance_source "route" or "auto".');
  if (!ctx.doc.streams.route) throw new ToolError('no_data', 'This workout has neither a distance stream nor a GPS route, so distance-based calculations are not possible.');
  const route = await loadRoute(ctx.c, ctx.dir, deps, ctx.doc);
  const rd = routeDistance(route);
  return { dist: { t: rd.t, d: rd.d }, used: 'route (GPS)' };
}

export async function workoutHrZones(deps: QueryDeps, args: { workout_id: string; max_hr?: number; zones_bpm?: number[]; timezone?: string }): Promise<ToolResult> {
  let zb;
  try {
    zb = zoneBounds(args);
  } catch (err) {
    throw new ToolError('bad_request', `${(err as Error).message}. Ask the user for their maximum heart rate or their zone boundaries; do not guess.`);
  }
  return withDuck(async (c, dir) => {
    const ctx = await calcContext(c, dir, deps, args.workout_id, args.timezone);
    const hr = await hrOf(deps, ctx);
    const moving = movingMs(ctx.pauses, ctx.row.s, ctx.row.e) / 1000;
    const result = heartRateZones(weightReadings(hr.t, hr.cols.v ?? [], ctx.row.e, ctx.pauses), zb.bounds, moving);
    return {
      ...calcEnvelope(deps, ctx, ['Time is counted between consecutive heart rate readings (gaps over 30 s count as unmeasured); paused time is excluded.']),
      workout_id: ctx.row.id, method: zb.method, ...result,
    };
  });
}

export async function workoutSplits(deps: QueryDeps, args: { workout_id: string; unit?: 'km' | 'mi'; distance_source?: DistanceSource; timezone?: string }): Promise<ToolResult> {
  return withDuck(async (c, dir) => {
    const ctx = await calcContext(c, dir, deps, args.workout_id, args.timezone);
    const { dist, used } = await distanceOf(deps, ctx, args.distance_source);
    const unit = args.unit ?? 'km';
    const hr = ctx.doc.streams.HeartRate ? await loadStream(c, dir, deps, ctx.doc, 'HeartRate', ctx.budget) : null;
    const routeAlt = ctx.doc.streams.route ? await loadRoute(c, dir, deps, ctx.doc) : null;
    const rows_ = splits({
      dist, unitM: unit === 'km' ? 1000 : 1609.344, startMs: ctx.row.s, pauses: ctx.pauses,
      hr: hr ? { t: hr.t, v: hr.cols.v ?? [] } : undefined,
      alt: routeAlt?.alt ? { t: routeAlt.t, v: routeAlt.alt } : undefined,
    });
    return {
      ...calcEnvelope(deps, ctx, [`Distance source: ${used}. Pace is moving time (pauses removed) per ${unit}. Elevation gain and avg_hr are null when those streams are missing.`]),
      workout_id: ctx.row.id, unit, distance_source: used,
      splits: rows_.map((r) => ({ ...r, pace: formatPace(r.pace_seconds_per_unit) })),
    };
  });
}

export async function workoutHrDrift(deps: QueryDeps, args: { workout_id: string; distance_source?: DistanceSource; timezone?: string }): Promise<ToolResult> {
  return withDuck(async (c, dir) => {
    const ctx = await calcContext(c, dir, deps, args.workout_id, args.timezone);
    const hr = await hrOf(deps, ctx);
    let dist: DistSeries | undefined;
    let used: string | null = null;
    try {
      const d = await distanceOf(deps, ctx, args.distance_source);
      dist = d.dist;
      used = d.used;
    } catch (err) {
      if (!(err instanceof ToolError)) throw err;
    }
    const result = heartRateDrift({ readings: weightReadings(hr.t, hr.cols.v ?? [], ctx.row.e, ctx.pauses), startMs: ctx.row.s, endMs: ctx.row.e, pauses: ctx.pauses, dist });
    return {
      ...calcEnvelope(deps, ctx, ['Compares the first and second half of moving time. decoupling_percent > 0 means speed per heartbeat fell in the second half; it is null without a distance source.']),
      workout_id: ctx.row.id, distance_source: used, ...result,
    };
  });
}

export async function workoutBestEfforts(deps: QueryDeps, args: { workout_id: string; distances_m?: number[]; distance_source?: DistanceSource; timezone?: string }): Promise<ToolResult> {
  const targets = args.distances_m ?? [400, 1000, 1609.344, 3000, 5000, 10000, 21097.5];
  if (targets.length > 12 || targets.some((d) => !Number.isFinite(d) || d <= 0)) throw new ToolError('bad_request', 'distances_m must be up to 12 positive numbers of metres.');
  return withDuck(async (c, dir) => {
    const ctx = await calcContext(c, dir, deps, args.workout_id, args.timezone);
    const { dist, used } = await distanceOf(deps, ctx, args.distance_source);
    const efforts = bestEfforts(dist, targets, ctx.row.s, ctx.pauses);
    return {
      ...calcEnvelope(deps, ctx, [`Fastest continuous stretch of each distance within this workout (moving time). Distance source: ${used}. Distances longer than the workout are omitted.`]),
      workout_id: ctx.row.id, distance_source: used,
      efforts: efforts.map((e) => ({ ...e, time: formatDuration(e.moving_seconds), pace_per_km: formatPace(e.pace_seconds_per_km), pace_per_mile: formatPace(e.pace_seconds_per_km * 1.609344) })),
    };
  });
}

export async function workoutElevation(deps: QueryDeps, args: { workout_id: string; timezone?: string }): Promise<ToolResult> {
  return withDuck(async (c, dir) => {
    const ctx = await calcContext(c, dir, deps, args.workout_id, args.timezone);
    const route = await loadRoute(c, dir, deps, ctx.doc);
    const result = elevationProfile(route);
    if (!result) throw new ToolError('no_data', 'This route has no altitude data.');
    return {
      ...calcEnvelope(deps, ctx, ['Computed from GPS altitude, lightly smoothed, ignoring changes under 2 m. Apple\'s own elevation figure (in get_workout metadata) may differ.']),
      workout_id: ctx.row.id, ...result,
    };
  });
}

export const formatPace = (secPerUnit: number | null): string | null => (secPerUnit == null || !Number.isFinite(secPerUnit) ? null : formatDuration(secPerUnit).replace(/^0:/, ''));

export function formatDuration(totalSeconds: number): string {
  const s = Math.round(totalSeconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
}

// ---------------------------------------------------------------------------------------------
// Daily context

export async function getDailyContext(deps: QueryDeps, args: { start_date: string; end_date: string }): Promise<ToolResult> {
  const r = range(deps, { ...args, timezone: 'UTC' });
  const days = (Date.parse(r.end + 'T00:00:00Z') - Date.parse(r.start + 'T00:00:00Z')) / 86_400_000 + 1;
  if (days > 400) throw new ToolError('too_large', 'At most 400 days per call. Use a shorter range.');
  return withDuck(async (c, dir) => {
    const s = Date.parse(r.start + 'T00:00:00Z');
    const e = Date.parse(r.end + 'T00:00:00Z') + 86_400_000;
    const man = await loadType(c, dir, deps, DAILY_TYPE, [s, e], 'd', { what: 'raw', budget: { bytes: 0 } });
    const out = await rows(c, `SELECT id, extra FROM d WHERE k = 'day' AND id >= ${lit(r.start)} AND id <= ${lit(r.end)} ORDER BY id`);
    return {
      ...envelope(deps, [[DAILY_TYPE, man]], isComplete(man, s, e, deps.now(), true), [
        'Each day is a local calendar day on the user\'s phone. Sleep is dated by the morning it ends. A missing metric means it was not recorded that day, not zero.',
      ]),
      count: out.length,
      days: out.map((d) => ({ date: String(d.id), ...tidyMetrics((parseExtra(d.extra).m as Record<string, unknown>) ?? {}) })),
    };
  });
}
