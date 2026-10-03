import { FieldPath, type Firestore } from 'firebase-admin/firestore';
import { COMPACT_THRESHOLD } from '../ingest/ingest.js';
import { effectiveUserPatch, emptyManifest, emptyWorkoutData, type WorkoutDataDoc, type BatchState, type BlobStore, type FileRef, type Interval, type MetaStore, type TypeManifest, type UserDoc } from './types.js';

/** Firestore document ids cannot contain '/'; HealthKit ids never do, but guard anyway. */
const typeDocId = (type: string) => type.replace(/\//g, '_');

// Firestore rejects arrays nested in arrays, so intervals are stored as {s, e} objects.
type StoredInterval = { s: number; e: number };
const packIntervals = (list: Interval[]): StoredInterval[] => list.map(([s, e]) => ({ s, e }));
const unpackIntervals = (list: (StoredInterval | Interval)[] | undefined): Interval[] =>
  (list ?? []).map((iv) => (Array.isArray(iv) ? iv : [iv.s, iv.e]));

export function toDoc(man: TypeManifest): Record<string, unknown> {
  const { intervals, statsIntervals } = man.coverage;
  return { ...man, coverage: { ...man.coverage, intervals: packIntervals(intervals), statsIntervals: packIntervals(statsIntervals) } };
}

export function fromDoc(data: Record<string, unknown>): TypeManifest {
  const man = data as unknown as TypeManifest;
  const cov = man.coverage as unknown as { intervals?: StoredInterval[]; statsIntervals?: StoredInterval[] };
  return { ...man, coverage: { ...man.coverage, intervals: unpackIntervals(cov.intervals), statsIntervals: unpackIntervals(cov.statsIntervals) } };
}

export class FirestoreMeta implements MetaStore {
  constructor(private readonly db: Firestore) {}

  private user(uid: string) {
    return this.db.collection('users').doc(uid);
  }

  async getUser(uid: string): Promise<UserDoc | null> {
    const snap = await this.user(uid).get();
    return snap.exists ? (snap.data() as UserDoc) : null;
  }

  async getManifest(uid: string, type: string): Promise<TypeManifest | null> {
    const snap = await this.user(uid).collection('types').doc(typeDocId(type)).get();
    return snap.exists ? fromDoc(snap.data()!) : null;
  }

  async listManifests(uid: string): Promise<TypeManifest[]> {
    const snap = await this.user(uid).collection('types').get();
    return snap.docs.map((d) => fromDoc(d.data()));
  }

  async batchState(uid: string, batchId: string): Promise<BatchState | null> {
    const snap = await this.user(uid).collection('batches').doc(batchId).get();
    return snap.exists ? ((snap.get('state') as BatchState) ?? null) : null;
  }

  async markBatch(uid: string, batchId: string, state: BatchState, detail?: string): Promise<void> {
    // Batch records of unknown users are kept at top level so they never create a user doc.
    const ref = (await this.user(uid).get()).exists
      ? this.user(uid).collection('batches').doc(batchId)
      : this.db.collection('orphanBatches').doc(`${uid}_${batchId}`);
    await ref.set({ state, detail: detail ?? null, at: Date.now(), expireAt: new Date(Date.now() + 30 * 86_400_000) });
  }

  async publish(args: Parameters<MetaStore['publish']>[0]): ReturnType<MetaStore['publish']> {
    const { uid, type, batchId, generation, mutate, userPatch } = args;
    const userRef = this.user(uid);
    const manRef = userRef.collection('types').doc(typeDocId(type));
    const batchRef = userRef.collection('batches').doc(batchId);
    return this.db.runTransaction(async (tx) => {
      const [userSnap, batchSnap, manSnap] = await Promise.all([tx.get(userRef), tx.get(batchRef), tx.get(manRef)]);
      const user = userSnap.data() as UserDoc | undefined;
      if (!user || user.deleting || user.generation !== generation) return 'discarded';
      if (batchSnap.get('state') === 'published') return 'duplicate';
      const current = manSnap.exists ? fromDoc(manSnap.data()!) : emptyManifest(type);
      tx.set(manRef, toDoc(mutate(current)));
      tx.set(batchRef, { state: 'published', at: Date.now(), expireAt: new Date(Date.now() + 30 * 86_400_000) });
      const patch = effectiveUserPatch(user, userPatch);
      if (patch.lastVisibleAt != null && user.analytics?.firstSyncReadyAt == null) {
        (patch as Record<string, unknown>)['analytics.firstSyncReadyAt'] = patch.lastVisibleAt;
      }
      if (Object.keys(patch).length) tx.update(userRef, patch);
      return 'published';
    });
  }

  async deleteManifest(uid: string, type: string): Promise<void> {
    await this.user(uid).collection('types').doc(typeDocId(type)).delete();
  }

  private workoutRef(uid: string, wid: string) {
    return this.user(uid).collection('workouts').doc(wid);
  }

  async getWorkoutData(uid: string, wid: string): Promise<WorkoutDataDoc | null> {
    const snap = await this.workoutRef(uid, wid).get();
    return snap.exists ? (snap.data() as WorkoutDataDoc) : null;
  }

  async listWorkoutData(uid: string): Promise<WorkoutDataDoc[]> {
    const snap = await this.user(uid).collection('workouts').get();
    return snap.docs.map((d) => d.data() as WorkoutDataDoc);
  }

  async publishWorkoutData(args: Parameters<MetaStore['publishWorkoutData']>[0]): ReturnType<MetaStore['publishWorkoutData']> {
    const { uid, wid, batchId, generation, mutate, userPatch } = args;
    const userRef = this.user(uid);
    const docRef = this.workoutRef(uid, wid);
    const batchRef = userRef.collection('batches').doc(batchId);
    return this.db.runTransaction(async (tx) => {
      const [userSnap, batchSnap, docSnap] = await Promise.all([tx.get(userRef), tx.get(batchRef), tx.get(docRef)]);
      const user = userSnap.data() as UserDoc | undefined;
      if (!user || user.deleting || user.generation !== generation) return 'discarded';
      if (batchSnap.get('state') === 'published') return 'duplicate';
      const current = docSnap.exists ? (docSnap.data() as WorkoutDataDoc) : emptyWorkoutData(wid);
      tx.set(docRef, mutate(current));
      tx.set(batchRef, { state: 'published', at: Date.now(), expireAt: new Date(Date.now() + 30 * 86_400_000) });
      const patch = effectiveUserPatch(user, userPatch);
      if (patch.lastVisibleAt != null && user.analytics?.firstSyncReadyAt == null) {
        (patch as Record<string, unknown>)['analytics.firstSyncReadyAt'] = patch.lastVisibleAt;
      }
      if (Object.keys(patch).length) tx.update(userRef, patch);
      return 'published';
    });
  }

  async deleteWorkoutData(uid: string, wids: string[]): Promise<FileRef[]> {
    const files: FileRef[] = [];
    for (const wid of wids) {
      const ref = this.workoutRef(uid, wid);
      const snap = await ref.get();
      if (!snap.exists) continue;
      for (const s of Object.values((snap.data() as WorkoutDataDoc).streams ?? {})) files.push(...s.files);
      await ref.delete();
    }
    return files;
  }

  async swapFiles(uid: string, type: string, partition: string, removed: string[], added: FileRef | null): Promise<boolean> {
    const manRef = this.user(uid).collection('types').doc(typeDocId(type));
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(manRef);
      if (!snap.exists) return false;
      const man = fromDoc(snap.data()!);
      const list = man.files[partition] ?? [];
      const paths = new Set(list.map((f) => f.path));
      if (!removed.every((p) => paths.has(p))) return false;
      const drop = new Set(removed);
      const next = list.filter((f) => !drop.has(f.path));
      if (added) next.push(added);
      const files = { ...man.files, [partition]: next };
      const fragmented = Object.entries(files).some(([k, f]) => k !== '_tombstones' && f.length > COMPACT_THRESHOLD);
      tx.update(manRef, new FieldPath('files', partition), next, 'version', man.version + 1, 'fragmented', fragmented);
      return true;
    });
  }
}

/** The subset of a Cloud Storage bucket we use (structural, to avoid CJS/ESM type clashes). */
interface BucketLike {
  file(path: string): {
    download(opts?: { destination?: string }): Promise<[Buffer]>;
    save(data: Buffer, opts: { resumable: boolean; contentType: string }): Promise<unknown>;
    delete(opts: { ignoreNotFound: boolean }): Promise<unknown>;
    exists(): Promise<[boolean]>;
  };
  deleteFiles(opts: { prefix: string; force: boolean }): Promise<unknown>;
  getFiles(opts: { prefix: string; maxResults?: number; autoPaginate?: boolean }): Promise<[{ name: string }[], ...unknown[]]>;
}

export class GcsBlobs implements BlobStore {
  constructor(private readonly bucket: BucketLike) {}
  async read(path: string) {
    const [buf] = await this.bucket.file(path).download();
    return buf;
  }
  async write(path: string, data: Buffer) {
    await this.bucket.file(path).save(data, { resumable: false, contentType: 'application/octet-stream' });
  }
  async download(path: string, localPath: string) {
    await this.bucket.file(path).download({ destination: localPath });
  }
  async delete(path: string) {
    await this.bucket.file(path).delete({ ignoreNotFound: true });
  }
  async exists(path: string) {
    const [ok] = await this.bucket.file(path).exists();
    return ok;
  }
  async list(prefix: string) {
    const [files] = await this.bucket.getFiles({ prefix });
    return files.map((f) => f.name);
  }
  async hasAny(prefix: string) {
    const [files] = await this.bucket.getFiles({ prefix, maxResults: 1, autoPaginate: false });
    return files.length > 0;
  }
  async deletePrefix(prefix: string) {
    await this.bucket.deleteFiles({ prefix, force: true });
  }
}
