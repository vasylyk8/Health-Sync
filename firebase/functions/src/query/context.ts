import type { DuckDBConnection } from '@duckdb/node-api';
import { join } from 'node:path';
import { LIMITS, resolveType, shortName, type CoverageEntry } from '../config.js';
import { covers, type BlobStore, type MetaStore, type TypeManifest } from '../store/types.js';
import { lit } from './duck.js';

export class ToolError extends Error {
  constructor(readonly code: 'not_found' | 'too_large' | 'bad_request' | 'no_data' | 'unavailable', message: string) {
    super(message);
  }
}

export interface QueryDeps {
  uid: string;
  meta: MetaStore;
  data: BlobStore;
  now: () => number;
  /** Default timezone (the phone's current zone). */
  tz: string;
}

export function validTz(tz: string): string {
  try {
    // UTC offsets such as "+05:30" pass Intl but not the query engine; only named zones are supported.
    if (/^[+-]/.test(tz)) throw new Error('offset');
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return tz;
  } catch {
    throw new ToolError('bad_request', `Unknown timezone "${tz}". Use an IANA name like "Europe/Berlin".`);
  }
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** Parses YYYY-MM-DD (a local calendar date in the request timezone). */
export function parseDate(value: string, field: string): string {
  const ms = DATE_RE.test(value) ? Date.parse(value + 'T00:00:00Z') : NaN;
  // Round-trip so impossible dates such as 2024-02-30 are rejected instead of rolling over.
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== value) {
    throw new ToolError('bad_request', `${field} must be a date like 2024-03-31`);
  }
  return value;
}

export function resolveKnownType(name: string): CoverageEntry {
  const t = resolveType(name);
  if (!t) throw new ToolError('not_found', `Unknown data type "${name}". Call list_available_data to see valid names.`);
  return t;
}

export interface CoverageInfo {
  type: string;
  syncedRanges: { from: string; to: string }[];
  fullHistorySynced: boolean;
  earliestSample: string | null;
  latestSample: string | null;
  lastCheckedAt: string | null;
  stale: boolean;
}

const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());

export function coverageInfo(man: TypeManifest | null, type: string, now: number): CoverageInfo {
  const c = man?.coverage;
  return {
    type: shortName(type),
    syncedRanges: (c?.intervals ?? []).map(([a, b]) => ({ from: a === 0 ? 'beginning' : iso(a)!, to: iso(b)! })),
    fullHistorySynced: c?.caughtUp ?? false,
    earliestSample: iso(c?.earliest ?? null),
    latestSample: iso(c?.latest ?? null),
    lastCheckedAt: iso(c?.checkedAt ?? null),
    stale: !c?.checkedAt || now - c.checkedAt > LIMITS.staleAfterMs,
  };
}

/** Months (UTC "YYYY-MM") overlapping [startMs, endMs]. */
export function monthsBetween(startMs: number, endMs: number): string[] {
  const out: string[] = [];
  const d = new Date(Date.UTC(new Date(startMs).getUTCFullYear(), new Date(startMs).getUTCMonth(), 1));
  while (d.getTime() <= endMs) {
    out.push(`${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`);
    d.setUTCMonth(d.getUTCMonth() + 1);
  }
  return out;
}

/** Rough UTC bounds for a local date range (±1 day covers every timezone), used for pruning. */
export function roughUtcRange(startDate: string, endDate: string): [number, number] {
  return [Date.parse(startDate + 'T00:00:00Z') - 86_400_000, Date.parse(endDate + 'T00:00:00Z') + 2 * 86_400_000];
}

/** Years overlapping [startMs, endMs]. */
export function yearsBetween(startMs: number, endMs: number): string[] {
  const out: string[] = [];
  for (let y = new Date(startMs).getUTCFullYear(); y <= new Date(endMs).getUTCFullYear(); y++) out.push(String(y));
  return out;
}

export interface LoadOptions {
  /** 'raw' = sample/workout/... records, 'stats' = merged hourly buckets, 'profile' = characteristics. */
  what: 'raw' | 'stats' | 'profile';
  /** Shared byte budget across all loads of one tool call. */
  budget: { bytes: number };
}

const EMPTY_ROWS =
  'SELECT NULL::VARCHAR k, NULL::VARCHAR id, NULL::BIGINT s, NULL::BIGINT e, NULL::DOUBLE v, NULL::INTEGER c, NULL::VARCHAR u, NULL::VARCHAR agg, NULL::VARCHAR src, NULL::VARCHAR bid, NULL::VARCHAR dev, NULL::VARCHAR tz, NULL::VARCHAR extra, NULL::BIGINT seq, NULL::VARCHAR batch, NULL::VARCHAR rid WHERE false';

/**
 * Downloads only the partitions of one type that overlap the range and creates table `<alias>`:
 *   raw:     deduplicated records minus deletions (latest upload of each id wins)
 *   stats:   merged hourly buckets (latest upload of each bucket wins)
 *   profile: characteristics rows
 * Returns the manifest used, so callers can report coverage.
 */
export async function loadType(
  c: DuckDBConnection,
  dir: string,
  deps: QueryDeps,
  type: string,
  range: [number, number] | 'all',
  alias: string,
  opts: LoadOptions,
): Promise<TypeManifest | null> {
  const man = await deps.meta.getManifest(deps.uid, type);
  const all = man?.files ?? {};
  let keys: string[];
  if (opts.what === 'profile') keys = ['_profile'];
  else if (opts.what === 'stats') {
    const years = range === 'all' ? null : new Set(yearsBetween(range[0], range[1]).map((y) => `_stats/${y}`));
    keys = Object.keys(all).filter((k) => k.startsWith('_stats/') && (!years || years.has(k)));
  } else {
    const months = range === 'all' ? null : new Set(monthsBetween(range[0], range[1]));
    keys = Object.keys(all).filter((k) => !k.startsWith('_') && (!months || months.has(k)));
  }
  const files = keys.flatMap((k) => all[k] ?? []);
  const tomb = opts.what === 'raw' ? (all._tombstones ?? []) : [];
  opts.budget.bytes += [...files, ...tomb].reduce((n, f) => n + f.bytes, 0);
  if (opts.budget.bytes > LIMITS.maxScanBytes) {
    throw new ToolError(
      'too_large',
      'That request needs too much data at once. Use a shorter date range or a coarser period, or use summarize (which can use hourly totals) instead of raw samples.',
    );
  }
  const local = await Promise.all(
    [...files, ...tomb].map(async (f, i) => {
      const p = join(dir, `${alias}_${i}.parquet`);
      await deps.data.download(f.path, p);
      return p;
    }),
  );
  const dataFiles = local.slice(0, files.length);
  const tombFiles = local.slice(files.length);
  const list = (ps: string[]) => `[${ps.map(lit).join(',')}]`;
  const src = dataFiles.length ? `SELECT * FROM read_parquet(${list(dataFiles)}, union_by_name=true)` : EMPTY_ROWS;
  if (opts.what === 'raw') {
    const tombSql = tombFiles.length ? `SELECT id FROM read_parquet(${list(tombFiles)})` : 'SELECT NULL::VARCHAR id WHERE false';
    await c.run(`CREATE OR REPLACE TEMP TABLE ${alias} AS
      SELECT * FROM (${src}) r WHERE k NOT IN ('h', 'p') AND split_part(id, '#', 1) NOT IN (${tombSql})
      QUALIFY row_number() OVER (PARTITION BY id ORDER BY seq DESC, batch DESC) = 1`);
  } else if (opts.what === 'stats') {
    await c.run(`CREATE OR REPLACE TEMP TABLE ${alias} AS
      SELECT * FROM (${src}) r WHERE k = 'h'
      QUALIFY row_number() OVER (PARTITION BY s, agg ORDER BY seq DESC, batch DESC) = 1`);
  } else {
    await c.run(`CREATE OR REPLACE TEMP TABLE ${alias} AS SELECT * FROM (${src}) r WHERE k = 'p' ORDER BY seq DESC, s DESC`);
  }
  return man;
}

/** Converts a local date range (inclusive) in `tz` to exact UTC ms bounds [start, endExclusive). */
export async function localRangeToUtc(c: DuckDBConnection, tz: string, startDate: string, endDate: string): Promise<[number, number]> {
  const r = await c.runAndReadAll(
    `SELECT epoch_ms(timezone(${lit(tz)}, ${lit(startDate)}::TIMESTAMP))::BIGINT a,
            epoch_ms(timezone(${lit(tz)}, (${lit(endDate)}::DATE + 1)::TIMESTAMP))::BIGINT b`,
  );
  const row = r.getRows()[0]!;
  return [Number(row[0]), Number(row[1])];
}

/**
 * True when the requested range is fully synced up to the last successful check. Ranges that
 * extend past the last check count as complete "as of" that check (reported via dataAsOf), unless
 * the check is stale or the range starts after it.
 */
export function isComplete(man: TypeManifest | null, start: number, end: number, now: number, stats = false): boolean {
  const checked = man?.coverage.checkedAt;
  if (!man || !checked || now - checked > LIMITS.staleAfterMs) return false;
  if (stats) {
    // Hourly totals are refreshed by their own batches, which are usually a few minutes older than
    // the latest anchored/empty check. Judge them against their own window, not `checkedAt`.
    const window = man.coverage.statsIntervals.find(([a, b]) => a <= start && start <= b);
    if (!window || checked - window[1] > LIMITS.statsMaxLagMs) return false;
    return covers(man.coverage.statsIntervals, start, Math.min(end, window[1]));
  }
  const until = Math.min(end, checked);
  if (until < start) return false;
  return covers(man.coverage.intervals, start, until);
}

/** SQL expression: local wall-clock TIMESTAMP of epoch-ms column `col` in `tz`. */
export const localTs = (col: string, tz: string) => `timezone(${lit(tz)}, to_timestamp(${col} / 1000.0))`;
