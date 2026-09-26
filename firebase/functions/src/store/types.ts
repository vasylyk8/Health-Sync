/** Storage and metadata abstractions, so ingestion and tools are testable without the cloud. */

export interface BlobStore {
  read(path: string): Promise<Buffer>;
  write(path: string, data: Buffer): Promise<void>;
  /** Downloads to a local file path (streams for large objects). */
  download(path: string, localPath: string): Promise<void>;
  deletePrefix(prefix: string): Promise<void>;
  delete(path: string): Promise<void>;
}

export type Interval = [number, number];

export interface Coverage {
  /** Time ranges (UTC ms) known to be fully synced for this type. */
  intervals: Interval[];
  /** Time ranges covered by merged hourly statistics (usually all history, early). */
  statsIntervals: Interval[];
  /** True once the anchored full-history pass reached the end. */
  caughtUp: boolean;
  earliest: number | null;
  latest: number | null;
  /** Last time the phone successfully read this type (even if nothing new). */
  checkedAt: number | null;
  /** When the most recent data became queryable. */
  visibleAt: number | null;
}

export interface FileRef {
  path: string;
  bytes: number;
}

export interface TypeManifest {
  type: string;
  version: number;
  /** Partition key ("2024-03", "_profile", "_tombstones") -> files. */
  files: Record<string, FileRef[]>;
  coverage: Coverage;
  records: number;
  /** Active reconcile pass, if any, and the upload sequence number it started at. */
  reconcileId?: string | null;
  reconcileStartSeq?: number | null;
  /** Set when some partition has accumulated enough files to be worth compacting. */
  fragmented?: boolean;
}

export interface UserDoc {
  generation: number;
  deleting: boolean;
  createdAt: number;
  lastVisibleAt: number | null;
  tz: string | null;
  connections: Partial<Record<string, { setUpAt: number; lastUsedAt: number }>>;
  links: Partial<Record<string, { tokenHash: string; createdAt: number }>>;
}

export type BatchState = 'published' | 'rejected' | 'discarded';

export interface MetaStore {
  getUser(uid: string): Promise<UserDoc | null>;
  getManifest(uid: string, type: string): Promise<TypeManifest | null>;
  listManifests(uid: string): Promise<TypeManifest[]>;
  /** Final state of a batch, or null if it has not been finished yet. */
  batchState(uid: string, batchId: string): Promise<BatchState | null>;
  markBatch(uid: string, batchId: string, state: BatchState, detail?: string): Promise<void>;
  /**
   * In one transaction: if the user still exists with `generation`, is not being deleted and the
   * batch is not already published, applies `mutate` to the type manifest, marks the batch
   * published and applies `userPatch`. Otherwise records why and changes nothing.
   */
  publish(args: {
    uid: string;
    type: string;
    batchId: string;
    generation: number;
    mutate: (m: TypeManifest) => TypeManifest;
    userPatch?: Partial<Pick<UserDoc, 'lastVisibleAt' | 'tz'>>;
  }): Promise<'published' | 'duplicate' | 'discarded'>;
  /**
   * Compaction: atomically removes `removed` paths from a partition and adds `added`, keeping any
   * files published meanwhile. Returns false (no change) if some removed path is already gone.
   */
  swapFiles(uid: string, type: string, partition: string, removed: string[], added: FileRef | null): Promise<boolean>;
}

export function emptyManifest(type: string): TypeManifest {
  return {
    type,
    version: 0,
    files: {},
    coverage: { intervals: [], statsIntervals: [], caughtUp: false, earliest: null, latest: null, checkedAt: null, visibleAt: null },
    records: 0,
    reconcileId: null,
    reconcileStartSeq: null,
    fragmented: false,
  };
}

/** Merge a new interval into a sorted, non-overlapping list (touching intervals are joined). */
export function addInterval(list: Interval[], iv: Interval): Interval[] {
  const all = [...list, iv].sort((a, b) => a[0] - b[0]);
  const out: Interval[] = [];
  for (const cur of all) {
    const last = out[out.length - 1];
    if (last && cur[0] <= last[1]) last[1] = Math.max(last[1], cur[1]);
    else out.push([cur[0], cur[1]]);
  }
  return out;
}

/** True if [start, end] lies entirely inside the union of intervals. */
export function covers(list: Interval[], start: number, end: number): boolean {
  return list.some(([a, b]) => a <= start && end <= b);
}
