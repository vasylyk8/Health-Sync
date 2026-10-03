/** Storage and metadata abstractions, so ingestion and tools are testable without the cloud. */

export interface BlobStore {
  read(path: string): Promise<Buffer>;
  write(path: string, data: Buffer): Promise<void>;
  /** Downloads to a local file path (streams for large objects). */
  download(path: string, localPath: string): Promise<void>;
  deletePrefix(prefix: string): Promise<void>;
  /** Object names starting with `prefix`. */
  list(prefix: string): Promise<string[]>;
  /** Bounded existence check, avoiding an unbounded listing on the query path. */
  hasAny?(prefix: string): Promise<boolean>;
  delete(path: string): Promise<void>;
  exists(path: string): Promise<boolean>;
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
  /**
   * Raw stream files only: columns stored as integers X with the real value X / scale[col] (delta-encoded
   * integers are several times smaller than doubles). A column not listed here is a plain DOUBLE column.
   */
  scale?: Record<string, number>;
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
  /** Consent categories the user switched on (see CATEGORIES in config.ts); missing = the defaults. */
  categories?: string[];
  generation: number;
  deleting: boolean;
  createdAt: number;
  lastVisibleAt: number | null;
  tz: string | null;
  connections: Partial<Record<string, { setUpAt: number; lastUsedAt: number }>>;
  links: Partial<Record<string, { tokenHash: string; createdAt: number }>>;
  oauthEpochs?: Partial<Record<string, number>>;
  oauthProfileId?: string;
  /** Product milestones only. Never contains Health values, free text, or external identity data. */
  analytics?: {
    firstOpenedAt?: number;
    healthConnectStartedAt?: number;
    healthConnectedAt?: number;
    appleLinkedAt?: number;
    firstSyncReadyAt?: number;
    assistantConnectedAt?: number;
    activatedAt?: number;
    activationProvider?: string;
    appVersion?: string;
  };
}

export type BatchState = 'published' | 'rejected' | 'discarded';

/** One raw data stream (heart rate, route, ...) of a workout, as stored in Parquet. */
export interface StreamInfo {
  /** Generation of the phone-side read that wrote these files; a newer one replaces older files. */
  gen: number;
  files: FileRef[];
  points: number;
  unit: string | null;
  /** Value columns present (v, lat, lon, alt, spd, crs, ha, va). */
  cols: string[];
}

/** Index of the raw data uploaded for one workout (Firestore: users/{uid}/workouts/{wid}). */
export interface WorkoutDataDoc {
  wid: string;
  version: number;
  streams: Record<string, StreamInfo>;
  /** What the phone said it would send (stream -> point count) for generation `expectedGen`. */
  expected: Record<string, number> | null;
  expectedGen: number | null;
  /** True once every expected stream of `expectedGen` has arrived in full. */
  rawComplete: boolean;
  updatedAt: number;
  /** Earliest raw-data timestamp (UTC ms), to find the workout's summary partition without scanning all. */
  firstT?: number | null;
}

export function emptyWorkoutData(wid: string): WorkoutDataDoc {
  return { wid, version: 0, streams: {}, expected: null, expectedGen: null, rawComplete: false, updatedAt: 0, firstT: null };
}

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
  getWorkoutData(uid: string, wid: string): Promise<WorkoutDataDoc | null>;
  listWorkoutData(uid: string): Promise<WorkoutDataDoc[]>;
  /** Like `publish`, but for one workout's raw-data index. `batchId` must be unique per workout. */
  publishWorkoutData(args: {
    uid: string;
    wid: string;
    batchId: string;
    generation: number;
    mutate: (d: WorkoutDataDoc) => WorkoutDataDoc;
    userPatch?: Partial<Pick<UserDoc, 'lastVisibleAt' | 'tz'>>;
  }): Promise<'published' | 'duplicate' | 'discarded'>;
  /** Removes one type's manifest (used when a data type is no longer synced). */
  deleteManifest(uid: string, type: string): Promise<void>;
  /** Removes the raw-data index of deleted workouts and returns the files it referenced. */
  deleteWorkoutData(uid: string, wids: string[]): Promise<FileRef[]>;
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
/** "Last updated" is written at most once a minute: every publish touches the user doc, and
 *  parallel uploads would otherwise contend on it (Firestore sustains ~1 write/s per doc). */
export const LAST_VISIBLE_MIN_STEP_MS = 60_000;

export function effectiveUserPatch(user: UserDoc, patch: Partial<Pick<UserDoc, 'lastVisibleAt' | 'tz'>> | undefined) {
  const out: Partial<Pick<UserDoc, 'lastVisibleAt' | 'tz'>> = {};
  if (!patch) return out;
  if (patch.tz !== undefined && patch.tz !== user.tz) out.tz = patch.tz;
  if (patch.lastVisibleAt != null && (user.lastVisibleAt == null || patch.lastVisibleAt - user.lastVisibleAt >= LAST_VISIBLE_MIN_STEP_MS)) {
    out.lastVisibleAt = patch.lastVisibleAt;
  }
  return out;
}

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
