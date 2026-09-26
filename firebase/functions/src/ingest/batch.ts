import { gunzipSync } from 'node:zlib';
import { z } from 'zod';
import { LIMITS, TYPES_BY_ID } from '../config.js';

/** See docs/DATA_CONTRACT.md §1. */
export const SCHEMA_VERSION = 1;

/** Epoch milliseconds between 1970 and 2100. */
const epochMs = z.number().int().min(0).max(4_102_444_800_000);

export const HeaderSchema = z.object({
  kind: z.literal('header'),
  schema: z.literal(SCHEMA_VERSION),
  batchId: z.string().uuid(),
  type: z.string().min(1).max(120),
  seq: z.number().int().min(0),
  device: z.string().max(64).optional(),
  appVersion: z.string().max(32).optional(),
  tz: z.string().max(64).optional(),
  createdAt: epochMs,
  mode: z.enum(['anchored', 'recent', 'stats', 'profile', 'reconcile']),
  window: z.object({ start: epochMs, end: epochMs }).optional(),
  caughtUp: z.boolean().optional(),
  checkedAt: epochMs.optional(),
  /** Set on every page of a reconcile pass; `reconcileDone` on the last page. */
  reconcileId: z.string().uuid().optional(),
  reconcileDone: z.boolean().optional(),
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

const SampleRec = z.object({ k: z.literal('s'), id: uuid, s: epochMs, e: epochMs, v: z.number().finite().nullish(), c: z.number().int().nullish(), u: str(40).nullish(), n: z.number().int().nullish(), ...common }).passthrough();
const WorkoutRec = z.object({ k: z.literal('w'), id: uuid, s: epochMs, e: epochMs, act: z.number().int(), ...common }).passthrough();
const CorrelationRec = z.object({ k: z.literal('x'), id: uuid, s: epochMs, e: epochMs, ct: str(120), ...common }).passthrough();
const EcgRec = z.object({ k: z.literal('ecg'), id: uuid, s: epochMs, e: epochMs, ...common }).passthrough();
const HeartbeatRec = z.object({ k: z.literal('hb'), id: uuid, s: epochMs, e: epochMs, ...common }).passthrough();
const ActivityRec = z.object({ k: z.literal('a'), day: z.string().regex(/^\d{4}-\d{2}-\d{2}$/) }).passthrough();
const StatRec = z.object({ k: z.literal('h'), t: str(120).optional(), s: epochMs, e: epochMs, agg: z.enum(['sum', 'avg', 'min', 'max']), v: z.number().finite(), u: str(40) }).strict();
const ProfileRec = z.object({ k: z.literal('p') }).passthrough();
const DeleteRec = z.object({ k: z.literal('d'), id: uuid }).strict();

export const RecordSchema = z.discriminatedUnion('k', [SampleRec, WorkoutRec, CorrelationRec, EcgRec, HeartbeatRec, ActivityRec, StatRec, ProfileRec, DeleteRec]);
export type BatchRecord = z.infer<typeof RecordSchema>;

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
  if (!TYPES_BY_ID.has(header.type)) throw new BatchError(`unknown type ${header.type}`);

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
    switch (rec.k) {
      case 'd':
        tombstones.push(rec.id);
        continue;
      case 'p':
        push('_profile', { ...base, k: 'p', id: null, s: header.createdAt, e: header.createdAt, v: null, c: null, u: null, agg: null, src: null, bid: null, dev: null, tz: null, extra: extraOf(rec) });
        continue;
      case 'a': {
        const [y, m, d] = rec.day.split('-').map(Number) as [number, number, number];
        const s = Date.UTC(y, m - 1, d);
        push(monthKey(s), { ...base, k: 'a', id: rec.day, s, e: s + 86_400_000, v: null, c: null, u: null, agg: null, src: null, bid: null, dev: null, tz: null, extra: extraOf(rec) });
        continue;
      }
      case 'h':
        if (rec.e <= rec.s) throw new BatchError(`line ${i}: stat bucket end before start`);
        push(`_stats/${new Date(rec.s).getUTCFullYear()}`, { ...base, k: 'h', id: null, s: rec.s, e: rec.e, v: rec.v, c: null, u: rec.u, agg: rec.agg, src: null, bid: null, dev: null, tz: null, extra: null });
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
    recordCount: lines.length - 1,
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
