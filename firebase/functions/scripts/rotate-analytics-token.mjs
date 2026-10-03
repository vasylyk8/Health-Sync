import { createHash } from 'node:crypto';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const oldToken = process.env.ANALYTICS_OLD_TOKEN;
const newToken = process.env.ANALYTICS_TOKEN;
const projectId = process.env.GCP_PROJECT_ID;
for (const [name, value] of Object.entries({ ANALYTICS_OLD_TOKEN: oldToken, ANALYTICS_TOKEN: newToken })) {
  if (!value || !/^[A-Za-z0-9_-]{43}$/.test(value)) throw new Error(`${name} must be a 256-bit base64url token.`);
}
if (!projectId) throw new Error('GCP_PROJECT_ID is required.');
initializeApp({ projectId });
const hash = (value) => createHash('sha256').update(value).digest('hex');
const db = getFirestore(), now = Date.now();
await db.runTransaction(async (tx) => {
  tx.set(db.collection('analyticsTokens').doc(hash(newToken)), { createdAt: now, label: 'owner', version: 1 });
  tx.set(db.collection('analyticsTokens').doc(hash(oldToken)), { revokedAt: now }, { merge: true });
});
process.stdout.write('KROK Analytics token rotated; the old connector is revoked.\n');

