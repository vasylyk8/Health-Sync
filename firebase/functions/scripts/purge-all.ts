// IRREVERSIBLE: deletes every account (Firebase Auth user, Firestore user tree, tokens, OAuth credentials,
// access log) and every stored byte (incoming and data buckets). Run through scripts/tasks/purge-all.sh.
//   npx tsx scripts/purge-all.ts plan    read-only report: what exists, nothing is changed
//   npx tsx scripts/purge-all.ts run     delete everything
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { GcsBlobs } from '../src/store/firestore.js';
import { dataBucketName, incomingBucketName } from '../src/config.js';
import { purgeUserData } from '../src/account.js';

const project = process.env.GCP_PROJECT_ID;
if (!project) throw new Error('GCP_PROJECT_ID is required');
const mode = process.argv[2];
if (mode !== 'plan' && mode !== 'run') throw new Error('usage: purge-all.ts plan|run');

initializeApp({ projectId: project });
const db = getFirestore();
const auth = getAuth();
const storage = getStorage();
const incoming = new GcsBlobs(storage.bucket(incomingBucketName(project)) as never);
const data = new GcsBlobs(storage.bucket(dataBucketName(project)) as never);

const short = (uid: string) => `${uid.slice(0, 6)}…`;

// Every account: Firestore user trees (including ones whose root doc is gone) and Auth users.
const uids = new Set<string>();
for (const ref of await db.collection('users').listDocuments()) uids.add(ref.id);
const authUsers: Record<string, string> = {};
let page: string | undefined;
do {
  const res = await auth.listUsers(1000, page);
  for (const u of res.users) {
    uids.add(u.uid);
    authUsers[u.uid] = u.providerData.map((p) => p.providerId).join(',') || 'anonymous/none';
  }
  page = res.pageToken;
} while (page);

const count = async (name: string) => (await db.collection(name).count().get()).data().count;
console.log(`project ${project}`);
console.log(`accounts: ${uids.size}`);
for (const uid of [...uids].sort()) {
  const snap = await db.collection('users').doc(uid).get();
  const d = snap.data() as { createdAt?: number; deleting?: boolean; links?: Record<string, unknown> } | undefined;
  console.log(` - ${short(uid)} auth[${authUsers[uid] ?? 'none'}] firestore[${snap.exists ? 'yes' : 'no'}] created ${d?.createdAt ? new Date(d.createdAt).toISOString() : '?'} links[${Object.keys(d?.links ?? {}).join(',') || 'none'}]${d?.deleting ? ' (deleting)' : ''}`);
}
console.log(`tokens: ${await count('tokens')}, oauthCredentials: ${await count('oauthCredentials')}, accessLog: ${await count('accessLog')}`);
if (mode === 'plan') {
  console.log('plan only: nothing was changed.');
  process.exit(0);
}

let failures = 0;
for (const uid of uids) {
  try {
    await purgeUserData({ db, incoming, data, deleteAuthUser: (u) => auth.deleteUser(u) }, uid);
    console.log(`purged ${short(uid)}`);
  } catch (err) {
    failures++;
    console.error(`FAILED ${short(uid)}: ${(err as Error).message}`);
  }
}
// Anything left that no account owns (orphans), then the derived collections.
await incoming.deletePrefix('incoming/');
await data.deletePrefix('data/');
for (const name of ['tokens', 'oauthCredentials', 'accessLog']) await db.recursiveDelete(db.collection(name));
console.log(`done. accounts left in Firestore: ${(await db.collection('users').listDocuments()).length}`);
if (failures) process.exit(1);
