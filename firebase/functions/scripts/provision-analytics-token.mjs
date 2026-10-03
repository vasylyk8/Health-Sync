import { createHash } from 'node:crypto';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const token = process.env.ANALYTICS_TOKEN;
const projectId = process.env.GCP_PROJECT_ID;
if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('ANALYTICS_TOKEN must be a 256-bit base64url token.');
if (!projectId) throw new Error('GCP_PROJECT_ID is required.');
initializeApp({ projectId });
const hash = createHash('sha256').update(token).digest('hex');
const ref = getFirestore().collection('analyticsTokens').doc(hash);
const snap = await ref.get();
if (!snap.exists) await ref.set({ createdAt: Date.now(), label: 'owner', version: 1 });
process.stdout.write('KROK Analytics operator token is provisioned (raw token not printed).\n');

