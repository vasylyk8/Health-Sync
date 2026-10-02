// Provision only after deployment/owner approval. Dry-run is the default.
// Passwords remain in environment variables, never files, logs or listing metadata.
import { gzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { UID as monitorUid, TZ, CATEGORIES, batches } from '../../../scripts/synthetic/data.mjs';

const project = process.env.GCP_PROJECT_ID;
const uid = process.env.KROK_REVIEWER_UID ?? 'krok-reviewer-directory';
const email = process.env.KROK_REVIEWER_EMAIL;
const password = process.env.KROK_REVIEWER_PASSWORD;
const apply = process.argv.includes('--apply');
const reuse = process.argv.includes('--reuse');
if (!['krok-1d60a', 'demo-health-sync'].includes(project)) throw new Error('Use the confirmed KROK project or the local demo-health-sync emulator.');
if (!/^krok-reviewer-[A-Za-z0-9_-]{1,80}$/.test(uid) || uid === monitorUid) throw new Error('A dedicated reviewer UID is required.');
if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || !password || password.length < 20) throw new Error('Provide reviewer email and a password of at least 20 characters through environment variables.');
const fixtures = batches();
if (!apply) {
  console.log(`Dry-run: prepare dedicated synthetic reviewer in ${project}, with ${fixtures.length} fixture batches. No cloud resources changed.`);
  process.exit(0);
}
initializeApp({ projectId: project });
const auth = getAuth(), db = getFirestore();
const ref = db.doc(`users/${uid}`);
const existingDoc = await ref.get();
let existingAuth;
try { existingAuth = await auth.getUser(uid); }
catch (error) { if (error.code !== 'auth/user-not-found') throw error; }
if ((existingDoc.exists && existingDoc.get('synthetic') !== true)
  || (existingAuth && (existingAuth.email !== email || existingAuth.customClaims?.krokReviewer !== true))) {
  throw new Error('Refusing to replace an account that is not the dedicated synthetic reviewer.');
}
if (existingDoc.get('deleting') === true) throw new Error('Reviewer account is being deleted; wait for cleanup before reprovisioning.');
if (reuse && existingAuth && existingDoc.exists) {
  console.log('Dedicated synthetic reviewer already exists; preserving password, grants and fixtures. Verification follows.');
  process.exit(0);
}
if (existingAuth) {
  await auth.updateUser(uid, { password, disabled: false });
  await auth.revokeRefreshTokens(uid);
} else {
  await auth.createUser({ uid, email, password });
}
await auth.setCustomUserClaims(uid, { ...(existingAuth?.customClaims ?? {}), krokReviewer: true });
if (!existingDoc.exists) {
  await ref.set({ generation: 1, deleting: false, createdAt: Date.now(), lastVisibleAt: null, tz: TZ,
    connections: {}, links: {}, categories: CATEGORIES, synthetic: true });
} else {
  // Password rotation must invalidate opaque MCP grants too, not only Firebase sessions.
  await ref.update({ 'oauthEpochs.claude': FieldValue.increment(1), 'oauthEpochs.chatgpt': FieldValue.increment(1), connections: {} });
}
const bucket = getStorage().bucket(`${project}-incoming`);
for (const lines of fixtures) {
  const gz = gzipSync(lines.map((line) => JSON.stringify(line)).join('\n'));
  const sha256 = createHash('sha256').update(gz).digest('hex');
  await bucket.file(`incoming/${uid}/${lines[0].batchId}.ndjson.gz`).save(gz, {
    resumable: false, contentType: 'application/gzip', metadata: { metadata: { schema: '1', sha256 } },
  });
}
console.log('Dedicated reviewer prepared with synthetic data. Wait for ingestion, verify OAuth and the review cases, then enter credentials only in secure review fields.');
