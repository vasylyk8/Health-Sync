import { readFile, stat } from 'node:fs/promises';
import { BatchError, parseBatch, type ParsedBatch } from './batch.js';
import { idsToParquet, rowsToParquet, withDuck } from '../query/duck.js';
import { addInterval, type BlobStore, type FileRef, type MetaStore, type TypeManifest } from '../store/types.js';
import { log } from '../log.js';

export interface IngestDeps {
  incoming: BlobStore;
  data: BlobStore;
  meta: MetaStore;
  now?: () => number;
  /** Called when a reconcile pass completes, to compute deletions missed while offline. */
  onReconcileDone?: (uid: string, type: string, reconcileId: string) => Promise<void>;
}

export type IngestOutcome = 'published' | 'duplicate' | 'discarded' | 'rejected' | 'ignored';

const INCOMING_RE = /^incoming\/([A-Za-z0-9]{1,128})\/([0-9a-f-]{36})\.ndjson\.gz$/;

export const dataPath = (uid: string, type: string, partition: string, batchId: string) =>
  `data/${uid}/${type}/${partition}/${batchId}.parquet`;

/**
 * Processes one uploaded batch: validate → write Parquet partitions → publish the manifest
 * atomically. Safe to run more than once for the same object (event retries).
 */
export async function ingestObject(objectPath: string, deps: IngestDeps): Promise<IngestOutcome> {
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
    parsed = parseBatch(await incoming.read(objectPath));
    if (parsed.header.batchId !== batchId) throw new BatchError('batchId does not match file name');
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
  const type = header.type;
  const written: Record<string, FileRef> = {};

  await withDuck(async (c, dir) => {
    let i = 0;
    for (const [partition, rows] of parsed.partitions) {
      const local = await rowsToParquet(c, dir, rows, `p${i++}`);
      const path = dataPath(uid, type, partition, batchId);
      await data.write(path, await readFile(local));
      written[partition] = { path, bytes: (await stat(local)).size };
    }
    if (parsed.tombstones.length) {
      const local = await idsToParquet(c, dir, parsed.tombstones, 'tomb');
      const path = dataPath(uid, type, '_tombstones', batchId);
      await data.write(path, await readFile(local));
      written._tombstones = { path, bytes: (await stat(local)).size };
    }
  });

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

  if (result === 'published' && header.reconcileId && header.reconcileDone && deps.onReconcileDone) {
    await deps.onReconcileDone(uid, type, header.reconcileId);
  }
  log.info('batch processed', { uid, batchId, type, result, records: parsed.recordCount });
  return result;
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
  if (span && !statsOnly) {
    cov.earliest = cov.earliest === null ? span.start : Math.min(cov.earliest, span.start);
    cov.latest = cov.latest === null ? span.end : Math.max(cov.latest, span.end);
  }
  if (header.checkedAt) cov.checkedAt = Math.max(cov.checkedAt ?? 0, header.checkedAt);
  cov.visibleAt = now;
  return {
    ...man,
    version: man.version + 1,
    files,
    coverage: cov,
    records: man.records + parsed.recordCount,
    reconcileId: header.reconcileId && !header.reconcileDone ? header.reconcileId : header.reconcileDone ? null : man.reconcileId ?? null,
  };
}
