import { describe, expect, it } from 'vitest';
import { planLegacyCleanup, runLegacyCleanup } from '../../src/jobs/legacy.js';
import { getWorkouts } from '../../src/query/workouts.js';
import { DirBlobs, deps, makeEnv, upload, type Env } from '../helpers/memory.js';
import { seedRun } from '../helpers/workouts.js';
import { emptyManifest } from '../../src/store/types.js';

const HR = 'HKQuantityTypeIdentifierHeartRate';
const SLEEP = 'HKCategoryTypeIdentifierSleepAnalysis';

/** An account as the previous app version left it: 3 legacy types plus the kept ones. */
async function seedAccount(env: Env) {
  await seedRun(env);
  for (const type of [HR, SLEEP, '_profile']) {
    env.meta.manifests.set(`${env.uid}/${type}`, { ...emptyManifest(type), files: { '2024-06': [{ path: `data/${env.uid}/${type}/2024-06/a.parquet`, bytes: 10 }], _tombstones: [{ path: `data/${env.uid}/${type}/_tombstones/t.parquet`, bytes: 4 }] } });
    await env.data.write(`data/${env.uid}/${type}/2024-06/a.parquet`, Buffer.from('legacy-data-' + type));
    await env.data.write(`data/${env.uid}/${type}/_tombstones/t.parquet`, Buffer.from('tomb'));
  }
  // An orphan folder that has files but no index.
  await env.data.write(`data/${env.uid}/HKQuantityTypeIdentifierStepCount/_stats/2024/x.parquet`, Buffer.from('steps'));
}

const keptFiles = (env: Env) => [...env.data.paths].filter((p) => !/HKQuantity|HKCategory|_profile/.test(p));

describe('legacy data cleanup', () => {
  it('plans without changing anything and never lists workouts, daily or raw streams', async () => {
    const env = makeEnv();
    await seedAccount(env);
    const before = [...env.data.paths].sort();
    const plan = await planLegacyCleanup(env, env.uid);
    expect(plan.types.map((t) => t.type)).toEqual([HR, 'HKQuantityTypeIdentifierStepCount', SLEEP, '_profile'].sort());
    expect(plan.totalFiles).toBe(7);
    expect(plan.types.find((t) => t.type === HR)?.hasManifest).toBe(true);
    expect(plan.types.find((t) => t.type === 'HKQuantityTypeIdentifierStepCount')?.hasManifest).toBe(false);
    expect([...env.data.paths].sort()).toEqual(before);
    const dry = await runLegacyCleanup({ meta: env.meta, data: env.data }, env.uid, { dryRun: true });
    expect(dry.deletedFiles).toBe(0);
    expect([...env.data.paths].sort()).toEqual(before);
  });

  it('backs up, deletes only legacy data, and leaves workouts fully working', async () => {
    const env = makeEnv();
    await seedAccount(env);
    const kept = keptFiles(env).sort();
    expect(kept.length).toBeGreaterThan(3);
    const backup = new DirBlobs();
    const res = await runLegacyCleanup({ meta: env.meta, data: env.data, backup }, env.uid, { dryRun: false });
    expect(res).toMatchObject({ backedUp: 7, deletedFiles: 7, deletedManifests: 3 });
    // legacy is gone, the backup holds it, everything else is untouched
    expect([...env.data.paths].filter((p) => /HKQuantity|HKCategory|_profile/.test(p))).toEqual([]);
    expect(keptFiles(env).sort()).toEqual(kept);
    expect(await backup.read(`legacy/${env.uid}/${HR}/2024-06/a.parquet`)).toEqual(Buffer.from('legacy-data-' + HR));
    expect(JSON.parse((await backup.read(`legacy/${env.uid}/_manifests.json`)).toString())).toHaveLength(3);
    expect((await env.meta.listManifests(env.uid)).map((m) => m.type).sort()).toEqual(['HKWorkoutTypeIdentifier', '_daily']);
    // the workout and its raw data still answer
    const r = await getWorkouts(deps(env), { start_date: '2024-06-20', end_date: '2024-06-20' });
    expect((r.workouts as { raw_data: string }[])[0]?.raw_data).toBe('complete');
    expect(await env.meta.getWorkoutData(env.uid, '33333333-3333-4333-8333-333333333333')).not.toBeNull();
    // the account itself is untouched
    expect(env.meta.users.get(env.uid)?.deleting).toBe(false);
    // running again finds nothing to do
    expect((await planLegacyCleanup(env, env.uid)).types).toEqual([]);
  });

  it('refuses to delete without a backup store', async () => {
    const env = makeEnv();
    await seedAccount(env);
    await expect(runLegacyCleanup({ meta: env.meta, data: env.data }, env.uid, { dryRun: false })).rejects.toThrow(/backup/);
    expect((await planLegacyCleanup(env, env.uid)).totalFiles).toBe(7);
  });

  it('deletes nothing if a backup copy does not match', async () => {
    const env = makeEnv();
    await seedAccount(env);
    const flaky = new DirBlobs();
    const write = flaky.write.bind(flaky);
    flaky.write = async (path: string, data: Buffer) => write(path, path.endsWith('a.parquet') ? data.subarray(0, 3) : data);
    await expect(runLegacyCleanup({ meta: env.meta, data: env.data, backup: flaky }, env.uid, { dryRun: false })).rejects.toThrow(/does not match/);
    expect((await planLegacyCleanup(env, env.uid)).totalFiles).toBe(7);
    expect(await env.meta.getManifest(env.uid, HR)).not.toBeNull();
  });

  it('is a no-op for an account that is already clean', async () => {
    const env = makeEnv();
    await upload(env, { type: 'HKWorkoutTypeIdentifier', caughtUp: true }, [{ k: 'w', id: 'w1', s: env.now, e: env.now + 1000, act: 37 }]);
    const res = await runLegacyCleanup({ meta: env.meta, data: env.data, backup: new DirBlobs() }, env.uid, { dryRun: false });
    expect(res.plan.types).toEqual([]);
    expect(res.deletedFiles).toBe(0);
  });
});
