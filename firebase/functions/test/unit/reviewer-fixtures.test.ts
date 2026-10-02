import { gzipSync } from 'node:zlib';
import { expect, it } from 'vitest';
// @ts-expect-error plain JS module shared with provisioning scripts
import { reviewerBatches, REVIEWER_CATEGORIES } from '../../../../scripts/synthetic/reviewer.mjs';
import { ingestObject } from '../../src/ingest/ingest.js';
import { getNutritionLog, getProfile } from '../../src/query/health.js';
import { deps, makeEnv } from '../helpers/memory.js';

it('ingests reviewer nutrition and profile fixtures through the real parser and queries', async () => {
  const env = makeEnv(Date.UTC(2026, 9, 2));
  env.meta.users.get(env.uid)!.categories = REVIEWER_CATEGORIES;
  for (const lines of (reviewerBatches() as { batchId?: string; type?: string }[][]).slice(-2)) {
    const object = `incoming/${env.uid}/${lines[0]!.batchId}.ndjson.gz`;
    await env.incoming.write(object, gzipSync(lines.map((line) => JSON.stringify(line)).join('\n')));
    expect(await ingestObject(object, { incoming: env.incoming, data: env.data, meta: env.meta, now: () => env.now })).toBe('published');
  }
  const nutrition = await getNutritionLog(deps(env, 'Europe/Berlin'), { start_date: '2024-03-01', end_date: '2024-03-07' });
  expect(nutrition.count).toBe(7);
  expect((nutrition.entries as Record<string, unknown>[])[0]).toMatchObject({ 'EnergyConsumed (kcal)': 600, 'Protein (g)': 30 });
  const profile = await getProfile(deps(env, 'Europe/Berlin'));
  expect(profile.profile).toMatchObject({ dob: '1990-05-01', age_years: 36, sex: 'male', wheelchair: false });
});
