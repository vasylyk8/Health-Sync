import { DAILY_TYPE, WORKOUT_TYPE } from '../ingest/batch.js';
import type { BlobStore, MetaStore } from '../store/types.js';
import { log } from '../log.js';

/** Manifest types that stay: workouts and daily context (raw streams have no manifest). */
export const KEEP_TYPES: ReadonlySet<string> = new Set([WORKOUT_TYPE, DAILY_TYPE]);
/** Folders under data/{uid}/ that stay. */
export const KEEP_DIRS: ReadonlySet<string> = new Set([WORKOUT_TYPE, DAILY_TYPE, 'wstream']);

export interface LegacyDeps {
  meta: MetaStore;
  data: BlobStore;
  /** Where copies go before anything is deleted (a separate bucket with a short lifecycle). */
  backup?: BlobStore;
}

export interface LegacyType {
  type: string;
  files: string[];
  hasManifest: boolean;
}

export interface LegacyPlan {
  uid: string;
  types: LegacyType[];
  totalFiles: number;
}

const dirOf = (uid: string, name: string) => name.slice(`data/${uid}/`.length).split('/')[0] ?? '';

/**
 * Finds everything the app no longer syncs: manifests and Parquet folders of every type other
 * than workouts, daily context and raw workout streams. Read-only.
 */
export async function planLegacyCleanup(deps: Pick<LegacyDeps, 'meta' | 'data'>, uid: string): Promise<LegacyPlan> {
  const byType = new Map<string, LegacyType>();
  const entry = (type: string) => {
    let e = byType.get(type);
    if (!e) byType.set(type, (e = { type, files: [], hasManifest: false }));
    return e;
  };
  for (const man of await deps.meta.listManifests(uid)) {
    if (!KEEP_TYPES.has(man.type)) entry(man.type).hasManifest = true;
  }
  for (const name of await deps.data.list(`data/${uid}/`)) {
    const dir = dirOf(uid, name);
    if (dir && !KEEP_DIRS.has(dir)) entry(dir).files.push(name);
  }
  const types = [...byType.values()].sort((a, b) => (a.type < b.type ? -1 : a.type > b.type ? 1 : 0));
  return { uid, types, totalFiles: types.reduce((n, t) => n + t.files.length, 0) };
}

export interface LegacyResult {
  plan: LegacyPlan;
  backedUp: number;
  deletedFiles: number;
  deletedManifests: number;
}

/**
 * Backs up, then removes, every legacy data type of one user. Order matters and is fixed:
 * copy everything → verify every copy → delete files → delete manifests → verify nothing legacy
 * is left. Any failure before the delete step leaves the server data untouched. Never touches
 * workouts, daily context, raw streams, tokens or the user document.
 */
export async function runLegacyCleanup(deps: LegacyDeps, uid: string, opts: { dryRun: boolean }): Promise<LegacyResult> {
  const plan = await planLegacyCleanup(deps, uid);
  const result: LegacyResult = { plan, backedUp: 0, deletedFiles: 0, deletedManifests: 0 };
  if (opts.dryRun || plan.types.length === 0) return result;
  if (!deps.backup) throw new Error('a backup store is required before deleting anything');

  // Keep the manifests too, so the backup can be understood (and restored) later.
  const manifests = (await deps.meta.listManifests(uid)).filter((m) => !KEEP_TYPES.has(m.type));
  await deps.backup.write(`legacy/${uid}/_manifests.json`, Buffer.from(JSON.stringify(manifests)));

  for (const t of plan.types) {
    for (const name of t.files) {
      const bytes = await deps.data.read(name);
      const dest = `legacy/${uid}/${name.slice(`data/${uid}/`.length)}`;
      await deps.backup.write(dest, bytes);
      const check = await deps.backup.read(dest);
      if (check.byteLength !== bytes.byteLength) throw new Error(`backup of ${name} does not match; nothing was deleted`);
      result.backedUp++;
    }
  }

  for (const t of plan.types) {
    for (const name of t.files) {
      await deps.data.delete(name);
      result.deletedFiles++;
    }
  }
  for (const t of plan.types) {
    if (t.hasManifest) {
      await deps.meta.deleteManifest(uid, t.type);
      result.deletedManifests++;
    }
  }

  const left = await planLegacyCleanup(deps, uid);
  if (left.types.length) throw new Error(`legacy data is still present: ${left.types.map((t) => t.type).join(', ')}`);
  log.info('legacy cleanup finished', { uid, files: result.deletedFiles, manifests: result.deletedManifests });
  return result;
}
