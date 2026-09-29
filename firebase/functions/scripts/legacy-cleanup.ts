// One-off: removes the Health data types the app no longer syncs (everything except workouts,
// daily context and raw workout streams). Run through scripts/tasks/cleanup-legacy*.sh.
//   npx tsx scripts/legacy-cleanup.ts plan     read-only report
//   npx tsx scripts/legacy-cleanup.ts run      back up, delete, verify
import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { GcsBlobs, FirestoreMeta } from '../src/store/firestore.js';
import { dataBucketName } from '../src/config.js';
import { runLegacyCleanup } from '../src/jobs/legacy.js';

const project = process.env.GCP_PROJECT_ID;
if (!project) throw new Error('GCP_PROJECT_ID is required');
const mode = process.argv[2];
if (mode !== 'plan' && mode !== 'run') throw new Error('usage: legacy-cleanup.ts plan|run');

initializeApp({ projectId: project });
const db = getFirestore();
const storage = getStorage();
const meta = new FirestoreMeta(db);
const data = new GcsBlobs(storage.bucket(dataBucketName(project)) as never);
const backup = new GcsBlobs(storage.bucket(`${project}-legacy-backup`) as never);

const users = await db.collection('users').listDocuments();
let failures = 0;
for (const ref of users) {
  const user = await meta.getUser(ref.id);
  if (!user || user.deleting) continue;
  try {
    const res = await runLegacyCleanup({ meta, data, backup }, ref.id, { dryRun: mode === 'plan' });
    console.log(`user ${ref.id.slice(0, 6)}…: ${res.plan.types.length} legacy type(s), ${res.plan.totalFiles} file(s)`);
    for (const t of res.plan.types) console.log(`  ${t.type}: ${t.files.length} file(s)${t.hasManifest ? ', has index' : ''}`);
    if (mode === 'run') console.log(`  backed up ${res.backedUp}, deleted ${res.deletedFiles} file(s) and ${res.deletedManifests} index doc(s)`);
  } catch (err) {
    failures++;
    console.error(`user ${ref.id.slice(0, 6)}…: FAILED: ${(err as Error).message}`);
  }
}
if (failures) process.exit(1);
