import type { Firestore } from 'firebase-admin/firestore';
import { MILESTONE_FIELD, PRODUCT_EVENTS, type ProductEvent, type ProductEventName, type SyncOutcome } from './contract.js';
import type { UserDoc } from '../store/types.js';

const VERSION_RE = /^[0-9A-Za-z][0-9A-Za-z.+_-]{0,31}$/;
const OUTCOMES = new Set<SyncOutcome>(['success', 'error', 'offline']);
const EVENT_TTL_MS = 90 * 86_400_000;

export class AnalyticsEventError extends Error {
  constructor(readonly code: 'invalid-argument' | 'failed-precondition', message: string) { super(message); }
}

export interface ParsedProductEvent {
  name: ProductEventName;
  appVersion?: string;
  outcome?: SyncOutcome;
  durationMs?: number;
}

/** Strict allowlist: unknown keys are rejected so sensitive fields cannot sneak in later. */
export function parseProductEvent(value: unknown): ParsedProductEvent {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new AnalyticsEventError('invalid-argument', 'event must be an object.');
  const raw = value as Record<string, unknown>;
  const allowed = new Set(['name', 'appVersion', 'outcome', 'durationMs']);
  const unknown = Object.keys(raw).filter((k) => !allowed.has(k));
  if (unknown.length) throw new AnalyticsEventError('invalid-argument', `unsupported analytics field: ${unknown[0]}`);
  if (typeof raw.name !== 'string' || !(PRODUCT_EVENTS as readonly string[]).includes(raw.name)) {
    throw new AnalyticsEventError('invalid-argument', `name must be one of: ${PRODUCT_EVENTS.join(', ')}`);
  }
  const name = raw.name as ProductEventName;
  const appVersion = raw.appVersion === undefined ? undefined : raw.appVersion;
  if (appVersion !== undefined && (typeof appVersion !== 'string' || !VERSION_RE.test(appVersion))) {
    throw new AnalyticsEventError('invalid-argument', 'appVersion is invalid.');
  }
  if (name === 'sync_finished') {
    if (typeof raw.outcome !== 'string' || !OUTCOMES.has(raw.outcome as SyncOutcome)) {
      throw new AnalyticsEventError('invalid-argument', 'sync_finished requires a valid outcome.');
    }
    if (typeof raw.durationMs !== 'number' || !Number.isInteger(raw.durationMs) || raw.durationMs < 0 || raw.durationMs > 3_600_000) {
      throw new AnalyticsEventError('invalid-argument', 'sync_finished requires durationMs from 0 to 3600000.');
    }
    return { name, appVersion: appVersion as string | undefined, outcome: raw.outcome as SyncOutcome, durationMs: raw.durationMs };
  }
  if (raw.outcome !== undefined || raw.durationMs !== undefined) throw new AnalyticsEventError('invalid-argument', `${name} does not accept sync properties.`);
  return { name, appVersion: appVersion as string | undefined };
}

function emptyUser(now: number): UserDoc {
  return { generation: 1, deleting: false, createdAt: now, lastVisibleAt: null, tz: null, connections: {}, links: {} };
}

/** Records an app event and atomically sets its one-time milestone. */
export async function recordProductEvent(db: Firestore, uid: string, input: unknown, now = Date.now()): Promise<{ recorded: boolean }> {
  const parsed = parseProductEvent(input);
  const userRef = db.collection('users').doc(uid);
  const eventRef = db.collection('productEvents').doc();
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(userRef);
    const user = snap.exists ? (snap.data() as UserDoc) : emptyUser(now);
    if (user.deleting) throw new AnalyticsEventError('failed-precondition', 'This account is being deleted.');
    const milestone = MILESTONE_FIELD[parsed.name];
    const already = milestone ? (user.analytics as Record<string, unknown> | undefined)?.[milestone] !== undefined : false;
    const event: ProductEvent = { uid, name: parsed.name, at: now, expireAt: new Date(now + EVENT_TTL_MS),
      ...(parsed.appVersion ? { appVersion: parsed.appVersion } : {}),
      ...(parsed.outcome ? { outcome: parsed.outcome } : {}),
      ...(parsed.durationMs !== undefined ? { durationMs: parsed.durationMs } : {}) };
    // Repeated one-time events are no-ops. Sync attempts remain an event stream.
    if (already && parsed.name !== 'sync_finished') return { recorded: false };
    if (snap.exists) {
      const patch: Record<string, unknown> = {};
      if (milestone) patch[`analytics.${milestone}`] = now;
      if (parsed.appVersion && !user.analytics?.appVersion) patch['analytics.appVersion'] = parsed.appVersion;
      if (Object.keys(patch).length) tx.update(userRef, patch);
    } else {
      const analytics = { ...(milestone ? { [milestone]: now } : {}), ...(parsed.appVersion ? { appVersion: parsed.appVersion } : {}) };
      tx.set(userRef, { ...user, analytics });
    }
    tx.set(eventRef, event);
    return { recorded: true };
  });
}

/** Server-authoritative milestone; only sets the first occurrence. */
export async function setServerMilestone(db: Firestore, uid: string, field: 'firstSyncReadyAt' | 'assistantConnectedAt' | 'activatedAt', now: number, extra: Record<string, unknown> = {}): Promise<void> {
  const ref = db.collection('users').doc(uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get('deleting') === true || snap.get(`analytics.${field}`) !== undefined) return;
    tx.update(ref, { [`analytics.${field}`]: now, ...extra });
  });
}

export async function deleteProductEvents(db: Firestore, uid: string): Promise<void> {
  for (;;) {
    const snap = await db.collection('productEvents').where('uid', '==', uid).limit(400).get();
    if (snap.empty) return;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
  }
}
