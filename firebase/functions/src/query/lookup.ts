import type { DuckDBConnection } from '@duckdb/node-api';
import { join } from 'node:path';
import { WORKOUT_TYPE } from '../ingest/batch.js';
import type { TypeManifest, WorkoutDataDoc } from '../store/types.js';
import { rows } from './common.js';
import { loadType, localTs, ToolError, type QueryDeps } from './context.js';
import { lit } from './duck.js';

const ID_RE = /^[0-9A-Za-z-]{8,64}$/;

export interface WorkoutRow {
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

export const parseExtra = (raw: unknown): Record<string, unknown> => {
  if (typeof raw !== 'string') return {};
  try {
    const v = JSON.parse(raw) as unknown;
    return v && typeof v === 'object' ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
};

export const toWorkoutRow = (r: Record<string, unknown>): WorkoutRow => ({
  id: String(r.id), s: Number(r.s), e: Number(r.e), startLocal: String(r.start_local), endLocal: String(r.end_local),
  src: (r.src as string) ?? null, bid: (r.bid as string) ?? null, dev: (r.dev as string) ?? null, extra: parseExtra(r.extra),
});

export const SELECT_W = (tz: string) => `SELECT id, s, e, src, bid, dev, extra,
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
export async function findWorkout(c: DuckDBConnection, dir: string, deps: QueryDeps, id: string, tz: string) {
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

