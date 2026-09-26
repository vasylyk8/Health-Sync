import { FieldPath, type Firestore } from 'firebase-admin/firestore';
import type { Bucket } from '@google-cloud/storage';
import { emptyManifest, type BatchState, type BlobStore, type FileRef, type MetaStore, type TypeManifest, type UserDoc } from './types.js';

/** Firestore document ids cannot contain '/'; HealthKit ids never do, but guard anyway. */
const typeDocId = (type: string) => type.replace(/\//g, '_');

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
    return snap.exists ? (snap.data() as TypeManifest) : null;
  }

  async listManifests(uid: string): Promise<TypeManifest[]> {
    const snap = await this.user(uid).collection('types').get();
    return snap.docs.map((d) => d.data() as TypeManifest);
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
      const current = manSnap.exists ? (manSnap.data() as TypeManifest) : emptyManifest(type);
      tx.set(manRef, mutate(current));
      tx.set(batchRef, { state: 'published', at: Date.now(), expireAt: new Date(Date.now() + 30 * 86_400_000) });
      if (userPatch && Object.keys(userPatch).length) tx.update(userRef, userPatch);
      return 'published';
    });
  }

  async swapFiles(uid: string, type: string, partition: string, removed: string[], added: FileRef | null): Promise<boolean> {
    const manRef = this.user(uid).collection('types').doc(typeDocId(type));
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(manRef);
      if (!snap.exists) return false;
      const man = snap.data() as TypeManifest;
      const list = man.files[partition] ?? [];
      const paths = new Set(list.map((f) => f.path));
      if (!removed.every((p) => paths.has(p))) return false;
      const drop = new Set(removed);
      const next = list.filter((f) => !drop.has(f.path));
      if (added) next.push(added);
      tx.update(manRef, new FieldPath('files', partition), next, 'version', man.version + 1);
      return true;
    });
  }
}

export class GcsBlobs implements BlobStore {
  constructor(private readonly bucket: Bucket) {}
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
  async deletePrefix(prefix: string) {
    await this.bucket.deleteFiles({ prefix, force: true });
  }
}
