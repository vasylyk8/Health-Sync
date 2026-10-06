import { afterAll, beforeAll, describe, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { assertFails, assertSucceeds, initializeTestEnvironment, type RulesTestEnvironment } from '@firebase/rules-unit-testing';
import { collection, collectionGroup, deleteDoc, doc, getDoc, getDocs, setDoc, updateDoc } from 'firebase/firestore';
import { ref, uploadBytes, getBytes, deleteObject, listAll } from 'firebase/storage';

let env: RulesTestEnvironment;
const UUID = '0f8fad5b-d9cb-469f-a165-70867728950e';
const meta = (extra: Record<string, string> = {}) => ({ contentType: 'application/gzip', customMetadata: { schema: '1', sha256: 'a'.repeat(64), ...extra } });

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-health-sync',
    firestore: { rules: readFileSync('../firestore.rules', 'utf8'), host: '127.0.0.1', port: 8080 },
    storage: { rules: readFileSync('../storage.rules', 'utf8'), host: '127.0.0.1', port: 9199 },
  });
  await env.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users/alice'), { generation: 1 });
    await setDoc(doc(ctx.firestore(), 'users/alice/types/HR'), { version: 1 });
    await setDoc(doc(ctx.firestore(), 'tokens/abc'), { uid: 'alice' });
    await setDoc(doc(ctx.firestore(), 'users/bob'), { generation: 1 });
    await setDoc(doc(ctx.firestore(), 'users/bob/types/HR'), { version: 1 });
    for (const path of ['users/alice/batches/b1', 'users/alice/workouts/w1', 'accessLog/a1', 'rateLimits/r1', 'orphanBatches/alice_b1']) {
      await setDoc(doc(ctx.firestore(), path), { uid: 'alice' });
    }
  });
});
afterAll(() => env.cleanup());

describe('Firestore rules', () => {
  it('lets users read only their own status', async () => {
    const alice = env.authenticatedContext('alice').firestore();
    const bob = env.authenticatedContext('bob').firestore();
    await assertSucceeds(getDoc(doc(alice, 'users/alice')));
    await assertSucceeds(getDoc(doc(alice, 'users/alice/types/HR')));
    await assertFails(getDoc(doc(bob, 'users/alice')));
    await assertFails(getDoc(doc(bob, 'users/alice/types/HR')));
    await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'users/alice')));
  });

  it('allows no client writes and hides tokens', async () => {
    const alice = env.authenticatedContext('alice').firestore();
    await assertFails(setDoc(doc(alice, 'users/alice'), { generation: 99 }));
    await assertFails(setDoc(doc(alice, 'users/alice/types/HR'), { version: 99 }));
    await assertFails(getDoc(doc(alice, 'tokens/abc')));
    for (const path of ['oauthClients/abc', 'oauthRequests/abc', 'oauthCredentials/abc', 'users/alice/oauthGrants/abc',
      'analyticsTokens/abc', 'productEvents/abc', 'analyticsRollups/2026-09-01']) {
      await assertFails(getDoc(doc(alice, path)));
      await assertFails(setDoc(doc(alice, path), { uid: 'alice' }));
    }
  });

  it('refuses listing and collection-group queries that would reach other users', async () => {
    const alice = env.authenticatedContext('alice').firestore();
    await assertFails(getDocs(collection(alice, 'users')));
    await assertFails(getDocs(collection(alice, 'users/bob/types')));
    await assertFails(getDocs(collectionGroup(alice, 'types')));
    await assertFails(getDocs(collectionGroup(alice, 'batches')));
    await assertSucceeds(getDocs(collection(alice, 'users/alice/types')));
  });

  it('refuses updates and deletes of the user\'s own status', async () => {
    const alice = env.authenticatedContext('alice').firestore();
    await assertFails(updateDoc(doc(alice, 'users/alice'), { generation: 99 }));
    await assertFails(deleteDoc(doc(alice, 'users/alice')));
    await assertFails(deleteDoc(doc(alice, 'users/alice/types/HR')));
    await assertFails(setDoc(doc(alice, 'users/alice/types/NEW'), { version: 1 }));
  });

  it('keeps every other server-owned collection closed to reads and writes', async () => {
    const alice = env.authenticatedContext('alice').firestore();
    for (const path of ['users/alice/batches/b1', 'users/alice/workouts/w1', 'accessLog/a1', 'rateLimits/r1',
      'orphanBatches/alice_b1', 'anything-new/x', 'users/alice/anything-new/x']) {
      await assertFails(getDoc(doc(alice, path)));
      await assertFails(setDoc(doc(alice, path), { uid: 'alice' }));
      await assertFails(deleteDoc(doc(alice, path)));
    }
  });

  it('gives an unauthenticated caller nothing', async () => {
    const anon = env.unauthenticatedContext().firestore();
    for (const path of ['users/alice/types/HR', 'users/bob', 'tokens/abc']) await assertFails(getDoc(doc(anon, path)));
    await assertFails(setDoc(doc(anon, 'users/anon'), { generation: 1 }));
  });
});

describe('Storage rules', () => {
  const data = new Uint8Array([31, 139, 8, 0]);
  it('accepts a well-formed batch in the user\'s own folder', async () => {
    const s = env.authenticatedContext('alice').storage();
    await assertSucceeds(uploadBytes(ref(s, `incoming/alice/${UUID}.ndjson.gz`), data, meta()));
  });
  it.each([
    ['another user\'s folder', 'bob', `incoming/alice/${UUID}.ndjson.gz`, meta()],
    ['a bad file name', 'alice', 'incoming/alice/evil.parquet', meta()],
    ['a wrong content type', 'alice', `incoming/alice/${UUID}.ndjson.gz`, { ...meta(), contentType: 'text/plain' }],
    ['a missing checksum', 'alice', `incoming/alice/${UUID}.ndjson.gz`, { contentType: 'application/gzip', customMetadata: { schema: '1' } }],
    ['a path outside incoming', 'alice', `data/alice/${UUID}.ndjson.gz`, meta()],
  ])('rejects %s', async (_n, uid, path, m) => {
    await assertFails(uploadBytes(ref(env.authenticatedContext(uid).storage(), path), data, m));
  });
  it('rejects an empty batch, an oversized batch and a wrong schema or checksum shape', async () => {
    const s = env.authenticatedContext('alice').storage();
    const big = new Uint8Array(5 * 1024 * 1024 + 1);
    await assertFails(uploadBytes(ref(s, `incoming/alice/${UUID}.ndjson.gz`), new Uint8Array(0), meta()));
    await assertFails(uploadBytes(ref(s, `incoming/alice/${UUID}.ndjson.gz`), big, meta()));
    await assertFails(uploadBytes(ref(s, `incoming/alice/${UUID}.ndjson.gz`), data, meta({ schema: '2' })));
    await assertFails(uploadBytes(ref(s, `incoming/alice/${UUID}.ndjson.gz`), data, meta({ sha256: 'a'.repeat(63) })));
    await assertFails(uploadBytes(ref(s, `incoming/alice/${UUID}.ndjson.gz`), data, meta({ sha256: 'A'.repeat(64) })));
    await assertFails(uploadBytes(ref(s, `incoming/alice/${UUID.toUpperCase()}.ndjson.gz`), data, meta()));
  });
  it('accepts a batch of exactly the size limit', async () => {
    const s = env.authenticatedContext('alice').storage();
    await assertSucceeds(uploadBytes(ref(s, `incoming/alice/3f2504e0-4f89-41d3-9a0c-0305e82c3301.ndjson.gz`), new Uint8Array(5 * 1024 * 1024), meta()));
  });
  // Overwrites are not asserted: storage.rules only allows `create`, which Cloud Storage should treat as new-object-only,
  // but the emulator accepts a second upload to the same path, so it cannot confirm that. Check it against a real project.
  it('never allows an upload to be deleted or listed, or nested deeper', async () => {
    const s = env.authenticatedContext('alice').storage();
    const path = `incoming/alice/6ba7b810-9dad-11d1-80b4-00c04fd430c8.ndjson.gz`;
    await assertSucceeds(uploadBytes(ref(s, path), data, meta()));
    await assertFails(deleteObject(ref(s, path)));
    await assertFails(listAll(ref(s, 'incoming/alice')));
    await assertFails(uploadBytes(ref(s, `incoming/alice/sub/${UUID}.ndjson.gz`), data, meta()));
  });
  it('gives an unauthenticated caller nothing', async () => {
    const anon = env.unauthenticatedContext().storage();
    await assertFails(uploadBytes(ref(anon, `incoming/alice/${UUID}.ndjson.gz`), data, meta()));
    await assertFails(getBytes(ref(anon, `incoming/alice/${UUID}.ndjson.gz`)));
  });
  it('never allows reads', async () => {
    await assertFails(getBytes(ref(env.authenticatedContext('alice').storage(), `incoming/alice/${UUID}.ndjson.gz`)));
  });
});
