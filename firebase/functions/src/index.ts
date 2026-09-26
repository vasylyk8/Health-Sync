import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { getFunctions } from 'firebase-admin/functions';
import { getStorage } from 'firebase-admin/storage';
import { setGlobalOptions } from 'firebase-functions/v2';
import { defineBoolean, defineString } from 'firebase-functions/params';
import { HttpsError, onCall, onRequest, type CallableRequest } from 'firebase-functions/v2/https';
import { onObjectFinalized } from 'firebase-functions/v2/storage';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { onTaskDispatched } from 'firebase-functions/v2/tasks';
import { REGION, LIMITS } from './config.js';
import { FirestoreMeta, GcsBlobs } from './store/firestore.js';
import { FirestoreTokens } from './auth/tokens.js';
import { ingestObject } from './ingest/ingest.js';
import { compactType, finishReconcile } from './jobs/maintenance.js';
import { handleMcp } from './mcp/server.js';
import * as account from './account.js';
import { AccountError, beginDeletion, parseProvider, purgeUserData } from './account.js';
import { log } from './log.js';

// Values written to functions/.env by the deploy workflow (see scripts/tasks/deploy.sh).
const INCOMING_BUCKET = defineString('INCOMING_BUCKET');
const DATA_BUCKET = defineString('DATA_BUCKET');
const PUBLIC_BASE_URL = defineString('PUBLIC_BASE_URL');
const RUNTIME_SA = defineString('RUNTIME_SA');
const ENFORCE_APP_CHECK = defineBoolean('ENFORCE_APP_CHECK', { default: false });

initializeApp();
setGlobalOptions({ region: REGION, serviceAccount: RUNTIME_SA });

let cached: ReturnType<typeof makeDeps> | undefined;
function makeDeps() {
  const db = getFirestore();
  const storage = getStorage();
  const tokens = new FirestoreTokens(db);
  return {
    db,
    meta: new FirestoreMeta(db),
    incoming: new GcsBlobs(storage.bucket(INCOMING_BUCKET.value())),
    data: new GcsBlobs(storage.bucket(DATA_BUCKET.value())),
    tokens,
  };
}
const deps = () => (cached ??= makeDeps());

// ---- Ingestion ------------------------------------------------------------------------------

export const ingest = onObjectFinalized(
  { bucket: INCOMING_BUCKET, memory: '2GiB', cpu: 1, timeoutSeconds: 300, retry: true, maxInstances: 40, concurrency: 1 },
  async (event) => {
    const d = deps();
    await ingestObject(event.data.name, {
      incoming: d.incoming,
      data: d.data,
      meta: d.meta,
      onReconcileDone: (uid, type, rid) => finishReconcile(d, uid, type, rid).then(() => undefined),
    }, { sha256: event.data.metadata?.sha256 ?? '' });
  },
);

// ---- MCP connector --------------------------------------------------------------------------

export const mcp = onRequest(
  { memory: '2GiB', cpu: 1, timeoutSeconds: 60, concurrency: 4, maxInstances: 20, invoker: 'public' },
  async (req, res) => {
    const d = deps();
    try {
      await handleMcp(req, res, { tokens: d.tokens, limiter: d.tokens, accessLog: d.tokens, connections: d.tokens, meta: d.meta, data: d.data });
    } catch (err) {
      log.error('mcp request failed', { code: (err as { code?: string }).code ?? 'internal' });
      if (!res.headersSent) res.status(500).json({ error: 'internal' });
    }
  },
);

export const healthz = onRequest({ memory: '256MiB', invoker: 'public' }, (_req, res) => {
  res.set('Cache-Control', 'no-store').json({ ok: true, time: new Date().toISOString() });
});

// ---- App-facing actions (require Firebase Auth; App Check enforced once validated) -----------

function uidOf(req: CallableRequest): string {
  if (!req.auth?.uid) throw new HttpsError('unauthenticated', 'Sign-in required.');
  return req.auth.uid;
}

function wrap<T>(fn: (req: CallableRequest) => Promise<T>) {
  return async (req: CallableRequest) => {
    try {
      return await fn(req);
    } catch (err) {
      if (err instanceof AccountError) throw new HttpsError(err.code, err.message);
      throw err;
    }
  };
}

const callableOpts = { enforceAppCheck: ENFORCE_APP_CHECK, memory: '256MiB' as const };

export const registerDevice = onCall(callableOpts, wrap((req) => account.registerDevice(deps().db, uidOf(req), (req.data as { tz?: unknown })?.tz)));

export const createConnectorLink = onCall(callableOpts, wrap(async (req) => {
  const uid = uidOf(req);
  const provider = parseProvider((req.data as { provider?: unknown })?.provider);
  if (!(await deps().tokens.hit(`link_${uid}`, 20, 3_600_000))) throw new HttpsError('resource-exhausted', 'Too many new links. Try again later.');
  return account.createConnectorLink(deps().db, uid, provider, PUBLIC_BASE_URL.value());
}));

export const disconnectProvider = onCall(callableOpts, wrap(async (req) => {
  await account.disconnect(deps().db, uidOf(req), parseProvider((req.data as { provider?: unknown })?.provider));
  return { ok: true };
}));

export const deleteAllData = onCall(callableOpts, wrap(async (req) => {
  const uid = uidOf(req);
  await beginDeletion(deps().db, uid);
  await getFunctions().taskQueue(`locations/${REGION}/functions/purgeUserTask`).enqueue({ uid });
  return { ok: true };
}));

export const purgeUserTask = onTaskDispatched(
  { retryConfig: { maxAttempts: 50, minBackoffSeconds: 60, maxBackoffSeconds: 3600 }, rateLimits: { maxConcurrentDispatches: 5 }, memory: '512MiB', timeoutSeconds: 540 },
  async (req) => {
    const uid = (req.data as { uid?: unknown }).uid;
    if (typeof uid !== 'string' || !uid) return;
    const d = deps();
    await purgeUserData({ db: d.db, incoming: d.incoming, data: d.data, deleteAuthUser: (u) => getAuth().deleteUser(u) }, uid);
  },
);

// ---- Scheduled maintenance ------------------------------------------------------------------

export const purgeInactive = onSchedule({ schedule: 'every day 02:17', timeZone: 'UTC', memory: '512MiB', timeoutSeconds: 540 }, async () => {
  const d = deps();
  const cutoff = Date.now() - LIMITS.purgeAfterMs;
  const stale = await d.db.collection('users').where('lastVisibleAt', '<', cutoff).limit(500).get();
  const never = await d.db.collection('users').where('lastVisibleAt', '==', null).where('createdAt', '<', cutoff).limit(500).get();
  const queue = getFunctions().taskQueue(`locations/${REGION}/functions/purgeUserTask`);
  for (const doc of [...stale.docs, ...never.docs]) {
    if (doc.get('deleting') === true) continue;
    await beginDeletion(d.db, doc.id);
    await queue.enqueue({ uid: doc.id });
  }
  log.info('inactive purge scheduled', { job: 'purgeInactive', count: stale.size + never.size });
});

export const compactFragmented = onSchedule({ schedule: 'every 6 hours', timeZone: 'UTC', memory: '2GiB', timeoutSeconds: 540 }, async () => {
  const d = deps();
  const snap = await d.db.collectionGroup('types').where('fragmented', '==', true).limit(100).get();
  let n = 0;
  for (const doc of snap.docs) {
    const uid = doc.ref.parent.parent?.id;
    if (!uid) continue;
    n += await compactType(d, uid, doc.get('type') as string).catch(() => 0);
  }
  log.info('compaction run', { job: 'compactFragmented', count: n });
});
