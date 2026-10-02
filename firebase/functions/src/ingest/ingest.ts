import { createHash } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { BatchError, WORKOUT_TYPE, parseBatch, type ParsedBatch, type StreamChunk } from './batch.js';
import { idsToParquet, rowsToParquet, streamToParquet, withDuck } from '../query/duck.js';
import { addInterval, type BlobStore, type FileRef, type MetaStore, type StreamInfo, type TypeManifest, type WorkoutDataDoc } from '../store/types.js';
import { log } from '../log.js';
import { DEFAULT_CATEGORIES, categoryOfType } from '../config.js';

export interface IngestDeps {
  incoming: BlobStore;
  data: BlobStore;
  meta: MetaStore;
  now?: () => number;
  /** Called when a reconcile pass completes, to compute deletions missed while offline. */
  onReconcileDone?: (uid: string, type: string, reconcileId: string) => Promise<void>;
}

export type IngestOutcome = 'published' | 'duplicate' | 'discarded' | 'rejected' | 'ignored';

const INCOMING_RE = /^incoming\/([A-Za-z0-9_-]{1,128})\/([0-9a-f-]{36})\.ndjson\.gz$/;

/** Raw workout stream files: one per (workout, stream, generation, batch). */
export const streamPath = (uid: string, wid: string, stream: string, gen: number, batchId: string) =>
  `data/${uid}/wstream/${wid}/${stream}/${gen}-${batchId}.parquet`;

export const dataPath = (uid: string, type: string, partition: string, batchId: string) =>
  `data/${uid}/${type}/${partition}/${batchId}.parquet`;

/**
 * Processes one uploaded batch: validate → write Parquet partitions → publish the manifest
 * atomically. Safe to run more than once for the same object (event retries).
 */
export async function ingestObject(objectPath: string, deps: IngestDeps, opts: { sha256?: string } = {}): Promise<IngestOutcome> {
  const m = INCOMING_RE.exec(objectPath);
  if (!m) return 'ignored';
  const [, uid, batchId] = m as unknown as [string, string, string];
  const { meta, incoming, data } = deps;
  const now = deps.now ?? Date.now;

  const prior = await meta.batchState(uid, batchId);
  if (prior) {
    await incoming.delete(objectPath).catch(() => undefined);
    return prior === 'published' ? 'duplicate' : prior;
  }

  const user = await meta.getUser(uid);
  if (!user || user.deleting) {
    await meta.markBatch(uid, batchId, 'discarded', 'user missing or deleting');
    await incoming.delete(objectPath).catch(() => undefined);
    return 'discarded';
  }

  let parsed: ParsedBatch;
  try {
    const bytes = await incoming.read(objectPath);
    if (opts.sha256 !== undefined && createHash('sha256').update(bytes).digest('hex') !== opts.sha256) {
      throw new BatchError('checksum mismatch');
    }
    parsed = parseBatch(bytes);
    if (parsed.header.batchId !== batchId) throw new BatchError('batchId does not match file name');
    if (parsed.skipped > 0) log.warn('invalid records skipped', { uid, batchId, skipped: parsed.skipped, first: parsed.firstSkip });
  } catch (err) {
    if (err instanceof BatchError) {
      log.warn('batch rejected', { uid, batchId, reason: err.message });
      await meta.markBatch(uid, batchId, 'rejected', err.message);
      await incoming.delete(objectPath).catch(() => undefined);
      return 'rejected';
    }
    throw err;
  }

  const { header } = parsed;
  // Data of a category the user has not switched on is never stored (the app only sends enabled categories).
  if (header.mode !== 'status' && !(user.categories ?? DEFAULT_CATEGORIES).includes(categoryOfType(header.type))) {
    log.info('batch for a switched-off category dropped', { uid, batchId, type: header.type });
    await meta.markBatch(uid, batchId, 'discarded', 'category not enabled');
    await incoming.delete(objectPath).catch(() => undefined);
    return 'discarded';
  }
  if (header.mode === 'workoutdata') return ingestStreams(uid, batchId, objectPath, parsed, user.generation, deps);
  if (header.mode === 'status') return ingestStatus(uid, batchId, objectPath, parsed, user.generation, deps);
  const type = header.type;
  const written: Record<string, FileRef> = {};

  // Up to 4 ingestions share an instance (2 GiB), so each gets a bounded DuckDB memory budget.
  await withDuck(async (c, dir) => {
    let i = 0;
    const uploads: (() => Promise<void>)[] = [];
    for (const [partition, rows] of parsed.partitions) {
      const local = await rowsToParquet(c, dir, rows, `p${i++}`);
      const path = dataPath(uid, type, partition, batchId);
      const bytes = await readFile(local);
      written[partition] = { path, bytes: bytes.length };
      uploads.push(() => data.write(path, bytes));
    }
    await pool(uploads, WRITE_CONCURRENCY);
    if (parsed.tombstones.length) {
      const local = await idsToParquet(c, dir, parsed.tombstones, 'tomb');
      const path = dataPath(uid, type, '_tombstones', batchId);
      await data.write(path, await readFile(local));
      written._tombstones = { path, bytes: (await stat(local)).size };
    }
  }, { memoryLimit: '384MB' });

  const t = now();
  const result = await meta.publish({
    uid,
    type,
    batchId,
    generation: user.generation,
    userPatch: { lastVisibleAt: t, ...(header.tz ? { tz: header.tz } : {}) },
    mutate: (man) => applyBatch(man, parsed, written, t),
  });

  if (result === 'discarded') {
    // A deletion started while we were writing: remove what we wrote.
    await Promise.all(Object.values(written).map((f) => data.delete(f.path).catch(() => undefined)));
  }
  await incoming.delete(objectPath).catch(() => undefined);

  // A deleted workout takes its raw data with it.
  if (result === 'published' && type === WORKOUT_TYPE && parsed.tombstones.length) {
    await dropWorkoutData(deps, uid, parsed.tombstones);
  }

  if (result === 'published' && header.reconcileId && header.reconcileDone && deps.onReconcileDone) {
    await deps.onReconcileDone(uid, type, header.reconcileId);
  }
  log.info('batch processed', { uid, batchId, type, result, records: parsed.recordCount, mode: header.mode, readMs: header.perf?.readMs, uploadMs: header.perf?.uploadMs });
  return result;
}

/** Deletes the raw-data index and Parquet files of workouts that no longer exist. */
export async function dropWorkoutData(deps: Pick<IngestDeps, 'meta' | 'data'>, uid: string, wids: string[]): Promise<void> {
  const files = await deps.meta.deleteWorkoutData(uid, [...new Set(wids)]);
  await Promise.all(files.map((f) => deps.data.delete(f.path).catch(() => undefined)));
}

interface WrittenStream { wid: string; st: string; gen: number; ref: FileRef; points: number; unit: string | null; cols: string[]; firstT?: number }

/** Runs `jobs` with at most `limit` at a time; results in input order. */
async function pool<T>(jobs: (() => Promise<T>)[], limit: number): Promise<T[]> {
  const out: T[] = new Array(jobs.length);
  let next = 0;
  const worker = async () => {
    while (next < jobs.length) {
      const i = next++;
      out[i] = await jobs[i]!();
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, jobs.length) }, worker));
  return out;
}

/** Parallel storage writes per batch (Parquet conversion itself stays one at a time on the DuckDB connection). */
const WRITE_CONCURRENCY = 8;
/** Workout index updates per batch at once (separate documents, so they do not contend). */
const PUBLISH_CONCURRENCY = 4;

/** A `workoutdata` batch: raw streams (and completeness markers) of one or more workouts. */
async function ingestStreams(uid: string, batchId: string, objectPath: string, parsed: ParsedBatch, generation: number, deps: IngestDeps): Promise<IngestOutcome> {
  const groups = new Map<string, StreamChunk[]>();
  for (const ch of parsed.streams) {
    const key = `${ch.wid}\u0000${ch.st}\u0000${ch.gen}`;
    groups.set(key, [...(groups.get(key) ?? []), ch]);
  }
  const written: WrittenStream[] = [];
  await withDuck(async (c, dir) => {
    // Conversions run one after another on the connection; each file is uploaded while the next is converted.
    const uploads: Promise<void>[] = [];
    const slots = new Set<Promise<void>>();
    let i = 0;
    for (const chunks of groups.values()) {
      const first = chunks[0]!;
      const local = await streamToParquet(c, dir, chunks, `s${i++}`);
      const path = streamPath(uid, first.wid, first.st, first.gen, batchId);
      const bytes = await readFile(local.path);
      let firstT = Infinity;
      for (const ch of chunks) for (const t of ch.t) if (t < firstT) firstT = t;
      written.push({
        wid: first.wid, st: first.st, gen: first.gen, points: local.points,
        ref: { path, bytes: bytes.length, ...(Object.keys(local.scale).length ? { scale: local.scale } : {}) },
        unit: first.unit,
        cols: [...new Set(chunks.flatMap((ch) => Object.keys(ch.cols)))],
        ...(Number.isFinite(firstT) ? { firstT } : {}),
      });
      while (slots.size >= WRITE_CONCURRENCY) await Promise.race(slots);
      const job: Promise<void> = deps.data.write(path, bytes).finally(() => slots.delete(job));
      slots.add(job);
      uploads.push(job);
    }
    await Promise.all(uploads);
  }, { memoryLimit: '384MB' });

  const now = (deps.now ?? Date.now)();
  const wids = [...new Set([...written.map((w) => w.wid), ...parsed.marks.map((m) => m.wid)])];
  let result: IngestOutcome = 'published';
  let discarded = false;
  await pool(wids.map((wid) => async () => {
    if (discarded) return;
    let outcome: ReturnType<typeof applyWorkoutData> | undefined;
    const mine = written.filter((w) => w.wid === wid);
    const r = await deps.meta.publishWorkoutData({
      uid,
      wid,
      // One publish per workout, each idempotent on its own id, so an event retry is harmless.
      batchId: `${batchId}.${wid}`,
      generation,
      userPatch: { lastVisibleAt: now, ...(parsed.header.tz ? { tz: parsed.header.tz } : {}) },
      mutate: (doc) => {
        outcome = applyWorkoutData(doc, mine, parsed.marks.filter((m) => m.wid === wid), now);
        return outcome.doc;
      },
    });
    if (r === 'discarded') {
      discarded = true;
      return;
    }
    if (r === 'published' && outcome) {
      await Promise.all([...outcome.superseded, ...outcome.ignored].map((f) => deps.data.delete(f.path).catch(() => undefined)));
    }
  }), PUBLISH_CONCURRENCY);
  if (discarded) {
    // The user was deleted (or reset) meanwhile: remove what this batch wrote.
    await Promise.all(written.map((w) => deps.data.delete(w.ref.path).catch(() => undefined)));
    result = 'discarded';
  }
  await deps.meta.markBatch(uid, batchId, result === 'discarded' ? 'discarded' : 'published');
  await deps.incoming.delete(objectPath).catch(() => undefined);
  log.info('batch processed', { uid, batchId, type: parsed.header.type, result, workouts: wids.length, streams: written.length, mode: 'workoutdata', readMs: parsed.header.perf?.readMs, uploadMs: parsed.header.perf?.uploadMs });
  return result;
}

/**
 * Pure update of one workout's raw-data index (exported for tests). A newer generation of a stream
 * replaces the older files; a stale one is ignored. `rawComplete` needs every stream promised by
 * the latest `wd` marker to have arrived in full at that generation.
 */
export function applyWorkoutData(
  doc: WorkoutDataDoc,
  written: WrittenStream[],
  marks: { gen: number; expected: Record<string, number> }[],
  now: number,
): { doc: WorkoutDataDoc; superseded: FileRef[]; ignored: FileRef[] } {
  const streams: Record<string, StreamInfo> = { ...doc.streams };
  const superseded: FileRef[] = [];
  const ignored: FileRef[] = [];
  for (const w of written) {
    const cur = streams[w.st];
    if (!cur || w.gen > cur.gen) {
      if (cur) superseded.push(...cur.files);
      streams[w.st] = { gen: w.gen, files: [w.ref], points: w.points, unit: w.unit, cols: w.cols };
    } else if (w.gen === cur.gen) {
      if (cur.files.some((f) => f.path === w.ref.path)) continue;
      streams[w.st] = { ...cur, files: [...cur.files, w.ref], points: cur.points + w.points, unit: cur.unit ?? w.unit, cols: [...new Set([...cur.cols, ...w.cols])] };
    } else {
      ignored.push(w.ref);
    }
  }
  let expected = doc.expected;
  let expectedGen = doc.expectedGen;
  for (const m of marks) {
    if (expectedGen === null || m.gen >= expectedGen) {
      expected = m.expected;
      expectedGen = m.gen;
    }
  }
  if (expected && expectedGen !== null) {
    // Streams of an older generation that the phone no longer reports (e.g. the workout was edited).
    for (const [name, s] of Object.entries(streams)) {
      if (s.gen < expectedGen && !(name in expected)) {
        superseded.push(...s.files);
        delete streams[name];
      }
    }
  }
  const rawComplete = !!expected && expectedGen !== null && Object.entries(expected).every(([name, n]) => streams[name]?.gen === expectedGen && streams[name]!.points >= n);
  let firstT = doc.firstT ?? null;
  for (const w of written) if (w.firstT !== undefined && (firstT === null || w.firstT < firstT)) firstT = w.firstT;
  return { doc: { ...doc, version: doc.version + 1, streams, expected, expectedGen, rawComplete, updatedAt: now, firstT }, superseded, ignored };
}

/** A `status` batch: many types checked with nothing new. Updates each type's freshness (and
 *  marks it fully synced when `caughtUp`) without writing any data files. */
async function ingestStatus(uid: string, batchId: string, objectPath: string, parsed: ParsedBatch, generation: number, deps: IngestDeps): Promise<IngestOutcome> {
  const now = (deps.now ?? Date.now)();
  let result: IngestOutcome = 'published';
  for (const [i, st] of parsed.statuses.entries()) {
    const r = await deps.meta.publish({
      uid,
      type: st.type,
      // One publish per type, each idempotent on its own id, so an event retry is harmless.
      batchId: `${batchId}.${i}`,
      generation,
      userPatch: { lastVisibleAt: now, ...(parsed.header.tz ? { tz: parsed.header.tz } : {}) },
      mutate: (man) => applyStatus(man, st, now),
    });
    if (r === 'discarded') {
      result = 'discarded';
      break;
    }
  }
  await deps.meta.markBatch(uid, batchId, result === 'discarded' ? 'discarded' : 'published');
  await deps.incoming.delete(objectPath).catch(() => undefined);
  log.info('batch processed', { uid, batchId, type: parsed.header.type, result, types: parsed.statuses.length, mode: 'status', readMs: parsed.header.perf?.readMs, uploadMs: parsed.header.perf?.uploadMs });
  return result;
}

/** Pure manifest update for one status entry (exported for tests). */
export function applyStatus(man: TypeManifest, st: { at: number; caughtUp: boolean }, now: number): TypeManifest {
  const cov = { ...man.coverage };
  if (st.caughtUp) {
    cov.caughtUp = true;
    cov.intervals = addInterval(cov.intervals, [0, st.at]);
  }
  cov.checkedAt = Math.max(cov.checkedAt ?? 0, st.at);
  cov.visibleAt = now;
  return { ...man, version: man.version + 1, coverage: cov };
}

/** Pure manifest update for one batch (exported for tests). */
export function applyBatch(man: TypeManifest, parsed: ParsedBatch, written: Record<string, FileRef>, now: number): TypeManifest {
  const { header, span } = parsed;
  const files = { ...man.files };
  for (const [partition, ref] of Object.entries(written)) {
    const list = files[partition] ?? [];
    if (!list.some((f) => f.path === ref.path)) files[partition] = [...list, ref];
  }
  const cov = { ...man.coverage };
  const statsOnly = header.mode === 'stats';
  if (header.window) {
    const iv: [number, number] = [header.window.start, header.window.end];
    if (statsOnly) cov.statsIntervals = addInterval(cov.statsIntervals, iv);
    else cov.intervals = addInterval(cov.intervals, iv);
  }
  if (header.caughtUp && !statsOnly && (header.mode === 'anchored' || header.mode === 'reconcile')) {
    cov.caughtUp = true;
    // The anchored pass has now delivered everything up to the moment it was read.
    cov.intervals = addInterval(cov.intervals, [0, header.checkedAt ?? header.createdAt]);
  }
  if (span) {
    cov.earliest = cov.earliest === null ? span.start : Math.min(cov.earliest, span.start);
    cov.latest = cov.latest === null ? span.end : Math.max(cov.latest, span.end);
  }
  if (header.checkedAt) cov.checkedAt = Math.max(cov.checkedAt ?? 0, header.checkedAt);
  cov.visibleAt = now;
  const startingReconcile = !!header.reconcileId && man.reconcileId !== header.reconcileId;
  const reconcileActive = header.reconcileId && !header.reconcileDone;
  return {
    ...man,
    version: man.version + 1,
    files,
    coverage: cov,
    records: man.records + parsed.recordCount,
    reconcileId: header.reconcileId ? (reconcileActive ? header.reconcileId : null) : man.reconcileId ?? null,
    reconcileStartSeq: header.reconcileId
      ? startingReconcile ? header.seq : man.reconcileStartSeq ?? header.seq
      : man.reconcileStartSeq ?? null,
    fragmented: Object.entries(files).some(([k, f]) => k !== '_tombstones' && f.length > COMPACT_THRESHOLD),
  };
}

/** Partitions with more files than this get merged by the daily compaction job. */
export const COMPACT_THRESHOLD = 8;
