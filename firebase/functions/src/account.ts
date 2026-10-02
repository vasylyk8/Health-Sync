import type { Firestore } from 'firebase-admin/firestore';
import { FieldValue } from 'firebase-admin/firestore';
import { CATEGORY_IDS, COVERAGE, DEFAULT_CATEGORIES, PROVIDERS, type Provider } from './config.js';
import { generateToken, hashToken } from './auth/tokens.js';
import type { BlobStore, MetaStore, UserDoc } from './store/types.js';
import { log } from './log.js';

export class AccountError extends Error {
  constructor(readonly code: 'invalid-argument' | 'failed-precondition' | 'not-found', message: string) {
    super(message);
  }
}

export function parseProvider(value: unknown): Provider {
  if (typeof value !== 'string' || !(PROVIDERS as readonly string[]).includes(value)) {
    throw new AccountError('invalid-argument', `provider must be one of ${PROVIDERS.join(', ')}`);
  }
  return value as Provider;
}

/** Creates the user document on first launch (idempotent) and records the phone's timezone. */
export async function registerDevice(db: Firestore, uid: string, tz: unknown): Promise<{ generation: number }> {
  const zone = typeof tz === 'string' && tz.length <= 64 ? tz : null;
  const ref = db.collection('users').doc(uid);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists) {
      const user = snap.data() as UserDoc;
      if (user.deleting) throw new AccountError('failed-precondition', 'This account is being deleted.');
      if (zone && zone !== user.tz) tx.update(ref, { tz: zone });
      return { generation: user.generation };
    }
    const doc: UserDoc = { generation: 1, deleting: false, createdAt: Date.now(), lastVisibleAt: null, tz: zone, connections: {}, links: {} };
    tx.set(ref, doc);
    return { generation: 1 };
  });
}

/**
 * Creates a new secret connector link for a provider, revoking any previous one. The raw token
 * is returned once and never stored; the app keeps it in the Keychain.
 */
export async function createConnectorLink(db: Firestore, uid: string, provider: Provider, baseUrl: string): Promise<{ url: string }> {
  const token = generateToken();
  const hash = hashToken(token);
  const userRef = db.collection('users').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    if (!snap.exists) throw new AccountError('failed-precondition', 'Register the device first.');
    const user = snap.data() as UserDoc;
    if (user.deleting) throw new AccountError('failed-precondition', 'This account is being deleted.');
    const old = user.links?.[provider];
    if (old) tx.delete(db.collection('tokens').doc(old.tokenHash));
    tx.set(db.collection('tokens').doc(hash), { uid, provider, createdAt: Date.now() });
    // Recorded when the user gave per-provider consent in the app and requested the link.
    tx.update(userRef, { [`links.${provider}`]: { tokenHash: hash, createdAt: Date.now(), consentAt: Date.now() } });
  });
  log.info('link created', { uid, provider });
  return { url: `${baseUrl.replace(/\/$/, '')}/mcp/${token}` };
}

export async function disconnect(db: Firestore, uid: string, provider: Provider): Promise<void> {
  const userRef = db.collection('users').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    if (!snap.exists) return;
    const old = (snap.data() as UserDoc).links?.[provider];
    if (old) tx.delete(db.collection('tokens').doc(old.tokenHash));
    tx.update(userRef, { [`links.${provider}`]: FieldValue.delete(), [`connections.${provider}`]: FieldValue.delete(),
      [`oauthEpochs.${provider}`]: FieldValue.increment(1) });
  });
  log.info('disconnected', { uid, provider });
}

/**
 * Step 1 of deletion, synchronous: stop all access immediately. The data itself is removed by
 * `purgeUserData`, which runs as a retried background task.
 */
export async function beginDeletion(db: Firestore, uid: string): Promise<void> {
  const userRef = db.collection('users').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    if (!snap.exists) return;
    const user = snap.data() as UserDoc;
    for (const link of Object.values(user.links ?? {})) if (link) tx.delete(db.collection('tokens').doc(link.tokenHash));
    tx.update(userRef, { deleting: true, generation: user.generation + 1, links: {}, connections: {} });
  });
  log.info('deletion started', { uid });
}

export interface PurgeDeps {
  db: Firestore;
  incoming: BlobStore;
  data: BlobStore;
  deleteAuthUser: (uid: string) => Promise<void>;
}

/** Step 2 of deletion: remove every stored byte. Idempotent, safe to retry. */
export async function purgeUserData(deps: PurgeDeps, uid: string): Promise<void> {
  const { db } = deps;
  // Tokens pointing at this user, in case any were created concurrently.
  const tokens = await db.collection('tokens').where('uid', '==', uid).get();
  await Promise.all(tokens.docs.map((d) => d.ref.delete()));
  // OAuth credentials live outside the user's subtree and must not survive deletion.
  for (;;) {
    const credentials = await db.collection('oauthCredentials').where('uid', '==', uid).limit(400).get();
    if (credentials.empty) break;
    const batch = db.batch();
    credentials.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
  await deps.incoming.deletePrefix(`incoming/${uid}/`);
  await deps.data.deletePrefix(`data/${uid}/`);
  for (;;) {
    const logs = await db.collection('accessLog').where('uid', '==', uid).limit(400).get();
    if (logs.empty) break;
    const batch = db.batch();
    logs.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
  // Late uploads may have been written after the prefix delete; the user doc (deleting=true)
  // blocks new publishes, so delete it last.
  await db.recursiveDelete(db.collection('users').doc(uid));
  await deps.deleteAuthUser(uid).catch((err: { code?: string }) => {
    if (err.code !== 'auth/user-not-found') throw err;
  });
  log.info('user purged', { uid });
}

export interface Status {
  registered: boolean;
  deleting: boolean;
  /** Providers whose link has been used at least once ("Set up"). */
  setUp: Record<string, boolean>;
  /** When the most recent data became queryable by the AI (ms), or null. */
  lastVisibleAt: number | null;
  /** Earliest date the AI can see for types whose full history is synced (ms), or null. */
  historySyncedBackTo: number | null;
  /** Number of data types with queryable data. */
  typesWithData: number;
  /** Consent categories switched on. */
  categories: string[];
}

/** What the app shows on its home screen. Everything comes from server-side published state. */
export async function getStatus(db: Firestore, uid: string): Promise<Status> {
  const ref = db.collection('users').doc(uid);
  const [snap, types] = await Promise.all([ref.get(), ref.collection('types').select('coverage').get()]);
  if (!snap.exists) return { registered: false, deleting: false, setUp: {}, lastVisibleAt: null, historySyncedBackTo: null, typesWithData: 0, categories: DEFAULT_CATEGORIES };
  const user = snap.data() as UserDoc;
  let earliest: number | null = null;
  let withData = 0;
  for (const t of types.docs) {
    const cov = t.get('coverage') as { caughtUp?: boolean; earliest?: number | null } | undefined;
    if (cov?.earliest != null) withData++;
    if (cov?.caughtUp && cov.earliest != null) earliest = earliest === null ? cov.earliest : Math.min(earliest, cov.earliest);
  }
  return {
    registered: true,
    deleting: user.deleting,
    setUp: Object.fromEntries(PROVIDERS.map((p) => [p, !!user.connections?.[p]])),
    lastVisibleAt: user.lastVisibleAt ?? null,
    historySyncedBackTo: earliest,
    typesWithData: withData,
    categories: user.categories ?? DEFAULT_CATEGORIES,
  };
}

/**
 * Whether the server already has a batch: processed (any outcome) or still waiting in the incoming
 * bucket. Lets the phone tell "already uploaded" apart from a real rejection when Storage answers
 * `unauthorized` (its rules only allow creating an object once).
 */
export async function batchExists(deps: { meta: MetaStore; incoming: BlobStore }, uid: string, batchId: unknown): Promise<boolean> {
  if (typeof batchId !== 'string' || !/^[0-9a-f-]{36}$/.test(batchId)) throw new AccountError('invalid-argument', 'batchId must be a batch UUID.');
  if ((await deps.meta.batchState(uid, batchId)) !== null) return true;
  return deps.incoming.exists(`incoming/${uid}/${batchId}.ndjson.gz`);
}

/**
 * Finishes deletions that never completed: accounts marked `deleting` whose background purge did not
 * run (the task could not be queued, or kept failing). Purging is idempotent, so this is safe to run
 * repeatedly and alongside the normal purge task. One account failing does not stop the others.
 */
export async function sweepDeletions(deps: PurgeDeps, limit = 20): Promise<{ purged: number; failed: number }> {
  const snap = await deps.db.collection('users').where('deleting', '==', true).limit(limit).get();
  let purged = 0;
  let failed = 0;
  for (const doc of snap.docs) {
    try {
      await purgeUserData(deps, doc.id);
      purged++;
    } catch (err) {
      failed++;
      log.error('sweep purge failed', { uid: doc.id, code: (err as { code?: string }).code ?? 'internal' });
    }
  }
  return { purged, failed };
}

/** Validates a list of consent category ids; "core" is always on. */
export function parseCategories(value: unknown): string[] {
  if (!Array.isArray(value) || value.some((c) => typeof c !== 'string' || !CATEGORY_IDS.has(c))) {
    throw new AccountError('invalid-argument', `categories must be a list of: ${[...CATEGORY_IDS].join(', ')}`);
  }
  return [...new Set<string>(['core', ...(value as string[])])].sort();
}

/** Removes every stored byte and index entry of the types in one consent category. Idempotent. */
export async function purgeCategoryData(deps: { meta: MetaStore; data: BlobStore }, uid: string, category: string): Promise<void> {
  for (const t of COVERAGE.types) {
    if ((t.category ?? 'core') !== category) continue;
    await deps.data.deletePrefix(`data/${uid}/${t.id}/`);
    await deps.meta.deleteManifest(uid, t.id);
  }
}

/**
 * Stores which categories the user switched on. Data of a category that was switched off is deleted now
 * (the app re-sends it from the beginning if the category is switched on again).
 */
export async function setCategories(db: Firestore, deps: { meta: MetaStore; data: BlobStore }, uid: string, value: unknown): Promise<{ categories: string[]; removed: string[] }> {
  const next = parseCategories(value);
  const ref = db.collection('users').doc(uid);
  const previous = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new AccountError('failed-precondition', 'Register the device first.');
    const user = snap.data() as UserDoc;
    if (user.deleting) throw new AccountError('failed-precondition', 'This account is being deleted.');
    tx.update(ref, { categories: next });
    return user.categories ?? DEFAULT_CATEGORIES;
  });
  const removed = previous.filter((c) => !next.includes(c));
  for (const category of removed) await purgeCategoryData(deps, uid, category);
  log.info('categories set', { uid, categories: next.join(','), removed: removed.join(',') });
  return { categories: next, removed };
}
