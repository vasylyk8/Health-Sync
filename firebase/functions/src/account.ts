import type { Firestore } from 'firebase-admin/firestore';
import { FieldValue } from 'firebase-admin/firestore';
import { PROVIDERS, type Provider } from './config.js';
import { generateToken, hashToken } from './auth/tokens.js';
import type { BlobStore, UserDoc } from './store/types.js';
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
    tx.update(userRef, { [`links.${provider}`]: FieldValue.delete(), [`connections.${provider}`]: FieldValue.delete() });
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
