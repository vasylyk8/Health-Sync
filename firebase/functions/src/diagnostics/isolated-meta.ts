import { effectiveUserPatch, emptyManifest, emptyWorkoutData, type WorkoutDataDoc, type BatchState, type FileRef, type MetaStore, type TypeManifest, type UserDoc } from '../store/types.js';

/** Request-local diagnostic metadata only; never connected to Firestore. */
export class MemoryMeta implements MetaStore {
  users = new Map<string, UserDoc>();
  manifests = new Map<string, TypeManifest>();
  batches = new Map<string, { state: BatchState; detail?: string }>();
  workoutData = new Map<string, WorkoutDataDoc>();
  addUser(uid: string, patch: Partial<UserDoc> = {}) {
    this.users.set(uid, { generation: 1, deleting: false, createdAt: 0, lastVisibleAt: null, tz: 'UTC', connections: {}, links: {}, ...patch });
  }
  async getUser(uid: string) { return this.users.get(uid) ?? null; }
  async getManifest(uid: string, type: string) { return structuredClone(this.manifests.get(`${uid}/${type}`) ?? null); }
  async listManifests(uid: string) { return [...this.manifests.entries()].filter(([k]) => k.startsWith(uid + '/')).map(([, v]) => structuredClone(v)); }
  async batchState(uid: string, batchId: string) { return this.batches.get(`${uid}/${batchId}`)?.state ?? null; }
  async markBatch(uid: string, batchId: string, state: BatchState, detail?: string) { this.batches.set(`${uid}/${batchId}`, { state, detail }); }
  async publish({ uid, type, batchId, generation, mutate, userPatch }: Parameters<MetaStore['publish']>[0]) {
    const user = this.users.get(uid);
    if (!user || user.deleting || user.generation !== generation) return 'discarded' as const;
    if (this.batches.get(`${uid}/${batchId}`)?.state === 'published') return 'duplicate' as const;
    const cur = this.manifests.get(`${uid}/${type}`) ?? emptyManifest(type);
    this.manifests.set(`${uid}/${type}`, mutate(structuredClone(cur)));
    this.batches.set(`${uid}/${batchId}`, { state: 'published' });
    Object.assign(user, effectiveUserPatch(user, userPatch));
    return 'published' as const;
  }
  async deleteManifest(uid: string, type: string) { this.manifests.delete(`${uid}/${type}`); }
  async getWorkoutData(uid: string, wid: string) { return structuredClone(this.workoutData.get(`${uid}/${wid}`) ?? null); }
  async listWorkoutData(uid: string) { return [...this.workoutData.entries()].filter(([k]) => k.startsWith(uid + '/')).map(([, v]) => structuredClone(v)); }
  async publishWorkoutData({ uid, wid, batchId, generation, mutate, userPatch }: Parameters<MetaStore['publishWorkoutData']>[0]) {
    const user = this.users.get(uid);
    if (!user || user.deleting || user.generation !== generation) return 'discarded' as const;
    if (this.batches.get(`${uid}/${batchId}`)?.state === 'published') return 'duplicate' as const;
    const cur = this.workoutData.get(`${uid}/${wid}`) ?? emptyWorkoutData(wid);
    this.workoutData.set(`${uid}/${wid}`, mutate(structuredClone(cur)));
    this.batches.set(`${uid}/${batchId}`, { state: 'published' });
    Object.assign(user, effectiveUserPatch(user, userPatch));
    return 'published' as const;
  }
  async deleteWorkoutData(uid: string, wids: string[]) {
    const files: FileRef[] = [];
    for (const wid of wids) {
      const d = this.workoutData.get(`${uid}/${wid}`);
      if (!d) continue;
      for (const s of Object.values(d.streams)) files.push(...s.files);
      this.workoutData.delete(`${uid}/${wid}`);
    }
    return files;
  }
  async swapFiles(uid: string, type: string, partition: string, removed: string[], added: FileRef | null) {
    const man = this.manifests.get(`${uid}/${type}`);
    if (!man) return false;
    const list = man.files[partition] ?? [];
    if (!removed.every((p) => list.some((f) => f.path === p))) return false;
    man.files[partition] = [...list.filter((f) => !removed.includes(f.path)), ...(added ? [added] : [])];
    man.version++;
    man.fragmented = Object.entries(man.files).some(([k, f]) => k !== '_tombstones' && f.length > 8);
    return true;
  }
}
