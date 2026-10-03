import { createHash, randomBytes } from 'node:crypto';
import type { Firestore } from 'firebase-admin/firestore';
import type { Provider } from '../config.js';

/** 32 random bytes, base64url: 43 characters, 256 bits. */
export const generateToken = () => randomBytes(32).toString('base64url');
export const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
/** Only this hash is ever stored; the raw token exists only in the user's app and AI settings. */
export const hashToken = (token: string) => createHash('sha256').update(token).digest('hex');

export interface TokenRecord {
  uid: string;
  provider: Provider;
  createdAt: number;
}

export interface TokenStore {
  resolve(hash: string): Promise<TokenRecord | null>;
}

export interface RateLimiter {
  /** Records one hit; returns false when `limit` hits in the current window were exceeded. */
  hit(key: string, limit: number, windowMs: number): Promise<boolean>;
}

export interface AccessLog {
  record(entry: { uid: string; provider: string; tool: string; ok: boolean; ms?: number }): Promise<void>;
}

export interface Connections {
  /** Marks the provider as set up (first use) and refreshes lastUsedAt at most every few minutes. */
  touch(uid: string, provider: Provider, now: number, previous?: { setUpAt: number; lastUsedAt: number }): Promise<void>;
}

export class FirestoreTokens implements TokenStore, RateLimiter, AccessLog, Connections {
  constructor(private readonly db: Firestore) {}

  async resolve(hash: string): Promise<TokenRecord | null> {
    const snap = await this.db.collection('tokens').doc(hash).get();
    return snap.exists ? (snap.data() as TokenRecord) : null;
  }

  async hit(key: string, limit: number, windowMs: number): Promise<boolean> {
    const window = Math.floor(Date.now() / windowMs);
    const ref = this.db.collection('rateLimits').doc(`${key}_${window}`);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const n = ((snap.get('n') as number | undefined) ?? 0) + 1;
      if (n > limit) return false;
      tx.set(ref, { n, expireAt: new Date((window + 2) * windowMs) });
      return true;
    });
  }

  async record(entry: { uid: string; provider: string; tool: string; ok: boolean; ms?: number }): Promise<void> {
    const now = Date.now();
    await this.db.collection('accessLog').add({ ...entry, at: now, expireAt: new Date(now + 90 * 86_400_000) });
    if (entry.ok) {
      const ref = this.db.collection('users').doc(entry.uid);
      await this.db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        if (!snap.exists || snap.get('deleting') === true || snap.get('analytics.activatedAt') !== undefined) return;
        tx.update(ref, { 'analytics.activatedAt': now, 'analytics.activationProvider': entry.provider });
      });
    }
  }

  async touch(uid: string, provider: Provider, now: number, previous?: { setUpAt: number; lastUsedAt: number }): Promise<void> {
    if (previous && now - previous.lastUsedAt < 5 * 60_000) return;
    const ref = this.db.collection('users').doc(uid);
    if (previous) {
      await ref.update({ [`connections.${provider}`]: { setUpAt: previous.setUpAt, lastUsedAt: now } });
      return;
    }
    await this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists || snap.get('deleting') === true) return;
      const existing = snap.get(`connections.${provider}`) as { setUpAt: number; lastUsedAt: number } | undefined;
      const patch: Record<string, unknown> = { [`connections.${provider}`]: { setUpAt: existing?.setUpAt ?? now, lastUsedAt: now } };
      if (snap.get('analytics.assistantConnectedAt') === undefined) patch['analytics.assistantConnectedAt'] = now;
      tx.update(ref, patch);
    });
  }
}
