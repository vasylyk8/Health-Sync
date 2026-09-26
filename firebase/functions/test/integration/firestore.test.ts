import { beforeEach, describe, expect, it } from 'vitest';
import { initializeApp, getApps } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { FirestoreMeta } from '../../src/store/firestore.js';
import { emptyManifest } from '../../src/store/types.js';
import { beginDeletion, createConnectorLink, disconnect, purgeUserData, registerDevice } from '../../src/account.js';
import { hashToken } from '../../src/auth/tokens.js';
import { DirBlobs } from '../helpers/memory.js';

if (!getApps().length) initializeApp({ projectId: 'demo-health-sync' });
const db = getFirestore();
const meta = new FirestoreMeta(db);

beforeEach(async () => {
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/demo-health-sync/databases/(default)/documents`, { method: 'DELETE' });
});

const add = (m: ReturnType<typeof emptyManifest>, path: string) => ({ ...m, version: m.version + 1, files: { ...m.files, '2024-06': [...(m.files['2024-06'] ?? []), { path, bytes: 1 }] } });

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

  it('deletes everything and refuses new links while deleting', async () => {
    await registerDevice(db, 'u5', 'UTC');
    const { url } = await createConnectorLink(db, 'u5', 'chatgpt', 'https://x.web.app');
    await meta.publish({ uid: 'u5', type: 'HR', batchId: 'b1', generation: 1, mutate: (m) => add(m, 'p1') });
    await db.collection('accessLog').add({ uid: 'u5', tool: 't' });
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
    expect(deleted).toEqual(['u5']);
  });
});
