// Stored size of the small data types with the synthetic user (one year of hourly series, a month of 5-minute glucose,
// headache entries and daily rows), to size them for a longer history.
//   npx tsx bench/small-types.ts
import { gzipSync } from 'node:zlib';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
// @ts-expect-error plain JS module shared with the monitoring scripts
import { batches, CATEGORIES } from '../../../scripts/synthetic/data.mjs';
import { ingestObject } from '../src/ingest/ingest.js';
import { makeEnv } from '../test/helpers/memory.js';

const env = makeEnv(Date.now());
env.meta.users.get(env.uid)!.categories = CATEGORIES;
const upload: Record<string, number> = {};
for (const lines of batches() as { batchId?: string; type?: string }[][]) {
  const type = lines[0]!.type!;
  if (type === 'HKWorkoutTypeIdentifier' || type === '_wstream') continue;
  const gz = gzipSync(lines.map((l) => JSON.stringify(l)).join('\n'));
  const path = `incoming/${env.uid}/${lines[0]!.batchId}.ndjson.gz`;
  await env.incoming.write(path, gz);
  const r = await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now });
  if (r !== 'published') throw new Error(`${type}: ${r}`);
  upload[type] = (upload[type] ?? 0) + gz.byteLength;
}
const stored: Record<string, number> = {};
for (const p of env.data.paths) {
  const type = p.split('/')[2]!;
  stored[type] = (stored[type] ?? 0) + (await stat(join(env.data.root, p))).size;
}
for (const t of Object.keys(upload)) console.log(`${t.padEnd(18)} upload ${(upload[t]! / 1024).toFixed(1)} KB (plain JSON), stored ${((stored[t] ?? 0) / 1024).toFixed(1)} KB`);
