import { readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { lit, withDuck } from '../query/duck.js';
import { dataPath, dropWorkoutData } from '../ingest/ingest.js';
import { WORKOUT_TYPE } from '../ingest/batch.js';
import type { BlobStore, MetaStore } from '../store/types.js';
import { log } from '../log.js';

interface Deps {
  meta: MetaStore;
  data: BlobStore;
}

/**
 * After a full reconcile pass, anything we still hold that the phone did not re-send was deleted
 * on the phone while we were not listening (HealthKit expires deletion records). Only rows
 * uploaded before the pass started are considered, so changes made during the pass are safe.
 */
export async function finishReconcile(deps: Deps, uid: string, type: string, reconcileId: string): Promise<number> {
  const man = await deps.meta.getManifest(uid, type);
  const user = await deps.meta.getUser(uid);
  if (!man || !user || man.reconcileStartSeq === null || man.reconcileStartSeq === undefined) return 0;
  const startSeq = man.reconcileStartSeq;
  const files = Object.entries(man.files).filter(([k]) => !k.startsWith('_')).flatMap(([, f]) => f);
  if (!files.length) return 0;
  return withDuck(async (c, dir) => {
    const local = await Promise.all(files.map(async (f, i) => {
      const p = join(dir, `f${i}.parquet`);
      await deps.data.download(f.path, p);
      return p;
    }));
    const out = join(dir, 'tomb.parquet');
    await c.run(`COPY (
        SELECT split_part(id, '#', 1) AS id FROM read_parquet([${local.map(lit).join(',')}], union_by_name=true)
        WHERE id IS NOT NULL
        GROUP BY 1
        HAVING max(seq) < ${startSeq} AND count(*) FILTER (WHERE rid = ${lit(reconcileId)}) = 0
      ) TO ${lit(out)} (FORMAT parquet)`);
    const n = Number((await c.runAndReadAll(`SELECT count(*) FROM ${lit(out)}`)).getRows()[0]![0]);
    if (n === 0) return 0;
    const path = dataPath(uid, type, '_tombstones', `reconcile-${reconcileId}`);
    await deps.data.write(path, await readFile(out));
    const bytes = (await stat(out)).size;
    const res = await deps.meta.publish({
      uid, type, batchId: reconcileId, generation: user.generation,
      mutate: (m) => ({ ...m, version: m.version + 1, files: { ...m.files, _tombstones: [...(m.files._tombstones ?? []).filter((f) => f.path !== path), { path, bytes }] } }),
    });
    if (res === 'published' && type === WORKOUT_TYPE) {
      const ids = (await c.runAndReadAll(`SELECT id FROM read_parquet(${lit(out)})`)).getRows().map((r) => String(r[0]));
      await dropWorkoutData(deps, uid, ids);
    }
    log.info('reconcile finished', { uid, type, removed: n, result: res });
    return n;
  });
}

/**
 * Merges the files of fragmented partitions into one: latest version of each record wins and
 * deleted records are dropped. Publishes by swapping the file list, then deletes old files.
 */
export async function compactType(deps: Deps, uid: string, type: string): Promise<number> {
  const man = await deps.meta.getManifest(uid, type);
  if (!man) return 0;
  const tomb = man.files._tombstones ?? [];
  let compacted = 0;
  for (const [partition, files] of Object.entries(man.files)) {
    if (partition.startsWith('_')) continue;
    if (files.length < 2) continue;
    await withDuck(async (c, dir) => {
      const local = await Promise.all([...files, ...tomb].map(async (f, i) => {
        const p = join(dir, `f${i}.parquet`);
        await deps.data.download(f.path, p);
        return p;
      }));
      const dataFiles = local.slice(0, files.length).map(lit).join(',');
      const tombFiles = local.slice(files.length).map(lit).join(',');
      const out = join(dir, 'merged.parquet');
      const dropDeleted = tombFiles ? `AND split_part(id, '#', 1) NOT IN (SELECT id FROM read_parquet([${tombFiles}]))` : '';
      await c.run(`COPY (
          SELECT * FROM read_parquet([${dataFiles}], union_by_name=true) WHERE true ${dropDeleted}
          QUALIFY row_number() OVER (PARTITION BY id ORDER BY seq DESC, batch DESC) = 1
          ORDER BY s
        ) TO ${lit(out)} (FORMAT parquet, COMPRESSION zstd)`);
      const path = dataPath(uid, type, partition, `compact-${Date.now()}`);
      await deps.data.write(path, await readFile(out));
      const ok = await deps.meta.swapFiles(uid, type, partition, files.map((f) => f.path), { path, bytes: (await stat(out)).size });
      if (ok) {
        await Promise.all(files.map((f) => deps.data.delete(f.path).catch(() => undefined)));
        compacted++;
      } else {
        await deps.data.delete(path).catch(() => undefined);
      }
    });
  }
  log.info('compacted', { uid, type, count: compacted });
  return compacted;
}
