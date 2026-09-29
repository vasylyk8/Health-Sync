import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { effectiveUserPatch, emptyManifest, emptyWorkoutData, type WorkoutDataDoc, type BatchState, type BlobStore, type FileRef, type MetaStore, type TypeManifest, type UserDoc } from '../../src/store/types.js';
import { ingestObject } from '../../src/ingest/ingest.js';

/** Blob store backed by a temp directory. */
export class DirBlobs implements BlobStore {
  readonly root = mkdtempSync(join(tmpdir(), 'blobs-'));
  paths = new Set<string>();
  async read(path: string) { return readFile(join(this.root, path)); }
  async write(path: string, data: Buffer) {
    await mkdir(dirname(join(this.root, path)), { recursive: true });
    await writeFile(join(this.root, path), data);
    this.paths.add(path);
  }
  async download(path: string, local: string) { await copyFile(join(this.root, path), local); }
  async delete(path: string) { this.paths.delete(path); }
  async exists(path: string) { return this.paths.has(path); }
  async deletePrefix(prefix: string) { for (const p of [...this.paths]) if (p.startsWith(prefix)) this.paths.delete(p); }
}

/** In-memory metadata store with the same transactional semantics as FirestoreMeta. */
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

export interface Env { incoming: DirBlobs; data: DirBlobs; meta: MemoryMeta; uid: string; now: number }

export function makeEnv(now = Date.UTC(2024, 5, 30, 12)): Env {
  const env = { incoming: new DirBlobs(), data: new DirBlobs(), meta: new MemoryMeta(), uid: 'user1', now };
  env.meta.addUser(env.uid);
  return env;
}

let seq = 0;
export interface UploadOpts {
  type: string;
  mode?: 'anchored' | 'recent' | 'stats' | 'profile' | 'reconcile' | 'status' | 'workoutdata';
  schema?: 1 | 2;
  window?: { start: number; end: number };
  caughtUp?: boolean;
  checkedAt?: number;
  tz?: string;
  reconcileId?: string;
  reconcileDone?: boolean;
  uid?: string;
  batchId?: string;
}

export function makeBatch(env: Env, opts: UploadOpts, records: object[]): { path: string; gz: Buffer; batchId: string } {
  const batchId = opts.batchId ?? randomUUID();
  const header = {
    kind: 'header', schema: opts.schema ?? (opts.type === '_wstream' || opts.type === '_daily' ? 2 : 1), batchId, type: opts.type, seq: ++seq, tz: opts.tz ?? 'UTC', createdAt: env.now,
    mode: opts.mode ?? 'anchored', checkedAt: opts.checkedAt ?? env.now,
    ...(opts.window ? { window: opts.window } : {}),
    ...(opts.caughtUp !== undefined ? { caughtUp: opts.caughtUp } : {}),
    ...(opts.reconcileId ? { reconcileId: opts.reconcileId, reconcileDone: !!opts.reconcileDone } : {}),
  };
  const gz = gzipSync([header, ...records].map((r) => JSON.stringify(r)).join('\n'));
  return { path: `incoming/${opts.uid ?? env.uid}/${batchId}.ndjson.gz`, gz, batchId };
}

export async function upload(env: Env, opts: UploadOpts, records: object[]) {
  const b = makeBatch(env, opts, records);
  await env.incoming.write(b.path, b.gz);
  const result = await ingestObject(b.path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
  return { ...b, result };
}

export const deps = (env: Env, tz = 'UTC') => ({ uid: env.uid, meta: env.meta, data: env.data, now: () => env.now, tz });
