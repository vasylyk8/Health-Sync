// IRREVERSIBLE: deletes every real account (Firebase Auth user, Firestore user tree, tokens, OAuth credentials,
// access log, stored data). The synthetic monitoring user and the directory reviewer account are always kept.
// Run through scripts/tasks/purge-all.sh.
//   npx tsx scripts/purge-all.ts plan    read-only report: what would be deleted and what is kept
//   npx tsx scripts/purge-all.ts run     delete the real accounts
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { GcsBlobs } from '../src/store/firestore.js';
import { dataBucketName, incomingBucketName } from '../src/config.js';
import { purgeUserData } from '../src/account.js';
import { FirestoreMeta } from '../src/store/firestore.js';
import { COVERAGE } from '../src/config.js';

const project = process.env.GCP_PROJECT_ID;
if (!project) throw new Error('GCP_PROJECT_ID is required');
const mode = process.argv[2];
if (mode !== 'plan' && mode !== 'run' && mode !== 'diag') throw new Error('usage: purge-all.ts plan|run|diag');

initializeApp({ projectId: project });
const db = getFirestore();
const auth = getAuth();
const storage = getStorage();
const incoming = new GcsBlobs(storage.bucket(incomingBucketName(project)) as never);
const data = new GcsBlobs(storage.bucket(dataBucketName(project)) as never);

const short = (uid: string) => `${uid.slice(0, 6)}…`;
/** The synthetic monitoring user and the review account are never touched. */
const SYNTHETIC_UID = 'synthetic-monitor';
const REVIEWER_UID = /^krok-reviewer-[A-Za-z0-9_-]{1,80}$/;

// Every account: Firestore user trees (including ones whose root doc is gone) and Auth users.
const uids = new Set<string>();
for (const ref of await db.collection('users').listDocuments()) uids.add(ref.id);
const authUsers: Record<string, string> = {};
const reviewerClaim = new Set<string>();
let page: string | undefined;
do {
  const res = await auth.listUsers(1000, page);
  for (const u of res.users) {
    uids.add(u.uid);
    authUsers[u.uid] = u.providerData.map((p) => p.providerId).join(',') || 'anonymous/none';
    if (u.customClaims?.krokReviewer === true) reviewerClaim.add(u.uid);
  }
  page = res.pageToken;
} while (page);

console.log(`project ${project}`);
console.log(`accounts found: ${uids.size}`);
const doomed: string[] = [];
for (const uid of [...uids].sort()) {
  const snap = await db.collection('users').doc(uid).get();
  const d = snap.data() as { createdAt?: number; deleting?: boolean; synthetic?: boolean; links?: Record<string, unknown> } | undefined;
  const keep = uid === SYNTHETIC_UID || REVIEWER_UID.test(uid) || reviewerClaim.has(uid) || d?.synthetic === true;
  if (!keep) doomed.push(uid);
  console.log(` - ${keep ? 'KEEP  ' : 'DELETE'} ${keep ? uid : short(uid)} auth[${authUsers[uid] ?? 'none'}] firestore[${snap.exists ? 'yes' : 'no'}] created ${d?.createdAt ? new Date(d.createdAt).toISOString() : '?'} links[${Object.keys(d?.links ?? {}).join(',') || 'none'}]${d?.deleting ? ' (deleting)' : ''}`);
}
console.log(`to delete: ${doomed.length} account(s); kept: ${uids.size - doomed.length}`);

if (mode === 'diag') {
  // Read-only: what the server holds per real account (counts and times only, no health values).
  const meta = new FirestoreMeta(db);
  const bucket = storage.bucket(incomingBucketName(project));
  for (const uid of [...uids].sort()) {
    if (uid === SYNTHETIC_UID || REVIEWER_UID.test(uid) || reviewerClaim.has(uid)) continue;
    const snap = await db.collection('users').doc(uid).get();
    if (!snap.exists) { console.log(`== ${short(uid)}: no user document`); continue; }
    const d = snap.data() as { categories?: string[]; links?: Record<string, unknown>; generation?: number };
    console.log(`== ${short(uid)} categories[${(d.categories ?? ['(defaults)']).join(',')}] links[${Object.keys(d.links ?? {}).join(',') || 'none'}]`);
    const [pending] = await bucket.getFiles({ prefix: `incoming/${uid}/`, maxResults: 1000 });
    console.log(`   incoming files still waiting: ${pending.length}`);
    for (const t of COVERAGE.types) {
      const m = await meta.getManifest(uid, t.id);
      if (!m) continue;
      const parts = Object.keys(m.files).filter((k) => !k.startsWith('_'));
      const iso = (n: number | null | undefined) => (n ? new Date(n).toISOString().slice(0, 10) : '-');
      console.log(`   ${t.id}: records ${m.records}, partitions ${parts.length} (${parts.sort()[0] ?? '-'}..${parts.sort().at(-1) ?? '-'}), earliest ${iso(m.coverage.earliest)}, latest ${iso(m.coverage.latest)}, checkedAt ${m.coverage.checkedAt ? new Date(m.coverage.checkedAt).toISOString() : '-'}`);
    }
  }
  process.exit(0);
}
if (mode === 'plan') {
  console.log('plan only: nothing was changed.');
  process.exit(0);
}

let failures = 0;
for (const uid of doomed) {
  try {
    await purgeUserData({ db, incoming, data, deleteAuthUser: (u) => auth.deleteUser(u) }, uid);
    console.log(`purged ${short(uid)}`);
  } catch (err) {
    failures++;
    console.error(`FAILED ${short(uid)}: ${(err as Error).message}`);
  }
}
console.log(`done. accounts left in Firestore: ${(await db.collection('users').listDocuments()).map((r) => r.id).join(', ') || 'none'}`);
if (failures) process.exit(1);
