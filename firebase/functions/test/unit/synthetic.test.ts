import { describe, expect, it } from 'vitest';
import { gzipSync } from 'node:zlib';
import { ingestObject } from '../../src/ingest/ingest.js';
import { getProfile, getSleep, getWorkouts, summarize } from '../../src/query/tools.js';
import { makeEnv, deps } from '../helpers/memory.js';
// The same generator seeds the deployed monitoring user and drives the real-AI evals.
// @ts-expect-error plain JS module outside the TS project
import { UID, TZ, batches, evalCases } from '../../../../scripts/synthetic/data.mjs';

describe('synthetic dataset: tools return the eval ground truth', () => {
  it('matches every expected answer', async () => {
    const env = makeEnv(Date.now());
    env.uid = UID;
    env.meta.addUser(UID, { tz: TZ });
    for (const lines of batches() as { batchId: string }[][]) {
      const path = `incoming/${UID}/${lines[0]!.batchId}.ndjson.gz`;
      await env.incoming.write(path, gzipSync(lines.map((l) => JSON.stringify(l)).join('\n')));
      expect(await ingestObject(path, { incoming: env.incoming, data: env.data, meta: env.meta })).toBe('published');
    }
    const d = deps(env, TZ);
    const cases = evalCases() as { expect: number[] }[];
    const steps = await summarize(d, { type: 'StepCount', start_date: '2024-03-01', end_date: '2024-03-31', period: 'none' });
    expect(steps.method).toBe('merged');
    expect((steps.rows as { value: number }[])[0]!.value).toBe(cases[0]!.expect[0]);
    const runs = await getWorkouts(d, { start_date: '2024-01-01', end_date: '2024-03-31', activity: 'running' });
    expect((runs.workouts as unknown[]).length).toBe(cases[1]!.expect[0]);
    expect(Math.round((runs.workouts as { distance_km: number }[]).reduce((a, w) => a + w.distance_km, 0))).toBe(cases[2]!.expect[0]);
    const rhr = await summarize(d, { type: 'RestingHeartRate', start_date: '2024-06-01', end_date: '2024-06-30', period: 'none' });
    expect(Math.round((rhr.rows as { value: number }[])[0]!.value * 10) / 10).toBe(cases[3]!.expect[0]);
    const sleep = await getSleep(d, { start_date: '2024-04-10', end_date: '2024-04-10' });
    expect((sleep.nights as { asleep_min: number }[])[0]!.asleep_min).toBe(cases[4]!.expect[0]);
    const profile = await getProfile(d);
    expect((profile.profile as { age: number }).age).toBe(cases[5]!.expect[0]);
  });
});
