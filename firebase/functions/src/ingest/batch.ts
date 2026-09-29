import { gunzipSync } from 'node:zlib';
import { z } from 'zod';
import { LIMITS, TYPES_BY_ID } from '../config.js';

/** See docs/DATA_CONTRACT.md §1. Schema 2 adds workout raw data (`ws`, `wd`) and daily context (`day`). */
export const SCHEMA_VERSION = 2;
export const OLDEST_SCHEMA = 1;

/** Epoch milliseconds between 1970 and 2100. */
const epochMs = z.number().int().min(0).max(4_102_444_800_000);

export const HeaderSchema = z.object({
  kind: z.literal('header'),
  schema: z.union([z.literal(1), z.literal(2)]),
  batchId: z.string().uuid(),
  type: z.string().min(1).max(120),
  seq: z.number().int().min(0),
  device: z.string().max(64).optional(),
  appVersion: z.string().max(32).optional(),
  tz: z.string().max(64).optional(),
  createdAt: epochMs,
  /** `status`: one batch for many types that had nothing new (type "_status", records `c`). */
  mode: z.enum(['anchored', 'recent', 'stats', 'reconcile', 'status', 'workoutdata']),
  window: z.object({ start: epochMs, end: epochMs }).optional(),
  caughtUp: z.boolean().optional(),
  checkedAt: epochMs.optional(),
  /** Set on every page of a reconcile pass; `reconcileDone` on the last page. */
  reconcileId: z.string().uuid().optional(),
  reconcileDone: z.boolean().optional(),
  /** Client timings for the batch (never health data): read = HealthKit query, upload = previous upload. */
  perf: z.object({ readMs: z.number().int().min(0).max(3_600_000).optional(), uploadMs: z.number().int().min(0).max(3_600_000).optional() }).strict().optional(),
}).strict();
export type BatchHeader = z.infer<typeof HeaderSchema>;

const str = (max: number) => z.string().max(max);
const common = {
  src: str(200).nullish(),
  bid: str(200).nullish(),
  dev: str(200).nullish(),
  tz: str(64).nullish(),
  md: z.record(z.string().max(100), z.union([z.string().max(1000), z.number(), z.boolean()])).nullish(),
};
const uuid = z.string().min(1).max(64);

const fin = z.number().finite().nullish();
const WorkoutRec = z.object({ k: z.literal('w'), id: uuid, s: epochMs, e: epochMs, act: z.number().int(), dur: fin, en: fin, dist: fin, hrAvg: fin, hrMax: fin, ...common }).passthrough();
/** Value columns of a raw workout stream (all optional except time). */
export const STREAM_COLS = ['v', 'lat', 'lon', 'alt', 'spd', 'crs', 'ha', 'va'] as const;
export const MAX_POINTS_PER_CHUNK = 20_000;
const pts = z.array(z.number().finite().nullable()).max(MAX_POINTS_PER_CHUNK);
/** A chunk of one raw stream: parallel arrays, `t` = absolute epoch ms of each point. */
const StreamRec = z.object({
  k: z.literal('ws'),
  wid: uuid,
  st: z.string().regex(/^[A-Za-z0-9_]{1,60}$/),
  gen: epochMs,
  u: str(40).nullish(),
  t: z.array(epochMs).min(1).max(MAX_POINTS_PER_CHUNK),
  v: pts.optional(), lat: pts.optional(), lon: pts.optional(), alt: pts.optional(),
  spd: pts.optional(), crs: pts.optional(), ha: pts.optional(), va: pts.optional(),
}).strict();
/** "Workout `wid` raw data of generation `gen` consists of these streams with these point counts." */
const WorkoutMarkRec = z.object({
  k: z.literal('wd'),
  wid: uuid,
  gen: epochMs,
  expected: z.record(z.string().regex(/^[A-Za-z0-9_]{1,60}$/), z.number().int().min(0).max(50_000_000)),
}).strict();
/** One day of context metrics, computed on the phone in the user's local calendar. */
const DayRec = z.object({
  k: z.literal('day'),
  day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  m: z.record(str(60), z.union([z.number().finite(), z.string().max(200), z.boolean(), z.null()])),
}).strict();
const DeleteRec = z.object({ k: z.literal('d'), id: uuid }).strict();
/** "Checked this type at `at`, nothing new; `cu` = its full history has been delivered." */
const StatusRec = z.object({ k: z.literal('c'), t: str(120), at: epochMs, cu: z.boolean() }).strict();

export const RecordSchema = z.discriminatedUnion('k', [StreamRec, WorkoutMarkRec, DayRec, WorkoutRec, DeleteRec, StatusRec]);

/** Batch type used by `status` batches. */
export const STATUS_TYPE = '_status';
/** Pseudo-types of schema 2 batches. */
export const WSTREAM_TYPE = '_wstream';
export const DAILY_TYPE = '_daily';
export const WORKOUT_TYPE = 'HKWorkoutTypeIdentifier';
export type BatchRecord = z.infer<typeof RecordSchema>;

/** Record kinds each batch type may carry: nothing else is stored. */
const KINDS_BY_TYPE: Record<string, ReadonlySet<string>> = {
  [WORKOUT_TYPE]: new Set(['w', 'd']),
  [DAILY_TYPE]: new Set(['day']),
  [WSTREAM_TYPE]: new Set(['ws', 'wd']),
  [STATUS_TYPE]: new Set(['c']),
};

/** Normalized row written to Parquet (one table shape for every type). */
export interface Row {
  k: string;
  id: string | null;
  s: number;
  e: number;
  v: number | null;
  c: number | null;
  u: string | null;
  agg: string | null;
  src: string | null;
  bid: string | null;
  dev: string | null;
  tz: string | null;
  extra: string | null;
  seq: number;
  batch: string;
  rid: string | null;
}

export interface ParsedBatch {
  header: BatchHeader;
  /** Rows grouped by partition key ("2024-03", "_stats/2024", "_profile"). */
  partitions: Map<string, Row[]>;
  tombstones: string[];
  /** Min/max sample start time in this batch (null if none). */
  span: { start: number; end: number } | null;
  recordCount: number;
  /** Only for `status` batches: one entry per known type. */
  statuses: { type: string; at: number; caughtUp: boolean }[];
  /** Only for `workoutdata` batches. */
  streams: StreamChunk[];
  marks: { wid: string; gen: number; expected: Record<string, number> }[];
}

export interface StreamChunk {
  wid: string;
  st: string;
  gen: number;
  unit: string | null;
  t: number[];
  cols: Partial<Record<(typeof STREAM_COLS)[number], (number | null)[]>>;
}

export class BatchError extends Error {
  constructor(message: string, readonly permanent = true) {
    super(message);
  }
}

export function monthKey(ms: number): string {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

const KNOWN_KEYS = new Set(['k', 'id', 's', 'e', 'v', 'c', 'u', 'agg', 'src', 'bid', 'dev', 'tz', 't']);

function extraOf(rec: Record<string, unknown>): string | null {
  const extra: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(rec)) if (!KNOWN_KEYS.has(key)) extra[key] = val;
  return Object.keys(extra).length ? JSON.stringify(extra) : null;
}

export function parseBatch(gz: Buffer): ParsedBatch {
  if (gz.byteLength > LIMITS.maxBatchBytes) throw new BatchError(`batch too large (${gz.byteLength} bytes)`);
  let text: string;
  try {
    text = gunzipSync(gz, { maxOutputLength: LIMITS.maxBatchInflatedBytes }).toString('utf8');
  } catch (err) {
    throw new BatchError(`not valid gzip or too large when decompressed: ${(err as Error).message}`);
  }
  const lines = text.split('\n').filter((l) => l.length > 0);
  if (lines.length === 0) throw new BatchError('empty batch');
  if (lines.length - 1 > LIMITS.maxRecordsPerBatch) throw new BatchError('too many records');

  const header = parseLine(lines[0]!, 0, HeaderSchema);
  const isStatus = header.mode === 'status';
  const isStream = header.mode === 'workoutdata';
  if (isStatus !== (header.type === STATUS_TYPE)) throw new BatchError('status batches must use type _status');
  if (isStream !== (header.type === WSTREAM_TYPE)) throw new BatchError('workoutdata batches must use type _wstream');
  if (!isStatus && !TYPES_BY_ID.has(header.type)) throw new BatchError(`unknown type ${header.type}`);
  if ((isStream || header.type === DAILY_TYPE) && header.schema < 2) throw new BatchError('this batch type needs schema 2');
  const statuses: ParsedBatch['statuses'] = [];
  const streams: StreamChunk[] = [];
  const marks: ParsedBatch['marks'] = [];

  const partitions = new Map<string, Row[]>();
  const tombstones: string[] = [];
  let min = Infinity;
  let max = -Infinity;
  const push = (key: string, row: Row) => {
    let rows = partitions.get(key);
    if (!rows) partitions.set(key, (rows = []));
    rows.push(row);
  };

  for (let i = 1; i < lines.length; i++) {
    const rec = parseLine(lines[i]!, i, RecordSchema) as Record<string, unknown> & BatchRecord;
    const base = { seq: header.seq, batch: header.batchId, rid: header.reconcileId ?? null };
    if (!KINDS_BY_TYPE[header.type]?.has(rec.k)) throw new BatchError(`line ${i}: record kind ${rec.k} is not allowed in a ${header.type} batch`);
    switch (rec.k) {
      case 'ws': {
        const cols: StreamChunk['cols'] = {};
        for (const col of STREAM_COLS) {
          const arr = rec[col];
          if (!arr) continue;
          if (arr.length !== rec.t.length) throw new BatchError(`line ${i}: ${col} has ${arr.length} points but t has ${rec.t.length}`);
          cols[col] = arr;
        }
        if (Object.keys(cols).length === 0) throw new BatchError(`line ${i}: stream chunk has no values`);
        streams.push({ wid: rec.wid, st: rec.st, gen: rec.gen, unit: rec.u ?? null, t: rec.t, cols });
        continue;
      }
      case 'wd':
        marks.push({ wid: rec.wid, gen: rec.gen, expected: rec.expected });
        continue;
      case 'day': {
        const [y, m, d] = rec.day.split('-').map(Number) as [number, number, number];
        const s = Date.UTC(y, m - 1, d);
        if (new Date(s).toISOString().slice(0, 10) !== rec.day) throw new BatchError(`line ${i}: impossible date ${rec.day}`);
        push(monthKey(s), { ...base, k: 'day', id: rec.day, s, e: s + 86_400_000, v: null, c: null, u: null, agg: null, src: null, bid: null, dev: null, tz: null, extra: JSON.stringify({ m: rec.m }) });
        min = Math.min(min, s);
        max = Math.max(max, s + 86_400_000);
        continue;
      }
      case 'c':
        // Unknown types (e.g. from a newer app) are skipped rather than failing the whole batch.
        if (TYPES_BY_ID.has(rec.t)) statuses.push({ type: rec.t, at: rec.at, caughtUp: rec.cu });
        continue;
      case 'd':
        tombstones.push(rec.id);
        continue;
      default: {
        if (rec.e < rec.s) throw new BatchError(`line ${i}: end before start`);
        const r = rec as Record<string, unknown>;
        min = Math.min(min, rec.s);
        max = Math.max(max, rec.e);
        push(monthKey(rec.s), {
          ...base,
          k: rec.k,
          id: rec.id,
          s: rec.s,
          e: rec.e,
          v: typeof r.v === 'number' ? r.v : null,
          c: typeof r.c === 'number' ? r.c : null,
          u: typeof r.u === 'string' ? r.u : null,
          agg: null,
          src: (r.src as string) ?? null,
          bid: (r.bid as string) ?? null,
          dev: (r.dev as string) ?? null,
          tz: (r.tz as string) ?? null,
          extra: extraOf(r),
        });
      }
    }
  }
  return {
    header,
    partitions,
    tombstones,
    span: min === Infinity ? null : { start: min, end: max },
    recordCount: isStatus ? 0 : lines.length - 1,
    statuses,
    streams,
    marks,
  };
}

function parseLine<T>(line: string, index: number, schema: z.ZodType<T>): T {
  if (line.length > LIMITS.maxRecordLineBytes) throw new BatchError(`line ${index}: too long`);
  let json: unknown;
  try {
    json = JSON.parse(line);
  } catch {
    throw new BatchError(`line ${index}: invalid JSON`);
  }
  const res = schema.safeParse(json);
  if (!res.success) throw new BatchError(`line ${index}: ${res.error.issues[0]?.path.join('.')} ${res.error.issues[0]?.message}`);
  return res.data;
}
