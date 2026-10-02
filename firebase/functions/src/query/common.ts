import type { DuckDBConnection } from '@duckdb/node-api';
import { coverageInfo, parseDate, ToolError, validTz, type CoverageInfo, type QueryDeps } from './context.js';
import type { TypeManifest } from '../store/types.js';

/** Common envelope for every tool result. */
export interface ToolResult {
  dataAsOf: string | null;
  complete: boolean;
  coverage: CoverageInfo[];
  notes: string[];
  [key: string]: unknown;
}

export async function rows(c: DuckDBConnection, sql: string): Promise<Record<string, unknown>[]> {
  const r = await c.runAndReadAll(sql);
  return r.getRowObjectsJS().map((row) => {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(row)) out[k] = typeof v === 'bigint' ? Number(v) : v;
    return out;
  });
}

export function envelope(deps: QueryDeps, mans: [string, TypeManifest | null][], complete: boolean, notes: string[] = []): ToolResult {
  const now = deps.now();
  const coverage = mans.map(([t, m]) => coverageInfo(m, t, now));
  if (deps.pendingUploadsDetected) {
    complete = false;
    coverage.forEach((item) => { item.fullHistorySynced = false; item.syncedRanges = []; });
    notes.push('Accepted uploads are still being processed. Results may omit earlier pages; open KROK and wait for sync to finish.');
  }
  const checked = mans.map(([, m]) => m?.coverage.checkedAt ?? null).filter((x): x is number => x !== null);
  const asOf = checked.length ? Math.min(...checked) : null;
  if (coverage.some((cv) => cv.stale)) {
    notes.push('Some of this data was last synced more than a day ago. Suggest the user opens the KROK app on their iPhone to refresh.');
  }
  if (!complete) {
    notes.push('The requested range is not fully synced yet (see coverage). Treat results as partial and tell the user.');
  }
  return { dataAsOf: asOf ? new Date(asOf).toISOString() : null, complete, coverage, notes };
}

export interface Range {
  tz: string;
  start: string;
  end: string;
}

export function range(deps: QueryDeps, args: { start_date: string; end_date: string; timezone?: string }): Range {
  const start = parseDate(args.start_date, 'start_date');
  const end = parseDate(args.end_date, 'end_date');
  if (end < start) throw new ToolError('bad_request', 'end_date is before start_date');
  return { tz: validTz(args.timezone ?? deps.tz), start, end };
}
