import type { DuckDBConnection } from '@duckdb/node-api';
import { join } from 'node:path';
import { LIMITS, shortName } from '../config.js';
import { covers, type BlobStore, type MetaStore, type TypeManifest } from '../store/types.js';
import { lit } from './duck.js';

export class ToolError extends Error {
  constructor(readonly code: 'not_found' | 'too_large' | 'bad_request' | 'no_data' | 'unavailable' | 'category_disabled', message: string) {
    super(message);
  }
}

export interface QueryDeps {
  uid: string;
  meta: MetaStore;
  data: BlobStore;
  incoming?: BlobStore;
  pendingUploadCheck?: Promise<boolean>;
  pendingUploadsDetected?: boolean;
  now: () => number;
  /** Default timezone (the phone's current zone). */
  tz: string;
}

/** Conservative completeness: an earlier accepted page may still be in flight.
 * One bounded storage lookup per tool, shared by all of its type loads. */
export async function checkPendingUploads(deps: QueryDeps): Promise<void> {
  if (!deps.incoming) return;
  const prefix = `incoming/${deps.uid}/`;
  deps.pendingUploadCheck ??= deps.incoming.hasAny
    ? deps.incoming.hasAny(prefix) : deps.incoming.list(prefix).then((paths) => paths.length > 0);
  deps.pendingUploadsDetected = await deps.pendingUploadCheck;
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
  /** Kept for readability at call sites: only raw records (workouts, daily rows) exist. */
  what?: 'raw';
  /** Shared byte budget across all loads of one tool call. */
  budget: { bytes: number };
  /** Keep every upload of a row instead of only the latest (daily rows are merged metric by metric by the caller). */
  keepVersions?: boolean;
}

const EMPTY_ROWS =
  'SELECT NULL::VARCHAR k, NULL::VARCHAR id, NULL::BIGINT s, NULL::BIGINT e, NULL::DOUBLE v, NULL::DOUBLE v2, NULL::DOUBLE v3, NULL::INTEGER c, NULL::VARCHAR u, NULL::VARCHAR agg, NULL::VARCHAR src, NULL::VARCHAR bid, NULL::VARCHAR dev, NULL::VARCHAR tz, NULL::VARCHAR extra, NULL::BIGINT seq, NULL::VARCHAR batch, NULL::VARCHAR rid WHERE false';

/** Identity of a row: its id, or (series, start, source) for rows without one (hourly buckets, dense readings). */
export const ROW_KEY = `COALESCE(id, concat_ws('|', agg, s::VARCHAR, src))`;

/**
 * Downloads only the monthly partitions of one type that overlap the range and creates table
 * `<alias>` of deduplicated records minus deletions (the latest upload of each id wins).
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
  await checkPendingUploads(deps);
  const man = await deps.meta.getManifest(deps.uid, type);
  const all = man?.files ?? {};
  const months = range === 'all' ? null : new Set(monthsBetween(range[0], range[1]));
  const keys = Object.keys(all).filter((k) => !k.startsWith('_') && (!months || months.has(k)));
  const files = keys.flatMap((k) => all[k] ?? []);
  const tomb = all._tombstones ?? [];
  opts.budget.bytes += [...files, ...tomb].reduce((n, f) => n + f.bytes, 0);
  if (opts.budget.bytes > LIMITS.maxScanBytes) {
    throw new ToolError('too_large', 'That request needs too much data at once. Use a shorter date range.');
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
  const tombSql = tombFiles.length ? `SELECT id FROM read_parquet(${list(tombFiles)})` : 'SELECT NULL::VARCHAR id WHERE false';
  const latest = opts.keepVersions ? '' : `QUALIFY row_number() OVER (PARTITION BY ${ROW_KEY} ORDER BY seq DESC, batch DESC) = 1`;
  await c.run(`CREATE OR REPLACE TEMP TABLE ${alias} AS
    SELECT * FROM (${src}) r WHERE (id IS NULL OR id NOT IN (${tombSql}))
    ${latest}`);
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
