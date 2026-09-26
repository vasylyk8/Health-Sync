// Seeds (or refreshes) the synthetic monitoring user in the deployed project.
// Env: GCP_PROJECT_ID, SYNTHETIC_TOKEN (raw 43-char link token). Uses Application Default
// Credentials (GitHub OIDC). Run from firebase/functions (for firebase-admin).
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { UID, TZ, batches } from './data.mjs';

const project = process.env.GCP_PROJECT_ID;
const token = process.env.SYNTHETIC_TOKEN;
if (!project || !/^[A-Za-z0-9_-]{43}$/.test(token ?? '')) throw new Error('GCP_PROJECT_ID and SYNTHETIC_TOKEN required');
initializeApp({ projectId: project });
const db = getFirestore();
const hash = createHash('sha256').update(token).digest('hex');

const user = db.doc(`users/${UID}`);
if (!(await user.get()).exists) {
  await user.set({ generation: 1, deleting: false, createdAt: Date.now(), lastVisibleAt: null, tz: TZ, connections: {}, links: {}, synthetic: true });
}
await db.doc(`tokens/${hash}`).set({ uid: UID, provider: 'claude', createdAt: Date.now() });
await user.update({ 'links.claude': { tokenHash: hash, createdAt: Date.now() } });

// Only upload data once (or when FORCE_RESEED=1): ingestion dedupes by record id anyway.
const types = await user.collection('types').get();
if (types.empty || process.env.FORCE_RESEED === '1') {
  const bucket = getStorage().bucket(`${project}-incoming`);
  for (const lines of batches()) {
    const gz = gzipSync(lines.map((l) => JSON.stringify(l)).join('\n'));
    const sha256 = createHash('sha256').update(gz).digest('hex');
    await bucket.file(`incoming/${UID}/${lines[0].batchId}.ndjson.gz`).save(gz, { resumable: false, contentType: 'application/gzip', metadata: { metadata: { schema: '1', sha256 } } });
    console.log(`uploaded ${lines[0].type} (${lines.length - 1} records)`);
  }
} else {
  console.log('synthetic data already present');
}
