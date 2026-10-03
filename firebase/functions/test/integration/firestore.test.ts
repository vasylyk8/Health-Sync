import { beforeEach, describe, expect, it } from 'vitest';
import { initializeApp, getApps } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { FirestoreMeta } from '../../src/store/firestore.js';
import { emptyManifest } from '../../src/store/types.js';
import { beginDeletion, createConnectorLink, disconnect, purgeUserData, registerDevice, setCategories, sweepDeletions } from '../../src/account.js';
import { FirestoreTokens, hashToken } from '../../src/auth/tokens.js';
import { DEFAULT_CATEGORIES } from '../../src/config.js';
import { DirBlobs } from '../helpers/memory.js';
import { KrokOAuth, DEFAULT_SCOPES, pkceChallenge } from '../../src/auth/oauth.js';
import { FirestoreOAuthStore } from '../../src/auth/oauth-store.js';
import { generateToken } from '../../src/auth/tokens.js';
import type { Response } from 'express';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { getAuth } from 'firebase-admin/auth';
import { recordProductEvent } from '../../src/analytics/events.js';
import { rebuildAnalyticsRollups } from '../../src/analytics/rollup.js';

if (!getApps().length) initializeApp({ projectId: 'demo-health-sync' });
const db = getFirestore();
const meta = new FirestoreMeta(db);

beforeEach(async () => {
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/demo-health-sync/databases/(default)/documents`, { method: 'DELETE' });
});

const add = (m: ReturnType<typeof emptyManifest>, path: string) => ({ ...m, version: m.version + 1, files: { ...m.files, '2024-06': [...(m.files['2024-06'] ?? []), { path, bytes: 1 }] } });

async function oauthCredentials() {
  await registerDevice(db, 'oauth-user', 'UTC');
  const oauth = new KrokOAuth(new FirestoreOAuthStore(db), 'https://krok.test');
  const callback = 'https://claude.ai/api/mcp/auth_callback';
  const client = await oauth.clientsStore.registerClient({ redirect_uris: [callback], token_endpoint_auth_method: 'none' });
  let cookie = '', request = '';
  await oauth.authorize(client, { redirectUri: callback, scopes: DEFAULT_SCOPES, codeChallenge: pkceChallenge(generateToken()), resource: new URL(oauth.resource) }, {
    cookie: (_key: string, value: string) => { cookie = value; },
    redirect: (_status: number, location: string) => { request = new URL(location).searchParams.get('request')!; },
  } as unknown as Response);
  const redirect = new URL(await oauth.finishConsent(request, cookie, 'oauth-user', true, false));
  const credentials = await oauth.exchangeAuthorizationCode(client, redirect.searchParams.get('code')!, undefined, callback, new URL(oauth.resource));
  return { oauth, client, credentials };
}

describe('OAuth on real Firestore transactions', () => {
  it('provisions a dedicated emulator reviewer and refuses to overwrite a non-synthetic account', async () => {
    const run = promisify(execFile);
    const uid = 'krok-reviewer-integration';
    const env = { ...process.env, GCP_PROJECT_ID: 'demo-health-sync', KROK_REVIEWER_UID: uid,
      KROK_REVIEWER_EMAIL: 'integration-reviewer@example.test', KROK_REVIEWER_PASSWORD: 'Emulator-only-reviewer-password-123' };
    await run(process.execPath, ['scripts/prepare-reviewer.mjs', '--apply'], { env });
    expect((await getAuth().getUser(uid)).customClaims?.krokReviewer).toBe(true);
    expect((await db.doc(`users/${uid}`).get()).get('synthetic')).toBe(true);
    await run(process.execPath, ['scripts/prepare-reviewer.mjs', '--apply'], { env });
    expect((await db.doc(`users/${uid}`).get()).get('oauthEpochs.claude')).toBe(1);
    const beforeReuse = (await getAuth().getUser(uid)).tokensValidAfterTime;
    await run(process.execPath, ['scripts/prepare-reviewer.mjs', '--apply', '--reuse', '--reseed'], { env });
    expect((await db.doc(`users/${uid}`).get()).get('oauthEpochs.claude')).toBe(1);
    expect((await getAuth().getUser(uid)).tokensValidAfterTime).toBe(beforeReuse);
    expect((await db.doc(`users/${uid}`).get()).get('categories')).toEqual(['core', 'devices', 'mind', 'nutrition', 'profile']);
    // Never convert an ordinary/customer account into a reviewer by accident.
    await db.doc(`users/${uid}`).update({ synthetic: false });
    await expect(run(process.execPath, ['scripts/prepare-reviewer.mjs', '--apply'], { env })).rejects.toThrow();
    await getAuth().deleteUser(uid);
  });
  it('persists omitted optional fields, hashed credentials and TTL timestamps', async () => {
    const { oauth, credentials } = await oauthCredentials();
    expect((await oauth.verifyAccessToken(credentials.access_token)).extra?.uid).toBe('oauth-user');
    const record = await db.doc(`oauthCredentials/${hashToken(credentials.access_token)}`).get();
    expect(record.get('expireAt').toMillis()).toBe(record.get('expires'));
    expect((await db.doc(`oauthCredentials/${credentials.access_token}`).get()).exists).toBe(false);
    expect((await db.collection('users/oauth-user/oauthGrants').get()).size).toBe(1);
  });
  it('atomically rotates refresh credentials and persists grant revocation on concurrent replay', async () => {
    const { oauth, client, credentials } = await oauthCredentials();
    const results = await Promise.allSettled([0, 1].map(() => oauth.exchangeRefreshToken(client, credentials.refresh_token!, undefined, new URL(oauth.resource))));
    expect(results.filter((result) => result.status === 'fulfilled')).toHaveLength(1);
    const winner = results.find((result) => result.status === 'fulfilled');
    if (winner?.status === 'fulfilled') await expect(oauth.verifyAccessToken(winner.value.access_token)).rejects.toThrow(/disconnected/);
  });
  it('disconnect invalidates OAuth even when there is no legacy link', async () => {
    const { oauth, credentials } = await oauthCredentials();
    await disconnect(db, 'oauth-user', 'claude');
    await expect(oauth.verifyAccessToken(credentials.access_token)).rejects.toThrow(/disconnected/);
  });
  it('deletion stops access immediately and removes credentials outside the user subtree', async () => {
    const { oauth, credentials } = await oauthCredentials();
    await db.doc('oauthCredentials/other-user-credential').set({ uid: 'other-user' });
    await beginDeletion(db, 'oauth-user');
    await expect(oauth.verifyAccessToken(credentials.access_token)).rejects.toThrow(/disconnected/);
    await purgeUserData({ db, incoming: new DirBlobs(), data: new DirBlobs(), deleteAuthUser: async () => undefined }, 'oauth-user');
    expect((await db.collection('oauthCredentials').where('uid', '==', 'oauth-user').get()).empty).toBe(true);
    expect((await db.collection('users/oauth-user/oauthGrants').get()).empty).toBe(true);
    expect((await db.doc('oauthCredentials/other-user-credential').get()).exists).toBe(true);
  });
});

describe('FirestoreMeta.publish', () => {
  it('publishes, rejects duplicates and discards after a deletion started', async () => {
    await registerDevice(db, 'u1', 'Europe/Berlin');
    const args = { uid: 'u1', type: 'HR', batchId: 'b1', generation: 1, mutate: (m: ReturnType<typeof emptyManifest>) => add(m, 'p1') };
    expect(await meta.publish(args)).toBe('published');
    expect(await meta.publish(args)).toBe('duplicate');
    expect(await meta.batchState('u1', 'b1')).toBe('published');
    await beginDeletion(db, 'u1');
    expect(await meta.publish({ ...args, batchId: 'b2', mutate: (m) => add(m, 'p2') })).toBe('discarded');
    expect((await meta.getManifest('u1', 'HR'))!.files['2024-06']).toHaveLength(1);
  });

  it('marks the first queryable publish as first-sync-ready exactly once', async () => {
    await registerDevice(db, 'analytics-sync', 'UTC');
    await meta.publish({ uid: 'analytics-sync', type: 'HR', batchId: 's1', generation: 1, mutate: (m) => add(m, 'p1'), userPatch: { lastVisibleAt: 1000 } });
    expect((await db.doc('users/analytics-sync').get()).get('analytics.firstSyncReadyAt')).toBe(1000);
    await meta.publish({ uid: 'analytics-sync', type: 'HR', batchId: 's2', generation: 1, mutate: (m) => add(m, 'p2'), userPatch: { lastVisibleAt: 2000 } });
    expect((await db.doc('users/analytics-sync').get()).get('analytics.firstSyncReadyAt')).toBe(1000);
  });

  it('round-trips coverage intervals (Firestore forbids nested arrays)', async () => {
    await registerDevice(db, 'u3', 'UTC');
    const mutate = (m: ReturnType<typeof emptyManifest>) => ({
      ...add(m, 'p1'),
      coverage: { ...m.coverage, intervals: [[0, 1000], [2000, 3000]] as [number, number][], statsIntervals: [[0, 5000]] as [number, number][], earliest: 1 },
    });
    expect(await meta.publish({ uid: 'u3', type: 'HR', batchId: 'b1', generation: 1, mutate })).toBe('published');
    const man = (await meta.getManifest('u3', 'HR'))!;
    expect(man.coverage.intervals).toEqual([[0, 1000], [2000, 3000]]);
    expect(man.coverage.statsIntervals).toEqual([[0, 5000]]);
    expect((await meta.listManifests('u3'))[0]!.coverage.intervals).toHaveLength(2);
  });

  it('handles concurrent publishes without losing files', async () => {
    await registerDevice(db, 'u2', 'UTC');
    await Promise.all(Array.from({ length: 8 }, (_, i) =>
      meta.publish({ uid: 'u2', type: 'HR', batchId: `b${i}`, generation: 1, mutate: (m) => add(m, `p${i}`) })));
    const man = (await meta.getManifest('u2', 'HR'))!;
    expect(man.files['2024-06']!.map((f) => f.path).sort()).toEqual(['p0', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7']);
    expect(man.version).toBe(8);
  });

  it('swaps compacted files while keeping files published meanwhile', async () => {
    await registerDevice(db, 'u3', 'UTC');
    for (const i of [1, 2, 3]) await meta.publish({ uid: 'u3', type: 'HR', batchId: `b${i}`, generation: 1, mutate: (m) => add(m, `p${i}`) });
    expect(await meta.swapFiles('u3', 'HR', '2024-06', ['p1', 'p2'], { path: 'merged', bytes: 2 })).toBe(true);
    expect(await meta.swapFiles('u3', 'HR', '2024-06', ['p1'], null)).toBe(false);
    expect((await meta.getManifest('u3', 'HR'))!.files['2024-06']!.map((f) => f.path)).toEqual(['p3', 'merged']);
  });
});

describe('accounts', () => {
  it('records allowlisted product events idempotently and rolls up identifier-free aggregates', async () => {
    const now = Date.UTC(2026, 8, 1, 12);
    expect(await recordProductEvent(db, 'analytics-user', { name: 'app_opened', appVersion: '1.0.0' }, now)).toEqual({ recorded: true });
    expect(await recordProductEvent(db, 'analytics-user', { name: 'app_opened', appVersion: '1.0.0' }, now + 1)).toEqual({ recorded: false });
    await recordProductEvent(db, 'analytics-user', { name: 'health_connect_started', appVersion: '1.0.0' }, now + 2);
    await recordProductEvent(db, 'analytics-user', { name: 'sync_finished', appVersion: '1.0.0', outcome: 'success', durationMs: 400 }, now + 3);
    const tokens = new FirestoreTokens(db);
    await tokens.touch('analytics-user', 'claude', now + 4);
    await tokens.record({ uid: 'analytics-user', provider: 'claude', tool: 'get_workouts', ok: true, ms: 20 });
    const user = await db.doc('users/analytics-user').get();
    expect(user.get('analytics')).toMatchObject({ firstOpenedAt: now, healthConnectStartedAt: now + 2, assistantConnectedAt: now + 4, activationProvider: 'claude' });
    expect((await db.collection('productEvents').where('uid', '==', 'analytics-user').get()).size).toBe(3);
    await rebuildAnalyticsRollups(db, now + 10, 1);
    const rollup = (await db.doc('analyticsRollups/2026-09-01').get()).data()!;
    expect(rollup).toMatchObject({ cohort: { steps: { first_opened: 1, health_connect_started: 1 } }, reliability: { syncAttempts: 1, syncSuccesses: 1 } });
    expect(JSON.stringify(rollup)).not.toContain('analytics-user');
  });

  it('rotates links, revoking the old token', async () => {
    await registerDevice(db, 'u4', 'UTC');
    const a = await createConnectorLink(db, 'u4', 'claude', 'https://x.web.app/');
    const b = await createConnectorLink(db, 'u4', 'claude', 'https://x.web.app');
    const tok = (u: string) => u.split('/mcp/')[1]!;
    expect(a.url).toMatch(/^https:\/\/x\.web\.app\/mcp\/[A-Za-z0-9_-]{43}$/);
    expect((await db.doc(`tokens/${hashToken(tok(a.url))}`).get()).exists).toBe(false);
    expect((await db.doc(`tokens/${hashToken(tok(b.url))}`).get()).data()).toMatchObject({ uid: 'u4', provider: 'claude' });
    await disconnect(db, 'u4', 'claude');
    expect((await db.doc(`tokens/${hashToken(tok(b.url))}`).get()).exists).toBe(false);
    expect((await db.doc('users/u4').get()).get('links.claude')).toBeUndefined();
  });

  it('registers an account that has no user document when a link is created', async () => {
    const { url } = await createConnectorLink(db, 'u-unregistered', 'claude', 'https://x.web.app');
    expect((await db.doc('users/u-unregistered').get()).data()).toMatchObject({ generation: 1, deleting: false });
    expect((await db.doc(`tokens/${hashToken(url.split('/mcp/')[1]!)}`).get()).data()).toMatchObject({ uid: 'u-unregistered', provider: 'claude' });
  });

  it('deletes everything and refuses new links while deleting', async () => {
    await registerDevice(db, 'u5', 'UTC');
    const { url } = await createConnectorLink(db, 'u5', 'chatgpt', 'https://x.web.app');
    await meta.publish({ uid: 'u5', type: 'HR', batchId: 'b1', generation: 1, mutate: (m) => add(m, 'p1') });
    await db.collection('accessLog').add({ uid: 'u5', tool: 't' });
    await recordProductEvent(db, 'u5', { name: 'app_opened', appVersion: '1.0.0' });
    await beginDeletion(db, 'u5');
    expect((await db.doc(`tokens/${hashToken(url.split('/mcp/')[1]!)}`).get()).exists).toBe(false);
    await expect(createConnectorLink(db, 'u5', 'claude', 'https://x')).rejects.toThrow(/being deleted/);
    const incoming = new DirBlobs();
    const data = new DirBlobs();
    await data.write('data/u5/HR/2024-06/p1.parquet', Buffer.from('x'));
    await data.write('data/u6/HR/2024-06/p1.parquet', Buffer.from('x'));
    const deleted: string[] = [];
    await purgeUserData({ db, incoming, data, deleteAuthUser: async (u) => void deleted.push(u) }, 'u5');
    expect([...data.paths]).toEqual(['data/u6/HR/2024-06/p1.parquet']);
    expect((await db.doc('users/u5').get()).exists).toBe(false);
    expect((await db.collection('users/u5/types').get()).empty).toBe(true);
    expect((await db.collection('accessLog').where('uid', '==', 'u5').get()).empty).toBe(true);
    expect((await db.collection('productEvents').where('uid', '==', 'u5').get()).empty).toBe(true);
    expect(deleted).toEqual(['u5']);
  });
});

describe('setCategories', () => {
  it('stores the choice (core is always on) and deletes the data of a category that was switched off', async () => {
    await registerDevice(db, 'u8', 'UTC');
    const data = new DirBlobs();
    const deps = { meta, data };
    // Every group except medications starts on, so choosing two switches the other defaults off (and deletes their data, none yet).
    expect(await setCategories(db, deps, 'u8', ['devices', 'nutrition'])).toEqual({ categories: ['core', 'devices', 'nutrition'], removed: ['heart', 'mind', 'cycle', 'profile'] });
    await meta.publish({ uid: 'u8', type: '_events_devices', batchId: 'g1', generation: 1, mutate: (m) => add(m, 'data/u8/_events_devices/2024-06/g1.parquet') });
    await meta.publish({ uid: 'u8', type: '_events_nutrition', batchId: 'n1', generation: 1, mutate: (m) => add(m, 'data/u8/_events_nutrition/2024-06/n1.parquet') });
    await data.write('data/u8/_events_devices/2024-06/g1.parquet', Buffer.from('x'));
    await data.write('data/u8/_events_nutrition/2024-06/n1.parquet', Buffer.from('x'));
    const out = await setCategories(db, deps, 'u8', ['nutrition']);
    expect(out).toEqual({ categories: ['core', 'nutrition'], removed: ['devices'] });
    expect([...data.paths]).toEqual(['data/u8/_events_nutrition/2024-06/n1.parquet']);
    expect(await meta.getManifest('u8', '_events_devices')).toBeNull();
    expect(await meta.getManifest('u8', '_events_nutrition')).not.toBeNull();
    expect((await db.doc('users/u8').get()).get('categories')).toEqual(['core', 'nutrition']);
    await expect(setCategories(db, deps, 'u8', ['bogus'])).rejects.toThrow(/categories must be/);
    await expect(setCategories(db, deps, 'nobody', [])).rejects.toThrow(/Register the device/);
  });
});

describe('sweepDeletions', () => {
  it('finishes accounts stuck in deleting and leaves others alone', async () => {
    await registerDevice(db, 'stuck1', 'UTC');
    await registerDevice(db, 'stuck2', 'UTC');
    await registerDevice(db, 'healthy', 'UTC');
    await beginDeletion(db, 'stuck1');
    await beginDeletion(db, 'stuck2');
    const incoming = new DirBlobs();
    const data = new DirBlobs();
    await data.write('data/stuck1/HR/2024-06/p1.parquet', Buffer.from('x'));
    await data.write('data/healthy/HR/2024-06/p1.parquet', Buffer.from('x'));
    const deleted: string[] = [];
    const res = await sweepDeletions({ db, incoming, data, deleteAuthUser: async (u) => void deleted.push(u) });
    expect(res).toEqual({ purged: 2, failed: 0 });
    expect(deleted.sort()).toEqual(['stuck1', 'stuck2']);
    expect((await db.doc('users/stuck1').get()).exists).toBe(false);
    expect((await db.doc('users/healthy').get()).exists).toBe(true);
    expect([...data.paths]).toEqual(['data/healthy/HR/2024-06/p1.parquet']);
    // Nothing left to do on the next run.
    expect(await sweepDeletions({ db, incoming, data, deleteAuthUser: async () => undefined })).toEqual({ purged: 0, failed: 0 });
  });

  it('keeps going when one account cannot be purged', async () => {
    await registerDevice(db, 'bad1', 'UTC');
    await registerDevice(db, 'good1', 'UTC');
    await beginDeletion(db, 'bad1');
    await beginDeletion(db, 'good1');
    const res = await sweepDeletions({
      db, incoming: new DirBlobs(), data: new DirBlobs(),
      deleteAuthUser: async (u) => { if (u === 'bad1') throw Object.assign(new Error('boom'), { code: 'auth/internal-error' }); },
    });
    expect(res).toEqual({ purged: 1, failed: 1 });
    expect((await db.doc('users/good1').get()).exists).toBe(false);
  });
});

describe('getStatus', () => {
  it('reports set-up providers and synced history from server state', async () => {
    const { getStatus } = await import('../../src/account.js');
    expect((await getStatus(db, 'nobody')).registered).toBe(false);
    await registerDevice(db, 'u7', 'UTC');
    await db.doc('users/u7').update({ 'connections.claude': { setUpAt: 1, lastUsedAt: 1 }, lastVisibleAt: 5 });
    await db.doc('users/u7/types/HR').set({ coverage: { caughtUp: true, earliest: 100 } });
    await db.doc('users/u7/types/Steps').set({ coverage: { caughtUp: false, earliest: 50 } });
    expect(await getStatus(db, 'u7')).toEqual({ registered: true, deleting: false, setUp: { claude: true, chatgpt: false }, lastVisibleAt: 5, historySyncedBackTo: 100, typesWithData: 2, categories: DEFAULT_CATEGORIES });
  });
});
