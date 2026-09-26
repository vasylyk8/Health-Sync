// Cost of one typical background sync batch (a handful of new readings for one type).
import { gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import { ingestObject } from '../src/ingest/ingest.js';
import { makeEnv } from '../test/helpers/memory.js';
const env = makeEnv();
const N = 50;
const s = Date.now();
for (let i = 0; i < N; i++) {
  const batchId = randomUUID();
  const recs = Array.from({ length: 12 }, (_, j) => ({ k: 's', id: randomUUID(), s: env.now - j * 300_000, e: env.now - j * 300_000, v: 60, u: 'count/min' }));
  const gz = gzipSync([{ kind: 'header', schema: 1, batchId, type: 'HKQuantityTypeIdentifierHeartRate', seq: i + 1, createdAt: env.now, mode: 'anchored', caughtUp: true, checkedAt: env.now }, ...recs].map((r) => JSON.stringify(r)).join('\n'));
  const path = `incoming/${env.uid}/${batchId}.ndjson.gz`;
  await env.incoming.write(path, gz);
  await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
}
console.log(`small batch ingest: ${((Date.now() - s) / N).toFixed(0)} ms each (local, excluding network/Firestore latency)`);
