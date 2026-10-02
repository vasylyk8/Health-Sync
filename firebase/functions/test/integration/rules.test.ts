import { afterAll, beforeAll, describe, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { assertFails, assertSucceeds, initializeTestEnvironment, type RulesTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc } from 'firebase/firestore';
import { ref, uploadBytes, getBytes } from 'firebase/storage';

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
    for (const path of ['oauthClients/abc', 'oauthRequests/abc', 'oauthCredentials/abc', 'users/alice/oauthGrants/abc']) {
      await assertFails(getDoc(doc(alice, path)));
      await assertFails(setDoc(doc(alice, path), { uid: 'alice' }));
    }
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
  it('never allows reads', async () => {
    await assertFails(getBytes(ref(env.authenticatedContext('alice').storage(), `incoming/alice/${UUID}.ndjson.gz`)));
  });
});
